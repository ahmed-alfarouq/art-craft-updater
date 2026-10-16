<#
.SYNOPSIS
  Pester tests for the packaged ArtCraftUpdater.exe. Launches the real EXE
  headless, verifies the GUI window appears, then closes it. Never installs
  updates (the GUI only inspects on launch).
#>
$Script:DistDir = 'D:\Art Craft\tools\dist'
$Script:Launched = @()

function Start-PackagedGui {
    param([string]$Directory)
    $p = Start-Process -FilePath (Join-Path $Directory 'ArtCraftUpdater.exe') `
        -WorkingDirectory $Directory -PassThru
    $Script:Launched += $p.Id
    return $p
}

function Find-GuiProcess {
    param([string]$Directory, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$Directory*" }
        foreach ($pr in @($procs)) {
            try {
                $live = Get-Process -Id $pr.ProcessId -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($live.MainWindowTitle)) { return $live }
            } catch { }
        }
        Start-Sleep -Milliseconds 1000
    }
    return $null
}

function Stop-GuiProcess {
    param($Process)
    try {
        $Process.CloseMainWindow() | Out-Null
        if (-not $Process.WaitForExit(15000)) { Stop-Process -Id $Process.Id -Force }
    } catch { }
}

Describe 'ArtCraft packaged EXE contents' {
    It 'ships byte-identical companions' {
        foreach ($name in @('ArtCraftUpdater.Gui.ps1', 'ArtCraftUpdater.Controller.psm1', 'ArtCraftInstall.psm1', 'apps.registry.json')) {
            $a = (Get-FileHash -LiteralPath (Join-Path 'D:\Art Craft\tools' $name) -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath (Join-Path $Script:DistDir $name) -Algorithm SHA256).Hash
            $a | Should Be $b
        }
    }
    It 'is a console-less Windows executable' {
        $exe = Join-Path $Script:DistDir 'ArtCraftUpdater.exe'
        (Test-Path -LiteralPath $exe) | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes($exe)
        $pe = [BitConverter]::ToInt32($bytes, 0x3C)
        $subsystem = [BitConverter]::ToUInt16($bytes, $pe + 0x5C)
        $subsystem | Should Be 2
    }
}

Describe 'ArtCraft packaged EXE launch' {
    It 'shows the updater window and closes cleanly' {
        $stub = Start-PackagedGui -Directory $Script:DistDir
        try {
            $gui = Find-GuiProcess -Directory $Script:DistDir
            $gui | Should Not BeNullOrEmpty
            $gui.MainWindowTitle | Should Be 'ArtCraft Updater'
            Stop-GuiProcess -Process $gui
            $gui.WaitForExit(15000) | Out-Null
            $gui.HasExited | Should Be $true
        } finally {
            try { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    It 'runs from an isolated copy without source-tree dependencies' {
        $iso = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftIso-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $iso | Out-Null
        try {
            Copy-Item -Path (Join-Path $Script:DistDir '*') -Destination $iso -Recurse -Force
            $stub = Start-PackagedGui -Directory $iso
            try {
                $gui = Find-GuiProcess -Directory $iso
                $gui | Should Not BeNullOrEmpty
                $gui.MainWindowTitle | Should Be 'ArtCraft Updater'
                Stop-GuiProcess -Process $gui
                $gui.WaitForExit(15000) | Out-Null
                $gui.HasExited | Should Be $true
            } finally {
                try { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        } finally {
            Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
