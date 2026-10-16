<#
.SYNOPSIS
  Pester tests for Get-UpdatePlan (Phase P1). Fixtures and mocks only - the planner
  never touches the filesystem, and these tests never touch the real installations.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftInstall.psm1' -Force

$Script:P1Roots = @()

function New-P1Fixture {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP1-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:P1Roots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-P1Candidate {
    param([hashtable]$Entries, [string]$Sha = ('c' * 64))
    $list = @()
    foreach ($rel in $Entries.Keys) {
        $list += [PSCustomObject]@{ Path = $rel; Length = 1; Sha256 = $Entries[$rel] }
    }
    return [PSCustomObject]@{ ArchivePath = 'mock.zip'; ArchiveSha256 = $Sha; Entries = $list }
}

function New-P1Evidence {
    return @{ GuiVersion = '1.2.3'; GuiSource = 'PE'; CliVersion = '1.2.3'; CliSource = 'Stdout'; SignaturesValid = $true }
}

function Get-P1Action {
    param($Plan, [string]$Path)
    return @($Plan.Actions | Where-Object { $_.Path -eq $Path })
}

Describe 'ArtCraftInstall P1 planner basics' {
    It 'proposes Create for new release files and Replace for changed ones' {
        $root = New-P1Fixture @{ 'app.exe' = 'old-bytes' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $oldHash = ($inv.Files | Where-Object { $_.Path -eq 'app.exe' }).Sha256
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64); 'top/new.dll' = ('e' * 64) }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $true
        @(Get-P1Action $plan 'app.exe').Action | Should Be 'Replace'
        @(Get-P1Action $plan 'app.exe').EligibleForExecution | Should Be $true
        @(Get-P1Action $plan 'new.dll').Action | Should Be 'Create'
        @(Get-P1Action $plan 'new.dll').EligibleForExecution | Should Be $true
    }
    It 'preserves identical files instead of replacing them' {
        $root = New-P1Fixture @{ 'same.dll' = 'identical' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $h = ($inv.Files | Where-Object { $_.Path -eq 'same.dll' }).Sha256
        $cand = New-P1Candidate @{ 'top/same.dll' = $h }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        @(Get-P1Action $plan 'same.dll').Action | Should Be 'Preserve'
    }
    It 'flags obsolete release files as RemoveCandidate, never automatic' {
        $root = New-P1Fixture @{ 'app.exe' = 'x'; 'legacy.dll' = 'old' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $hist = @([PSCustomObject]@{ Path = 'legacy.dll'; Sha256 = $null })
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -HistoricalReleaseFiles $hist `
            -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $a = @(Get-P1Action $plan 'legacy.dll')
        $a.Action | Should Be 'RemoveCandidate'
        $a.RequiresApproval | Should Be $true
        $a.EligibleForExecution | Should Be $false
    }
    It 'preserves unevidenced files instead of assuming they are obsolete' {
        $root = New-P1Fixture @{ 'app.exe' = 'x'; 'mystery.dat' = '?' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $a = @(Get-P1Action $plan 'mystery.dat')
        $a.Action | Should Be 'Preserve'
        $a.RequiresReview | Should Be $true
    }
}

Describe 'ArtCraftInstall P1 protection rules' {
    It 'preserves user data and agent documentation' {
        $root = New-P1Fixture @{ 'PhotoCraftData/preferences.json' = '{}'; 'SKILL.md' = 'x'; 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        @(Get-P1Action $plan 'PhotoCraftData/preferences.json').Action | Should Be 'Preserve'
        @(Get-P1Action $plan 'SKILL.md').Action | Should Be 'Preserve'
        ($plan.ProtectedPaths -contains 'PhotoCraftData/preferences.json') | Should Be $true
        ($plan.ProtectedPaths -contains 'SKILL.md') | Should Be $true
    }
    It 'protects user projects regardless of their names' {
        $root = New-P1Fixture @{ 'sample-test.fcproj' = 'x'; 'weird name (2).ecproj' = 'y'; 'app.exe' = 'z' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $plan = Get-UpdatePlan -AppId filmcraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        @(Get-P1Action $plan 'sample-test.fcproj').Action | Should Be 'Preserve'
        @(Get-P1Action $plan 'weird name (2).ecproj').Action | Should Be 'Preserve'
    }
    It 'requires provenance evidence before proposing quarantine' {
        $root = New-P1Fixture @{ 'scratch.tmp' = 'x'; 'app.exe' = 'y' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $plain = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        @(Get-P1Action $plain 'scratch.tmp').Action | Should Be 'Preserve'
        $prov = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -ProvenancePaths @('scratch.tmp') -Timestamp '20260101-000000' `
            -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $a = @(Get-P1Action $prov 'scratch.tmp')
        $a.Action | Should Be 'QuarantineCandidate'
        $a.RequiresApproval | Should Be $true
        $a.EligibleForExecution | Should Be $false
        $prov.Quarantine.Count | Should Be 1
        $prov.Quarantine[0].Destination | Should Be '.quarantine/photocraft/20260101-000000/scratch.tmp'
        $prov.Quarantine[0].Retention | Should Match '30 days'
    }
    It 'reports candidate collisions with protected user data as conflicts' {
        $root = New-P1Fixture @{ 'diary.txt' = 'x' }
        New-Item -ItemType Directory -Path (Join-Path $root 'data') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'data\prefs.json') -Value '{}' -NoNewline
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/data/prefs.json' = ('d' * 64); 'top/data/stowaway.bin' = ('e' * 64) }
        $plan = Get-UpdatePlan -AppId filmcraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        @(Get-P1Action $plan 'data/prefs.json').Action | Should Be 'Conflict'
        @(Get-P1Action $plan 'data/stowaway.bin').Action | Should Be 'Conflict'
        @(Get-P1Action $plan 'data/prefs.json').EligibleForExecution | Should Be $false
    }
}

Describe 'ArtCraftInstall P1 portable markers' {
    It 'does not restore a user-removed marker' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64); 'top/portable.txt' = ('e' * 64) }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $false; MarkerName = $null; MarkerIsFile = $false; Path = $null })
        $a = @(Get-P1Action $plan 'portable.txt')
        $a.Action | Should Be 'Preserve'
        ($a.Action -eq 'Create') | Should Be $false
        $a.RequiresReview | Should Be $true
    }
    It 'distinguishes marker files from marker-named directories' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $fileState = [PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt'; MarkerIsFile = $true; Path = 'x' }
        $dirState = [PSCustomObject]@{ Present = $false; MarkerName = 'portable.txt'; MarkerIsFile = $false; Path = 'x'; Note = 'a directory with the marker name is not a marker' }
        $pFile = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState $fileState
        $pDir = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState $dirState
        ($pFile.Notes -join ';') | Should Match 'as a file'
        ($pDir.Notes -join ';') | Should Match 'not a marker'
    }
}

Describe 'ArtCraftInstall P1 verification gates' {
    It 'blocks eligibility on archive hash failure' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) } -Sha ('9' * 64)
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $false
        ($plan.Blockers -join ';') | Should Match 'SHA-256 mismatch'
    }
    It 'blocks eligibility on unsafe ZIP paths' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = [PSCustomObject]@{
            ArchivePath = 'mock.zip'; ArchiveSha256 = ('c' * 64)
            Entries = @(
                [PSCustomObject]@{ Path = 'top/app.exe'; Length = 1 },
                [PSCustomObject]@{ Path = 'top/../../evil.exe'; Length = 1 }
            )
        }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $false
        ($plan.Blockers -join ';') | Should Match 'unsafe candidate ZIP path'
        $abs = [PSCustomObject]@{
            ArchivePath = 'mock.zip'; ArchiveSha256 = ('c' * 64)
            Entries = @([PSCustomObject]@{ Path = 'C:/abs/evil.exe'; Length = 1 })
        }
        $plan2 = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $abs `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan2.Eligible | Should Be $false
    }
    It 'detects duplicate normalized candidate paths' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = [PSCustomObject]@{
            ArchivePath = 'mock.zip'; ArchiveSha256 = ('c' * 64)
            Entries = @(
                [PSCustomObject]@{ Path = 'top/sub/a.dll'; Length = 1 },
                [PSCustomObject]@{ Path = 'top\sub\a.dll'; Length = 1 }
            )
        }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $false
        ($plan.Blockers -join ';') | Should Match 'duplicate normalized candidate path'
    }
    It 'blocks on GUI/CLI version disagreement' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $ev = New-P1Evidence; $ev.CliVersion = '9.9.8'
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence $ev -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $false
        ($plan.Blockers -join ';') | Should Match 'disagreement'
    }
    It 'accepts a CLI without PE metadata via the runtime interface' {
        $root = New-P1Fixture @{ 'app.exe' = 'x' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $ev = @{ GuiVersion = '1.2.3'; GuiSource = 'PE'; CliVersion = '1.2.3'; CliSource = 'Stdout'; SignaturesValid = $true }
        $plan = Get-UpdatePlan -AppId filmcraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence $ev -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $true
        $plan.VersionEvidenceOk | Should Be $true
    }
    It 'produces a conservative plan for an invalid manifest' {
        $root = New-P1Fixture @{ 'app.exe' = 'x'; 'legacy.dll' = 'old' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64) }
        $hist = @([PSCustomObject]@{ Path = 'legacy.dll'; Sha256 = $null })
        $badManifest = [PSCustomObject]@{ schemaVersion = 99; appId = 'nope'; version = ''; files = $null }
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -ExistingManifest $badManifest -HistoricalReleaseFiles $hist `
            -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $plan.Eligible | Should Be $false
        ($plan.Blockers -join ';') | Should Match 'manifest is invalid'
        @(Get-P1Action $plan 'legacy.dll').Action | Should Be 'Preserve'
    }
}

Describe 'ArtCraftInstall P1 determinism and purity' {
    It 'produces identical plans regardless of input order' {
        $root = New-P1Fixture @{ 'b.dll' = 'b'; 'a.exe' = 'a'; 'PhotoCraftData/p.json' = '{}'; 'z.dat' = 'z' }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/a.exe' = ('d' * 64); 'top/c.dll' = ('e' * 64) }
        $mkPlan = {
            Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
                -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
                -VersionEvidence (New-P1Evidence) -Timestamp '20260101-000000' `
                -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' }) |
                ConvertTo-Json -Depth 6
        }
        (& $mkPlan) | Should Be (& $mkPlan)
        $plan = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -Timestamp '20260101-000000' `
            -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $paths = @($plan.Actions | ForEach-Object { $_.Path })
        ($paths -join '|') | Should Be ((@($paths | Sort-Object)) -join '|')
    }
    It 'changes nothing on disk and creates no quarantine directory' {
        $root = New-P1Fixture @{ 'app.exe' = 'x'; 'scratch.tmp' = 's'; 'PhotoCraftData/p.json' = '{}' }
        $before = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $cand = New-P1Candidate @{ 'top/app.exe' = ('d' * 64); 'top/n.dll' = ('e' * 64) }
        $null = Get-UpdatePlan -AppId photocraft -ExistingInventory $inv -CandidateZip $cand `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('c' * 64) -Layout Flat `
            -VersionEvidence (New-P1Evidence) -ProvenancePaths @('scratch.tmp') -Timestamp '20260101-000000' `
            -MarkerState ([PSCustomObject]@{ Present = $true; MarkerName = 'portable.txt' })
        $after = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        (Compare-Object $before $after) | Should Be $null
        (Test-Path -LiteralPath (Join-Path $root '.quarantine')) | Should Be $false
    }
}

Describe 'ArtCraftInstall P1 fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:P1Roots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:P1Roots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
