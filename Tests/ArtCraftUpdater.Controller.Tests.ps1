<#
.SYNOPSIS
  Pester tests for ArtCraftUpdater.Controller.psm1. Fixture directories and
  mock verifiers only. The GUI script itself is syntax-checked, never shown.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftUpdater.Controller.psm1' -Force

$Script:CRoots = @()

function New-CRoot {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftC-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:CRoots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-CMocks {
    param([string]$Version)
    $sig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $true; Status = 'Valid'; Subject = 'Learning Machines Inc' } }.GetNewClosure()
    $ver = { param($GuiPath, $CliPath) [PSCustomObject]@{ GuiVersion = $Version; GuiSource = 'PE'; CliVersion = $Version; CliSource = 'Stdout' } }.GetNewClosure()
    return @{ Sig = $sig; Ver = $ver }
}

function New-CArchive {
    param([hashtable]$Files, [string]$Top, [string]$ZipName)
    $root = New-CRoot @{}
    $src = New-Item -ItemType Directory -Path (Join-Path $root $Top)
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $src.FullName ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    $zip = Join-Path $root $ZipName
    Compress-Archive -Path $src.FullName -DestinationPath $zip
    $zh = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $root 'SHA256SUMS.txt') -Value "$zh  $ZipName"
    return $zip
}

Describe 'ArtCraftUpdater controller sessions' {
    It 'creates sessions with app defaults' {
        $s = New-UpdaterSession -AppId photocraft
        $s.AppId | Should Be 'photocraft'
        $s.InstallRoot | Should Be 'D:\Art Craft\photocraft'
        $s.Preview | Should Be $null
    }
    It 'detects installed versions from manifests without launching' {
        $root = New-CRoot @{ 'install-manifest.json' = '{"schemaVersion":1,"appId":"photocraft","version":"9.9.9","files":[]}' }
        $info = Get-InstalledAppInfo -AppId photocraft -InstallRoot $root
        $info.Exists | Should Be $true
        $info.Version | Should Be '9.9.9'
        $info.Source | Should Be 'Manifest'
    }
    It 'reports missing installations as unknown' {
        $info = Get-InstalledAppInfo -AppId filmcraft -InstallRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-dir-12345')
        $info.Exists | Should Be $false
        $info.Version | Should Be $null
    }
    It 'rejects missing archives at selection time' {
        $s = New-UpdaterSession -AppId photocraft
        $r = Set-UpdateArchive -Session $s -ArchivePath 'C:\no-such-archive.zip'
        $r.Ok | Should Be $false
    }
}

Describe 'ArtCraftUpdater controller preview binding' {
    It 'runs a dry-run preview that changes nothing' {
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $before = @(Get-ChildItem -LiteralPath $appDir -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        $s = New-UpdaterSession -AppId photocraft
        $s.InstallRoot = $appDir
        (Set-UpdateArchive -Session $s -ArchivePath $zip).Ok | Should Be $true
        $m = New-CMocks -Version '9.9.9'
        $out = Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $out.Ok | Should Be $true
        (Test-PreviewBinding -Session $s) | Should Be $true
        $after = @(Get-ChildItem -LiteralPath $appDir -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        (Compare-Object @($before) @($after)) | Should Be $null
    }
    It 'invalidates the binding when the archive changes' {
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $s = New-UpdaterSession -AppId photocraft
        $s.InstallRoot = $appDir
        Set-UpdateArchive -Session $s -ArchivePath $zip | Out-Null
        $m = New-CMocks -Version '9.9.9'
        (Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $true
        Set-Content -LiteralPath $zip -Value 'tampered' -Force
        (Test-PreviewBinding -Session $s) | Should Be $false
        $blocked = Install-ApprovedUpdate -Session $s -Confirmed -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $blocked.Ok | Should Be $false
        ($blocked.Error -join '') | Should Match 'stale'
    }
    It 'invalidates the binding when the app or options change' {
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $s = New-UpdaterSession -AppId photocraft
        $s.InstallRoot = $appDir
        Set-UpdateArchive -Session $s -ArchivePath $zip | Out-Null
        $m = New-CMocks -Version '9.9.9'
        (Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $true
        (Test-PreviewBinding -Session $s) | Should Be $true
        $s.AppId = 'filmcraft'
        (Test-PreviewBinding -Session $s) | Should Be $false
        $s.AppId = 'photocraft'
        (Test-PreviewBinding -Session $s) | Should Be $true
        (Test-PreviewBinding -Session $s -McpConfigPath 'C:\other.json') | Should Be $false
        $blocked = Install-ApprovedUpdate -Session $s -Confirmed -McpConfigPath 'C:\other.json' -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $blocked.Ok | Should Be $false
        ($blocked.Error -join '') | Should Match 'stale'
    }
    It 'blocks install without a preview and without confirmation' {
        $s = New-UpdaterSession -AppId photocraft
        $m = New-CMocks -Version '9.9.9'
        (Install-ApprovedUpdate -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $false
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $s.InstallRoot = $appDir
        Set-UpdateArchive -Session $s -ArchivePath $zip | Out-Null
        (Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $true
        (Install-ApprovedUpdate -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $false
    }
    It 'installs after confirmation and reports failures honestly' {
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $s = New-UpdaterSession -AppId photocraft
        $s.InstallRoot = $appDir
        Set-UpdateArchive -Session $s -ArchivePath $zip | Out-Null
        $m = New-CMocks -Version '9.9.9'
        (Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver).Ok | Should Be $true
        $done = Install-ApprovedUpdate -Session $s -Confirmed -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $done.Ok | Should Be $true
        (Get-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Raw) | Should Be 'v2'
        $badSig = { param($a, $b) [PSCustomObject]@{ Valid = $false; Status = 'NotSigned'; Subject = $null } }.GetNewClosure()
        $appDir2 = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $s2 = New-UpdaterSession -AppId photocraft
        $s2.InstallRoot = $appDir2
        Set-UpdateArchive -Session $s2 -ArchivePath $zip | Out-Null
        $prev = Start-UpdatePreview -Session $s2 -SignatureChecker $badSig -VersionProvider $m.Ver
        $prev.Ok | Should Be $false
        $blocked = Install-ApprovedUpdate -Session $s2 -Confirmed -SignatureChecker $badSig -VersionProvider $m.Ver
        $blocked.Ok | Should Be $false
        (Get-Content -LiteralPath (Join-Path $appDir2 'photocraft.exe') -Raw) | Should Be 'v1'
    }
    It 'summarizes previews for the log view' {
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $zip = New-CArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $s = New-UpdaterSession -AppId photocraft
        $s.InstallRoot = $appDir
        Set-UpdateArchive -Session $s -ArchivePath $zip | Out-Null
        $m = New-CMocks -Version '9.9.9'
        $out = Start-UpdatePreview -Session $s -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $text = (Format-PreviewSummary -Preview $out.Preview) -join "`n"
        $text | Should Match '9\.9\.9'
        $text | Should Match 'Replace'
        (Format-PreviewSummary -Preview $null) -join '' | Should Match 'No preview'
    }
}

Describe 'ArtCraftUpdater tracked updates' {
    It 'downloads, previews, and installs after prior confirmation' {
        $srvDir = New-CRoot @{}
        $top = 'photocraft-9.9.9-windows-x64-portable'
        $stage = New-Item -ItemType Directory -Path (Join-Path $srvDir $top) | ForEach-Object { $_.FullName }
        Set-Content -LiteralPath (Join-Path $stage 'photocraft.exe') -Value 'v2' -NoNewline
        Set-Content -LiteralPath (Join-Path $stage 'photocraft-cli.exe') -Value 'v2' -NoNewline
        Set-Content -LiteralPath (Join-Path $stage 'portable.txt') -Value 'm' -NoNewline
        $zipReal = Join-Path $srvDir 'photocraft-9.9.9-windows-x64-portable.zip'
        Compress-Archive -Path $stage -DestinationPath $zipReal
        $zh = (Get-FileHash -LiteralPath $zipReal -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $srvDir 'SHA256SUMS.txt') -Value "$zh  photocraft-9.9.9-windows-x64-portable.zip"
        $appDir = New-CRoot @{ 'photocraft.exe' = 'v1'; 'photocraft-cli.exe' = 'v1'; 'portable.txt' = 'm' }
        $toUrl = { param($p) return ('file:///' + ($p -replace '\\', '/')) }
        $st = [PSCustomObject]@{
            AppId = 'photocraft'; DisplayName = 'PhotoCraft'
            AssetUrl = (& $toUrl (Join-Path $srvDir 'photocraft-9.9.9-windows-x64-portable.zip')); ChecksumUrl = (& $toUrl (Join-Path $srvDir 'SHA256SUMS.txt'))
            State = 'UpdateAvailable'; InstallSupported = $true
        }
        $m = New-CMocks -Version '9.9.9'
        $tmpParent = New-CRoot @{}
        $out = Install-AppUpdate -Status $st -TempParent $tmpParent -InstallRoot $appDir -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $out.Success | Should Be $true
        (Get-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Raw) | Should Be 'v2'
    }
    It 'refuses tracked updates with missing URLs or failed downloads' {
        $noUrl = [PSCustomObject]@{ AppId = 'photocraft'; DisplayName = 'PhotoCraft'; AssetUrl = ''; ChecksumUrl = ''; State = 'UpdateAvailable'; InstallSupported = $true }
        (Install-AppUpdate -Status $noUrl).Success | Should Be $false
        $tmpParent = New-CRoot @{}
        $badDl = [PSCustomObject]@{ AppId = 'photocraft'; DisplayName = 'PhotoCraft';
            AssetUrl = 'file:///C:/no-such-file-12345.zip'; ChecksumUrl = 'file:///C:/no-such-file-12345.txt';
            State = 'UpdateAvailable'; InstallSupported = $true }
        $out = Install-AppUpdate -Status $badDl -TempParent $tmpParent
        $out.Success | Should Be $false
        ($out.Outcome -join '') | Should Match 'download failed'
    }
}

Describe 'ArtCraftInstall GUI script static checks' {
    It 'parses without errors and wires required controls' {
        $errs = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content 'D:\Art Craft\tools\ArtCraftUpdater.Gui.ps1' -Raw), [ref]$errs)
        $errs.Count | Should Be 0
        $src = Get-Content 'D:\Art Craft\tools\ArtCraftUpdater.Gui.ps1' -Raw
        foreach ($name in @('btnCheck', 'btnUpdate', 'btnUpdateAll', 'appList', 'summaryList', 'statusLabel', 'progressBar', 'runspacefactory', 'Timer', 'MessageBox', 'Install-AppUpdate', 'Get-RowActions', 'Get-AppReleaseStatus', 'Find-InstalledApps', 'Read-AppRegistry')) {
            ($src -match [regex]::Escape($name)) | Should Be $true
        }
    }
}

Describe 'ArtCraftUpdater fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:CRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:CRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
