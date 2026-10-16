<#
.SYNOPSIS
  Pester tests for tools/Bridge/ArtCraftBridge.ps1. Fixture roots only; the
  bridge never touches real installs in tests. No network access: discovery
  is local, and check-updates tests use roots that yield no HTTP calls.
#>

$Script:BridgeScript = 'D:\Art Craft\tools\Bridge\ArtCraftBridge.ps1'
$Script:BRoots = @()

function Invoke-BridgeRequest {
    param([string]$Request, [string]$Root = $null)
    $inputText = $Request
    if ($Root) {
        $out = $inputText | powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript -Root $Root 2>$null
    } else {
        $out = $inputText | powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript 2>$null
    }
    return ($out | ConvertFrom-Json)
}

function New-BRoot {
    param([hashtable]$Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftB-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $Script:BRoots += $root
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Set-Content -LiteralPath $full -Value $Files[$rel] -NoNewline
    }
    return $root
}

Describe 'ArtCraft bridge protocol' {
    It 'answers discover from a fixture root' {
        $root = New-BRoot @{ 'photocraft/photocraft.exe' = 'x'; 'notes/readme.txt' = 'docs, not an app' }
        $r = Invoke-BridgeRequest -Request '{"protocol":1,"id":"d1","op":"discover","params":{}}' -Root $root
        $r.ok | Should Be $true
        $r.id | Should Be 'd1'
        $r.protocol | Should Be 1
        (@($r.data.applications | Where-Object { $_.appId -eq 'photocraft' }).Count) | Should Be 1
        (@($r.data.applications | Where-Object { $_.installRoot -like '*notes*' }).Count) | Should Be 0
    }
    It 'rejects malformed, empty, and unknown requests without crashing' {
        $root = New-BRoot @{}
        $bad = Invoke-BridgeRequest -Request 'not json{{{' -Root $root
        $bad.ok | Should Be $false
        $bad.error.code | Should Be 'malformed-request'
        $empty = Invoke-BridgeRequest -Request '' -Root $root
        $empty.ok | Should Be $false
        $op = Invoke-BridgeRequest -Request '{"protocol":1,"id":"z9","op":"install","params":{}}' -Root $root
        $op.ok | Should Be $false
        $op.id | Should Be 'z9'
        $op.error.code | Should Be 'unknown-operation'
        $proto = Invoke-BridgeRequest -Request '{"protocol":99,"id":"p1","op":"discover","params":{}}' -Root $root
        $proto.ok | Should Be $false
        $proto.error.code | Should Be 'unsupported-protocol'
    }
    It 'exposes only the confirmed-update operation, never arbitrary execution' {
        $src = Get-Content -LiteralPath $Script:BridgeScript -Raw
        ($src -match 'Invoke-Expression|iex |Add-Type.*Reflection|Start-Process') | Should Be $false
        ($src -match 'Update-ArtCraftApp|Invoke-FlatUpdate|Invoke-VersionedCleanInstall|Install-ApprovedUpdate') | Should Be $false
        ($src -match 'Install-AppUpdate') | Should Be $true
        ($src -match '"discover"|"check-updates"|"validate-target"|"install-update"') | Should Be $true
    }
    It 'keeps diagnostics on stderr, protocol on stdout' {
        $root = New-BRoot @{}
        $raw = '{"protocol":1,"id":"s1","op":"discover","params":{}}' | powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript -Root $root 2>&1 | Out-String
        $lines = @($raw -split "`r`n" | Where-Object { $_.Trim() -ne '' })
        $parsed = $null
        foreach ($line in $lines) {
            try { $parsed = $line | ConvertFrom-Json; break } catch { }
        }
        $parsed.ok | Should Be $true
        $parsed.id | Should Be 's1'
    }
}

Describe 'ArtCraft bridge target validation' {
    It 'validates a fixture install root without modifying it' {
        $root = New-BRoot @{ 'photocraft/photocraft.exe' = 'x'; 'photocraft/portable.txt' = 'm' }
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        $req = '{"protocol":1,"id":"v1","op":"validate-target","params":{"appId":"photocraft","installRoot":"' +
            ($root -replace '\\', '/') + '/photocraft"}}'
        $out = $req | powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript 2>$null
        $r = ($out | ConvertFrom-Json)
        $r.ok | Should Be $true
        $r.id | Should Be 'v1'
        $r.data.rootExists | Should Be $true
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        (Compare-Object @($before) @($after)) | Should Be $null
    }
    It 'rejects unknown apps and missing parameters' {
        $root = New-BRoot @{}
        $bad = '{"protocol":1,"id":"v2","op":"validate-target","params":{"appId":"nope"}}' |
            powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript -Root $root 2>$null |
            ConvertFrom-Json
        $bad.ok | Should Be $false
        $bad.error.code | Should Be 'unknown-app'
        $missing = '{"protocol":1,"id":"v3","op":"validate-target","params":{}}' |
            powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $Script:BridgeScript -Root $root 2>$null |
            ConvertFrom-Json
        $missing.ok | Should Be $false
        $missing.error.code | Should Be 'bad-params'
    }
    It 'accepts a BOM-prefixed request instead of misreading its id' {
        # Regression: a UTF-8 BOM on stdin used to fail parsing, surfacing
        # downstream as a bridge id mismatch on the client.
        $root = New-BRoot @{}
        $reqFile = Join-Path $root 'bom-request.json'
        $json = '{"protocol":1,"id":"bom1","op":"discover","params":{}}'
        $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($json)
        [System.IO.File]::WriteAllBytes($reqFile, $bytes)
        $out = cmd /c "powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$($Script:BridgeScript)`" -Root `"$root`" < `"$reqFile`"" 2>$null
        $r = ($out | ConvertFrom-Json)
        $r.ok | Should Be $true
        $r.id | Should Be 'bom1'
    }
}

Describe 'ArtCraft bridge confirmed install gating' {
    It 'rejects install requests with missing approval fields' {
        $root = New-BRoot @{}
        $r = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i1","op":"install-update","params":{"appId":"photocraft"}}' -Root $root
        $r.ok | Should Be $false
        $r.id | Should Be 'i1'
        $r.error.code | Should Be 'bad-params'
    }
    It 'rejects untrusted application IDs and unsupported strategies' {
        $root = New-BRoot @{}
        $bad = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i2","op":"install-update","params":{"appId":"nope","installedVersion":"1.0.0","latestVersion":"2.0.0"}}' -Root $root
        $bad.ok | Should Be $false
        $bad.id | Should Be 'i2'
        $bad.error.code | Should Be 'unknown-app'
        $unsup = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i3","op":"install-update","params":{"appId":"vectorcraft","installedVersion":"1.0.0","latestVersion":"2.0.0"}}' -Root $root
        $unsup.ok | Should Be $false
        $unsup.id | Should Be 'i3'
        $unsup.error.code | Should Be 'unsupported-app'
    }
    It 'refuses when no verified target exists under the bridge root' {
        $root = New-BRoot @{ 'notes/readme.txt' = 'docs, not an app' }
        $r = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i4","op":"install-update","params":{"appId":"photocraft","installedVersion":"0.9.0","latestVersion":"9.9.9"}}' -Root $root
        $r.ok | Should Be $false
        $r.id | Should Be 'i4'
        $r.error.code | Should Be 'no-verified-target'
    }
    It 'rejects a stale approval when the installed version changed since review' {
        $root = New-BRoot @{ 'photocraft/install-manifest.json' = '{"schemaVersion":1,"appId":"photocraft","version":"9.9.8","files":[]}' }
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        $r = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i5","op":"install-update","params":{"appId":"photocraft","installedVersion":"9.9.9","latestVersion":"9.9.10"}}' -Root $root
        $r.ok | Should Be $false
        $r.id | Should Be 'i5'
        $r.error.code | Should Be 'stale-approval'
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        (Compare-Object @($before) @($after)) | Should Be $null
    }
    It 'reports release-check failures honestly without downloading anything' {
        # An unparseable installed version can never match a release, so the
        # release check refuses either way (offline CheckFailed or online
        # Unknown) before any download or install is attempted.
        $root = New-BRoot @{ 'photocraft/install-manifest.json' = '{"schemaVersion":1,"appId":"photocraft","version":"not-a-version","files":[]}' }
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        $r = Invoke-BridgeRequest -Request '{"protocol":1,"id":"i6","op":"install-update","params":{"appId":"photocraft","installedVersion":"not-a-version","latestVersion":"9.9.9"}}' -Root $root
        $r.ok | Should Be $false
        $r.id | Should Be 'i6'
        ($r.error.code -ne $null -and $r.error.code -ne '') | Should Be $true
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
        (Compare-Object @($before) @($after)) | Should Be $null
    }
}

Describe 'ArtCraft bridge fixture cleanup' {
    It 'removes temporary fixture directories' {
        foreach ($r in $Script:BRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:BRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
