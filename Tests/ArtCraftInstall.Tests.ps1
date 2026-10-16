<#
.SYNOPSIS
  Pester tests for ArtCraftInstall.psm1 (Phase P0). Fixtures only - never touches real installs.
  Requires Pester; run: Invoke-Pester D:\Art` Craft\tools\Tests
#>
$ModulePath = 'D:\Art Craft\tools\ArtCraftInstall.psm1'
Import-Module $ModulePath -Force

$Script:FixtureRoots = @()

function New-P0Fixture {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftP0-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:FixtureRoots += $root
    return $root
}

function New-P0ValidManifest {
    return [PSCustomObject]@{
        schemaVersion = 1
        appId         = 'photocraft'
        version       = '0.9.0'
        tag           = 'v0.9.0'
        archive       = [PSCustomObject]@{ name = 'photocraft-0.9.0-windows-x64-portable.zip'; sha256 = ('a' * 64) }
        files         = @([PSCustomObject]@{ path = 'photocraft.exe'; sha256 = ('b' * 64) })
    }
}

Describe 'ArtCraftInstall P0 prerequisites' {
    It 'reports prerequisite status without throwing' {
        $r = Test-ArtCraftPrerequisites
        $r.PowerShellOk | Should Be $true
        $r.ZipApiAvailable | Should Be $true
    }
}

Describe 'ArtCraftInstall P0 manifest validation' {
    It 'accepts a valid manifest' {
        @(Test-InstallManifest -Manifest (New-P0ValidManifest)).Count | Should Be 0
    }
    It 'rejects a null manifest' {
        @(Test-InstallManifest -Manifest $null).Count | Should BeGreaterThan 0
    }
    It 'rejects wrong schema version' {
        $m = New-P0ValidManifest; $m.schemaVersion = 99
        (Test-InstallManifest -Manifest $m) -join ';' | Should Match 'schemaVersion'
    }
    It 'rejects unknown appId' {
        $m = New-P0ValidManifest; $m.appId = 'wordcraft'
        (Test-InstallManifest -Manifest $m) -join ';' | Should Match 'appId'
    }
    It 'rejects missing version' {
        $m = New-P0ValidManifest; $m.version = ''
        @(Test-InstallManifest -Manifest $m).Count | Should BeGreaterThan 0
    }
    It 'rejects bad archive hash' {
        $m = New-P0ValidManifest; $m.archive.sha256 = 'xyz'
        (Test-InstallManifest -Manifest $m) -join ';' | Should Match 'archive.sha256'
    }
    It 'rejects absolute paths' {
        Test-ManifestPath -Path 'C:/evil.exe' | Should Be $false
        Test-ManifestPath -Path '/abs/path' | Should Be $false
        Test-ManifestPath -Path '\abs\path' | Should Be $false
    }
    It 'rejects traversal paths' {
        Test-ManifestPath -Path '../escape.exe' | Should Be $false
        Test-ManifestPath -Path 'sub/../../escape.exe' | Should Be $false
        Test-ManifestPath -Path '' | Should Be $false
    }
    It 'rejects wildcards and illegal characters' {
        Test-ManifestPath -Path 'sub/*.exe' | Should Be $false
        Test-ManifestPath -Path 'a:b.exe' | Should Be $false
    }
    It 'accepts normal relative paths' {
        Test-ManifestPath -Path 'photocraft.exe' | Should Be $true
        Test-ManifestPath -Path 'effectcraft-0.10.0-windows-x64-portable/effectcraft.exe' | Should Be $true
    }
    It 'rejects duplicates' {
        $m = New-P0ValidManifest
        $m.files = @([PSCustomObject]@{ path = 'a.exe' }, [PSCustomObject]@{ path = 'a.exe' })
        (Test-InstallManifest -Manifest $m) -join ';' | Should Match 'duplicate'
    }
    It 'reports missing manifest file without throwing' {
        $r = Read-InstallManifest -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-manifest-12345.json')
        $r.Found | Should Be $false
        $r.Errors.Count | Should BeGreaterThan 0
    }
    It 'reports malformed JSON without throwing' {
        $root = New-P0Fixture
        $p = Join-Path $root 'bad.json'
        Set-Content -LiteralPath $p -Value '{not json'
        $r = Read-InstallManifest -LiteralPath $p
        $r.Found | Should Be $true
        $r.Manifest | Should Be $null
        $r.Errors.Count | Should BeGreaterThan 0
    }
    It 'round-trips a valid manifest file' {
        $root = New-P0Fixture
        $p = Join-Path $root 'good.json'
        (New-P0ValidManifest) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p
        $r = Read-InstallManifest -LiteralPath $p
        $r.Found | Should Be $true
        $r.Errors.Count | Should Be 0
        $r.Manifest.version | Should Be '0.9.0'
    }
}

Describe 'ArtCraftInstall P0 hashing and inventory' {
    It 'computes the known SHA-256 of abc' {
        $root = New-P0Fixture
        $p = Join-Path $root 'abc.txt'
        Set-Content -LiteralPath $p -Value 'abc' -NoNewline
        Get-FileSha256Hex -LiteralPath $p | Should Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
    It 'inventories files with spaces in names' {
        $root = New-P0Fixture
        $sub = New-Item -ItemType Directory -Path (Join-Path $root 'dir with spaces')
        Set-Content -LiteralPath (Join-Path $sub.FullName 'my file.txt') -Value 'x'
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $inv.Errors.Count | Should Be 0
        @($inv.Files | Where-Object { $_.Path -eq 'dir with spaces/my file.txt' }).Count | Should Be 1
        ($inv.Directories -contains 'dir with spaces') | Should Be $true
    }
    It 'is idempotent and changes nothing on disk' {
        $root = New-P0Fixture
        Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'hello'
        $before = Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        $first = Get-AppInventory -Root $root -IncludeHashes
        $second = Get-AppInventory -Root $root -IncludeHashes
        $after = Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        (Compare-Object $before $after).Count | Should Be 0
        ($first.Files.Path -join '|') | Should Be ($second.Files.Path -join '|')
        ($first.Files.Sha256 -join '|') | Should Be ($second.Files.Sha256 -join '|')
    }
    It 'reports exclusively-locked files in Errors instead of failing' {
        $root = New-P0Fixture
        $p = Join-Path $root 'locked.bin'
        Set-Content -LiteralPath $p -Value 'locked-content'
        $stream = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $inv = Get-AppInventory -Root $root -IncludeHashes
            @($inv.Files | Where-Object { $_.Path -eq 'locked.bin' }).Count | Should Be 1
            ($inv.Errors -join ';') | Should Match 'locked.bin'
        } finally {
            $stream.Dispose()
        }
    }
}

Describe 'ArtCraftInstall P0 ZIP handling' {
    It 'lists ZIP entries and matches the archive hash' {
        $root = New-P0Fixture
        $src = New-Item -ItemType Directory -Path (Join-Path $root 'app-1.0-pkg')
        Set-Content -LiteralPath (Join-Path $src.FullName 'app.exe') -Value 'binary-stub'
        Set-Content -LiteralPath (Join-Path $src.FullName 'notes.txt') -Value 'hello'
        $zip = Join-Path $root 'app.zip'
        Compress-Archive -Path $src.FullName -DestinationPath $zip
        $inv = Get-ZipInventory -LiteralPath $zip
        ($inv.Entries.Path -contains 'app-1.0-pkg/app.exe') | Should Be $true
        ($inv.Entries.Path -contains 'app-1.0-pkg/notes.txt') | Should Be $true
        $inv.ArchiveSha256 | Should Be (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'detects missing, extra and hash-mismatched files' {
        $expected = @(
            [PSCustomObject]@{ Path = 'a.exe'; Sha256 = ('a' * 64) },
            [PSCustomObject]@{ Path = 'gone.dll'; Sha256 = $null },
            [PSCustomObject]@{ Path = 'changed.dll'; Sha256 = ('c' * 64) }
        )
        $actual = [PSCustomObject]@{ Files = @(
            [PSCustomObject]@{ Path = 'a.exe'; Sha256 = ('a' * 64) },
            [PSCustomObject]@{ Path = 'changed.dll'; Sha256 = ('d' * 64) },
            [PSCustomObject]@{ Path = 'surprise.txt'; Sha256 = $null }
        ) }
        $cmp = Compare-ReleaseInventory -Expected $expected -Actual $actual
        $cmp.Missing -contains 'gone.dll' | Should Be $true
        $cmp.Extra -contains 'surprise.txt' | Should Be $true
        $cmp.HashMismatches -contains 'changed.dll' | Should Be $true
        $cmp.Missing.Count | Should Be 1
    }
}

Describe 'ArtCraftInstall P0 portable markers' {
    It 'detects a marker file' {
        $root = New-P0Fixture
        Set-Content -LiteralPath (Join-Path $root 'portable.txt') -Value 'x'
        $s = Get-PortableMarkerState -ExeDirectory $root
        $s.Present | Should Be $true
        $s.MarkerIsFile | Should Be $true
    }
    It 'does not treat a marker-named directory as a marker' {
        $root = New-P0Fixture
        New-Item -ItemType Directory -Path (Join-Path $root 'portable.txt') | Out-Null
        $s = Get-PortableMarkerState -ExeDirectory $root
        $s.Present | Should Be $false
    }
    It 'reports absent markers' {
        $root = New-P0Fixture
        (Get-PortableMarkerState -ExeDirectory $root).Present | Should Be $false
    }
}

Describe 'ArtCraftInstall P0 classification' {
    It 'protects user data, agent files and downloads; unknowns stay unknown' {
        $root = New-P0Fixture
        New-Item -ItemType Directory -Path (Join-Path $root 'PhotoCraftData') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'PhotoCraftData\preferences.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $root 'SKILL.md') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'work.fcproj') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'release.zip') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'mystery.dat') -Value 'x'
        $inv = Get-AppInventory -Root $root
        $c = Get-OwnershipClassification -AppId photocraft -Inventory $inv
        ($c | Where-Object { $_.Path -eq 'PhotoCraftData/preferences.json' }).Class | Should Be 'UserData'
        ($c | Where-Object { $_.Path -eq 'SKILL.md' }).Class | Should Be 'AgentOwned'
        ($c | Where-Object { $_.Path -eq 'work.fcproj' }).Class | Should Be 'UserData'
        ($c | Where-Object { $_.Path -eq 'release.zip' }).Class | Should Be 'ReleaseDownload'
        ($c | Where-Object { $_.Path -eq 'mystery.dat' }).Class | Should Be 'Unknown'
    }
    It 'gates scratch classification on caller-supplied provenance' {
        $root = New-P0Fixture
        Set-Content -LiteralPath (Join-Path $root 'scratch.tmp') -Value 'x'
        $inv = Get-AppInventory -Root $root
        (Get-OwnershipClassification -AppId photocraft -Inventory $inv |
            Where-Object { $_.Path -eq 'scratch.tmp' }).Class | Should Be 'Unknown'
        (Get-OwnershipClassification -AppId photocraft -Inventory $inv -ProvenancePaths @('scratch.tmp') |
            Where-Object { $_.Path -eq 'scratch.tmp' }).Class | Should Be 'ScratchProvenance'
    }
    It 'verifies release files by hash' {
        $root = New-P0Fixture
        Set-Content -LiteralPath (Join-Path $root 'app.exe') -Value 'exact-bytes' -NoNewline
        $inv = Get-AppInventory -Root $root -IncludeHashes
        $hash = ($inv.Files | Where-Object { $_.Path -eq 'app.exe' }).Sha256
        $exp = @([PSCustomObject]@{ Path = 'app.exe'; Sha256 = $hash })
        (Get-OwnershipClassification -AppId photocraft -Inventory $inv -ExpectedFiles $exp |
            Where-Object { $_.Path -eq 'app.exe' }).Class | Should Be 'ReleaseVerified'
        $bad = @([PSCustomObject]@{ Path = 'app.exe'; Sha256 = ('0' * 64) })
        (Get-OwnershipClassification -AppId photocraft -Inventory $inv -ExpectedFiles $bad |
            Where-Object { $_.Path -eq 'app.exe' }).Class | Should Be 'Unknown'
    }
}

Describe 'ArtCraftInstall P0 version metadata' {
    It 'reads PE version info without executing' {
        $v = Get-PeVersion -LiteralPath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $v.ProductVersion | Should Not BeNullOrEmpty
    }
    It 'returns nulls gracefully for missing files' {
        $v = Get-PeVersion -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary-12345.exe')
        $v.ProductVersion | Should Be $null
    }
}

Describe 'ArtCraftInstall P0 fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:FixtureRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:FixtureRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
