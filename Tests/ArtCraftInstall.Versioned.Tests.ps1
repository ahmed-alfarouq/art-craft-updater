<#
.SYNOPSIS
  Pester tests for Update-McpServerCommand and Invoke-VersionedCleanInstall.
  Fixtures under %TEMP% only. Real installs are referenced solely to verify the
  production-root refusal, which performs no modifications.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftInstall.psm1' -Force

$Script:VRoots = @()

function New-VRoot {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftV-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:VRoots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-VArchive {
    param([hashtable]$Files, [string]$Top = 'effectcraft-9.9.9-windows-x64-portable')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftVz-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:VRoots += $root
    $src = New-Item -ItemType Directory -Path (Join-Path $root $Top)
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $src.FullName ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    $zip = Join-Path $root 'candidate.zip'
    Compress-Archive -Path $src.FullName -DestinationPath $zip
    return [PSCustomObject]@{ Path = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant(); Top = $Top }
}

function New-VMocks {
    param([string]$Version)
    $sig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $true; Status = 'Valid'; Subject = 'Learning Machines Inc' } }.GetNewClosure()
    $ver = { param($GuiPath, $CliPath) [PSCustomObject]@{ GuiVersion = $Version; GuiSource = 'PE'; CliVersion = $Version; CliSource = 'Stdout' } }.GetNewClosure()
    return @{ Sig = $sig; Ver = $ver }
}

function New-VReleaseFiles {
    param([string]$Gui = 'gui-bytes', [string]$Cli = 'cli-bytes')
    return @{ 'effectcraft.exe' = $Gui; 'effectcraft-cli.exe' = $Cli; 'portable.txt' = 'm'; 'README.md' = 'r' }
}

Describe 'ArtCraftInstall versioned clean install' {
    It 'performs a clean install into a new versioned directory' {
        $instRoot = New-VRoot @{}
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        $r.TargetDirectory | Should Be (Join-Path $instRoot $zip.Top)
        foreach ($f in @('effectcraft.exe', 'effectcraft-cli.exe', 'portable.txt', 'README.md', 'install-manifest.json')) {
            (Test-Path -LiteralPath (Join-Path $r.TargetDirectory $f)) | Should Be $true
        }
        (Get-Content -LiteralPath (Join-Path $r.TargetDirectory 'effectcraft.exe') -Raw) | Should Be 'gui-bytes'
        $manifest = (Get-Content -LiteralPath (Join-Path $r.TargetDirectory 'install-manifest.json') -Raw) | ConvertFrom-Json
        $manifest.version | Should Be '9.9.9'
        $manifest.schemaVersion | Should Be 1
        $r.ManifestWritten | Should Be $true
    }
    It 'refuses when the target versioned directory already differs' {
        $instRoot = New-VRoot @{ 'effectcraft-9.9.9-windows-x64-portable/effectcraft.exe' = 'stale' }
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'target-create'
        (Get-Content -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.9-windows-x64-portable\effectcraft.exe') -Raw) | Should Be 'stale'
    }
    It 'is idempotent for a byte-identical target' {
        $instRoot = New-VRoot @{}
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $common = @{ AppId = 'effectcraft'; InstallRoot = $instRoot; Version = '9.9.9'; ArchivePath = $zip.Path; ExpectedArchiveSha256 = $zip.Sha256; SignatureChecker = $m.Sig; VersionProvider = $m.Ver }
        $r1 = Invoke-VersionedCleanInstall @common
        $r1.Success | Should Be $true
        $snap = @(Get-ChildItem -LiteralPath $r1.TargetDirectory -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        $r2 = Invoke-VersionedCleanInstall @common
        $r2.Success | Should Be $true
        $r2.AlreadyInstalled | Should Be $true
        $r2.Operations.Count | Should Be 0
        (Compare-Object $snap @(Get-ChildItem -LiteralPath $r1.TargetDirectory -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)) | Should Be $null
    }
    It 'blocks on archive hash, signature, and version failures' {
        $instRoot = New-VRoot @{}
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $badHash = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 ('0' * 64) -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $badHash.Success | Should Be $false
        $badHash.StageReached | Should Be 'archive-hash'
        $badSig = { param($a, $b) [PSCustomObject]@{ Valid = $false; Status = 'NotSigned'; Subject = $null } }.GetNewClosure()
        $rSig = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $badSig -VersionProvider $m.Ver
        $rSig.Success | Should Be $false
        $rSig.StageReached | Should Be 'signatures'
        $mWrong = New-VMocks -Version '1.2.3'
        $rVer = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $mWrong.Ver
        $rVer.Success | Should Be $false
        $rVer.StageReached | Should Be 'version-evidence'
        (Test-Path -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.9-windows-x64-portable')) | Should Be $false
    }
    It 'removes only the partial new directory on failure and keeps siblings' {
        $instRoot = New-VRoot @{ 'effectcraft-9.9.8-windows-x64-portable/effectcraft.exe' = 'previous'; 'notes.txt' = 'mine' }
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 `
            -FaultInjection @{ FailAfterWrites = 0 } -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        (Test-Path -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.9-windows-x64-portable')) | Should Be $false
        (Get-Content -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.8-windows-x64-portable\effectcraft.exe') -Raw) | Should Be 'previous'
        (Get-Content -LiteralPath (Join-Path $instRoot 'notes.txt') -Raw) | Should Be 'mine'
    }
    It 'refuses the real EffectCraft root without explicit production approval' {
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot 'D:\Art Craft\EffectCraft' -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'preflight'
    }
    It 'aborts before any target change when staging is impossible' {
        $instRoot = New-VRoot @{}
        $before = @(Get-ChildItem -LiteralPath $instRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $blocker = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftVblk-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content -LiteralPath $blocker -Value 'not a directory'
        $Script:VRoots += $blocker
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -StagingParent $blocker `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        $r.StageReached | Should Be 'stage-copy'
        (Test-Path -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.9-windows-x64-portable')) | Should Be $false
    }
}

Describe 'ArtCraftInstall MCP config activation' {
    It 'repoints one server command and preserves all other fields' {
        $root = New-VRoot @{}
        $cfgPath = Join-Path $root 'mcp-config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"mcpServers":{"effectcraft":{"command":"OLD","args":["mcp","--empty"]},"other":{"command":"keep-me","args":[]}},"global":{"x":1}}'
        $r = Update-McpServerCommand -ConfigPath $cfgPath -ServerName 'effectcraft' -Command 'D:\New\effectcraft-cli.exe'
        $r.Updated | Should Be $true
        $r.PreviousCommand | Should Be 'OLD'
        $cfg = (Get-Content -LiteralPath $cfgPath -Raw) | ConvertFrom-Json
        $cfg.mcpServers.effectcraft.command | Should Be 'D:\New\effectcraft-cli.exe'
        ($cfg.mcpServers.effectcraft.args -join ',') | Should Be 'mcp,--empty'
        $cfg.mcpServers.other.command | Should Be 'keep-me'
        $cfg.global.x | Should Be 1
    }
    It 'leaves an already-correct config untouched' {
        $root = New-VRoot @{}
        $cfgPath = Join-Path $root 'mcp-config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"mcpServers":{"effectcraft":{"command":"D:\\X\\e.exe","args":[]}}}'
        $before = Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256
        $r = Update-McpServerCommand -ConfigPath $cfgPath -ServerName 'effectcraft' -Command 'D:\X\e.exe'
        $r.Updated | Should Be $false
        (Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash | Should Be $before.Hash
    }
    It 'refuses missing configs and unknown servers without inventing structure' {
        $root = New-VRoot @{}
        $cfgPath = Join-Path $root 'mcp-config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"mcpServers":{"other":{"command":"x"}}}'
        $r = Update-McpServerCommand -ConfigPath $cfgPath -ServerName 'effectcraft' -Command 'D:\New\e.exe'
        $r.Updated | Should Be $false
        $r.Error | Should Match 'not present'
        $r2 = Update-McpServerCommand -ConfigPath (Join-Path $root 'absent.json') -ServerName 'effectcraft' -Command 'D:\New\e.exe'
        $r2.Updated | Should Be $false
    }
    It 'updates config only after install verification, never before' {
        $instRoot = New-VRoot @{}
        $cfgPath = Join-Path $instRoot 'mcp-config.json'
        Set-Content -LiteralPath $cfgPath -Value '{"mcpServers":{"effectcraft":{"command":"OLD","args":["mcp"]}}}'
        $zip = New-VArchive (New-VReleaseFiles)
        $m = New-VMocks -Version '9.9.9'
        $badSig = { param($a, $b) [PSCustomObject]@{ Valid = $false; Status = 'NotSigned'; Subject = $null } }.GetNewClosure()
        $rFail = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $badSig -VersionProvider $m.Ver `
            -McpConfigPath $cfgPath
        $rFail.Success | Should Be $false
        ((Get-Content -LiteralPath $cfgPath -Raw) | ConvertFrom-Json).mcpServers.effectcraft.command | Should Be 'OLD'
        $r = Invoke-VersionedCleanInstall -AppId effectcraft -InstallRoot $instRoot -Version '9.9.9' `
            -ArchivePath $zip.Path -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver `
            -McpConfigPath $cfgPath
        $r.Success | Should Be $true
        $r.ConfigUpdated | Should Be $true
        $cfg = ((Get-Content -LiteralPath $cfgPath -Raw) | ConvertFrom-Json)
        $cfg.mcpServers.effectcraft.command | Should Be (Join-Path $r.TargetDirectory 'effectcraft-cli.exe')
        ($cfg.mcpServers.effectcraft.args -join ',') | Should Be 'mcp'
    }
}

Describe 'ArtCraftInstall wrapper script' {
    It 'runs a dry run from a spaced path without changing anything' {
        $parentBase = Join-Path ([System.IO.Path]::GetTempPath()) 'Art Craft Wrapper Test'
        if (Test-Path -LiteralPath $parentBase) { Remove-Item -LiteralPath $parentBase -Recurse -Force }
        $parent = New-Item -ItemType Directory -Path $parentBase -Force
        $Script:ERoots += $parent.FullName
        $bundle = New-Item -ItemType Directory -Path (Join-Path $parent.FullName 'EffectCraft') -Force
        Copy-Item -LiteralPath 'D:\Art Craft\EffectCraft\Install-EffectCraft.ps1' -Destination (Join-Path $bundle.FullName 'Install-EffectCraft.ps1')
        $src = New-Item -ItemType Directory -Path (Join-Path $parent.FullName 'pkg-src\effectcraft-9.9.9-windows-x64-portable') -Force
        Set-Content -LiteralPath (Join-Path $src.FullName 'effectcraft.exe') -Value 'g' -NoNewline
        Set-Content -LiteralPath (Join-Path $src.FullName 'effectcraft-cli.exe') -Value 'c' -NoNewline
        $zipDest = Join-Path $bundle.FullName 'effectcraft-9.9.9-windows-x64-portable.zip'
        Compress-Archive -Path $src.FullName -DestinationPath $zipDest
        $zh = (Get-FileHash -LiteralPath $zipDest -Algorithm SHA256).Hash
        Set-Content -LiteralPath (Join-Path $bundle.FullName 'SHA256SUMS.txt') -Value "$zh  effectcraft-9.9.9-windows-x64-portable.zip"
        $before = @(Get-ChildItem -LiteralPath $bundle.FullName -Recurse | ForEach-Object { $_.FullName } | Sort-Object)
        $out = powershell -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $bundle.FullName 'Install-EffectCraft.ps1') `
            -InstallRoot $bundle.FullName -ToolsModule 'D:\Art Craft\tools\ArtCraftInstall.psm1' -DryRun 2>&1 | Out-String
        # Unsigned fixture exes fail the real signature gate: no changes, clear stage output.
        $out | Should Match 'signatures'
        $out | Should Match '9.9.9'
        $after = @(Get-ChildItem -LiteralPath $bundle.FullName -Recurse | ForEach-Object { $_.FullName } | Sort-Object)
        (Compare-Object @($before) @($after)) | Should Be $null
    }
}

Describe 'ArtCraftInstall versioned fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:VRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:VRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
