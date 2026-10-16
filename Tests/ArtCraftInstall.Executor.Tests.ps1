<#
.SYNOPSIS
  Pester tests for Invoke-FlatUpdate (Phase P2A). Fixture archives and fixture
  targets under %TEMP% only. Real installs are referenced solely to verify the
  production-root refusal, which performs no modifications.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftInstall.psm1' -Force

$Script:P2Roots = @()

function New-P2Target {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:P2Roots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-P2Archive {
    param([hashtable]$Files, [string]$Top = 'pkg')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2z-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:P2Roots += $root
    $src = New-Item -ItemType Directory -Path (Join-Path $root $Top)
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $src.FullName ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    $zip = Join-Path $root 'candidate.zip'
    Compress-Archive -Path $src.FullName -DestinationPath $zip
    return [PSCustomObject]@{ Path = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function New-P2Mocks {
    param([string]$Version)
    $sig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $true; Status = 'Valid'; Subject = 'Learning Machines Inc' } }.GetNewClosure()
    $ver = { param($GuiPath, $CliPath) [PSCustomObject]@{ GuiVersion = $Version; GuiSource = 'PE'; CliVersion = $Version; CliSource = 'Stdout' } }.GetNewClosure()
    return @{ Sig = $sig; Ver = $ver }
}

function Get-P2Snapshot {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.FullName)|$($_.Length)|$((Get-FileSha256Hex -LiteralPath $_.FullName))" } | Sort-Object)
}

Describe 'ArtCraftInstall P2A successful updates' {
    It 'applies a valid staged update in a fixture' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1-gui'; 'photocraft-cli.exe' = 'v1-cli'; 'portable.txt' = 'm'; 'PhotoCraftData/prefs.json' = '{}'; 'SKILL.md' = 'x' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2-gui'; 'photocraft-cli.exe' = 'v2-cli'; 'portable.txt' = 'm'; 'new.dll' = 'n' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        (Get-Content -LiteralPath (Join-Path $target 'photocraft.exe') -Raw) | Should Be 'v2-gui'
        (Get-Content -LiteralPath (Join-Path $target 'photocraft-cli.exe') -Raw) | Should Be 'v2-cli'
        (Get-Content -LiteralPath (Join-Path $target 'new.dll') -Raw) | Should Be 'n'
        $r.ManifestWritten | Should Be $true
        $manifest = (Get-Content -LiteralPath (Join-Path $target 'install-manifest.json') -Raw) | ConvertFrom-Json
        $manifest.version | Should Be '9.9.9'
        $manifest.schemaVersion | Should Be 1
    }
    It 'performs a fresh install into a missing target root' {
        $parent = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2f-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $parent | Out-Null
        $Script:P2Roots += $parent
        $target = Join-Path $parent 'fresh-app'
        $zip = New-P2Archive @{ 'photocraft.exe' = 'g'; 'photocraft-cli.exe' = 'c'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        @('photocraft.exe', 'photocraft-cli.exe', 'portable.txt', 'install-manifest.json' | ForEach-Object { Test-Path -LiteralPath (Join-Path $target $_) }) -contains $false | Should Be $false
    }
    It 'leaves protected and unrelated files byte-identical' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm'; 'PhotoCraftData/prefs.json' = '{"a":1}'; 'SKILL.md' = 'keep' }
        $beforeData = Get-FileSha256Hex -LiteralPath (Join-Path $target 'PhotoCraftData\prefs.json')
        $beforeSkill = Get-FileSha256Hex -LiteralPath (Join-Path $target 'SKILL.md')
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        (Get-FileSha256Hex -LiteralPath (Join-Path $target 'PhotoCraftData\prefs.json')) | Should Be $beforeData
        (Get-FileSha256Hex -LiteralPath (Join-Path $target 'SKILL.md')) | Should Be $beforeSkill
    }
    It 'reinstalling the same release is idempotent' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $common = @{ AppId = 'photocraft'; TargetRoot = $target; ArchivePath = $zip.Path; CandidateVersion = '9.9.9'; ExpectedArchiveSha256 = $zip.Sha256; SignatureChecker = $m.Sig; VersionProvider = $m.Ver }
        $r1 = Invoke-FlatUpdate @common
        $r1.Success | Should Be $true
        $snap = Get-P2Snapshot -Root $target
        $r2 = Invoke-FlatUpdate @common
        $r2.Success | Should Be $true
        $r2.Operations.Count | Should Be 0
        $r2.ManifestWritten | Should Be $false
        (Compare-Object $snap (Get-P2Snapshot -Root $target)) | Should Be $null
    }
    It 'a second update preserves protected files and carries manifest history' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm'; 'PhotoCraftData/prefs.json' = '{}' }
        $m = New-P2Mocks -Version '9.9.9'
        $z1 = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $r1 = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $z1.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $z1.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r1.Success | Should Be $true
        $existing = (Get-Content -LiteralPath (Join-Path $target 'install-manifest.json') -Raw) | ConvertFrom-Json
        $m2 = New-P2Mocks -Version '9.9.10'
        $z2 = New-P2Archive @{ 'photocraft.exe' = 'v3'; 'photocraft-cli.exe' = 'v3'; 'portable.txt' = 'm' }
        $r2 = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $z2.Path `
            -CandidateVersion '9.9.10' -ExpectedArchiveSha256 $z2.Sha256 -ExistingManifest $existing `
            -SignatureChecker $m2.Sig -VersionProvider $m2.Ver
        $r2.Success | Should Be $true
        (Get-Content -LiteralPath (Join-Path $target 'photocraft.exe') -Raw) | Should Be 'v3'
        (Get-Content -LiteralPath (Join-Path $target 'PhotoCraftData\prefs.json') -Raw) | Should Be '{}'
        $manifest2 = (Get-Content -LiteralPath (Join-Path $target 'install-manifest.json') -Raw) | ConvertFrom-Json
        $manifest2.version | Should Be '9.9.10'
        $manifest2.previous.version | Should Be '9.9.9'
    }
}

Describe 'ArtCraftInstall P2A verification gates' {
    It 'aborts on archive hash mismatch before touching the target' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1' }
        $before = Get-P2Snapshot -Root $target
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('0' * 64) -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'archive-hash'
        (Compare-Object $before (Get-P2Snapshot -Root $target)) | Should Be $null
    }
    It 'aborts on invalid signatures before touching the target' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1' }
        $before = Get-P2Snapshot -Root $target
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2' }
        $badSig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $false; Status = 'NotSigned'; Subject = $null } }.GetNewClosure()
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $badSig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'signatures'
        (Compare-Object $before (Get-P2Snapshot -Root $target)) | Should Be $null
    }
    It 'rejects unsafe and duplicate ZIP paths' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2e-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $Script:P2Roots += $root
        $evil = Join-Path $root 'evil.zip'
        $fs = [System.IO.File]::Create($evil)
        $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($n in @('pkg/ok.exe', 'pkg/../../evil.exe')) {
            $en = $za.CreateEntry($n)
            $w = New-Object System.IO.StreamWriter($en.Open())
            $w.Write('x'); $w.Dispose()
        }
        $za.Dispose(); $fs.Dispose()
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1' }
        $before = Get-P2Snapshot -Root $target
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $evil `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 (Get-FileSha256Hex -LiteralPath $evil) `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        ($r.Blockers + $r.Errors -join ';') | Should Match 'unsafe candidate ZIP path'
        (Compare-Object $before (Get-P2Snapshot -Root $target)) | Should Be $null
    }
    It 'blocks archives missing a required executable' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'required-contents'
    }
    It 'blocks on version mismatch' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2' }
        $m = New-P2Mocks -Version '1.2.3'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'version-evidence'
    }
    It 'blocks plans with conflicts or unsupported actions' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        New-Item -ItemType Directory -Path (Join-Path $target 'PhotoCraftData') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'PhotoCraftData\prefs.json') -Value '{}' -NoNewline
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm'; 'PhotoCraftData/evil.bin' = 'x' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'plan'
        (Test-Path -LiteralPath (Join-Path $target 'PhotoCraftData\evil.bin')) | Should Be $false
    }
    It 'never deletes obsolete files: unsupported-action plans are refused' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm'; 'legacy.dll' = 'old' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -HistoricalReleaseFiles @([PSCustomObject]@{ Path = 'legacy.dll' }) `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        (Test-Path -LiteralPath (Join-Path $target 'legacy.dll')) | Should Be $true
        (Get-Content -LiteralPath (Join-Path $target 'legacy.dll') -Raw) | Should Be 'old'
    }
    It 'aborts before any target change when staging is impossible' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $before = Get-P2Snapshot -Root $target
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $blocker = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2blk-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content -LiteralPath $blocker -Value 'not a directory'
        $Script:P2Roots += $blocker
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -StagingParent $blocker `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'stage-copy'
        (Compare-Object $before (Get-P2Snapshot -Root $target)) | Should Be $null
    }
    It 'refuses real installation roots without explicit production approval' {
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2' }
        $m = New-P2Mocks -Version '9.9.9'
        foreach ($prod in @('D:\Art Craft\photocraft', 'D:\Art Craft\filmcraft')) {
            $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $prod -ArchivePath $zip.Path `
                -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
            $r.Success | Should Be $false
            $r.StageReached | Should Be 'preflight'
        }
    }
}

Describe 'ArtCraftInstall P2A recovery' {
    It 'recovers from locked-file failures with originals intact' {
        # Deny writes but allow reads: inventory/hashing succeed so planning
        # passes, then the commit-time copy fails and rollback must restore.
        # (The lock handle itself is read-only: a ReadWrite handle would block
        # reads too, which correctly fails earlier at plan time instead.)
        $target = New-P2Target @{ 'photocraft.exe' = 'v1-gui'; 'photocraft-cli.exe' = 'v1-cli'; 'portable.txt' = 'm' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2-gui'; 'photocraft-cli.exe' = 'v2-cli'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $lock = [System.IO.File]::Open((Join-Path $target 'photocraft.exe'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
                -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
            $r.Success | Should Be $false
            $r.RollbackPerformed | Should Be $true
            $r.RollbackSucceeded | Should Be $true
        } finally {
            $lock.Dispose()
        }
        (Get-Content -LiteralPath (Join-Path $target 'photocraft.exe') -Raw) | Should Be 'v1-gui'
        (Get-Content -LiteralPath (Join-Path $target 'photocraft-cli.exe') -Raw) | Should Be 'v1-cli'
    }
    It 'restores replaced bytes and removes only transaction-created files' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm'; 'added.dll' = 'new' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -FaultInjection @{ FailAfterWrites = 1 } -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.RollbackPerformed | Should Be $true
        $r.RollbackSucceeded | Should Be $true
        (Get-Content -LiteralPath (Join-Path $target 'photocraft.exe') -Raw) | Should Be 'v1'
        (Get-Content -LiteralPath (Join-Path $target 'photocraft-cli.exe') -Raw) | Should Be 'v1'
        (Test-Path -LiteralPath (Join-Path $target 'added.dll')) | Should Be $false
    }
    It 'surfaces rollback failure without claiming success' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -FaultInjection @{ FailAfterWrites = 0; DestroyBackups = @('photocraft.exe', 'photocraft-cli.exe') } `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.RollbackPerformed | Should Be $true
        $r.RollbackSucceeded | Should Be $false
        ($r.Errors -join ';') | Should Match 'rollback'
    }
    It 'handles manifest-write failure by rolling back, not by claiming success' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $before = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileSha256Hex -LiteralPath $_.FullName))" } | Sort-Object)
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 `
            -FaultInjection @{ FailManifestWrite = $true } -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.ManifestWritten | Should Be $false
        $r.RollbackSucceeded | Should Be $true
        (Test-Path -LiteralPath (Join-Path $target 'install-manifest.json')) | Should Be $false
        $after = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { "$($_.FullName)|$((Get-FileSha256Hex -LiteralPath $_.FullName))" } | Sort-Object)
        (Compare-Object $before $after) | Should Be $null
    }
    It 'creates no quarantine directory' {
        $target = New-P2Target @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-P2Archive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' }
        $m = New-P2Mocks -Version '9.9.9'
        $r = Invoke-FlatUpdate -AppId photocraft -TargetRoot $target -ArchivePath $zip.Path `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        (Test-Path -LiteralPath (Join-Path $target '.quarantine')) | Should Be $false
    }
}

Describe 'ArtCraftInstall P2A default verifiers' {
    It 'rejects a non-matching signer with the real signature checker' {
        $ev = Get-DefaultSignatureEvidence -ExePath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ExpectedSignerSubject 'Learning Machines Inc'
        $ev.Valid | Should Be $false
    }
    It 'probes versions with the real default provider against fixtures' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP2v-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $Script:P2Roots += $root
        Set-Content -LiteralPath (Join-Path $root 'fakecli.cmd') -Value @('@echo off', 'echo powershell-cli 9.9.9 (abc, 2026-01-01)')
        $ev = Get-DefaultVersionEvidence -GuiPath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -CliPath (Join-Path $root 'fakecli.cmd')
        $ev.GuiVersion | Should Not BeNullOrEmpty
        $ev.CliVersion | Should Match '9.9.9'
    }
}

Describe 'ArtCraftInstall P2A fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:P2Roots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:P2Roots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
