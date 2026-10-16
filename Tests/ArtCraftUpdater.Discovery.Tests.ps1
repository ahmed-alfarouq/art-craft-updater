<#
.SYNOPSIS
  Pester tests for Phase 3: discovery, registry trust, version comparison,
  release-status checks, row actions, and the asset downloader.
  Fixtures and injected HTTP only. Real installs are never modified, and no
  real network access occurs (all HTTP is mocked except where noted).
#>
Import-Module 'D:\Art Craft\tools\ArtCraftUpdater.Controller.psm1' -Force

$Script:DRoots = @()

function New-DRoot {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftD-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:DRoots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

function New-DRegistry {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftDreg-' + [guid]::NewGuid().ToString('N') + '.json')
    $Script:DRoots += $path
    Set-Content -LiteralPath $path -Value @'
{
  "registryVersion": 1,
  "infrastructureDirectories": [".quarantine", "tools"],
  "applications": [
    {"appId": "alpha", "displayName": "Alpha", "repo": "https://github.com/storytold/alpha", "assetPolicy": "verified", "assetPattern": "-windows-x64-portable.zip", "checksumFile": "SHA256SUMS.txt", "installStrategy": "flat"},
    {"appId": "beta", "displayName": "Beta", "repo": "https://github.com/storytold/beta", "assetPolicy": "unconfirmed", "assetPattern": "-windows-x64-portable.zip", "checksumFile": "SHA256SUMS.txt", "installStrategy": "unsupported"}
  ]
}
'@
    return Read-AppRegistry -RegistryPath $path
}

function New-DReleasesJson {
    param([array]$Tags)
    $items = @()
    foreach ($t in $Tags) {
        $draft = 'false'
        $pre = 'false'
        $tag = $t
        if ($t.StartsWith('draft:')) { $draft = 'true'; $tag = $t.Substring(6) }
        if ($t.StartsWith('pre:')) { $pre = 'true'; $tag = $t.Substring(4) }
        $items += "{`"tag_name`":`"$tag`",`"draft`":$draft,`"prerelease`":$pre,`"assets`":[{`"name`":`"alpha-1.0.0-windows-x64-portable.zip`",`"browser_download_url`":`"https://example.com/a.zip`"},{`"name`":`"SHA256SUMS.txt`",`"browser_download_url`":`"https://example.com/s.txt`"}]}"
    }
    return '[' + ($items -join ',') + ']'
}

Describe 'ArtCraft discovery' {
    It 'finds registered apps and excludes everything else' {
        $root = New-DRoot @{
            'alpha/alpha.exe'            = 'x'
            'projects/my project.fcproj' = 'user work, not an app'
            'tools/helper.ps1'           = 'tooling, not an app'
            '.quarantine/old/app.exe'    = 'quarantined, not installed'
            'archives.zip'               = 'a file, not a directory'
        }
        $reg = New-DRegistry
        $found = Find-InstalledApps -Root $root -Registry $reg
        (@($found | Where-Object { $_.AppId -eq 'alpha' }).Count) | Should Be 1
        (@($found | Where-Object { $_.InstallRoot -like '*projects*' }).Count) | Should Be 0
        (@($found | Where-Object { $_.InstallRoot -like '*tools*' }).Count) | Should Be 0
        (@($found | Where-Object { $_.InstallRoot -like '*quarantine*' }).Count) | Should Be 0
    }
    It 'detects versioned-layout installs by executable identity' {
        $root = New-DRoot @{ 'beta-1.0.0-windows-x64-portable/beta.exe' = 'x' }
        $reg = New-DRegistry
        $found = Find-InstalledApps -Root $root -Registry $reg
        $b = @($found | Where-Object { $_.AppId -eq 'beta' })
        $b.Count | Should Be 1
        $b[0].Status | Should Be 'Identified'
    }
    It 'reports executable-bearing unknowns as needing configuration' {
        $root = New-DRoot @{ 'mystery/mystery.exe' = 'x' }
        $reg = New-DRegistry
        $found = Find-InstalledApps -Root $root -Registry $reg
        $u = @($found | Where-Object { $_.Status -eq 'NeedsConfiguration' })
        $u.Count | Should Be 1
        ($u[0].Reason -join '') | Should Match 'never guessed'
        $u[0].AppId | Should Be $null
    }
    It 'rejects untrusted repository URLs instead of trusting them' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftDbad-' + [guid]::NewGuid().ToString('N') + '.json')
        $Script:DRoots += $path
        Set-Content -LiteralPath $path -Value '{"registryVersion":1,"applications":[{"appId":"evil","displayName":"Evil","repo":"https://example.com/not-storytold/evil","installStrategy":"flat"}]}'
        $reg = Read-AppRegistry -RegistryPath $path
        (@($reg.Entries | Where-Object { $_.AppId -eq 'evil' }).Count) | Should Be 0
        ($reg.Errors -join ';') | Should Match 'untrusted'
    }
    It 'discovers a fourth registered app without hardcoding three' {
        $root = New-DRoot @{ 'alpha/alpha.exe' = 'x'; 'beta/beta.exe' = 'y' }
        $reg = New-DRegistry
        $found = Find-InstalledApps -Root $root -Registry $reg
        (@($found | Where-Object { $_.Status -eq 'Identified' }).Count) | Should Be 2
    }
}

Describe 'ArtCraft version comparison' {
    It 'orders versions numerically across segments' {
        (Compare-AppVersions -A '0.10.0' -B '0.9.2') | Should Be 1
        (Compare-AppVersions -A '0.9.2' -B '0.10.0') | Should Be -1
        (Compare-AppVersions -A 'v0.10.0' -B '0.10.0') | Should Be 0
        (Compare-AppVersions -A '1.2' -B '1.2.0') | Should Be 0
        (Compare-AppVersions -A '2.0.0' -B '10.0.0') | Should Be -1
    }
    It 'sorts prereleases below clean releases and rejects garbage' {
        (Compare-AppVersions -A '1.0.0-rc.1' -B '1.0.0') | Should Be -1
        (Compare-AppVersions -A 'nope' -B '1.0.0') | Should Be $null
        (Compare-AppVersions -A '' -B '1.0.0') | Should Be $null
    }
}

Describe 'ArtCraft release status' {
    It 'selects the newest stable release, never drafts or prereleases' {
        $reg = New-DRegistry
        $entry = @($reg.Entries | Where-Object { $_.AppId -eq 'alpha' })[0]
        $json = New-DReleasesJson @('v1.0.0', 'draft:v9.9.9', 'pre:v8.0.0', 'v0.9.0')
        $http = { param($u) return $json }.GetNewClosure()
        $s = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '0.9.0' -HttpGet $http
        $s.LatestVersion | Should Be '1.0.0'
        $s.State | Should Be 'UpdateAvailable'
        $s.AssetUrl | Should Be 'https://example.com/a.zip'
        $s.ChecksumUrl | Should Be 'https://example.com/s.txt'
    }
    It 'reports up to date only on numeric equality' {
        $reg = New-DRegistry
        $entry = @($reg.Entries | Where-Object { $_.AppId -eq 'alpha' })[0]
        $oneOh = New-DReleasesJson @('v1.0.0')
        $http = { param($u) return $oneOh }.GetNewClosure()
        (Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $http).State | Should Be 'UpToDate'
        (Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0' -HttpGet $http).State | Should Be 'UpToDate'
    }
    It 'reports unknown rather than up to date on missing data' {
        $reg = New-DRegistry
        $entry = @($reg.Entries | Where-Object { $_.AppId -eq 'alpha' })[0]
        $empty = { param($u) return '[]' }.GetNewClosure()
        (Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $empty).State | Should Be 'Unknown'
        $twoOh = New-DReleasesJson @('v2.0.0')
        $nover = { param($u) return $twoOh }.GetNewClosure()
        (Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '' -HttpGet $nover).State | Should Be 'Unknown'
        $noassets = { param($u) return '[{"tag_name":"v2.0.0","draft":false,"prerelease":false,"assets":[]}]' }.GetNewClosure()
        $s = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $noassets
        $s.State | Should Be 'Unknown'
        ($s.Reason -join '') | Should Match 'missing'
    }
    It 'reports check failures without claiming currency' {
        $reg = New-DRegistry
        $entry = @($reg.Entries | Where-Object { $_.AppId -eq 'alpha' })[0]
        $boom = { param($u) throw 'network down' }.GetNewClosure()
        $s = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $boom
        $s.State | Should Be 'CheckFailed'
        ($s.Reason -join '') | Should Match 'network down'
        $garbage = { param($u) return 'this is not json{{{]' }.GetNewClosure()
        (Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $garbage).State | Should Be 'CheckFailed'
    }
    It 'withholds install support for unverified policies' {
        $reg = New-DRegistry
        $entry = @($reg.Entries | Where-Object { $_.AppId -eq 'beta' })[0]
        $twoOhBeta = New-DReleasesJson @('v2.0.0')
        $http = { param($u) return $twoOhBeta }.GetNewClosure()
        $s = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion '1.0.0' -HttpGet $http
        $s.InstallSupported | Should Be $false
        $s.State | Should Be 'Unknown'
    }
}

Describe 'ArtCraft row actions' {
    It 'enables update only for supported, asset-resolved newer releases' {
        $ok = [PSCustomObject]@{ State = 'UpdateAvailable'; InstallSupported = $true; AssetUrl = 'https://x/a.zip'; ChecksumUrl = 'https://x/s.txt'; Reason = '' }
        (Get-RowActions -Status $ok).CanUpdate | Should Be $true
        $noAssets = [PSCustomObject]@{ State = 'UpdateAvailable'; InstallSupported = $true; AssetUrl = ''; ChecksumUrl = ''; Reason = '' }
        (Get-RowActions -Status $noAssets).CanUpdate | Should Be $false
        $uptodate = [PSCustomObject]@{ State = 'UpToDate'; InstallSupported = $false; AssetUrl = ''; ChecksumUrl = ''; Reason = 'current' }
        (Get-RowActions -Status $uptodate).CanUpdate | Should Be $false
        $failed = [PSCustomObject]@{ State = 'CheckFailed'; InstallSupported = $false; AssetUrl = ''; ChecksumUrl = ''; Reason = 'offline' }
        $r = Get-RowActions -Status $failed
        $r.CanUpdate | Should Be $false
        ($r.Reason -join '') | Should Match 'offline'
    }
}

Describe 'ArtCraft asset downloads' {
    It 'copies file URLs and reports missing sources' {
        $root = New-DRoot @{ 'payload.bin' = '0123456789' }
        $dst = Join-Path $root 'out.bin'
        $r = Save-ReleaseAsset -Url ('file:///' + ((Join-Path $root 'payload.bin') -replace '\\', '/')) -Destination $dst
        $r.Ok | Should Be $true
        (Get-Content -LiteralPath $dst -Raw) | Should Be '0123456789'
        $bad = Save-ReleaseAsset -Url 'file:///C:/no-such-file-12345.bin' -Destination (Join-Path $root 'nope.bin')
        $bad.Ok | Should Be $false
    }
}

Describe 'ArtCraft discovery fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:DRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:DRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
