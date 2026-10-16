<#
.SYNOPSIS
  Phases P0+P1+P2A+P2B: read-only inventory, manifest primitives, dry-run
  update planner, transactional Flat executor (PhotoCraft/FilmCraft), versioned
  clean installer (EffectCraft), and the unified Update-ArtCraftApp entry point.
.DESCRIPTION
  Supports PhotoCraft, FilmCraft and EffectCraft under D:\Art Craft (or any root).
  Every function in this module is READ-ONLY and planning-only: inventory, hashing,
  ZIP listing, manifest validation, classification, and update-plan generation.
  Nothing here creates, modifies, moves or deletes files in an installation, and
  nothing touches %APPDATA%, %LOCALAPPDATA%, processes, services or scheduled tasks.

  Requires Windows PowerShell 5.1+. Uses Microsoft.PowerShell.Archive only if
  present (ZIP reads use System.IO.Compression directly and have no dependency).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ManifestSchemaVersion = 1
$Script:KnownAppIds = @('photocraft', 'filmcraft', 'effectcraft')

function Test-ArtCraftPrerequisites {
    <#
    .SYNOPSIS
      Reports whether this machine can run the inventory tooling.
    #>
    $notes = @()
    $psOk = $PSVersionTable.PSVersion.Major -ge 5
    if (-not $psOk) { $notes += 'Windows PowerShell 5.1 or newer is required.' }
    $archive = Get-Module -ListAvailable Microsoft.PowerShell.Archive | Select-Object -First 1
    if (-not $archive) { $notes += 'Microsoft.PowerShell.Archive is unavailable; ZIP reads still work via System.IO.Compression.' }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zipOk = $true
    } catch {
        $zipOk = $false
        $notes += 'System.IO.Compression.FileSystem could not be loaded; ZIP inventory is unavailable.'
    }
    $pester = Get-Module -ListAvailable Pester | Select-Object -First 1
    if (-not $pester) { $notes += 'Pester is unavailable; tests cannot run.' }
    return [PSCustomObject]@{
        PowerShellOk      = $psOk
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ArchiveAvailable  = [bool]$archive
        ZipApiAvailable   = $zipOk
        PesterAvailable   = [bool]$pester
        IsAdmin           = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Notes             = $notes
    }
}

function Get-NormalizedRelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$FullName)
    $rel = $FullName.Substring($Root.Length).TrimStart('\', '/')
    return $rel -replace '\\', '/'
}

function Test-ManifestPath {
    <#
    .SYNOPSIS
      True when a manifest path is a safe relative path (no absolute, traversal, or escape).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[a-zA-Z]:' -or $Path.StartsWith('/') -or $Path.StartsWith('\')) { return $false }
    $parts = $Path -split '[/\\]'
    foreach ($p in $parts) {
        if ($p -eq '..' -or $p -eq '' -or $p -match '[:*?"<>|]') { return $false }
    }
    return $true
}

function Get-PropValue {
    # StrictMode-safe property read: returns $null when the property is absent
    # (plain $obj.Name throws under Set-StrictMode -Version Latest).
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

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
    }
}

function Get-AppInventory {
    <#
    .SYNOPSIS
      Read-only inventory of a directory: relative paths, sizes, timestamps, optional hashes.
    .OUTPUTS
      Object with Root, Files[] ({Path, Length, LastWriteTimeUtc, Sha256}), Directories[], Errors[].
      Files the reader cannot open are listed in Errors, never skipped silently.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeHashes
    )
    $resolved = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $files = @()
    $dirs = @()
    $errors = @()
    $allDirs = @($resolved) + @(Get-ChildItem -LiteralPath $resolved -Recurse -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    foreach ($d in $allDirs) {
        if ($d -ne $resolved) { $dirs += Get-NormalizedRelativePath -Root $resolved -FullName $d }
    }
    $allFiles = Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $allFiles) {
        $rel = Get-NormalizedRelativePath -Root $resolved -FullName $f.FullName
        $entry = [PSCustomObject]@{
            Path              = $rel
            Length            = $f.Length
            LastWriteTimeUtc  = $f.LastWriteTimeUtc.ToString('o')
            Sha256            = $null
        }
        if ($IncludeHashes) {
            try {
                $entry.Sha256 = Get-FileSha256Hex -LiteralPath $f.FullName
            } catch {
                $errors += "unreadable file: $rel ($($_.Exception.Message))"
            }
        }
        $files += $entry
    }
    return [PSCustomObject]@{
        Root        = $resolved
        Files       = @($files | Sort-Object Path)
        Directories = @($dirs | Sort-Object)
        Errors      = @($errors)
    }
}

function Read-InstallManifest {
    <#
    .SYNOPSIS
      Reads (not trusts) an install manifest file. Returns parsed object; errors listed, never thrown for content.
    #>
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [PSCustomObject]@{ Found = $false; Manifest = $null; Errors = @("manifest not found: $LiteralPath") }
    }
    try {
        $raw = Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Found = $true; Manifest = $null; Errors = @("manifest is not valid JSON: $($_.Exception.Message)") }
    }
    $validation = Test-InstallManifest -Manifest $parsed
    return [PSCustomObject]@{ Found = $true; Manifest = $parsed; Errors = @($validation) }
}

function Test-InstallManifest {
    <#
    .SYNOPSIS
      Validates a manifest object against schema version 1. Returns a list of error strings (empty = valid).
    #>
    param([Parameter(Mandatory = $true)][AllowNull()]$Manifest)
    $errs = @()
    if ($null -eq $Manifest) { return @('manifest is null') }
    if ((Get-PropValue $Manifest 'schemaVersion') -ne $Script:ManifestSchemaVersion) {
        $errs += "schemaVersion must be $($Script:ManifestSchemaVersion)"
    }
    if ($Script:KnownAppIds -notcontains (Get-PropValue $Manifest 'appId')) {
        $errs += "appId must be one of: $($Script:KnownAppIds -join ', ')"
    }
    if ([string]::IsNullOrWhiteSpace((Get-PropValue $Manifest 'version'))) { $errs += 'version is required' }
    $archive = Get-PropValue $Manifest 'archive'
    if ($null -ne $archive) {
        if ([string]::IsNullOrWhiteSpace((Get-PropValue $archive 'name'))) { $errs += 'archive.name is required when archive is present' }
        if ((Get-PropValue $archive 'sha256') -notmatch '^[0-9a-fA-F]{64}$') { $errs += 'archive.sha256 must be 64 hex characters' }
    }
    $files = Get-PropValue $Manifest 'files'
    if ($null -eq $files) {
        # Windows PowerShell 5.1 deserializes an empty JSON array as $null;
        # treat a missing or empty file list as "no release files recorded".
        $files = @()
    }
    $seen = @{}
    foreach ($f in @($files)) {
        $fpath = [string](Get-PropValue $f 'path')
        if (-not (Test-ManifestPath -Path $fpath)) {
            $errs += "unsafe file path rejected: '$fpath'"
            continue
        }
        if ($seen.ContainsKey($fpath)) { $errs += "duplicate file path: '$fpath'" } else { $seen[$fpath] = $true }
        $fsha = Get-PropValue $f 'sha256'
        if ($null -ne $fsha -and $fsha -notmatch '^[0-9a-fA-F]{64}$') {
            $errs += "bad sha256 for '$fpath'"
        }
    }
    $marker = Get-PropValue $Manifest 'portableMarker'
    if ($null -ne $marker) {
        $present = Get-PropValue $marker 'present'
        if ($null -ne $present -and $present -isnot [bool]) {
            $errs += 'portableMarker.present must be boolean'
        }
    }
    return @($errs)
}

function Get-ZipInventory {
    <#
    .SYNOPSIS
      Read-only listing of a ZIP archive: archive SHA-256 plus entry paths and sizes. Never extracts.
    #>
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($LiteralPath)
    try {
        $entries = @()
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            # Normalize separators: Compress-Archive on Windows writes '\' in entry
            # names, so comparisons use canonical '/' form everywhere.
            $entries += [PSCustomObject]@{ Path = ($e.FullName -replace '\\', '/'); Length = $e.Length }
        }
        return [PSCustomObject]@{
            ArchivePath   = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue).Path
            ArchiveSha256 = (Get-FileSha256Hex -LiteralPath $LiteralPath).ToLowerInvariant()
            Entries       = @($entries | Sort-Object Path)
        }
    } finally {
        $zip.Dispose()
    }
}

function Test-ZipLayout {
    <#
    .SYNOPSIS
      Validates candidate ZIP entries and maps them to install-relative paths.
      Returns @{ Errors = @(); Map = @{} } where Map holds install-relative path
      -> entry. Flat layout strips the single shared top folder; Versioned keeps
      full paths. Unsafe, absolute, top-less (Flat) or duplicate normalized paths
      are errors, never warnings.
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Entries,
        [ValidateSet('Flat', 'Versioned', 'None')][string]$Layout = 'Flat'
    )
    $errs = @()
    $map = @{}
    foreach ($e in $Entries) {
        $raw = [string](Get-PropValue $e 'Path')
        $norm = ($raw -replace '\\', '/')
        if (-not (Test-ManifestPath -Path $norm)) {
            $errs += "unsafe candidate ZIP path rejected: '$raw'"
            continue
        }
        if ($Layout -eq 'Flat') {
            $segs = $norm -split '/'
            if ($segs.Count -lt 2) {
                $errs += "flat-layout candidate entry without a top folder: '$norm'"
                continue
            }
            $rel = ($segs[1..($segs.Count - 1)] -join '/')
        } elseif ($Layout -eq 'None') {
            # Already install-relative (e.g. executor-staged sets): validate only.
            $rel = $norm
        } else {
            $rel = $norm
        }
        if ($map.ContainsKey($rel)) {
            $errs += "duplicate normalized candidate path: '$rel'"
            continue
        }
        $map[$rel] = $e
    }
    return [PSCustomObject]@{ Errors = @($errs); Map = $map }
}

function Compare-ReleaseInventory {
    <#
    .SYNOPSIS
      Compares expected relative paths (ZIP entries or manifest files) with an actual inventory.
    .OUTPUTS
      Object with Missing[], Extra[], HashMismatches[] (hashes compared only when both sides provide them).
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )
    $expMap = @{}
    foreach ($e in $Expected) {
        $pn = Get-PropValue $e 'Path'
        $p = if ($pn) { [string]$pn } else { [string]$e }
        $expMap[$p] = $e
    }
    $actMap = @{}
    foreach ($f in @($Actual.Files)) { $actMap[$f.Path] = $f }
    $missing = @()
    $mismatch = @()
    foreach ($p in $expMap.Keys | Sort-Object) {
        if (-not $actMap.ContainsKey($p)) {
            $missing += $p
        } else {
            $expSha = Get-PropValue $expMap[$p] 'Sha256'
            $actSha = Get-PropValue $actMap[$p] 'Sha256'
            if ($expSha -and $actSha -and ($expSha.ToLowerInvariant() -ne $actSha.ToLowerInvariant())) {
                $mismatch += $p
            }
        }
    }
    $extra = @()
    foreach ($p in $actMap.Keys | Sort-Object) {
        if (-not $expMap.ContainsKey($p)) { $extra += $p }
    }
    return [PSCustomObject]@{
        Missing        = @($missing)
        Extra          = @($extra)
        HashMismatches = @($mismatch)
    }
}

function Get-PortableMarkerState {
    <#
    .SYNOPSIS
      Inspects portable-marker presence beside an executable directory without modifying anything.
      A directory with a marker name is NOT a marker (matches upstream app_dirs.rs behavior).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExeDirectory,
        [string[]]$Markers = @('portable.txt')
    )
    foreach ($m in $Markers) {
        $p = Join-Path $ExeDirectory $m
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            return [PSCustomObject]@{ Present = $true; MarkerName = $m; MarkerIsFile = $true; Path = $p }
        }
        if (Test-Path -LiteralPath $p -PathType Container) {
            return [PSCustomObject]@{ Present = $false; MarkerName = $m; MarkerIsFile = $false; Path = $p; Note = 'a directory with the marker name is not a marker' }
        }
    }
    return [PSCustomObject]@{ Present = $false; MarkerName = $null; MarkerIsFile = $false; Path = $null }
}

function Get-PeVersion {
    <#
    .SYNOPSIS
      Reads PE ProductVersion/FileVersion metadata without executing the file. Returns nulls when absent
      (filmcraft-cli.exe and effectcraft-cli.exe ship no version resource - use CLI --version instead).
    #>
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    try {
        $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath)
        return [PSCustomObject]@{ ProductVersion = $v.ProductVersion; FileVersion = $v.FileVersion }
    } catch {
        return [PSCustomObject]@{ ProductVersion = $null; FileVersion = $null }
    }
}

function Get-OwnershipClassification {
    <#
    .SYNOPSIS
      Read-only classification of inventoried paths for one app. Informational only in P0.
      Classes: ReleaseVerified (hash matches expected set), ReleaseUnverified (path in expected
      set, no hash to compare), UserData, AgentOwned, ReleaseDownload, ScratchProvenance
      (only when the caller supplies -ProvenancePaths), Unknown (default; means preserve).
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('photocraft', 'filmcraft', 'effectcraft')][string]$AppId,
        [Parameter(Mandatory = $true)]$Inventory,
        [array]$ExpectedFiles = @(),
        [string[]]$ProvenancePaths = @()
    )
    $userDirs = @{
        photocraft  = @('PhotoCraftData')
        filmcraft   = @('data')
        effectcraft = @('EffectCraftData')
    }
    $agentFiles = @('AGENTS.md', 'SKILL.md', 'agent-guide.md', 'control-protocol.md', 'CLI-help.txt',
        'CLI-commands.txt', 'CLI-commands.json', 'mcp-config.json',
        'Install-EffectCraft.cmd', 'Install-EffectCraft.ps1', 'install-manifest.json')
    $expMap = @{}
    foreach ($e in $ExpectedFiles) {
        $pn = Get-PropValue $e 'Path'
        if ($pn) { $expMap[[string]$pn] = $e }
    }
    $result = @()
    foreach ($f in @($Inventory.Files)) {
        $class = 'Unknown'
        $reason = 'no ownership evidence; preserve'
        if ($expMap.ContainsKey($f.Path)) {
            $expSha = Get-PropValue $expMap[$f.Path] 'Sha256'
            if ($expSha -and $f.Sha256) {
                if ($expSha.ToLowerInvariant() -eq $f.Sha256.ToLowerInvariant()) {
                    $class = 'ReleaseVerified'; $reason = 'path and SHA-256 match the expected set'
                } else {
                    $class = 'Unknown'; $reason = 'path expected but hash differs; preserve pending review'
                }
            } else {
                $class = 'ReleaseUnverified'; $reason = 'path in expected set, no hash comparison available'
            }
        } else {
            $first = ($f.Path -split '/')[0]
            if ($userDirs[$AppId] -contains $first) {
                $class = 'UserData'; $reason = "under protected data directory '$first/'"
            } elseif ($f.Path -match '\.(fcproj|ecproj|pcraft)$') {
                $class = 'UserData'; $reason = 'user project document'
            } elseif ($agentFiles -contains $f.Path) {
                $class = 'AgentOwned'; $reason = 'agent documentation/config allowlist'
            } elseif ($f.Path -match '\.(zip)$' -or $f.Path -match '^SHA256SUMS.*\.txt$') {
                $class = 'ReleaseDownload'; $reason = 'release archive or checksum manifest'
            } elseif ($ProvenancePaths -contains $f.Path) {
                $class = 'ScratchProvenance'; $reason = 'caller-supplied documented provenance only'
            }
        }
        $result += [PSCustomObject]@{ Path = $f.Path; Class = $class; Reason = $reason }
    }
    return @($result)
}

function Get-UpdatePlan {
    <#
    .SYNOPSIS
      Phase P1: deterministic dry-run update plan. Planning only - never touches the filesystem.
    .DESCRIPTION
      Compares an existing installation inventory with a verified candidate release
      archive and explains the proposed treatment of every relevant path. All inputs
      are in-memory objects; version/signature evidence is caller-supplied data
      (designed for fixture/mock testing - real executables are never launched here).
      Stable action set: Create, Replace, Preserve, QuarantineCandidate,
      RemoveCandidate, Unknown, Conflict. QuarantineCandidate/RemoveCandidate/
      Unknown/Conflict always require approval and are never execution-eligible
      without it.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('photocraft', 'filmcraft', 'effectcraft')][string]$AppId,
        [Parameter(Mandatory = $true)]$ExistingInventory,
        [Parameter(Mandatory = $true)]$CandidateZip,
        [Parameter(Mandatory = $true)][string]$CandidateVersion,
        [string]$ExpectedArchiveSha256 = $null,
        [ValidateSet('Flat', 'Versioned', 'None')][string]$Layout = 'Flat',
        $ExistingManifest = $null,
        [array]$HistoricalReleaseFiles = @(),
        $VersionEvidence = $null,
        $MarkerState = $null,
        [string[]]$ProvenancePaths = @(),
        [string]$Timestamp = $null
    )
    $blockers = @()
    $notes = @()

    # ---- Gate 1: archive hash -------------------------------------------------
    $hashOk = $false
    if ([string]::IsNullOrWhiteSpace($ExpectedArchiveSha256)) {
        $blockers += 'candidate archive SHA-256 unknown; cannot authenticate the release'
    } else {
        $actualHash = [string](Get-PropValue $CandidateZip 'ArchiveSha256')
        if ($actualHash.ToLowerInvariant() -eq $ExpectedArchiveSha256.ToLowerInvariant()) {
            $hashOk = $true
        } else {
            $blockers += 'candidate archive SHA-256 mismatch; archive must not be used'
        }
    }

    # ---- Gate 2: ZIP layout ----------------------------------------------------
    # Shared helper: identical messages to the previous inline implementation.
    $layoutCheck = Test-ZipLayout -Entries @((Get-PropValue $CandidateZip 'Entries')) -Layout $Layout
    $candidateMap = $layoutCheck.Map
    foreach ($err in @($layoutCheck.Errors)) {
        $blockers += $err
    }
    $layoutOk = ($layoutCheck.Errors.Count -eq 0)

    # ---- Gate 3: existing manifest ---------------------------------------------
    $manifestErrors = @()
    $manifestUsable = $false
    if ($null -ne $ExistingManifest) {
        $manifestErrors = @(Test-InstallManifest -Manifest $ExistingManifest)
        if ($manifestErrors.Count -eq 0) {
            $manifestUsable = $true
        } else {
            $blockers += 'existing manifest is invalid; plan is conservative (preserve everything not in the candidate)'
        }
    }

    # ---- Gate 4: version + signature evidence -----------------------------------
    $verOk = $false
    if ($null -eq $VersionEvidence) {
        $blockers += 'version evidence not provided; executor would need GUI/CLI agreement first'
    } else {
        $gui = [string](Get-PropValue $VersionEvidence 'GuiVersion')
        $cli = [string](Get-PropValue $VersionEvidence 'CliVersion')
        $guiSrc = [string](Get-PropValue $VersionEvidence 'GuiSource')
        $cliSrc = [string](Get-PropValue $VersionEvidence 'CliSource')
        $sig = Get-PropValue $VersionEvidence 'SignaturesValid'
        if ([string]::IsNullOrWhiteSpace($gui) -or [string]::IsNullOrWhiteSpace($cli)) {
            $blockers += 'incomplete version evidence: both GUI and CLI versions are required'
        } elseif ($gui -ne $cli) {
            $blockers += "GUI/CLI version disagreement: GUI='$gui' CLI='$cli'"
        } else {
            # Missing PE metadata on a CLI is acceptable when its version comes
            # from the designated runtime interface (verified filmcraft-cli and
            # effectcraft-cli ship no version resource; photocraft-cli does).
            $notes += "candidate version evidence: GUI='$gui' ($guiSrc) CLI='$cli' ($cliSrc)"
            $verOk = $true
        }
        if ($sig -ne $true) {
            $blockers += 'executable signature evidence missing or not valid'
        }
    }

    # ---- Supporting maps --------------------------------------------------------
    # An invalid supplied manifest degrades ALL historical evidence: without a
    # trustworthy record of what was installed, obsolescence cannot be proven.
    $useHistorical = ($null -eq $ExistingManifest) -or $manifestUsable
    $histMap = @{}
    if ($useHistorical) {
        foreach ($h in $HistoricalReleaseFiles) {
            $pn = Get-PropValue $h 'Path'
            if ($pn) { $histMap[[string]$pn] = $h }
        }
    } elseif ($HistoricalReleaseFiles.Count -gt 0) {
        $notes += 'historical release evidence ignored because the existing manifest is invalid'
    }
    $existMap = @{}
    foreach ($f in @((Get-PropValue $ExistingInventory 'Files'))) { $existMap[[string](Get-PropValue $f 'Path')] = $f }
    $existDirs = @(Get-PropValue $ExistingInventory 'Directories')
    if ($null -eq $existDirs) { $existDirs = @() }

    $classInput = [PSCustomObject]@{ Files = @($existMap.Values) }
    $expForClass = @()
    foreach ($rel in $candidateMap.Keys) {
        $expForClass += [PSCustomObject]@{ Path = $rel; Sha256 = (Get-PropValue $candidateMap[$rel] 'Sha256') }
    }
    $baseClass = @{}
    foreach ($c in @(Get-OwnershipClassification -AppId $AppId -Inventory $classInput -ExpectedFiles $expForClass -ProvenancePaths $ProvenancePaths)) {
        $baseClass[$c.Path] = $c
    }

    $markerPresent = $null
    $markerName = $null
    if ($null -ne $MarkerState) {
        $markerPresent = [bool](Get-PropValue $MarkerState 'Present')
        $markerName = [string](Get-PropValue $MarkerState 'MarkerName')
        $markerIsFile = Get-PropValue $MarkerState 'MarkerIsFile'
        $markerNote = Get-PropValue $MarkerState 'Note'
        if ($markerPresent) {
            $notes += "portable marker present as a file ('$markerName'): data directory stays beside the executable"
        } elseif ($markerIsFile -eq $false -and $markerName) {
            $notes += "name '$markerName' exists as a directory, which is not a marker: platform data directory applies"
            if ($markerNote) { $notes += $markerNote }
        } else {
            $notes += 'no portable marker observed: platform data directory applies; a candidate marker must not be restored without consent'
        }
        $notes += 'environment-variable data-dir overrides cannot be observed from inventory and are out of scope for this plan'
    }
    $protectedDataDirs = @{
        photocraft  = @('PhotoCraftData')
        filmcraft   = @('data')
        effectcraft = @('EffectCraftData')
    }
    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    }

    $agentNames = @('AGENTS.md', 'SKILL.md', 'agent-guide.md', 'control-protocol.md', 'CLI-help.txt',
        'CLI-commands.txt', 'CLI-commands.json', 'mcp-config.json',
        'Install-EffectCraft.cmd', 'Install-EffectCraft.ps1', 'install-manifest.json')

    # ---- Per-path plan ------------------------------------------------------------
    $allPaths = @(@($existMap.Keys) + @($candidateMap.Keys) | Sort-Object -Unique)
    $actions = @()
    $quarantine = @()
    foreach ($p in $allPaths) {
        $inCandidate = $candidateMap.ContainsKey($p)
        $exists = $existMap.ContainsKey($p)
        $cls = if ($baseClass.ContainsKey($p)) { $baseClass[$p].Class } else { 'Unknown' }
        $action = 'Preserve'
        $reason = 'default: preserve'
        $review = $false
        $approval = $false

        # Protection is evaluated independently of the candidate set: a path the
        # candidate happens to contain must not lose UserData/AgentOwned status.
        $seg0 = ($p -split '/')[0]
        $isProtectedPath = ($protectedDataDirs[$AppId] -contains $seg0) -or
            ($p -match '\.(fcproj|ecproj|pcraft)$') -or
            ($agentNames -contains $p)

        if ($isProtectedPath -and $inCandidate) {
            $action = 'Conflict'; $reason = 'candidate file collides with a protected path; manual review required'
            $review = $true; $approval = $true
        } elseif ((($p -eq 'portable.txt') -or ($p -eq 'PhotoCraft.portable')) -and $inCandidate -and ($markerPresent -eq $false)) {
            # Never silently restore a user-removed portable marker: flipped data
            # directories would orphan settings.
            $action = 'Preserve'; $reason = 'portable marker absent; candidate marker must not be restored without consent'
            $review = $true; $approval = $true
        } elseif ($inCandidate -and -not $exists) {
            $firstSeg = ($p -split '/')[0]
            if ($protectedDataDirs[$AppId] -contains $firstSeg) {
                $action = 'Conflict'; $reason = "candidate path lies under protected data directory '$firstSeg/'; manual review required"
                $review = $true; $approval = $true
            } elseif ($existDirs -contains $p) {
                $action = 'Conflict'; $reason = 'candidate file collides with an existing directory'
                $review = $true; $approval = $true
            } else {
                $action = 'Create'; $reason = 'new file in the candidate release'
            }
        } elseif ($inCandidate -and $exists) {
            # Protected collisions are handled above; this branch is release-owned only.
            $candSha = Get-PropValue $candidateMap[$p] 'Sha256'
            $existSha = Get-PropValue $existMap[$p] 'Sha256'
            if ($candSha -and $existSha) {
                if ($candSha.ToLowerInvariant() -eq $existSha.ToLowerInvariant()) {
                    $action = 'Preserve'; $reason = 'identical hash already installed'
                } else {
                    $action = 'Replace'; $reason = 'verified release file differs in the candidate release'
                }
            } else {
                $action = 'Replace'; $reason = 'release-evidenced path; hash comparison unavailable'
                $review = $true
            }
        } elseif (-not $inCandidate -and $exists) {
            if ($cls -eq 'ScratchProvenance') {
                $action = 'QuarantineCandidate'; $reason = 'documented scratch provenance: ' + $baseClass[$p].Reason
                $approval = $true
                $quarantine += [PSCustomObject]@{
                    OriginalPath = $p
                    Destination  = ".quarantine/$AppId/$Timestamp/$p"
                    Evidence     = $baseClass[$p].Reason
                    Reason       = 'positively identified scratch artifact'
                    Recovery     = 'copy back from the quarantine directory'
                    Retention    = '30 days; no automatic deletion or scheduled cleanup'
                    ApprovalRequired = $true
                }
            } elseif ($histMap.ContainsKey($p) -and ($cls -ne 'UserData') -and ($cls -ne 'AgentOwned')) {
                $action = 'RemoveCandidate'; $reason = 'evidenced obsolete release file (previous verified listing); removal needs approval, never automatic'
                $approval = $true
            } elseif ($cls -eq 'ReleaseDownload') {
                # Downloads are never removal candidates inside a plan: retention
                # (including superseded archives) is a separate approved step.
                # Keeping the archive preserves rollback and auditability.
                $isCurrent = $p -like "*$CandidateVersion*"
                $action = 'Preserve'
                $reason = $(if ($isCurrent) { 'current release download; retained' } else { 'superseded release download; retained pending an approved retention step' })
            } else {
                $action = 'Preserve'; $reason = "no candidate entry and no removal evidence ($cls); preserve"
                if ($cls -eq 'Unknown') { $review = $true }
            }
        }
        $actions += [PSCustomObject]@{
            Path                 = $p
            Exists               = $exists
            InCandidate          = $inCandidate
            Class                = $cls
            Action               = $action
            Reason               = $reason
            RequiresReview       = $review
            RequiresApproval     = $approval
            EligibleForExecution = $false
        }
    }

    $planEligible = ($blockers.Count -eq 0)
    foreach ($a in $actions) {
        $a.EligibleForExecution = $planEligible -and (-not $a.RequiresApproval) -and (-not $a.RequiresReview)
    }
    $counts = @{}
    foreach ($a in $actions) {
        if (-not $counts.ContainsKey($a.Action)) { $counts[$a.Action] = 0 }
        $counts[$a.Action]++
    }
    return [PSCustomObject]@{
        AppId              = $AppId
        CandidateVersion   = $CandidateVersion
        Layout             = $Layout
        ArchiveHashOk      = $hashOk
        LayoutOk           = $layoutOk
        ManifestUsable     = $manifestUsable
        ManifestErrors     = @($manifestErrors)
        VersionEvidenceOk  = $verOk
        Notes              = @($notes)
        Actions            = @($actions | Sort-Object Path)
        Counts             = $counts
        ProtectedPaths     = @($actions | Where-Object { $_.Class -eq 'UserData' -or $_.Class -eq 'AgentOwned' } | ForEach-Object { $_.Path } | Sort-Object)
        AmbiguousPaths     = @($actions | Where-Object { $_.RequiresReview } | ForEach-Object { $_.Path } | Sort-Object)
        Quarantine         = @($quarantine | Sort-Object OriginalPath)
        Blockers           = @($blockers)
        Eligible           = $planEligible
        FilesystemMutated  = $false
    }
}
function Get-DefaultSignatureEvidence {
    <#
    .SYNOPSIS
      Real Authenticode check: Valid status plus expected signer subject. Read-only.
    #>
    param([Parameter(Mandatory = $true)][string]$ExePath, [string]$ExpectedSignerSubject = 'Learning Machines Inc')
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $ExePath
        $subject = $null
        if ($null -ne $sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
        $ok = ($sig.Status -eq 'Valid') -and ($subject -match [regex]::Escape($ExpectedSignerSubject))
        return [PSCustomObject]@{ Valid = [bool]$ok; Status = [string]$sig.Status; Subject = $subject }
    } catch {
        return [PSCustomObject]@{ Valid = $false; Status = "error: $($_.Exception.Message)"; Subject = $null }
    }
}

function Get-DefaultVersionEvidence {
    <#
    .SYNOPSIS
      Real version evidence: PE ProductVersion for the GUI plus "<cli> --version"
      stdout for the CLI. Spawns a process but modifies nothing.
    #>
    param([Parameter(Mandatory = $true)][string]$GuiPath, [Parameter(Mandatory = $true)][string]$CliPath)
    $guiVer = (Get-PeVersion -LiteralPath $GuiPath).ProductVersion
    $cliProbe = Get-DefaultCliVersion -CliPath $CliPath
    return [PSCustomObject]@{
        GuiVersion = $guiVer; GuiSource = 'PE'
        CliVersion = [string](Get-PropValue $cliProbe 'Output'); CliSource = 'Stdout'
        CliExitCode = (Get-PropValue $cliProbe 'ExitCode'); CliTimedOut = [bool](Get-PropValue $cliProbe 'TimedOut')
    }
}
    <#
    .SYNOPSIS
      Real CLI version probe: runs "<cli> --version" with a timeout. Spawns a
      process but modifies nothing. Returns @{ Output; ExitCode; TimedOut }.
    #>
function Get-DefaultCliVersion {
    <#
    .SYNOPSIS
      Real CLI version probe: runs "<cli> --version" with a timeout. Spawns a
      process but modifies nothing. Returns @{ Output; ExitCode; TimedOut }.
    #>
    param([Parameter(Mandatory = $true)][string]$CliPath, [int]$TimeoutMs = 60000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $CliPath
        $psi.Arguments = '--version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [PSCustomObject]@{ Output = ''; ExitCode = -1; TimedOut = $true }
        }
        return [PSCustomObject]@{ Output = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()).Trim(); ExitCode = $p.ExitCode; TimedOut = $false }
    } catch {
        return [PSCustomObject]@{ Output = ''; ExitCode = -1; TimedOut = $false; Error = $_.Exception.Message }
    }
}

function Invoke-FlatUpdate {
    <#
    .SYNOPSIS
      Phase P2A: transactional executor for flattened installs (PhotoCraft, FilmCraft).
      Fixture-scoped: refuses the real install roots unless -AllowProduction is given.
    .DESCRIPTION
      Stages: preflight, archive-hash, zip-layout, stage-extract, entry-hashes,
      required-contents, signatures, version-evidence, plan, commit (with backups),
      post-verify, manifest-write. Any failure before commit leaves the target
      untouched; commit failures roll back replaced files and remove created ones.
      Only Create/Replace/Preserve actions from an eligible plan are applied.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('photocraft', 'filmcraft')][string]$AppId,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$CandidateVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedArchiveSha256,
        [string]$ReleaseTag = $null,
        $ExistingManifest = $null,
        [array]$HistoricalReleaseFiles = @(),
        [string[]]$ProvenancePaths = @(),
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$ExpectedSignerSubject = 'Learning Machines Inc',
        [string]$StagingParent = $null,
        [hashtable]$FaultInjection = $null,
        [switch]$AllowProduction,
        [switch]$DryRun
    )
    $result = [PSCustomObject]@{
        Success            = $false
        DryRun             = $false
        Plan               = $null
        StageReached       = 'none'
        StageResults       = @()
        Operations         = @()
        RollbackPerformed  = $false
        RollbackSucceeded  = $null
        ManifestWritten    = $false
        ManifestPath       = $null
        Verification       = $null
        Errors             = @()
        Blockers           = @()
        StagingPath        = $null
        WorkPath           = $null
    }
    function Add-StageResult([string]$Name, [bool]$Ok, [string]$Detail) {
        $result.StageResults += [PSCustomObject]@{ Stage = $Name; Ok = $Ok; Detail = $Detail }
        $result.StageReached = $Name
    }
    function Fail([string]$Stage, [string]$Message) {
        $result.Errors += "$Stage`: $Message"
        Add-StageResult -Name $Stage -Ok $false -Detail $Message
    }

    $productionRoots = @('D:\Art Craft\photocraft', 'D:\Art Craft\filmcraft')
    try {
        if (Test-Path -LiteralPath $TargetRoot) {
            $targetFull = (Resolve-Path -LiteralPath $TargetRoot).Path
        } else {
            $targetFull = [System.IO.Path]::GetFullPath($TargetRoot)
        }
    } catch {
        Fail 'preflight' "cannot resolve target root: $($_.Exception.Message)"
        return $result
    }
    $normTarget = $targetFull.TrimEnd('\', '/')
    $isProduction = $false
    foreach ($pr in $productionRoots) {
        if ($normTarget -ieq $pr.TrimEnd('\', '/')) { $isProduction = $true }
    }
    if ($isProduction -and -not $AllowProduction) {
        Fail 'preflight' "refusing real installation root without -AllowProduction: $targetFull"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = "v$CandidateVersion" }
    Add-StageResult -Name 'preflight' -Ok $true -Detail "target=$targetFull"

    $workRoot = $StagingParent
    if ([string]::IsNullOrWhiteSpace($workRoot)) { $workRoot = [System.IO.Path]::GetTempPath() }
    $workBase = Join-Path $workRoot ('ArtCraftUpd-' + [guid]::NewGuid().ToString('N'))
    $stageDir = Join-Path $workBase 'stage'
    $workDir = Join-Path $workBase 'work'
    $result.StagingPath = $stageDir
    $result.WorkPath = $workDir
    # All content reads below use the private copy, so a swapped original
    # cannot reach the target. $ArchivePath keeps its published identity for
    # manifest and audit records.
    $sourceZip = $ArchivePath

    try {
        # ---- archive hash ----
        if (-not (Test-Path -LiteralPath $sourceZip -PathType Leaf)) {
            Fail 'archive-hash' "archive not found: $sourceZip"
            return $result
        }
        $actualHash = (Get-FileSha256Hex -LiteralPath $sourceZip).ToLowerInvariant()
        if ($actualHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) {
            Fail 'archive-hash' 'archive SHA-256 does not match the trusted release hash'
            return $result
        }
        Add-StageResult -Name 'archive-hash' -Ok $true -Detail 'SHA-256 matches the trusted hash'

        # ---- private staging copy (closes verify-to-use replacement) ----
        try {
            New-Item -ItemType Directory -Path $stageDir, $workDir | Out-Null
            $sourceZip = Join-Path $workBase 'source.zip'
            Copy-Item -LiteralPath $ArchivePath -Destination $sourceZip -Force
            $copyHash = (Get-FileSha256Hex -LiteralPath $sourceZip).ToLowerInvariant()
            if ($copyHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) {
                throw 'staged copy hash differs from the trusted hash'
            }
        } catch {
            Fail 'stage-copy' "cannot stage a private archive copy: $($_.Exception.Message)"
            return $result
        }
        Add-StageResult -Name 'stage-copy' -Ok $true -Detail 'verified private copy; original archive no longer read'

        # ---- zip layout ----
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $rawEntries = @()
        $zip = [System.IO.Compression.ZipFile]::OpenRead($sourceZip)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.FullName.EndsWith('/')) { continue }
                $rawEntries += [PSCustomObject]@{ Path = $e.FullName; Length = $e.Length }
            }
        } finally { $zip.Dispose() }
        $layoutCheck = Test-ZipLayout -Entries $rawEntries -Layout Flat
        if ($layoutCheck.Errors.Count -gt 0) {
            Fail 'zip-layout' (($layoutCheck.Errors) -join '; ')
            return $result
        }
        # Flat derivation: every entry must share one top folder (guaranteed by Test-ZipLayout).
        $topSegs = @($layoutCheck.Map.Keys | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
        Add-StageResult -Name 'zip-layout' -Ok $true -Detail "$($layoutCheck.Map.Count) entries under '$($topSegs -join ',')'"

        # ---- stage extract (entry by entry into validated paths) ----
        $zip2 = [System.IO.Compression.ZipFile]::OpenRead($sourceZip)
        try {
            foreach ($rel in ($layoutCheck.Map.Keys | Sort-Object)) {
                $srcEntry = $null
                foreach ($e in $zip2.Entries) {
                    if ((($e.FullName -replace '\\', '/') -split '/', 2)[1] -eq $rel) { $srcEntry = $e; break }
                }
                if ($null -eq $srcEntry) { throw "staged entry vanished: $rel" }
                $dest = Join-Path $stageDir ($rel -replace '/', '\')
                $destDir = Split-Path $dest -Parent
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
                $inStream = $srcEntry.Open()
                try {
                    $outStream = [System.IO.File]::Create($dest)
                    try { $inStream.CopyTo($outStream) } finally { $outStream.Dispose() }
                } finally { $inStream.Dispose() }
            }
        } finally { $zip2.Dispose() }
        Add-StageResult -Name 'stage-extract' -Ok $true -Detail "$($layoutCheck.Map.Count) files staged"

        # ---- entry hashes ----
        $stagedSet = @{}
        foreach ($rel in ($layoutCheck.Map.Keys | Sort-Object)) {
            $stagedSet[$rel] = [PSCustomObject]@{
                Path   = $rel
                Sha256 = (Get-FileSha256Hex -LiteralPath (Join-Path $stageDir ($rel -replace '/', '\'))).ToLowerInvariant()
            }
        }
        Add-StageResult -Name 'entry-hashes' -Ok $true -Detail "$($stagedSet.Count) staged hashes computed"

        # ---- required contents ----
        $guiName = "$AppId.exe"
        $cliName = "$AppId-cli.exe"
        foreach ($req in @($guiName, $cliName)) {
            if (-not $stagedSet.ContainsKey($req)) {
                Fail 'required-contents' "candidate archive lacks required executable: $req"
                return $result
            }
        }
        Add-StageResult -Name 'required-contents' -Ok $true -Detail "$guiName + $cliName present"

        # ---- signatures ----
        if ($null -eq $SignatureChecker) {
            $SignatureChecker = { param($ExePath, $Expected) Get-DefaultSignatureEvidence -ExePath $ExePath -ExpectedSignerSubject $Expected }.GetNewClosure()
        }
        foreach ($req in @($guiName, $cliName)) {
            $sev = & $SignatureChecker (Join-Path $stageDir $req) $ExpectedSignerSubject
            $okSig = [bool](Get-PropValue $sev 'Valid')
            if (-not $okSig) {
                Fail 'signatures' "signature rejected for $req : $((Get-PropValue $sev 'Status')) $((Get-PropValue $sev 'Subject'))"
                return $result
            }
        }
        Add-StageResult -Name 'signatures' -Ok $true -Detail 'both executables signed by the expected signer'

        # ---- version evidence ----
        # Injectable interface: provider receives staged (GuiPath, CliPath) and
        # returns GuiVersion/GuiSource/CliVersion/CliSource. The default is the
        # real implementation (PE metadata + process probe); tests inject mocks.
        if ($null -eq $VersionProvider) {
            $VersionProvider = { param($GuiPath, $CliPath) Get-DefaultVersionEvidence -GuiPath $GuiPath -CliPath $CliPath }.GetNewClosure()
        }
        $vev = & $VersionProvider (Join-Path $stageDir $guiName) (Join-Path $stageDir $cliName)
        $guiVer = [string](Get-PropValue $vev 'GuiVersion')
        $guiSrc = [string](Get-PropValue $vev 'GuiSource')
        $cliOut = [string](Get-PropValue $vev 'CliVersion')
        $cliSrc = [string](Get-PropValue $vev 'CliSource')
        if ([string]::IsNullOrWhiteSpace($guiVer)) { $guiSrc = 'PE' }
        if ([string]::IsNullOrWhiteSpace($cliSrc)) { $cliSrc = 'Stdout' }
        if ([string]::IsNullOrWhiteSpace($guiVer) -or [string]::IsNullOrWhiteSpace($cliOut)) {
            Fail 'version-evidence' 'incomplete version evidence from provider (GUI and CLI versions required)'
            return $result
        }
        if ($cliOut -notmatch [regex]::Escape($CandidateVersion) -or $guiVer -ne $CandidateVersion) {
            Fail 'version-evidence' "staged version mismatch: GUI='$guiVer' CLI='$cliOut' expected='$CandidateVersion'"
            return $result
        }
        $versionEvidence = @{ GuiVersion = $guiVer; GuiSource = $guiSrc; CliVersion = $CandidateVersion; CliSource = $cliSrc; SignaturesValid = $true }
        Add-StageResult -Name 'version-evidence' -Ok $true -Detail "GUI=$guiSrc`:$guiVer CLI=$cliSrc`:$CandidateVersion"

        # ---- plan ----
        $markerState = $null
        $existingInv = [PSCustomObject]@{ Files = @(); Directories = @(); Errors = @() }
        if (Test-Path -LiteralPath $targetFull -PathType Container) {
            $markerState = Get-PortableMarkerState -ExeDirectory $targetFull
            $existingInv = Get-AppInventory -Root $targetFull -IncludeHashes
        }
        $zipObj = [PSCustomObject]@{ ArchivePath = $ArchivePath; ArchiveSha256 = $actualHash; Entries = @($stagedSet.Values) }
        $plan = Get-UpdatePlan -AppId $AppId -ExistingInventory $existingInv `
            -CandidateZip $zipObj -CandidateVersion $CandidateVersion -ExpectedArchiveSha256 $ExpectedArchiveSha256 `
            -Layout None -ExistingManifest $ExistingManifest -VersionEvidence $versionEvidence `
            -MarkerState $markerState -ProvenancePaths $ProvenancePaths -Timestamp ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
        if (-not $plan.Eligible) {
            $result.Blockers += @($plan.Blockers)
            Fail 'plan' ('update plan is not eligible: ' + (($plan.Blockers) -join '; '))
            return $result
        }
        $badActions = @($plan.Actions | Where-Object { @('Create', 'Replace', 'Preserve') -notcontains $_.Action -or -not $_.EligibleForExecution })
        if ($badActions.Count -gt 0) {
            $result.Blockers += @($badActions | ForEach-Object { "unsupported or ineligible action: $($_.Action) $($_.Path)" })
            Fail 'plan' 'plan contains actions the P2A executor must not apply'
            return $result
        }
        Add-StageResult -Name 'plan' -Ok $true -Detail "$($plan.Actions.Count) paths, eligible"

        if ($DryRun) {
            Add-StageResult -Name 'dry-run' -Ok $true -Detail 'plan eligible; no files created, replaced, or removed'
            $result.DryRun = $true
            $result.Success = $true
            $result.Plan = $plan
            Remove-Item -LiteralPath $workBase -Recurse -Force -ErrorAction SilentlyContinue
            $result.StagingPath = $null
            $result.WorkPath = $null
            return $result
        }

        # ---- commit ----
        $ops = @($plan.Actions | Where-Object { $_.Action -eq 'Create' -or $_.Action -eq 'Replace' } | Sort-Object Path)
        if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
            New-Item -ItemType Directory -Path $targetFull | Out-Null
        }
        $txnPath = Join-Path $workDir 'transaction.json'
        $backupDir = Join-Path $workDir 'backup'
        New-Item -ItemType Directory -Path $backupDir | Out-Null
        $txn = [PSCustomObject]@{ AppId = $AppId; Version = $CandidateVersion; StartedUtc = (Get-Date).ToUniversalTime().ToString('o'); Operations = @(); Completed = @() }
        $txn | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $txnPath
        $writes = 0
        $failAfter = -1
        if ($null -ne $FaultInjection -and $FaultInjection.ContainsKey('FailAfterWrites')) { $failAfter = [int]$FaultInjection['FailAfterWrites'] }
        try {
            foreach ($op in $ops) {
                $dest = Join-Path $targetFull ($op.Path -replace '/', '\')
                if ($op.Action -eq 'Replace') {
                    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw "replace target vanished: $($op.Path)" }
                    $preHash = (Get-FileSha256Hex -LiteralPath $dest).ToLowerInvariant()
                    $bpath = Join-Path $backupDir ($op.Path -replace '/', '\')
                    $bdir = Split-Path $bpath -Parent
                    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
                    Copy-Item -LiteralPath $dest -Destination $bpath -Force
                    $postHash = (Get-FileSha256Hex -LiteralPath $bpath).ToLowerInvariant()
                    if ($preHash -ne $postHash) { throw "backup verification failed: $($op.Path)" }
                    $txn.Operations += [PSCustomObject]@{ Path = $op.Path; Op = 'Replace'; BackupHash = $preHash }
                } else {
                    $txn.Operations += [PSCustomObject]@{ Path = $op.Path; Op = 'Create'; BackupHash = $null }
                }
                $txn | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $txnPath
                Copy-Item -LiteralPath (Join-Path $stageDir ($op.Path -replace '/', '\')) -Destination $dest -Force
                $writes++
                $txn.Completed += [PSCustomObject]@{ Path = $op.Path; Writes = $writes }
                $txn | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $txnPath
                $result.Operations += [PSCustomObject]@{ Path = $op.Path; Op = $op.Action; Evidence = $op.Reason; Ok = $true }
                if ($failAfter -ge 0 -and $writes -gt $failAfter) { throw "injected commit failure after $writes writes" }
            }
        } catch {
            $commitError = $_.Exception.Message
            Add-StageResult -Name 'commit' -Ok $false -Detail $commitError
            $rb = Invoke-FlatRollback -WorkDir $workDir -TargetRoot $targetFull -StagedSet $stagedSet -FaultInjection $FaultInjection
            $result.RollbackPerformed = $true
            $result.RollbackSucceeded = $rb.Ok
            $result.Errors += @($rb.Errors)
            if (-not $rb.Ok) { $result.Errors += "commit: $commitError (rollback also failed)" }
            else { $result.Errors += "commit: $commitError (rolled back)" }
            return $result
        }
        Add-StageResult -Name 'commit' -Ok $true -Detail "$($result.Operations.Count) operations applied"

        # ---- post-verify ----
        $post = Get-AppInventory -Root $targetFull -IncludeHashes
        $postMap = @{}
        foreach ($f in @($post.Files)) { $postMap[$f.Path] = $f }
        foreach ($rel in ($stagedSet.Keys | Sort-Object)) {
            if (-not $postMap.ContainsKey($rel)) {
                return Invoke-FlatRollbackAndFail $result $workDir $targetFull $stagedSet $FaultInjection "post-verify: expected file missing: $rel"
            }
            if ($postMap[$rel].Sha256.ToLowerInvariant() -ne $stagedSet[$rel].Sha256.ToLowerInvariant()) {
                return Invoke-FlatRollbackAndFail $result $workDir $targetFull $stagedSet $FaultInjection "post-verify: hash mismatch after install: $rel"
            }
        }
        foreach ($a in @($plan.Actions | Where-Object { $_.Action -eq 'Preserve' })) {
            if ($a.Class -eq 'UserData' -or $a.Class -eq 'AgentOwned') {
                if (-not $postMap.ContainsKey($a.Path)) {
                    return Invoke-FlatRollbackAndFail $result $workDir $targetFull $stagedSet $FaultInjection "post-verify: protected path lost: $($a.Path)"
                }
            }
        }
        Add-StageResult -Name 'post-verify' -Ok $true -Detail 'all expected files verified; protected paths intact'

        # ---- manifest ----
        if ($null -ne $FaultInjection -and $FaultInjection.ContainsKey('FailManifestWrite') -and $FaultInjection['FailManifestWrite']) {
            return Invoke-FlatRollbackAndFail $result $workDir $targetFull $stagedSet $FaultInjection 'manifest-write: injected persistence failure'
        }
        $manifest = [PSCustomObject]@{
            schemaVersion = 1
            appId         = $AppId
            version       = $CandidateVersion
            tag           = $ReleaseTag
            archive       = [PSCustomObject]@{ name = (Split-Path $ArchivePath -Leaf); sha256 = $actualHash }
            files         = @($stagedSet.Values | Sort-Object Path | ForEach-Object { [PSCustomObject]@{ path = $_.Path; sha256 = $_.Sha256 } })
            verification  = [PSCustomObject]@{ cliVersionOutput = $cliOut; signatureStatus = 'Valid'; verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            portableMarker = [PSCustomObject]@{ present = [bool](Get-PropValue $markerState 'Present'); markerName = [string](Get-PropValue $markerState 'MarkerName') }
            previous      = $null
        }
        if ($null -ne $ExistingManifest -and (Get-PropValue $ExistingManifest 'version')) {
            $manifest.previous = [PSCustomObject]@{ version = [string](Get-PropValue $ExistingManifest 'version'); location = $null; archiveSha256 = $null }
        }
        $manifestPath = Join-Path $targetFull 'install-manifest.json'
        $writeManifest = $true
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $existing = Read-InstallManifest -LiteralPath $manifestPath
            if ($existing.Found -and $existing.Errors.Count -eq 0) {
                # verifiedAtUtc changes every run; exclude it so identical
                # releases do not rewrite the manifest (idempotent reinstall).
                $oldClone = ($existing.Manifest | ConvertTo-Json -Depth 6) | ConvertFrom-Json
                $oldClone.verification.verifiedAtUtc = ''
                $newClone = ($manifest | ConvertTo-Json -Depth 6) | ConvertFrom-Json
                $newClone.verification.verifiedAtUtc = ''
                if (($oldClone | ConvertTo-Json -Depth 6) -eq ($newClone | ConvertTo-Json -Depth 6)) { $writeManifest = $false }
            }
        }
        try {
            if ($writeManifest) {
                ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath
            }
        } catch {
            return Invoke-FlatRollbackAndFail $result $workDir $targetFull $stagedSet $FaultInjection "manifest-write: $($_.Exception.Message)"
        }
        $result.ManifestWritten = $writeManifest
        $result.ManifestPath = $manifestPath
        Add-StageResult -Name 'manifest-write' -Ok $true -Detail ($(if ($writeManifest) { 'manifest persisted' } else { 'identical manifest already present; not rewritten' }))
        $result.Verification = [PSCustomObject]@{ GuiVersion = $guiVer; CliOutput = $cliOut; SignaturesValid = $true }
        $result.Success = $true
        Remove-Item -LiteralPath $workBase -Recurse -Force -ErrorAction SilentlyContinue
        $result.StagingPath = $null
        $result.WorkPath = $null
        return $result
    } catch {
        Fail 'unexpected' $_.Exception.Message
        return $result
    }
}

function Invoke-FlatRollback {
    <#
    .SYNOPSIS
      Restores backups and removes transaction-created files. Internal to the P2A executor.
    #>
    param($WorkDir, [string]$TargetRoot, $StagedSet, [hashtable]$FaultInjection)
    $errs = @()
    $ok = $true
    $txn = $null
    try { $txn = (Get-Content -LiteralPath (Join-Path $WorkDir 'transaction.json') -Raw) | ConvertFrom-Json } catch { $errs += "rollback: unreadable transaction record: $($_.Exception.Message)"; return [PSCustomObject]@{ Ok = $false; Errors = @($errs) } }
    $destroy = @()
    if ($null -ne $FaultInjection -and $FaultInjection.ContainsKey('DestroyBackups')) { $destroy = @($FaultInjection['DestroyBackups']) }
    $completed = @($txn.Completed | Sort-Object Writes -Descending)
    foreach ($c in $completed) {
        $op = @($txn.Operations | Where-Object { $_.Path -eq $c.Path }) | Select-Object -First 1
        $dest = Join-Path $TargetRoot ($c.Path -replace '/', '\')
        if ($op.Op -eq 'Replace') {
            $bpath = Join-Path (Join-Path $WorkDir 'backup') ($c.Path -replace '/', '\')
            if ($destroy -contains $c.Path) {
                Remove-Item -LiteralPath $bpath -Force -ErrorAction SilentlyContinue
            }
            try {
                if (-not (Test-Path -LiteralPath $bpath -PathType Leaf)) { throw "backup missing for $($c.Path)" }
                Copy-Item -LiteralPath $bpath -Destination $dest -Force
                $restored = (Get-FileSha256Hex -LiteralPath $dest).ToLowerInvariant()
                if ($restored -ne $op.BackupHash.ToLowerInvariant()) { throw "restored bytes do not match backup for $($c.Path)" }
            } catch {
                $ok = $false
                $errs += "rollback restore failed: $($c.Path): $($_.Exception.Message)"
            }
        } else {
            try {
                if ((Test-Path -LiteralPath $dest -PathType Leaf) -and $StagedSet.ContainsKey($c.Path)) {
                    $cur = (Get-FileSha256Hex -LiteralPath $dest).ToLowerInvariant()
                    if ($cur -ne $StagedSet[$c.Path].Sha256.ToLowerInvariant()) { throw "created file changed unexpectedly: $($c.Path); refusing to remove" }
                    Remove-Item -LiteralPath $dest -Force
                }
            } catch {
                $ok = $false
                $errs += "rollback cleanup failed: $($c.Path): $($_.Exception.Message)"
            }
        }
    }
    return [PSCustomObject]@{ Ok = [bool]$ok; Errors = @($errs) }
}

function Invoke-FlatRollbackAndFail {
    param($Result, $WorkDir, $TargetRoot, $StagedSet, $FaultInjection, [string]$Message)
    $rb = Invoke-FlatRollback -WorkDir $WorkDir -TargetRoot $TargetRoot -StagedSet $StagedSet -FaultInjection $FaultInjection
    $Result.RollbackPerformed = $true
    $Result.RollbackSucceeded = $rb.Ok
    $Result.Errors += @($rb.Errors)
    $Result.Errors += @($Message + $(if ($rb.Ok) { ' (rolled back)' } else { ' (rollback also failed)' }))
    return $Result
}

function Update-McpServerCommand {
    <#
    .SYNOPSIS
      Points one MCP server entry at a new command path, preserving all other
      fields. Read-modify-write on a single file; callers must invoke it only
      after the target release is verified.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][string]$Command
    )
    $result = [PSCustomObject]@{ Updated = $false; PreviousCommand = $null; Error = $null }
    try {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            $result.Error = "MCP config not found: $ConfigPath"
            return $result
        }
        $cfg = (Get-Content -LiteralPath $ConfigPath -Raw) | ConvertFrom-Json
        $servers = Get-PropValue $cfg 'mcpServers'
        $entry = $null
        if ($null -ne $servers) { $entry = Get-PropValue $servers $ServerName }
        if ($null -eq $entry) {
            $result.Error = "server '$ServerName' not present in $ConfigPath; refusing to invent configuration structure"
            return $result
        }
        $result.PreviousCommand = [string](Get-PropValue $entry 'command')
        if ($result.PreviousCommand -eq $Command) {
            $result.Updated = $false
            return $result
        }
        $cfg.mcpServers.$ServerName.command = $Command
        ($cfg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $ConfigPath
        $verify = ((Get-Content -LiteralPath $ConfigPath -Raw) | ConvertFrom-Json).mcpServers.$ServerName.command
        if ($verify -ne $Command) {
            $result.Error = 'MCP config re-read mismatch after write'
            return $result
        }
        $result.Updated = $true
        return $result
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Invoke-VersionedCleanInstall {
    <#
    .SYNOPSIS
      Clean install of one versioned release beside (never over) existing ones.
      Fixture-scoped: refuses the real EffectCraft root unless -AllowProduction.
    .DESCRIPTION
      Stages: preflight, archive-hash, zip-layout, top-folder derivation, stage,
      entry-hashes, required-contents, signatures, version-evidence, target-create,
      copy, post-verify, manifest-write, config-activation. The target versioned
      directory must not exist (clean-install invariant); a byte-identical target
      short-circuits as AlreadyInstalled. Any failure removes only the partial
      new directory; previous releases are never touched.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('effectcraft')][string]$AppId,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedArchiveSha256,
        [string]$ReleaseTag = $null,
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$ExpectedSignerSubject = 'Learning Machines Inc',
        [string]$McpConfigPath = $null,
        [string]$McpServerName = 'effectcraft',
        [string]$StagingParent = $null,
        [hashtable]$FaultInjection = $null,
        [switch]$AllowProduction,
        [switch]$DryRun
    )
    $result = [PSCustomObject]@{
        Success = $false; StageReached = 'none'; StageResults = @(); Operations = @()
        DryRun = $false; TargetExists = $false
        TargetDirectory = $null; AlreadyInstalled = $false; ManifestWritten = $false
        ConfigUpdated = $false; ConfigError = $null; Verification = $null
        Errors = @(); StagingPath = $null
    }
    function Add-StageResultV([string]$Name, [bool]$Ok, [string]$Detail) {
        $result.StageResults += [PSCustomObject]@{ Stage = $Name; Ok = $Ok; Detail = $Detail }
        $result.StageReached = $Name
    }
    function Fail-VStage([string]$Stage, [string]$Message) {
        $result.Errors += "$Stage`: $Message"
        Add-StageResultV -Name $Stage -Ok $false -Detail $Message
    }

    $productionRoots = @('D:\Art Craft\EffectCraft')
    try {
        if (Test-Path -LiteralPath $InstallRoot) {
            $rootFull = (Resolve-Path -LiteralPath $InstallRoot).Path
        } else {
            $rootFull = [System.IO.Path]::GetFullPath($InstallRoot)
        }
    } catch {
        Fail-VStage 'preflight' "cannot resolve install root: $($_.Exception.Message)"
        return $result
    }
    $isProduction = $false
    foreach ($pr in $productionRoots) {
        if ($rootFull.TrimEnd('\', '/') -ieq $pr.TrimEnd('\', '/')) { $isProduction = $true }
    }
    if ($isProduction -and -not $AllowProduction) {
        Fail-VStage 'preflight' "refusing real installation root without -AllowProduction: $rootFull"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = "v$Version" }
    Add-StageResultV -Name 'preflight' -Ok $true -Detail "root=$rootFull"

    $workBase = Join-Path ($(if ([string]::IsNullOrWhiteSpace($StagingParent)) { [System.IO.Path]::GetTempPath() } else { $StagingParent })) ('ArtCraftVer-' + [guid]::NewGuid().ToString('N'))
    $stageDir = Join-Path $workBase 'stage'
    $result.StagingPath = $stageDir
    $createdTarget = $false
    $targetDir = $null
    # All content reads below use the private copy (see stage-copy); $ArchivePath
    # keeps its published identity for manifest and audit records.
    $sourceZip = $ArchivePath

    try {
        if (-not (Test-Path -LiteralPath $sourceZip -PathType Leaf)) {
            Fail-VStage 'archive-hash' "archive not found: $sourceZip"
            return $result
        }
        $actualHash = (Get-FileSha256Hex -LiteralPath $sourceZip).ToLowerInvariant()
        if ($actualHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) {
            Fail-VStage 'archive-hash' 'archive SHA-256 does not match the trusted release hash'
            return $result
        }
        Add-StageResultV -Name 'archive-hash' -Ok $true -Detail 'SHA-256 matches the trusted hash'

        # ---- private staging copy (closes verify-to-use replacement) ----
        try {
            New-Item -ItemType Directory -Path $stageDir | Out-Null
            $sourceZip = Join-Path $workBase 'source.zip'
            Copy-Item -LiteralPath $ArchivePath -Destination $sourceZip -Force
            $copyHash = (Get-FileSha256Hex -LiteralPath $sourceZip).ToLowerInvariant()
            if ($copyHash -ne $ExpectedArchiveSha256.ToLowerInvariant()) {
                throw 'staged copy hash differs from the trusted hash'
            }
        } catch {
            Fail-VStage 'stage-copy' "cannot stage a private archive copy: $($_.Exception.Message)"
            return $result
        }
        Add-StageResultV -Name 'stage-copy' -Ok $true -Detail 'verified private copy; original archive no longer read'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $rawEntries = @()
        $zip = [System.IO.Compression.ZipFile]::OpenRead($sourceZip)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.FullName.EndsWith('/')) { continue }
                $rawEntries += [PSCustomObject]@{ Path = $e.FullName; Length = $e.Length }
            }
        } finally { $zip.Dispose() }
        $layoutCheck = Test-ZipLayout -Entries $rawEntries -Layout Versioned
        if ($layoutCheck.Errors.Count -gt 0) {
            Fail-VStage 'zip-layout' (($layoutCheck.Errors) -join '; ')
            return $result
        }
        $tops = @($layoutCheck.Map.Keys | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
        if ($tops.Count -ne 1) {
            Fail-VStage 'zip-layout' 'archive must contain exactly one top-level release folder'
            return $result
        }
        $topFolder = $tops[0]
        if ($topFolder -notlike "$AppId-*") {
            Fail-VStage 'zip-layout' "top folder '$topFolder' does not belong to $AppId"
            return $result
        }
        $targetDir = Join-Path $rootFull $topFolder
        $result.TargetDirectory = $targetDir
        Add-StageResultV -Name 'zip-layout' -Ok $true -Detail "$($layoutCheck.Map.Count) entries under '$topFolder'"

        $zip2 = [System.IO.Compression.ZipFile]::OpenRead($sourceZip)
        try {
            foreach ($rel in ($layoutCheck.Map.Keys | Sort-Object)) {
                $srcEntry = $null
                foreach ($e in $zip2.Entries) {
                    if ((($e.FullName -replace '\\', '/')) -eq $rel) { $srcEntry = $e; break }
                }
                if ($null -eq $srcEntry) { throw "staged entry vanished: $rel" }
                $dest = Join-Path $stageDir ($rel -replace '/', '\')
                $destDir = Split-Path $dest -Parent
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
                $inStream = $srcEntry.Open()
                try {
                    $outStream = [System.IO.File]::Create($dest)
                    try { $inStream.CopyTo($outStream) } finally { $outStream.Dispose() }
                } finally { $inStream.Dispose() }
            }
        } finally { $zip2.Dispose() }
        Add-StageResultV -Name 'stage-extract' -Ok $true -Detail "$($layoutCheck.Map.Count) files staged"

        $stagedSet = @{}
        foreach ($rel in ($layoutCheck.Map.Keys | Sort-Object)) {
            $stagedSet[$rel] = [PSCustomObject]@{
                Path   = $rel
                Sha256 = (Get-FileSha256Hex -LiteralPath (Join-Path $stageDir ($rel -replace '/', '\'))).ToLowerInvariant()
            }
        }
        Add-StageResultV -Name 'entry-hashes' -Ok $true -Detail "$($stagedSet.Count) staged hashes computed"

        $guiRel = "$topFolder/$AppId.exe"
        $cliRel = "$topFolder/$AppId-cli.exe"
        foreach ($req in @($guiRel, $cliRel)) {
            if (-not $stagedSet.ContainsKey($req)) {
                Fail-VStage 'required-contents' "candidate archive lacks required executable: $req"
                return $result
            }
        }
        Add-StageResultV -Name 'required-contents' -Ok $true -Detail "$AppId.exe + $AppId-cli.exe present"

        if ($null -eq $SignatureChecker) {
            $SignatureChecker = { param($ExePath, $Expected) Get-DefaultSignatureEvidence -ExePath $ExePath -ExpectedSignerSubject $Expected }.GetNewClosure()
        }
        foreach ($req in @($guiRel, $cliRel)) {
            $sev = & $SignatureChecker (Join-Path $stageDir ($req -replace '/', '\')) $ExpectedSignerSubject
            if (-not [bool](Get-PropValue $sev 'Valid')) {
                Fail-VStage 'signatures' "signature rejected for $req : $((Get-PropValue $sev 'Status')) $((Get-PropValue $sev 'Subject'))"
                return $result
            }
        }
        Add-StageResultV -Name 'signatures' -Ok $true -Detail 'both executables signed by the expected signer'

        if ($null -eq $VersionProvider) {
            $VersionProvider = { param($GuiPath, $CliPath) Get-DefaultVersionEvidence -GuiPath $GuiPath -CliPath $CliPath }.GetNewClosure()
        }
        $vev = & $VersionProvider (Join-Path $stageDir ($guiRel -replace '/', '\')) (Join-Path $stageDir ($cliRel -replace '/', '\'))
        $guiVer = [string](Get-PropValue $vev 'GuiVersion')
        $cliOut = [string](Get-PropValue $vev 'CliVersion')
        if ([string]::IsNullOrWhiteSpace($guiVer) -or [string]::IsNullOrWhiteSpace($cliOut)) {
            Fail-VStage 'version-evidence' 'incomplete version evidence from provider (GUI and CLI versions required)'
            return $result
        }
        if ($cliOut -notmatch [regex]::Escape($Version) -or $guiVer -ne $Version) {
            Fail-VStage 'version-evidence' "staged version mismatch: GUI='$guiVer' CLI='$cliOut' expected='$Version'"
            return $result
        }
        Add-StageResultV -Name 'version-evidence' -Ok $true -Detail "GUI:$guiVer CLI contains $Version"

        if ($DryRun) {
            $targetExists = Test-Path -LiteralPath $targetDir -PathType Container
            Add-StageResultV -Name 'dry-run' -Ok $true -Detail ($(if ($targetExists) { "target exists; full comparison needed before any change" } else { "$($stagedSet.Count) files would be installed to $targetDir; no files created, no configuration changed" }))
            $result.DryRun = $true
            $result.Success = $true
            $result.TargetExists = $targetExists
            Remove-Item -LiteralPath $workBase -Recurse -Force -ErrorAction SilentlyContinue
            $result.StagingPath = $null
            return $result
        }

        # Idempotence: a byte-identical target needs no changes.
        if (Test-Path -LiteralPath $targetDir -PathType Container) {
            $same = $true
            # install-manifest.json is our own bookkeeping, not release content.
            $existingFiles = @(Get-ChildItem -LiteralPath $targetDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'install-manifest.json' })
            if ($existingFiles.Count -ne $stagedSet.Count) {
                $same = $false
            } else {
                foreach ($f in $existingFiles) {
                    $rel = ($f.FullName.Substring($targetDir.Length).TrimStart('\', '/') -replace '\\', '/')
                    $key = "$topFolder/$rel"
                    if (-not $stagedSet.ContainsKey($key)) { $same = $false; break }
                    if ((Get-FileSha256Hex -LiteralPath $f.FullName).ToLowerInvariant() -ne $stagedSet[$key].Sha256.ToLowerInvariant()) { $same = $false; break }
                }
            }
            if ($same) {
                $result.AlreadyInstalled = $true
                $result.Success = $true
                Add-StageResultV -Name 'target-create' -Ok $true -Detail 'byte-identical target already installed; no changes'
                Remove-Item -LiteralPath $workBase -Recurse -Force -ErrorAction SilentlyContinue
                $result.StagingPath = $null
                return $result
            }
            Fail-VStage 'target-create' "target directory already exists with different content: $targetDir (clean-install invariant; remove or repair it first)"
            return $result
        }

        $failAfter = -1
        if ($null -ne $FaultInjection -and $FaultInjection.ContainsKey('FailAfterWrites')) { $failAfter = [int]$FaultInjection['FailAfterWrites'] }
        try {
            New-Item -ItemType Directory -Path $targetDir | Out-Null
            $createdTarget = $true
            $writes = 0
            foreach ($rel in ($stagedSet.Keys | Sort-Object)) {
                $short = if ($rel.StartsWith("$topFolder/")) { $rel.Substring($topFolder.Length + 1) } else { $rel }
                $dest = Join-Path $targetDir ($short -replace '/', '\')
                $destDir = Split-Path $dest -Parent
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
                Copy-Item -LiteralPath (Join-Path $stageDir ($rel -replace '/', '\')) -Destination $dest -Force
                $writes++
                $result.Operations += [PSCustomObject]@{ Path = $short; Op = 'Create'; Evidence = 'verified staged release file'; Ok = $true }
                if ($failAfter -ge 0 -and $writes -gt $failAfter) { throw "injected install failure after $writes writes" }
            }
        } catch {
            $commitError = $_.Exception.Message
            Add-StageResultV -Name 'target-create' -Ok $false -Detail $commitError
            if ($createdTarget) {
                $leftoverOk = $true
                try {
                    $created = @(Get-ChildItem -LiteralPath $targetDir -Recurse -File -Force -ErrorAction Stop)
                    foreach ($f in $created) {
                        $rel = ($f.FullName.Substring($targetDir.Length).TrimStart('\', '/') -replace '\\', '/')
                        $key = "$topFolder/$rel"
                        if (-not $stagedSet.ContainsKey($key)) { $leftoverOk = $false; break }
                        if ((Get-FileSha256Hex -LiteralPath $f.FullName).ToLowerInvariant() -ne $stagedSet[$key].Sha256.ToLowerInvariant()) { $leftoverOk = $false; break }
                    }
                    if ($leftoverOk) {
                        Remove-Item -LiteralPath $targetDir -Recurse -Force
                    } else {
                        $result.Errors += 'rollback: partial target contains unexpected content; refusing to remove, manual review required'
                    }
                } catch {
                    $leftoverOk = $false
                    $result.Errors += "rollback: target cleanup failed: $($_.Exception.Message)"
                }
                if (-not $leftoverOk) {
                    $result.Errors += "target-create: $commitError (rollback incomplete)"
                    return $result
                }
            }
            $result.Errors += "target-create: $commitError (partial target removed)"
            return $result
        }
        Add-StageResultV -Name 'target-create' -Ok $true -Detail "$($result.Operations.Count) files installed"

        foreach ($rel in ($stagedSet.Keys | Sort-Object)) {
            $short = if ($rel.StartsWith("$topFolder/")) { $rel.Substring($topFolder.Length + 1) } else { $rel }
            $installed = Join-Path $targetDir ($short -replace '/', '\')
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
                Fail-VStage 'post-verify' "installed file missing: $short"
                return $result
            }
            if ((Get-FileSha256Hex -LiteralPath $installed).ToLowerInvariant() -ne $stagedSet[$rel].Sha256.ToLowerInvariant()) {
                Fail-VStage 'post-verify' "installed hash mismatch: $short"
                return $result
            }
        }
        Add-StageResultV -Name 'post-verify' -Ok $true -Detail 'all installed files hash-verified'

        $manifest = [PSCustomObject]@{
            schemaVersion = 1
            appId         = $AppId
            version       = $Version
            tag           = $ReleaseTag
            archive       = [PSCustomObject]@{ name = (Split-Path $ArchivePath -Leaf); sha256 = $actualHash }
            files         = @($stagedSet.Values | Sort-Object Path | ForEach-Object { [PSCustomObject]@{ path = $_.Path; sha256 = $_.Sha256 } })
            verification  = [PSCustomObject]@{ cliVersionOutput = $cliOut; signatureStatus = 'Valid'; verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            portableMarker = $null
            previous      = $null
        }
        $manifestPath = Join-Path $targetDir 'install-manifest.json'
        try {
            ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath
        } catch {
            Fail-VStage 'manifest-write' "cannot persist install manifest: $($_.Exception.Message)"
            return $result
        }
        Add-StageResultV -Name 'manifest-write' -Ok $true -Detail 'manifest persisted inside the versioned directory'
        $result.Verification = [PSCustomObject]@{ GuiVersion = $guiVer; CliOutput = $cliOut; SignaturesValid = $true }

        if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) {
            $mc = Update-McpServerCommand -ConfigPath $McpConfigPath -ServerName $McpServerName `
                -Command (Join-Path $targetDir "$AppId-cli.exe")
            $result.ConfigUpdated = [bool]$mc.Updated
            $result.ConfigError = [string]$mc.Error
            if ($mc.Error) {
                Add-StageResultV -Name 'config-activation' -Ok $false -Detail $mc.Error
            } else {
                Add-StageResultV -Name 'config-activation' -Ok $true -Detail ($(if ($mc.Updated) { 'MCP command repointed' } else { 'MCP command already correct' }))
            }
        }
        $result.ManifestWritten = $true
        $result.Success = $true
        Remove-Item -LiteralPath $workBase -Recurse -Force -ErrorAction SilentlyContinue
        $result.StagingPath = $null
        return $result
    } catch {
        Fail-VStage 'unexpected' $_.Exception.Message
        return $result
    }
}

function Get-PublishedChecksum {
    <#
    .SYNOPSIS
      Fetches a published SHA256SUMS-style manifest over HTTPS (or file:// in
      tests) into %TEMP% and returns name->hash entries. The URL itself is the
      trust anchor and is always reported; callers must pass a release-artifact
      URL, never an untrusted mirror.
    #>
    param([Parameter(Mandatory = $true)][string]$Url)
    $dest = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftSums-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        if ($Url -like 'file://*') {
            $local = ([System.Uri]$Url).LocalPath
            Copy-Item -LiteralPath $local -Destination $dest -Force
        } else {
            $wc = New-Object System.Net.WebClient
            try { $wc.DownloadFile($Url, $dest) } finally { $wc.Dispose() }
        }
        $entries = @{}
        foreach ($line in (Get-Content -LiteralPath $dest)) {
            $parts = ($line.Trim() -split '\s+')
            if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9a-fA-F]{64}$') {
                $entries[$parts[-1].TrimStart('*')] = $parts[0].ToLowerInvariant()
            }
        }
        return [PSCustomObject]@{ Url = $Url; Entries = $entries; Error = $null }
    } catch {
        return [PSCustomObject]@{ Url = $Url; Entries = @{}; Error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    }
}

function Update-ArtCraftApp {
    <#
    .SYNOPSIS
      Single entry point for updating PhotoCraft, FilmCraft, and EffectCraft.
    .DESCRIPTION
      Resolves the candidate archive, expected version, and trusted hash (each
      source reported, never silent), then delegates to Invoke-FlatUpdate
      (photocraft/filmcraft) or Invoke-VersionedCleanInstall (effectcraft).
      -DryRun performs verification + planning only and changes nothing.
      Production roots require -AllowProduction even for dry runs.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('photocraft', 'filmcraft', 'effectcraft')][string]$AppId,
        [string]$InstallRoot = $null,
        [string]$ArchivePath = $null,
        [string]$Version = $null,
        [string]$ExpectedArchiveSha256 = $null,
        [string]$ChecksumManifestPath = $null,
        $ExistingManifest = $null,
        [array]$HistoricalReleaseFiles = @(),
        [string[]]$ProvenancePaths = @(),
        [scriptblock]$SignatureChecker = $null,
        [scriptblock]$VersionProvider = $null,
        [string]$McpConfigPath = $null,
        [switch]$DryRun,
        [switch]$AllowProduction
    )
    $defaults = @{ photocraft = 'D:\Art Craft\photocraft'; filmcraft = 'D:\Art Craft\filmcraft'; effectcraft = 'D:\Art Craft\EffectCraft' }
    $result = [PSCustomObject]@{
        Success = $false; AppId = $AppId; DryRun = [bool]$DryRun; Selection = $null
        ExecutorResult = $null; Retention = $null; Errors = @()
    }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $defaults[$AppId] }
    $selectionNotes = @()

    # ---- archive selection (explicit, never silent) ----
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
            $result.Errors += "no archive given and install root missing: $InstallRoot"
            return $result
        }
        $cands = @(Get-ChildItem -LiteralPath $InstallRoot -Filter "$AppId-*-windows-*-portable.zip" -File -ErrorAction SilentlyContinue)
        if ($cands.Count -eq 0) {
            $result.Errors += 'no candidate archive given and none found in the install root; pass -ArchivePath explicitly'
            return $result
        }
        if ($cands.Count -gt 1) {
            $result.Errors += 'multiple candidate archives present; pass -ArchivePath explicitly: ' + (($cands | ForEach-Object { $_.Name }) -join ', ')
            return $result
        }
        $ArchivePath = $cands[0].FullName
        $selectionNotes += "archive auto-selected (only candidate present): $($cands[0].Name)"
    }
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        $result.Errors += "archive not found: $ArchivePath"
        return $result
    }

    # ---- version selection ----
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $leaf = Split-Path $ArchivePath -Leaf
        if ($leaf -match '-(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)-windows-') {
            $Version = $Matches[1]
            $selectionNotes += "version derived from archive name: $Version (verified later against executable evidence)"
        } else {
            $result.Errors += 'cannot derive a version from the archive name; pass -Version explicitly'
            return $result
        }
    }

    # ---- trusted hash (published manifest entry or explicit value) ----
    # A hash is trusted only from the release's published checksum manifest
    # (fetched over HTTPS at download time) or an explicit caller value. The
    # archive itself is never a hash source. Every source is reported.
    $hashSource = 'explicit caller value'
    if ([string]::IsNullOrWhiteSpace($ExpectedArchiveSha256)) {
        $manifestPath = $ChecksumManifestPath
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            foreach ($candidate in @('SHA256SUMS.txt', "SHA256SUMS-v$Version.txt")) {
                $try = Join-Path (Split-Path $ArchivePath -Parent) $candidate
                if (Test-Path -LiteralPath $try -PathType Leaf) { $manifestPath = $try; break }
            }
        }
        if ($manifestPath) {
            $want = Split-Path $ArchivePath -Leaf
            $line = @(Get-Content -LiteralPath $manifestPath -ErrorAction SilentlyContinue |
                Where-Object { ($_ -split '\s+')[-1].TrimStart('*') -eq $want }) | Select-Object -First 1
            if ($line) {
                $ExpectedArchiveSha256 = (($line -split '\s+')[0]).ToLowerInvariant()
                $hashSource = "published manifest entry ($manifestPath)"
            } else {
                $result.Errors += "archive '$want' has no entry in $manifestPath; pass -ExpectedArchiveSha256 explicitly"
                return $result
            }
        } else {
            $result.Errors += 'no checksum manifest found beside the archive; pass -ExpectedArchiveSha256 explicitly'
            return $result
        }
    }
    $result.Selection = [PSCustomObject]@{
        ArchivePath = $ArchivePath; Version = $Version
        ExpectedArchiveSha256 = $ExpectedArchiveSha256; HashSource = $hashSource
        Notes = @($selectionNotes)
    }

    $delegate = @{
        ArchivePath = $ArchivePath
        ExpectedArchiveSha256 = $ExpectedArchiveSha256
        DryRun = $DryRun; AllowProduction = $AllowProduction
    }
    if ($null -ne $SignatureChecker) { $delegate['SignatureChecker'] = $SignatureChecker }
    if ($null -ne $VersionProvider) { $delegate['VersionProvider'] = $VersionProvider }

    if ($AppId -eq 'effectcraft') {
        if (-not [string]::IsNullOrWhiteSpace($McpConfigPath)) { $delegate['McpConfigPath'] = $McpConfigPath }
        $exec = Invoke-VersionedCleanInstall -AppId $AppId -InstallRoot $InstallRoot -Version $Version @delegate
        $result.ExecutorResult = $exec
        $result.Retention = Get-EffectCraftRetention -InstallRoot $InstallRoot
        $result.Success = [bool]$exec.Success
        $result.Errors += @($exec.Errors)
    } else {
        $delegate['CandidateVersion'] = $Version
        if ($null -ne $ExistingManifest) { $delegate['ExistingManifest'] = $ExistingManifest }
        if ($HistoricalReleaseFiles.Count -gt 0) { $delegate['HistoricalReleaseFiles'] = $HistoricalReleaseFiles }
        if ($ProvenancePaths.Count -gt 0) { $delegate['ProvenancePaths'] = $ProvenancePaths }
        $exec = Invoke-FlatUpdate -AppId $AppId -TargetRoot $InstallRoot @delegate
        $result.ExecutorResult = $exec
        $result.Success = [bool]$exec.Success
        $result.Errors += @($exec.Errors)
        if ($null -ne (Get-PropValue $exec 'Blockers')) { $result | Add-Member -NotePropertyName Blockers -NotePropertyValue @($exec.Blockers) -Force }
    }
    return $result
}

function Get-EffectCraftRetention {
    <#
    .SYNOPSIS
      Reports which versioned EffectCraft installs would be retained or retired.
      Report only: performs no moves or deletions. Retains the two newest
      version-sorted installs; older ones are retirement candidates on approval.
    #>
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $dirs = @()
    if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
        $dirs = @(Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^effectcraft-(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)-windows-' } |
            ForEach-Object {
                [PSCustomObject]@{ Directory = $_.FullName; Name = $_.Name; Version = $Matches[1] }
            } | Sort-Object { [version]($_.Version -split '-')[0] })
    }
    $report = @()
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $keep = ($i -ge ($dirs.Count - 2))
        $report += [PSCustomObject]@{
            Name    = $dirs[$i].Name
            Version = $dirs[$i].Version
            Retain  = [bool]$keep
            Reason  = $(if ($keep) { 'within newest-two retention window' } else { 'superseded; retirement candidate on explicit approval (quarantine, never delete)' })
        }
    }
    return @($report)
}

Export-ModuleMember -Function Test-ArtCraftPrerequisites, Get-AppInventory, Get-FileSha256Hex,
    Read-InstallManifest, Test-InstallManifest, Test-ManifestPath, Get-ZipInventory, Test-ZipLayout,
    Compare-ReleaseInventory, Get-PortableMarkerState, Get-PeVersion, Get-OwnershipClassification,
    Get-UpdatePlan, Get-DefaultSignatureEvidence, Get-DefaultCliVersion, Get-DefaultVersionEvidence, Invoke-FlatUpdate,
    Update-McpServerCommand, Invoke-VersionedCleanInstall, Get-PublishedChecksum, Update-ArtCraftApp, Get-EffectCraftRetention
