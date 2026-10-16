<#
.SYNOPSIS
  Pester tests for confirmed update execution via Install-AppUpdate.
  Controlled file:// archives and fixture install roots under %TEMP% only.
  Real installations are never targeted: production roots are referenced
  solely to verify the preflight refusal, which performs no modifications.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftUpdater.Controller.psm1' -Force
Import-Module 'D:\Art Craft\tools\ArtCraftInstall.psm1' -Force

$Script:IRoots = @()

function New-IServer {
    # Controlled "release server": a fixture directory holding a release zip
    # plus its SHA256SUMS.txt, consumed through file:// URLs (no network).
    param([hashtable]$Files, [string]$ZipName)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftISrv-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:IRoots += $root
    $stage = New-Item -ItemType Directory -Path (Join-Path $root 'photocraft-9.9.9-windows-x64-portable')
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $stage.FullName ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    $zip = Join-Path $root $ZipName
    Compress-Archive -Path $stage.FullName -DestinationPath $zip
    $zh = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $root 'SHA256SUMS.txt') -Value "$zh  $ZipName"
    return [PSCustomObject]@{ Root = $root; Zip = $zip; Sha256 = $zh }
}

function New-ITarget {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftITgt-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:IRoots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-IMocks {
    param([string]$Version)
    $sig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $true; Status = 'Valid'; Subject = 'Learning Machines Inc' } }.GetNewClosure()
    $ver = { param($GuiPath, $CliPath) [PSCustomObject]@{ GuiVersion = $Version; GuiSource = 'PE'; CliVersion = $Version; CliSource = 'Stdout' } }.GetNewClosure()
    return @{ Sig = $sig; Ver = $ver }
}

function Get-IStatus {
    param($Server)
    $toUrl = { param($p) return ('file:///' + ($p -replace '\\', '/')) }
    return [PSCustomObject]@{
        AppId = 'photocraft'; DisplayName = 'PhotoCraft'
        AssetUrl = (& $toUrl $Server.Zip); ChecksumUrl = (& $toUrl (Join-Path $Server.Root 'SHA256SUMS.txt'))
        State = 'UpdateAvailable'; InstallSupported = $true
    }
}

function Get-ISnapshot {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } | Sort-Object)
}

function Get-IDownloadDirs {
    param([string]$TempParent)
    return @(Get-ChildItem -LiteralPath $TempParent -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'ArtCraftDl-*' } | Select-Object -ExpandProperty FullName)
}

Describe 'ArtCraftUpdater confirmed install execution' {
    It 'installs a verified fixture release and reports the engine evidence' {
        $srv = New-IServer @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $appDir = New-ITarget @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $tmpParent = New-ITarget @{}
        $m = New-IMocks -Version '9.9.9'
        $out = Install-AppUpdate -Status (Get-IStatus $srv) -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $out.Success | Should Be $true
        $out.Outcome | Should Match 'installed and verified'
        ($out.StageReached -ne $null -and $out.StageReached -ne '') | Should Be $true
        $out.RollbackPerformed | Should Be $false
        $out.RollbackSucceeded | Should Be $null
        (@($out.Errors).Count -eq 0) | Should Be $true
        (Get-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Raw) | Should Be 'v2'
        ((Get-Content -LiteralPath (Join-Path $appDir 'install-manifest.json') -Raw | ConvertFrom-Json).version) | Should Be '9.9.9'
        (@(Get-IDownloadDirs $tmpParent).Count -eq 0) | Should Be $true
    }
    It 'refuses a tampered archive at the hash stage and leaves the target untouched' {
        $srv = New-IServer @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        Add-Content -LiteralPath $srv.Zip -Value 'tampered-bytes' -NoNewline
        $appDir = New-ITarget @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $before = Get-ISnapshot $appDir
        $tmpParent = New-ITarget @{}
        $m = New-IMocks -Version '9.9.9'
        $out = Install-AppUpdate -Status (Get-IStatus $srv) -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $out.Success | Should Be $false
        ($out.Outcome -join '') | Should Match 'preview blocked'
        ($out.Outcome -join '') | Should Match 'archive-hash'
        # Pre-executor refusals carry no executor stage object; the Outcome
        # text is the stage evidence. Nothing may have been staged or written.
        $out.StageReached | Should Be $null
        (Compare-Object @(Get-ISnapshot $appDir) @($before)) | Should Be $null
        (@(Get-IDownloadDirs $tmpParent).Count -eq 0) | Should Be $true
    }
    It 'refuses a release whose checksum manifest has no entry' {
        $srv = New-IServer @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        Set-Content -LiteralPath (Join-Path $srv.Root 'SHA256SUMS.txt') -Value "0000000000000000000000000000000000000000000000000000000000000000  other.zip"
        $appDir = New-ITarget @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $before = Get-ISnapshot $appDir
        $tmpParent = New-ITarget @{}
        $m = New-IMocks -Version '9.9.9'
        $out = Install-AppUpdate -Status (Get-IStatus $srv) -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $out.Success | Should Be $false
        ($out.Outcome -join '') | Should Match 'preview blocked'
        (Compare-Object @(Get-ISnapshot $appDir) @($before)) | Should Be $null
        (@(Get-IDownloadDirs $tmpParent).Count -eq 0) | Should Be $true
    }
    It 'refuses unsigned executables and version-evidence mismatches without writing' {
        $srv = New-IServer @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $m = New-IMocks -Version '9.9.9'
        $badSig = { param($a, $b) [PSCustomObject]@{ Valid = $false; Status = 'NotSigned'; Subject = $null } }.GetNewClosure()
        $appDir = New-ITarget @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $tmpParent = New-ITarget @{}
        $out = Install-AppUpdate -Status (Get-IStatus $srv) -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $badSig -VersionProvider $m.Ver
        $out.Success | Should Be $false
        ($out.Outcome -join '') | Should Match 'preview blocked'
        (Get-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Raw) | Should Be 'v1'
        $wrongVer = { param($a, $b) [PSCustomObject]@{ GuiVersion = '8.8.8'; GuiSource = 'PE'; CliVersion = '8.8.8'; CliSource = 'Stdout' } }.GetNewClosure()
        $out2 = Install-AppUpdate -Status (Get-IStatus $srv) -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $m.Sig -VersionProvider $wrongVer
        $out2.Success | Should Be $false
        ($out2.Outcome -join '') | Should Match 'preview blocked'
        (Get-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Raw) | Should Be 'v1'
        (@(Get-IDownloadDirs $tmpParent).Count -eq 0) | Should Be $true
    }
    It 'refuses a production root without AllowProduction and leaves it untouched' {
        $realRoot = 'D:\Art Craft\photocraft'
        (Test-Path -LiteralPath $realRoot -PathType Container) | Should Be $true
        $before = Get-ISnapshot $realRoot
        $r = Invoke-FlatUpdate -AppId 'photocraft' -TargetRoot $realRoot -ArchivePath 'C:\no-such-archive-12345.zip' `
            -CandidateVersion '9.9.9' -ExpectedArchiveSha256 ('0' * 64)
        $r.Success | Should Be $false
        (@($r.Errors) -join '') | Should Match 'without -AllowProduction'
        (Compare-Object @(Get-ISnapshot $realRoot) @($before)) | Should Be $null
    }
}

Describe 'ArtCraftUpdater install fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:IRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:IRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
