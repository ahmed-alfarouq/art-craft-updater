<#
.SYNOPSIS
  ArtCraft Updater JSON bridge (protocol v1): discovery, release checks,
  read-only target validation, and confirmed update execution.
.DESCRIPTION
  Reads ONE JSON request line from stdin, writes ONE JSON response line to
  stdout, and exits. Diagnostic text goes to stderr only; stdout carries
  protocol messages exclusively.
  Operations: discover, check-updates, validate-target, install-update.
  install-update executes ONLY through Install-AppUpdate (trusted registry,
  verified assets, dry-run preview, transaction with rollback) after the
  caller passes the exact approved appId + installedVersion + latestVersion,
  which are revalidated here. There is deliberately NO arbitrary-command,
  URL/hash/path-accepting, or direct-executor operation in this bridge.
  Request : {"protocol":1,"id":"<guid>","op":"discover"|"check-updates"|"validate-target"|"install-update","params":{}}
  Success : {"protocol":1,"id":"<same>","ok":true,"data":{...}}
  Failure : {"protocol":1,"id":"<same-or-empty>","ok":false,"error":{"code":"...","message":"..."}}
#>
param([string]$ToolsDir = $null, [string]$Root = 'D:\Art Craft')
$ErrorActionPreference = 'Stop'

function Write-BridgeResponse([string]$Id, [bool]$Ok, $Data, $Err) {
    $response = [PSCustomObject]@{ protocol = 1; id = $Id; ok = $Ok; data = $Data; error = $Err }
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 6 -Compress))
}

function Write-BridgeLog([string]$Text) {
    [Console]::Error.WriteLine("[bridge] $Text")
}

function Get-BridgeProp {
    # Local StrictMode-safe property read (module internals are not visible here).
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

if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
    $ToolsDir = Split-Path $PSScriptRoot -Parent
}
$controller = Join-Path $ToolsDir 'ArtCraftUpdater.Controller.psm1'
$registryPath = Join-Path $ToolsDir 'apps.registry.json'
$requestId = ''

try {
    Import-Module $controller -Force -ErrorAction Stop
    # The controller nests ArtCraftInstall.psm1, whose functions are not
    # re-exported; import it here so validate-target can call exported
    # helpers (marker state, retention) directly in session scope.
    Import-Module (Join-Path $ToolsDir 'ArtCraftInstall.psm1') -Force -ErrorAction Stop
    # Read stdin as UTF-8 explicitly: [Console]::In decodes redirected input
    # with the console code page, which mangles non-ASCII bytes (including a
    # UTF-8 byte-order mark) into mojibake that JSON parsing then rejects.
    $stdinReader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $rawLine = $stdinReader.ReadLine()
    # Tolerate a byte-order mark emitted by UTF-8 clients; PowerShell 5.1
    # ConvertFrom-Json rejects it, which would otherwise mask the request.
    $line = ([string]$rawLine).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($line)) {
        Write-BridgeResponse '' $false $null ([PSCustomObject]@{ code = 'empty-request'; message = 'no request line received on stdin' })
        exit 0
    }
    try {
        $request = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-BridgeResponse '' $false $null ([PSCustomObject]@{ code = 'malformed-request'; message = 'request is not valid JSON' })
        exit 0
    }
    $requestId = [string]$request.id
    if ($request.protocol -ne 1) {
        Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'unsupported-protocol'; message = 'only protocol 1 is supported' })
        exit 0
    }
    $op = [string]$request.op
    if ($op -eq 'discover') {
        $reg = Read-AppRegistry -RegistryPath $registryPath
        $apps = @(Find-InstalledApps -Root $Root -Registry $reg)
        $data = [PSCustomObject]@{
            applications = @($apps | ForEach-Object {
                [PSCustomObject]@{ appId = $_.AppId; displayName = $_.DisplayName; installRoot = $_.InstallRoot;
                    installedVersion = $_.InstalledVersion; versionSource = $_.VersionSource;
                    status = $_.Status; reason = $_.Reason }
            })
            registryErrors = @($reg.Errors)
        }
        Write-BridgeResponse $requestId $true $data $null
        exit 0
    }
    if ($op -eq 'check-updates') {
        $reg = Read-AppRegistry -RegistryPath $registryPath
        $rows = @()
        foreach ($app in (Find-InstalledApps -Root $Root -Registry $reg)) {
            if ($app.Status -ne 'Identified') {
                $rows += [PSCustomObject]@{ appId = $app.AppId; displayName = $app.DisplayName;
                    installedVersion = $app.InstalledVersion; latestVersion = $null; state = 'Unknown';
                    reason = $app.Reason; assetUrl = $null; checksumUrl = $null; installSupported = $false }
                continue
            }
            $entry = @($reg.Entries | Where-Object { $_.AppId -eq $app.AppId })[0]
            if ($null -eq $entry) {
                $rows += [PSCustomObject]@{ appId = $app.AppId; displayName = $app.DisplayName;
                    installedVersion = $app.InstalledVersion; latestVersion = $null; state = 'Unknown';
                    reason = 'no verified registry entry'; assetUrl = $null; checksumUrl = $null; installSupported = $false }
                continue
            }
            $st = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion $app.InstalledVersion
            $rows += [PSCustomObject]@{ appId = $st.AppId; displayName = $st.DisplayName;
                installedVersion = $st.InstalledVersion; latestVersion = $st.LatestVersion; state = [string]$st.State;
                reason = [string]$st.Reason; assetUrl = [string]$st.AssetUrl; checksumUrl = [string]$st.ChecksumUrl;
                installSupported = [bool]$st.InstallSupported }
        }
        Write-BridgeResponse $requestId $true ([PSCustomObject]@{ rows = @($rows); registryErrors = @($reg.Errors) }) $null
        exit 0
    }
    if ($op -eq 'validate-target') {
        # Read-only pre-install validation for one app. Inspects the install
        # root, manifest, version evidence, marker, and versioned siblings.
        # Writes nothing. params: {appId, installRoot?}
        $targetApp = [string](Get-BridgeProp $request.params 'appId')
        $targetRoot = [string](Get-BridgeProp $request.params 'installRoot')
        $warnings = @()
        if ([string]::IsNullOrWhiteSpace($targetApp)) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'bad-params'; message = 'params.appId is required' })
            exit 0
        }
        $reg = Read-AppRegistry -RegistryPath $registryPath
        $matches = @($reg.Entries | Where-Object { $_.AppId -eq $targetApp })
        if ($matches.Count -eq 0) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'unknown-app'; message = "no verified registry entry for '$targetApp'" })
            exit 0
        }
        $entry = $matches[0]
        if ([string]::IsNullOrWhiteSpace($targetRoot)) {
            try {
                $targetRoot = (New-UpdaterSession -AppId $targetApp).InstallRoot
            } catch {
                $targetRoot = ''
            }
        }
        $data = [PSCustomObject]@{
            appId = $targetApp; installRoot = $targetRoot
            rootExists = $false; detectedVersion = $null; versionSource = 'None'
            manifestPresent = $false; manifestValid = $false; manifestErrors = @()
            markerPresent = $null; markerName = $null; versionedInstalls = @()
        }
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            $warnings += 'installation directory is missing'
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue @($warnings) -Force
            Write-BridgeResponse $requestId $true $data $null
            exit 0
        }
        $data.rootExists = $true
        $info = Get-InstalledAppInfo -AppId $targetApp -InstallRoot $targetRoot
        $data.detectedVersion = $info.Version
        $data.versionSource = [string]$info.Source
        if ([string]::IsNullOrWhiteSpace($info.Version)) {
            $warnings += 'installed version could not be determined'
        }
        $manifestPath = Join-Path $targetRoot 'install-manifest.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $data.manifestPresent = $true
            $read = Read-InstallManifest -LiteralPath $manifestPath
            $data.manifestErrors = @($read.Errors)
            if ($read.Errors.Count -eq 0) {
                $data.manifestValid = $true
            } else {
                $warnings += 'existing install manifest is invalid; install would proceed without manifest history'
            }
        } else {
            $warnings += 'no install manifest; install would proceed without manifest history'
        }
        $marker = Get-PortableMarkerState -ExeDirectory $targetRoot
        $data.markerPresent = [bool]$marker.Present
        $data.markerName = [string]$marker.MarkerName
        if ($entry.InstallStrategy -eq 'versioned') {
            $retention = Get-EffectCraftRetention -InstallRoot $targetRoot
            $data.versionedInstalls = @($retention | ForEach-Object {
                [PSCustomObject]@{ name = $_.Name; version = $_.Version; retain = [bool]$_.Retain }
            })
        }
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue @($warnings) -Force
        Write-BridgeResponse $requestId $true $data $null
        exit 0
    }
    if ($op -eq 'install-update') {
        # Confirmed update execution for one app. The caller (UI) must have
        # obtained an explicit user approval for this exact appId +
        # installedVersion + latestVersion first; the parameters below carry
        # that approval and are revalidated here before anything runs.
        # params: {appId, installedVersion, latestVersion}. No URLs, hashes,
        # paths, or commands are accepted from the caller: the release is
        # re-selected from the trusted registry, the target is rediscovered
        # under the bridge root, and execution reuses Install-AppUpdate
        # (download -> dry-run preview -> confirmed install -> temp cleanup).
        # Refusal (ok:false + code) means nothing ran. A completed attempt
        # reports ok:true with data.success true/false plus the engine's
        # stage, rollback, and re-read version evidence.
        $execApp = [string](Get-BridgeProp $request.params 'appId')
        $execWas = [string](Get-BridgeProp $request.params 'installedVersion')
        $execWant = [string](Get-BridgeProp $request.params 'latestVersion')
        if ([string]::IsNullOrWhiteSpace($execApp) -or [string]::IsNullOrWhiteSpace($execWas) -or [string]::IsNullOrWhiteSpace($execWant)) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'bad-params'; message = 'params.appId, params.installedVersion, and params.latestVersion are required' })
            exit 0
        }
        $reg = Read-AppRegistry -RegistryPath $registryPath
        $matches = @($reg.Entries | Where-Object { $_.AppId -eq $execApp })
        if ($matches.Count -eq 0) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'unknown-app'; message = "no verified registry entry for '$execApp'" })
            exit 0
        }
        $entry = $matches[0]
        if ($entry.InstallStrategy -notin @('flat', 'versioned')) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'unsupported-app'; message = "safe install path is not verified for '$execApp'" })
            exit 0
        }
        $found = @(Find-InstalledApps -Root $Root -Registry $reg | Where-Object { $_.AppId -eq $execApp -and $_.Status -eq 'Identified' })
        if ($found.Count -eq 0) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'no-verified-target'; message = "no verified installation of '$execApp' under the bridge root" })
            exit 0
        }
        $targetRoot = [string]$found[0].InstallRoot
        if ([string]::IsNullOrWhiteSpace([string]$found[0].InstalledVersion) -or [string]$found[0].InstalledVersion -ne $execWas) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'stale-approval'; message = 'installed version changed since review; re-review before installing' })
            exit 0
        }
        $st = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion $found[0].InstalledVersion
        if ($st.State -ne 'UpdateAvailable' -or -not [bool]$st.InstallSupported -or
            [string]::IsNullOrWhiteSpace([string]$st.AssetUrl) -or [string]::IsNullOrWhiteSpace([string]$st.ChecksumUrl)) {
            $why = [string]$st.Reason
            if ([string]::IsNullOrWhiteSpace($why)) { $why = 'no verified update available right now' }
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'release-unavailable'; message = $why })
            exit 0
        }
        if ([string]$st.LatestVersion -ne $execWant) {
            Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'stale-approval'; message = 'target release changed since review; re-review before installing' })
            exit 0
        }
        $exec = Install-AppUpdate -Status $st -InstallRoot $targetRoot
        $after = Get-InstalledAppInfo -AppId $execApp -InstallRoot $targetRoot
        $data = [PSCustomObject]@{
            appId = $execApp; installedVersion = $execWas; latestVersion = $execWant
            success = [bool]$exec.Success; outcome = [string]$exec.Outcome
            stageReached = $exec.StageReached; rollbackPerformed = [bool]$exec.RollbackPerformed
            rollbackSucceeded = $exec.RollbackSucceeded; errors = @($exec.Errors)
            installedVersionAfter = $after.Version
        }
        Write-BridgeResponse $requestId $true $data $null
        exit 0
    }
    Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'unknown-operation'; message = "unsupported op: '$op' (allowed: discover, check-updates, validate-target, install-update)" })
    exit 0
} catch {
    Write-BridgeLog "fatal: $($_.Exception.Message)"
    Write-BridgeResponse $requestId $false $null ([PSCustomObject]@{ code = 'internal-error'; message = $_.Exception.Message })
    exit 0
}
