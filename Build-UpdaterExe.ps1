<#
.SYNOPSIS
  Builds tools\dist\ArtCraftUpdater.exe, a double-clickable console-less
  launcher for ArtCraftUpdater.Gui.ps1.
.DESCRIPTION
  Uses only the .NET Framework C# compiler already present on Windows
  (no downloads, no new dependencies). The EXE is a thin stub: it starts
  powershell.exe hidden with the GUI script beside it and returns its exit
  code. All updater logic stays in the auditable .ps1/.psm1/.json companions,
  which the build copies fresh from tools\ on every run. PowerShell 5.1 is
  still required at runtime.
.EXAMPLE
  powershell -File Build-UpdaterExe.ps1
  powershell -File Build-UpdaterExe.ps1 -OutputDir C:\temp\au-dist
#>
param([string]$OutputDir = '')
$ErrorActionPreference = 'Stop'
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $ToolsDir 'dist' }

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $null
foreach ($c in $cscCandidates) {
    if (Test-Path -LiteralPath $c -PathType Leaf) { $csc = $c; break }
}
if (-not $csc) { throw 'No .NET Framework C# compiler found; cannot build without downloading tools.' }
Write-Output "Compiler: $csc"

$companions = @('ArtCraftUpdater.Gui.ps1', 'ArtCraftUpdater.Controller.psm1', 'ArtCraftInstall.psm1', 'apps.registry.json')
foreach ($name in $companions) {
    if (-not (Test-Path -LiteralPath (Join-Path $ToolsDir $name) -PathType Leaf)) {
        throw "Required companion missing in ${ToolsDir}: $name"
    }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$stubPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftUpdaterStub-' + [guid]::NewGuid().ToString('N') + '.cs')
$stubSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string script = Path.Combine(exeDir, "ArtCraftUpdater.Gui.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show("ArtCraftUpdater.Gui.ps1 was not found next to the executable:\n" + script,
                    "ArtCraft Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(powershell))
            {
                powershell = "powershell.exe";
            }
            string arguments = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File \"" + script + "\"";
            foreach (string a in args)
            {
                arguments += " \"" + a.Replace("\"", "") + "\"";
            }
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = arguments;
            psi.WorkingDirectory = exeDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process proc = Process.Start(psi);
            proc.WaitForExit();
            return proc.ExitCode;
        }
        catch (Exception ex)
        {
            try
            {
                MessageBox.Show("ArtCraft Updater failed to start:\n" + ex.Message,
                    "ArtCraft Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch { }
            return 1;
        }
    }
}
'@
Set-Content -LiteralPath $stubPath -Value $stubSource -Encoding UTF8
try {
    $exePath = Join-Path $OutputDir 'ArtCraftUpdater.exe'
    & $csc /nologo /target:winexe /optimize+ /out:"$exePath" "$stubPath"
    if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $stubPath -Force -ErrorAction SilentlyContinue
}
foreach ($name in $companions) {
    Copy-Item -LiteralPath (Join-Path $ToolsDir $name) -Destination (Join-Path $OutputDir $name) -Force
}
Write-Output "Built: $exePath"
Get-ChildItem -LiteralPath $OutputDir -File | ForEach-Object { Write-Output ("  {0}  {1} bytes" -f $_.Name, $_.Length) }
foreach ($name in $companions) {
    $a = (Get-FileHash -LiteralPath (Join-Path $ToolsDir $name) -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath (Join-Path $OutputDir $name) -Algorithm SHA256).Hash
    if ($a -ne $b) { throw "companion mismatch after copy: $name" }
}
Write-Output 'Companions verified byte-identical to tools\ sources.'
