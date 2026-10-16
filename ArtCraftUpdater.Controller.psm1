<#
.SYNOPSIS
  UI-independent workflow controller for the ArtCraft updater GUI.
.DESCRIPTION
  Pure workflow logic over ArtCraftInstall.psm1: session state, installed-app
  detection (manifest, then PE metadata - never launches executables), preview
  binding, and gated installation. No WinForms code here; nothing here writes
  to an installation except Install-ApprovedUpdate after explicit confirmation
  and a passing binding check.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$updaterModule = Join-Path $PSScriptRoot 'ArtCraftInstall.psm1'
if (-not (Get-Module -Name ArtCraftInstall)) { Import-Module $updaterModule -Force }

$Script:UpdaterModuleName = 'ArtCraftInstall'
function Get-PreviewProp {
    # Local StrictMode-safe property read (Get-PropValue is module-internal
    # to ArtCraftInstall.psm1 and not exported).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

$Script:DefaultInstallRoots = @{
    photocraft  = 'D:\Art Craft\photocraft'
    filmcraft   = 'D:\Art Craft\filmcraft'
    effectcraft = 'D:\Art Craft\EffectCraft'
}

function New-UpdaterSession {
    <#
    .SYNOPSIS
      Creates an empty workflow session for one app. No filesystem access.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('photocraft', 'filmcraft', 'effectcraft')][string]$AppId)
    return [PSCustomObject]@{
        AppId            = $AppId
        InstallRoot      = $Script:DefaultInstallRoots[$AppId]
        ArchivePath      = $null
        ArchiveSha256    = $null
        Version          = $null
        ExpectedHash     = $null
        HashSource       = $null
        ChecksumManifest = $null
        Preview          = $null
        PreviewBinding   = $null
    }
}

function Get-InstalledAppInfo {
    <#
    .SYNOPSIS
      Read-only detection of the installed app: version + path. Never launches.
      Sources: install-manifest.json, then GUI-exe PE metadata. Unknown -> None.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $info = [PSCustomObject]@{ AppId = $AppId; InstallRoot = $InstallRoot; Exists = $false; Version = $null; Source = 'None'; ExePath = $null }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { return $info }
    $read = Read-InstallManifest -LiteralPath (Join-Path $InstallRoot 'install-manifest.json')
    if ($read.Found -and $read.Errors.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($read.Manifest.version)) {
        $info.Exists = $true
        $info.Version = [string]$read.Manifest.version
        $info.Source = 'Manifest'
        return $info
    }
    $guiName = "$AppId.exe"
    $candidates = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Depth 2 -Filter $guiName -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName | Sort-Object)
    if ($candidates.Count -eq 0) { return $info }
    $pe = Get-PeVersion -LiteralPath $candidates[0]
    $info.Exists = $true
    $info.ExePath = $candidates[0]
    if (-not [string]::IsNullOrWhiteSpace($pe.ProductVersion)) {
        $info.Version = [string]$pe.ProductVersion
        $info.Source = 'PE'
    }
    return $info
}

function Set-UpdateArchive {
    <#
    .SYNOPSIS
      Binds an archive file to the session (existence + hash only). Any archive
      change clears the previous preview binding.
    #>
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ArchivePath,
        [string]$ChecksumManifestPath = $null,
        [string]$ExpectedHash = $null
    )
    $Session.ArchivePath = $ArchivePath
    $Session.ChecksumManifest = $ChecksumManifestPath
    $Session.ExpectedHash = $ExpectedHash
    $Session.Preview = $null
    $Session.PreviewBinding = $null
    $Session.Version = $null
    $Session.ArchiveSha256 = $null
    $Session.HashSource = $null
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        return [PSCustomObject]@{ Ok = $false; Error = 'archive file not found; pick a release ZIP first' }
    }
    try {
        $Session.ArchiveSha256 = Get-FileSha256Hex -LiteralPath $ArchivePath
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = "archive is not readable: $($_.Exception.Message)" }
    }
    return [PSCustomObject]@{ Ok = $true; Error = $null }
}

function Start-UpdatePreview {
    <#
    .SYNOPSIS
      Runs Update-ArtCraftApp in dry-run mode and binds the preview to the exact
      archive bytes, version, hash, and target. Changes nothing on disk.
    #>
    param(
        [Parameter(Mandatory = $true)]$Session,
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$McpConfigPath = $null
    )
    if ([string]::IsNullOrWhiteSpace($Session.ArchivePath)) {
        return [PSCustomObject]@{ Ok = $false; Error = 'no archive selected'; Preview = $null }
    }
    $params = @{
        AppId = $Session.AppId; InstallRoot = $Session.InstallRoot
        ArchivePath = $Session.ArchivePath; DryRun = $true; AllowProduction = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Session.Version)) { $params['Version'] = $Session.Version }
    if (-not [string]::IsNullOrWhiteSpace($Session.ExpectedHash)) { $params['ExpectedArchiveSha256'] = $Session.ExpectedHash }
    if (-not [string]::IsNullOrWhiteSpace($Session.ChecksumManifest)) { $params['ChecksumManifestPath'] = $Session.ChecksumManifest }
    if ($null -ne $SignatureChecker) { $params['SignatureChecker'] = $SignatureChecker }
    if ($null -ne $VersionProvider) { $params['VersionProvider'] = $VersionProvider }
    if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) { $params['McpConfigPath'] = $McpConfigPath }
    try {
        $preview = Update-ArtCraftApp @params
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = "preview failed: $($_.Exception.Message)"; Preview = $null }
    }
    $Session.Preview = $preview
    if ($null -eq $preview.Selection) {
        return [PSCustomObject]@{ Ok = $false; Error = ($preview.Errors -join '; '); Preview = $preview }
    }
    $Session.Version = $preview.Selection.Version
    $Session.ExpectedHash = $preview.Selection.ExpectedArchiveSha256
    $Session.HashSource = $preview.Selection.HashSource
    $Session.PreviewBinding = [PSCustomObject]@{
        AppId = $Session.AppId
        ArchivePath = $preview.Selection.ArchivePath
        ArchiveSha256 = (Get-FileSha256Hex -LiteralPath $preview.Selection.ArchivePath)
        Version = $preview.Selection.Version
        ExpectedHash = $preview.Selection.ExpectedArchiveSha256
        InstallRoot = $Session.InstallRoot
        McpConfigPath = $McpConfigPath
    }
    return [PSCustomObject]@{ Ok = [bool]$preview.Success; Error = ($preview.Errors -join '; '); Preview = $preview }
}

function Test-PreviewBinding {
    <#
    .SYNOPSIS
      True only when the app, archive bytes, version, hash, target, and MCP
      options are identical to the bound preview. Any change invalidates it.
    #>
    param([Parameter(Mandatory = $true)]$Session, [string]$McpConfigPath = $null)
    $b = $Session.PreviewBinding
    if ($null -eq $b -or $null -eq $Session.Preview) { return $false }
    if ($Session.AppId -ne (Get-PreviewProp $b 'AppId')) { return $false }
    if ($Session.ArchivePath -ne $b.ArchivePath) { return $false }
    if ($Session.InstallRoot -ne $b.InstallRoot) { return $false }
    $boundMcp = [string](Get-PreviewProp $b 'McpConfigPath')
    if ([string]$McpConfigPath -ne $boundMcp) { return $false }
    if (-not (Test-Path -LiteralPath $Session.ArchivePath -PathType Leaf)) { return $false }
    try {
        $now = Get-FileSha256Hex -LiteralPath $Session.ArchivePath
    } catch { return $false }
    return ($now.ToLowerInvariant() -eq $b.ArchiveSha256.ToLowerInvariant())
}

function Install-ApprovedUpdate {
    <#
    .SYNOPSIS
      Executes a previously successful, still-bound preview after explicit
      confirmation. Refuses missing, failed, or stale previews.
    #>
    param(
        [Parameter(Mandatory = $true)]$Session,
        [switch]$Confirmed,
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$McpConfigPath = $null
    )
    if (-not $Confirmed) {
        return [PSCustomObject]@{ Ok = $false; Error = 'installation requires explicit user confirmation'; Result = $null }
    }
    if ($null -eq $Session.Preview -or -not $Session.Preview.Success) {
        return [PSCustomObject]@{ Ok = $false; Error = 'no successful preview to install from; run Verify & Preview first'; Result = $null }
    }
    if (-not (Test-PreviewBinding -Session $Session -McpConfigPath $McpConfigPath)) {
        return [PSCustomObject]@{ Ok = $false; Error = 'preview is stale (app, archive, version, hash, target, or options changed); re-run Verify & Preview'; Result = $null }
    }
    $params = @{
        AppId = $Session.AppId; InstallRoot = $Session.InstallRoot
        ArchivePath = $Session.PreviewBinding.ArchivePath; Version = $Session.PreviewBinding.Version
        ExpectedArchiveSha256 = $Session.PreviewBinding.ExpectedHash; AllowProduction = $true
    }
    if ($null -ne $SignatureChecker) { $params['SignatureChecker'] = $SignatureChecker }
    if ($null -ne $VersionProvider) { $params['VersionProvider'] = $VersionProvider }
    if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) { $params['McpConfigPath'] = $McpConfigPath }
    try {
        $result = Update-ArtCraftApp @params
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = "installation failed: $($_.Exception.Message)"; Result = $null }
    }
    if (-not $result.Success) {
        return [PSCustomObject]@{ Ok = $false; Error = ($result.Errors -join '; '); Result = $result }
    }
    return [PSCustomObject]@{ Ok = $true; Error = $null; Result = $result }
}

function Format-PreviewSummary {
    <#
    .SYNOPSIS
      Human-readable lines describing a preview result for the log view.
      Accepts $null (reports "No preview available").
    #>
    param([Parameter(Mandatory = $false)][AllowNull()]$Preview)
    $lines = @()
    if ($null -eq $Preview -or $null -eq $Preview.Selection) {
        return @('No preview available.')
    }
    $lines += "Version : $($Preview.Selection.Version)"
    $lines += "Archive : $($Preview.Selection.ArchivePath)"
    $lines += "Hash via: $($Preview.Selection.HashSource)"
    $stages = @($Preview.ExecutorResult.StageResults)
    foreach ($s in $stages) {
        $lines += "  [$($s.Stage)] $($s.Ok) $($s.Detail)"
    }
    $plan = Get-PreviewProp $Preview.ExecutorResult 'Plan'
    if ($null -ne $plan) {
        $groups = @($plan.Actions | Group-Object Action)
        $lines += 'Actions : ' + (($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
        foreach ($a in @($plan.Actions | Where-Object { $_.Action -ne 'Preserve' } | Sort-Object Path)) {
            $lines += "  $($a.Action): $($a.Path) ($($a.Reason))"
        }
        if (@($plan.Actions | Where-Object { $_.Action -ne 'Preserve' }).Count -eq 0) {
            $lines += 'Already installed: every path is preserved, no update needed.'
        }
    }
    if (@($Preview.Errors).Count -gt 0) {
        $lines += 'Errors  : ' + (($Preview.Errors) -join '; ')
    }
    return @($lines)
}

function Read-AppRegistry {
    <#
    .SYNOPSIS
      Reads and validates the trusted application registry. Never guesses:
      entries with non-official repository URLs are rejected.
    #>
    param([string]$RegistryPath = $null)
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Join-Path $PSScriptRoot 'apps.registry.json'
    }
    $result = [PSCustomObject]@{ Entries = @(); Errors = @() }
    try {
        $raw = Get-Content -LiteralPath $RegistryPath -Raw -ErrorAction Stop
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Errors += "registry unreadable: $($_.Exception.Message)"
        return $result
    }
    if ((Get-PreviewProp $doc 'registryVersion') -ne 1) {
        $result.Errors += 'unsupported registry version (expected 1)'
        return $result
    }
    $infra = @(Get-PreviewProp $doc 'infrastructureDirectories')
    if ($null -eq $infra) { $infra = @() }
    foreach ($app in @(Get-PreviewProp $doc 'applications')) {
        $id = [string](Get-PreviewProp $app 'appId')
        $repo = [string](Get-PreviewProp $app 'repo')
        $strategy = [string](Get-PreviewProp $app 'installStrategy')
        if ([string]::IsNullOrWhiteSpace($id)) { $result.Errors += 'registry entry without appId skipped'; continue }
        if ($repo -notmatch '^https://github\.com/storytold/[A-Za-z0-9_.-]+$') {
            $result.Errors += "registry entry '$id' has an untrusted repository URL and is skipped: '$repo'"
            continue
        }
        if (@('flat', 'versioned', 'unsupported') -notcontains $strategy) {
            $result.Errors += "registry entry '$id' has an unknown install strategy and is skipped: '$strategy'"
            continue
        }
        $result.Entries += [PSCustomObject]@{
            AppId           = $id
            DisplayName     = [string](Get-PreviewProp $app 'displayName')
            Repo            = $repo
            AssetPolicy     = [string](Get-PreviewProp $app 'assetPolicy')
            AssetPattern    = [string](Get-PreviewProp $app 'assetPattern')
            ChecksumFile    = [string](Get-PreviewProp $app 'checksumFile')
            InstallStrategy = $strategy
        }
    }
    $result | Add-Member -NotePropertyName InfrastructureDirectories -NotePropertyValue @($infra) -Force
    return $result
}

function Find-InstalledApps {
    <#
    .SYNOPSIS
      Discovers installed applications under an ArtCraft root. Read-only.
      Directories without manifests or executables (projects, data, samples)
      are skipped; executable-bearing unknowns are reported for configuration.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Registry
    )
    $found = @()
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @($found) }
    $byId = @{}
    foreach ($e in @($Registry.Entries)) { $byId[$e.AppId] = $e }
    $infra = @($Registry.InfrastructureDirectories)
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        if ($infra -contains $d.Name) { continue }
        $manifest = Read-InstallManifest -LiteralPath (Join-Path $d.FullName 'install-manifest.json')
        $mid = $null
        if ($manifest.Found -and $manifest.Errors.Count -eq 0) { $mid = [string]$manifest.Manifest.appId }
        if ($mid -and $byId.ContainsKey($mid)) {
            $info = Get-InstalledAppInfo -AppId $mid -InstallRoot $d.FullName
            $found += [PSCustomObject]@{ AppId = $mid; DisplayName = $byId[$mid].DisplayName; InstallRoot = $d.FullName;
                InstalledVersion = $info.Version; VersionSource = $info.Source; Status = 'Identified'; Reason = 'manifest identity' }
            continue
        }
        $matched = $null
        foreach ($id in $byId.Keys) {
            $hits = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Depth 2 -Filter "$id.exe" -File -Force -ErrorAction SilentlyContinue)
            if ($hits.Count -gt 0) { $matched = $id; break }
        }
        if ($matched) {
            $info = Get-InstalledAppInfo -AppId $matched -InstallRoot $d.FullName
            $found += [PSCustomObject]@{ AppId = $matched; DisplayName = $byId[$matched].DisplayName; InstallRoot = $d.FullName;
                InstalledVersion = $info.Version; VersionSource = $info.Source; Status = 'Identified'; Reason = 'executable identity' }
            continue
        }
        $anyExe = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Depth 2 -Filter '*.exe' -File -Force -ErrorAction SilentlyContinue)
        if ($anyExe.Count -gt 0) {
            $found += [PSCustomObject]@{ AppId = $null; DisplayName = $d.Name; InstallRoot = $d.FullName;
                InstalledVersion = $null; VersionSource = 'None'; Status = 'NeedsConfiguration'; Reason = 'executables present but no verified registry identity; repository must be configured, never guessed' }
        }
    }
    return @($found | Sort-Object { if ($_.AppId) { $_.AppId } else { $_.DisplayName } })
}

function Compare-AppVersions {
    <#
    .SYNOPSIS
      Numeric version comparison (-1/0/1); multi-digit safe. $null when either
      side is not parseable. A pre-release suffix sorts below the clean release.
    #>
    param([string]$A, [string]$B)
    $pa = ConvertTo-VersionParts $A
    $pb = ConvertTo-VersionParts $B
    if ($null -eq $pa -or $null -eq $pb) { return $null }
    $n = [Math]::Max($pa.Numbers.Count, $pb.Numbers.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Numbers.Count) { $x = $pa.Numbers[$i] }
        if ($i -lt $pb.Numbers.Count) { $y = $pb.Numbers[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    if ($pa.PreRelease -and -not $pb.PreRelease) { return -1 }
    if ($pb.PreRelease -and -not $pa.PreRelease) { return 1 }
    return 0
}

function ConvertTo-VersionParts {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim() -replace '^[vV]', ''
    $m = [regex]::Match($t, '^(\d+(?:\.\d+)*)')
    if (-not $m.Success) { return $null }
    $nums = @($m.Groups[1].Value -split '\.' | ForEach-Object { [int]$_ })
    $rest = $t.Substring($m.Groups[1].Value.Length)
    return [PSCustomObject]@{ Numbers = $nums; PreRelease = (-not [string]::IsNullOrWhiteSpace($rest)) }
}

function Get-AppReleaseStatus {
    <#
    .SYNOPSIS
      Checks one app's official GitHub releases for a newer stable release.
      Drafts and prereleases are never selected. Failures report CheckFailed,
      never "up to date". HTTP access is injectable for tests.
    #>
    param(
        [Parameter(Mandatory = $true)]$RegistryEntry,
        [string]$InstalledVersion = $null,
        [scriptblock]$HttpGet = $null
    )
    $status = [PSCustomObject]@{
        AppId = $RegistryEntry.AppId; DisplayName = $RegistryEntry.DisplayName
        InstalledVersion = $InstalledVersion; LatestVersion = $null; ReleaseTag = $null
        AssetUrl = $null; ChecksumUrl = $null; InstallSupported = $false
        State = 'CheckFailed'; Reason = $null
    }
    if ($null -eq $HttpGet) {
        $HttpGet = {
            param($Url)
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = 'ArtCraft-Updater'
            $req.Timeout = 30000
            $req.Accept = 'application/vnd.github+json'
            try {
                $resp = $req.GetResponse()
                try {
                    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    return $sr.ReadToEnd()
                } finally { $resp.Close() }
            } catch [System.Net.WebException] {
                $code = $null
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -eq 403 -or $code -eq 429) { throw "GitHub rate limit reached (HTTP $code); retry later" }
                throw "release check failed: $($_.Exception.Message)"
            }
        }.GetNewClosure()
    }
    $apiUrl = ($RegistryEntry.Repo.TrimEnd('/') -replace '^https://github\.com/', 'https://api.github.com/repos/') + '/releases?per_page=20'
    try {
        $json = & $HttpGet $apiUrl
        # ConvertFrom-Json emits a whole JSON array as ONE pipeline object, so
        # @(... | ConvertFrom-Json) would nest it; flatten via ForEach-Object.
        $releases = @($json | ConvertFrom-Json | ForEach-Object { $_ })
    } catch {
        $status.Reason = $_.Exception.Message
        return $status
    }
    $stable = @($releases | Where-Object { -not [bool](Get-PreviewProp $_ 'draft') -and -not [bool](Get-PreviewProp $_ 'prerelease') })
    if ($stable.Count -eq 0) {
        $status.State = 'Unknown'
        $status.Reason = 'no stable releases published'
        return $status
    }
    $best = $null
    foreach ($r in $stable) {
        if ($null -eq $best) { $best = $r; continue }
        $cmp = Compare-AppVersions -A ([string]$r.tag_name) -B ([string]$best.tag_name)
        if ($cmp -eq $null) { continue }
        if ($cmp -gt 0) { $best = $r }
    }
    if ($null -eq $best) {
        $status.State = 'Unknown'
        $status.Reason = 'no parseable stable release tags'
        return $status
    }
    $status.LatestVersion = ([string]$best.tag_name).TrimStart('v', 'V')
    $status.ReleaseTag = [string]$best.tag_name
    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
        $status.State = 'Unknown'
        $status.Reason = 'installed version unknown; latest is ' + $status.LatestVersion
        return $status
    }
    $cmp = Compare-AppVersions -A $status.LatestVersion -B $InstalledVersion
    if ($cmp -eq $null) {
        $status.State = 'Unknown'
        $status.Reason = 'installed version is not parseable'
        return $status
    }
    if ($cmp -le 0) {
        $status.State = 'UpToDate'
        $status.Reason = 'installed version is current'
        return $status
    }
    if ($RegistryEntry.AssetPolicy -ne 'verified' -or $RegistryEntry.InstallStrategy -eq 'unsupported') {
        $status.State = 'Unknown'
        $status.Reason = 'newer release available (' + $status.LatestVersion + ') but safe install path is not verified for this app'
        return $status
    }
    $bestAssets = @(Get-PreviewProp $best 'assets')
    $asset = @($bestAssets | Where-Object { [string](Get-PreviewProp $_ 'name') -like "*$($RegistryEntry.AssetPattern)" }) | Select-Object -First 1
    $sums = @($bestAssets | Where-Object { [string](Get-PreviewProp $_ 'name') -eq $RegistryEntry.ChecksumFile }) | Select-Object -First 1
    if ($null -eq $asset -or $null -eq $sums) {
        $status.State = 'Unknown'
        $status.Reason = 'latest release is missing the installer asset or checksum file'
        return $status
    }
    $status.AssetUrl = [string]$asset.browser_download_url
    $status.ChecksumUrl = [string]$sums.browser_download_url
    $status.InstallSupported = $true
    $status.State = 'UpdateAvailable'
    $status.Reason = "version $($status.LatestVersion) available with verified assets"
    return $status
}

function Save-ReleaseAsset {
    <#
    .SYNOPSIS
      Downloads one release artifact to a destination path. file:// URLs are
      supported for tests. Returns Ok/Error without throwing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$TimeoutSec = 300
    )
    try {
        if ($Url -like 'file://*') {
            Copy-Item -LiteralPath ([System.Uri]$Url).LocalPath -Destination $Destination -Force
        } else {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = 'ArtCraft-Updater'
            $req.Timeout = 30000
            $resp = $req.GetResponse()
            try {
                $inStream = $resp.GetResponseStream()
                $outStream = [System.IO.File]::Create($Destination)
                try {
                    $buf = New-Object byte[] 262144
                    $deadline = (Get-Date).AddSeconds($TimeoutSec)
                    while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                        if ((Get-Date) -gt $deadline) { throw 'download timed out' }
                        $outStream.Write($buf, 0, $read)
                    }
                } finally { $outStream.Dispose() }
            } finally { $resp.Close() }
        }
        return [PSCustomObject]@{ Ok = $true; Error = $null }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Install-AppUpdate {
    <#
    .SYNOPSIS
      Downloads verified release assets to a temp dir, dry-run previews, and
      installs after the caller has obtained explicit user confirmation.
      The caller MUST confirm with the user before invoking. Returns per-app
      outcome; cleans its temp dir. Pure workflow: safe to run off-thread.
    #>
    param(
        [Parameter(Mandatory = $true)]$Status,
        [string]$TempParent = $null,
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$McpConfigPath = $null,
        [string]$InstallRoot = $null
    )
    $outcome = [PSCustomObject]@{ DisplayName = [string]$Status.DisplayName; Outcome = ''; Success = $false;
        StageReached = $null; RollbackPerformed = $false; RollbackSucceeded = $null; Errors = @() }
    $workDir = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Status.AssetUrl) -or [string]::IsNullOrWhiteSpace($Status.ChecksumUrl)) {
            $outcome.Outcome = 'missing asset or checksum URL; refusing'
            return $outcome
        }
        if ([string]::IsNullOrWhiteSpace($TempParent)) { $TempParent = [System.IO.Path]::GetTempPath() }
        $workDir = Join-Path $TempParent ('ArtCraftDl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir | Out-Null
        $zipName = Split-Path $Status.AssetUrl -Leaf
        if ([string]::IsNullOrWhiteSpace($zipName)) { $zipName = 'release.zip' }
        $zipPath = Join-Path $workDir $zipName
        $sumPath = Join-Path $workDir 'SHA256SUMS.txt'
        $dl1 = Save-ReleaseAsset -Url ([string]$Status.AssetUrl) -Destination $zipPath
        if (-not $dl1.Ok) { $outcome.Outcome = "download failed: $($dl1.Error)"; return $outcome }
        $dl2 = Save-ReleaseAsset -Url ([string]$Status.ChecksumUrl) -Destination $sumPath
        if (-not $dl2.Ok) { $outcome.Outcome = "checksum download failed: $($dl2.Error)"; return $outcome }
        $session = New-UpdaterSession -AppId ([string]$Status.AppId)
        if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $session.InstallRoot = $InstallRoot }
        $setResult = Set-UpdateArchive -Session $session -ArchivePath $zipPath -ChecksumManifestPath $sumPath
        if (-not $setResult.Ok) { $outcome.Outcome = "selection failed: $($setResult.Error)"; return $outcome }
        $previewArgs = @{ Session = $session }
        if ($null -ne $SignatureChecker) { $previewArgs['SignatureChecker'] = $SignatureChecker }
        if ($null -ne $VersionProvider) { $previewArgs['VersionProvider'] = $VersionProvider }
        if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) { $previewArgs['McpConfigPath'] = $McpConfigPath }
        $preview = Start-UpdatePreview @previewArgs
        if (-not $preview.Ok) { $outcome.Outcome = "preview blocked: $($preview.Error)"; $outcome.Errors = @($preview.Error); return $outcome }
        if ($null -ne $preview.Preview -and $null -ne $preview.Preview.ExecutorResult) {
            $outcome.StageReached = [string]$preview.Preview.ExecutorResult.StageReached
        }
        $installArgs = @{ Session = $session; Confirmed = $true }
        if ($null -ne $SignatureChecker) { $installArgs['SignatureChecker'] = $SignatureChecker }
        if ($null -ne $VersionProvider) { $installArgs['VersionProvider'] = $VersionProvider }
        if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) { $installArgs['McpConfigPath'] = $McpConfigPath }
        $installed = Install-ApprovedUpdate @installArgs
        if ($null -ne $installed.Result -and $null -ne $installed.Result.ExecutorResult) {
            $outcome.StageReached = [string]$installed.Result.ExecutorResult.StageReached
            $outcome.RollbackPerformed = [bool]$installed.Result.ExecutorResult.RollbackPerformed
            $outcome.RollbackSucceeded = $installed.Result.ExecutorResult.RollbackSucceeded
        }
        if (-not $installed.Ok) {
            if ($null -ne $installed.Result) { $outcome.Errors = @($installed.Result.Errors) }
            else { $outcome.Errors = @($installed.Error) }
            $outcome.Outcome = "install refused/failed: $($installed.Error)"; return $outcome
        }
        $outcome.Success = $true
        $outcome.Outcome = 'installed and verified'
        return $outcome
    } catch {
        $outcome.Outcome = "error: $($_.Exception.Message)"
        return $outcome
    } finally {
        if ($workDir -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RowActions {
    <#
    .SYNOPSIS
      Button-state rules for one status row. Update is enabled only for a
      supported, asset-resolved, newer stable release.
    #>
    param([Parameter(Mandatory = $true)]$Status)
    $can = ($Status.State -eq 'UpdateAvailable') -and [bool]$Status.InstallSupported -and
        (-not [string]::IsNullOrWhiteSpace([string]$Status.AssetUrl)) -and
        (-not [string]::IsNullOrWhiteSpace([string]$Status.ChecksumUrl))
    $reason = [string]$Status.Reason
    if (-not $can -and [string]::IsNullOrWhiteSpace($reason)) { $reason = 'update not available' }
    return [PSCustomObject]@{ CanUpdate = [bool]$can; Reason = $reason }
}

Export-ModuleMember -Function New-UpdaterSession, Get-InstalledAppInfo, Set-UpdateArchive,
    Start-UpdatePreview, Test-PreviewBinding, Install-ApprovedUpdate, Format-PreviewSummary,
    Read-AppRegistry, Find-InstalledApps, Compare-AppVersions, Get-AppReleaseStatus,
    Save-ReleaseAsset, Get-RowActions, Install-AppUpdate
