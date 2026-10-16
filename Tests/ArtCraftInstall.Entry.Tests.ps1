<#
.SYNOPSIS
  Pester tests for Update-ArtCraftApp, Get-PublishedChecksum, and
  Get-EffectCraftRetention. Fixtures under %TEMP% only. Real installs are
  referenced solely to verify the production guard and the read-only dry-run
  report, which performs no modifications.
#>
Import-Module 'D:\Art Craft\tools\ArtCraftInstall.psm1' -Force

$Script:ERoots = @()

function New-ERoot {
    param([string]$Name = $null)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftE-' + [guid]::NewGuid().ToString('N'))
    } else {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) $Name
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:ERoots += $root
    return $root
}

function New-EArchive {
    param([hashtable]$Files, [string]$Top = 'photocraft-9.9.9-windows-x64-portable', [string]$ZipName = 'app.zip')
    $root = New-ERoot
    $src = New-Item -ItemType Directory -Path (Join-Path $root $Top)
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $src.FullName ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    $zip = Join-Path $root $ZipName
    Compress-Archive -Path $src.FullName -DestinationPath $zip
    return [PSCustomObject]@{ Path = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function New-EMocks {
    param([string]$Version)
    $sig = { param($ExePath, $Expected) [PSCustomObject]@{ Valid = $true; Status = 'Valid'; Subject = 'Learning Machines Inc' } }.GetNewClosure()
    $ver = { param($GuiPath, $CliPath) [PSCustomObject]@{ GuiVersion = $Version; GuiSource = 'PE'; CliVersion = $Version; CliSource = 'Stdout' } }.GetNewClosure()
    return @{ Sig = $sig; Ver = $ver }
}

function Get-ESnapshot {
    param([string]$Root)
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
    if ($null -eq $items) { return @() }
    return $items
}

Describe 'ArtCraftInstall entry point selection' {
    It 'auto-selects the only archive and derives version and hash' {
        $root = New-ERoot
        $appDir = New-Item -ItemType Directory -Path (Join-Path $root 'photocraft') | ForEach-Object { $_.FullName }
        Set-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Value 'v1' -NoNewline
        Set-Content -LiteralPath (Join-Path $appDir 'photocraft-cli.exe') -Value 'v1' -NoNewline
        Set-Content -LiteralPath (Join-Path $appDir 'portable.txt') -Value 'm' -NoNewline
        $zip = New-EArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        Copy-Item -LiteralPath $zip.Path -Destination (Join-Path $appDir 'photocraft-9.9.9-windows-x64-portable.zip')
        Set-Content -LiteralPath (Join-Path $appDir 'SHA256SUMS.txt') -Value "$($zip.Sha256)  photocraft-9.9.9-windows-x64-portable.zip"
        $m = New-EMocks -Version '9.9.9'
        $r = Update-ArtCraftApp -AppId photocraft -InstallRoot $appDir -DryRun `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        $r.DryRun | Should Be $true
        $r.Selection.Version | Should Be '9.9.9'
        ($r.Selection.ArchivePath -like '*photocraft-9.9.9-windows-x64-portable.zip') | Should Be $true
        ($r.Selection.HashSource -like 'published manifest entry*') | Should Be $true
    }
    It 'refuses ambiguous archive selection' {
        $root = New-ERoot
        $appDir = New-Item -ItemType Directory -Path (Join-Path $root 'photocraft') | ForEach-Object { $_.FullName }
        $z1 = New-EArchive @{ 'photocraft.exe' = 'a'; 'photocraft-cli.exe' = 'a' } -Top 'photocraft-9.9.8-windows-x64-portable' -ZipName 'photocraft-9.9.8-windows-x64-portable.zip'
        $z2 = New-EArchive @{ 'photocraft.exe' = 'b'; 'photocraft-cli.exe' = 'b' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        Copy-Item -LiteralPath $z1.Path -Destination (Join-Path $appDir 'photocraft-9.9.8-windows-x64-portable.zip')
        Copy-Item -LiteralPath $z2.Path -Destination (Join-Path $appDir 'photocraft-9.9.9-windows-x64-portable.zip')
        $m = New-EMocks -Version '9.9.9'
        $r = Update-ArtCraftApp -AppId photocraft -InstallRoot $appDir -DryRun -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        ($r.Errors -join ';') | Should Match 'explicitly'
    }
    It 'requires an explicit hash when no manifest entry exists' {
        $root = New-ERoot
        $appDir = New-Item -ItemType Directory -Path (Join-Path $root 'photocraft') | ForEach-Object { $_.FullName }
        $zip = New-EArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $zp = Join-Path $appDir 'photocraft-9.9.9-windows-x64-portable.zip'
        Copy-Item -LiteralPath $zip.Path -Destination $zp
        $m = New-EMocks -Version '9.9.9'
        $r = Update-ArtCraftApp -AppId photocraft -InstallRoot $appDir -ArchivePath $zp -Version '9.9.9' -DryRun `
            -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $false
        ($r.Errors -join ';') | Should Match 'ExpectedArchiveSha256'
        $r2 = Update-ArtCraftApp -AppId photocraft -InstallRoot $appDir -ArchivePath $zp -Version '9.9.9' -DryRun `
            -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r2.Success | Should Be $true
        $r2.Selection.HashSource | Should Be 'explicit caller value'
    }
    It 'refuses production roots without approval even for dry runs' {
        $m = New-EMocks -Version '9.9.9'
        foreach ($prod in @('D:\Art Craft\photocraft', 'D:\Art Craft\filmcraft', 'D:\Art Craft\EffectCraft')) {
            $app = if ($prod -like '*EffectCraft') { 'effectcraft' } elseif ($prod -like '*filmcraft*') { 'filmcraft' } else { 'photocraft' }
            $r = Update-ArtCraftApp -AppId $app -InstallRoot $prod -ArchivePath 'C:\nonexistent.zip' -Version '9.9.9' `
                -ExpectedArchiveSha256 ('0' * 64) -DryRun -SignatureChecker $m.Sig -VersionProvider $m.Ver
            $r.Success | Should Be $false
        }
    }
}

Describe 'ArtCraftInstall entry point dry-run purity' {
    It 'changes nothing on disk during flat dry runs' {
        $root = New-ERoot
        $appDir = New-Item -ItemType Directory -Path (Join-Path $root 'my app') | ForEach-Object { $_.FullName }
        Set-Content -LiteralPath (Join-Path $appDir 'photocraft.exe') -Value 'v1' -NoNewline
        Set-Content -LiteralPath (Join-Path $appDir 'photocraft-cli.exe') -Value 'v1' -NoNewline
        Set-Content -LiteralPath (Join-Path $appDir 'portable.txt') -Value 'm' -NoNewline
        $zip = New-EArchive @{ 'photocraft.exe' = 'v2'; 'photocraft-cli.exe' = 'v2'; 'portable.txt' = 'm' } -Top 'photocraft-9.9.9-windows-x64-portable' -ZipName 'photocraft-9.9.9-windows-x64-portable.zip'
        $zp = Join-Path $appDir 'photocraft-9.9.9-windows-x64-portable.zip'
        Copy-Item -LiteralPath $zip.Path -Destination $zp
        $before = Get-ESnapshot -Root $appDir
        $m = New-EMocks -Version '9.9.9'
        $r = Update-ArtCraftApp -AppId photocraft -InstallRoot $appDir -ArchivePath $zp -Version '9.9.9' -DryRun `
            -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        (Compare-Object @($before) @(Get-ESnapshot -Root $appDir)) | Should Be $null
    }
    It 'changes nothing on disk during versioned dry runs' {
        $root = New-ERoot
        $instRoot = New-Item -ItemType Directory -Path (Join-Path $root 'bundle dir') | ForEach-Object { $_.FullName }
        $zip = New-EArchive @{ 'effectcraft.exe' = 'v2'; 'effectcraft-cli.exe' = 'v2' } -Top 'effectcraft-9.9.9-windows-x64-portable' -ZipName 'effectcraft-9.9.9-windows-x64-portable.zip'
        $before = Get-ESnapshot -Root $instRoot
        $m = New-EMocks -Version '9.9.9'
        $r = Update-ArtCraftApp -AppId effectcraft -InstallRoot $instRoot -ArchivePath $zip.Path -Version '9.9.9' -DryRun `
            -ExpectedArchiveSha256 $zip.Sha256 -SignatureChecker $m.Sig -VersionProvider $m.Ver
        $r.Success | Should Be $true
        (Test-Path -LiteralPath (Join-Path $instRoot 'effectcraft-9.9.9-windows-x64-portable')) | Should Be $false
        (Compare-Object @($before) @(Get-ESnapshot -Root $instRoot)) | Should Be $null
    }
}

Describe 'ArtCraftInstall retention report' {
    It 'retains the newest two installs and flags older ones' {
        $root = New-ERoot
        foreach ($v in @('0.8.0', '0.9.2', '0.10.0')) {
            New-Item -ItemType Directory -Path (Join-Path $root "effectcraft-$v-windows-x64-portable") | Out-Null
        }
        $rep = Get-EffectCraftRetention -InstallRoot $root
        $rep.Count | Should Be 3
        (@($rep | Where-Object { $_.Retain }).Count) | Should Be 2
        $old = @($rep | Where-Object { $_.Version -eq '0.8.0' })
        $old.Retain | Should Be $false
        ($old.Reason -join '') | Should Match 'quarantine'
    }
}

Describe 'ArtCraftInstall published checksums' {
    It 'parses checksum manifests and ignores malformed lines' {
        $root = New-ERoot
        $p = Join-Path $root 'SHA256SUMS.txt'
        $lines = @()
        $lines += ('aa' * 32) + '  good.zip'
        $lines += 'not-a-hash  bad.zip'
        $lines += ''
        $lines += 'short line'
        Set-Content -LiteralPath $p -Value $lines
        $r = Get-PublishedChecksum -Url ('file:///' + ($p -replace '\\', '/'))
        $r.Error | Should Be $null
        $r.Url | Should Match 'SHA256SUMS.txt'
        $r.Entries['good.zip'] | Should Be ('aa' * 32)
        $r.Entries.ContainsKey('bad.zip') | Should Be $false
    }
    It 'reports fetch failures without throwing' {
        $r = Get-PublishedChecksum -Url 'file:///C:/no-such-dir-12345/SHA256SUMS.txt'
        $r.Error | Should Not BeNullOrEmpty
        $r.Entries.Count | Should Be 0
    }
}

Describe 'ArtCraftInstall versioned fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:ERoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:ERoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
