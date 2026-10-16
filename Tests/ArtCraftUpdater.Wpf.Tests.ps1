<#
.SYNOPSIS
  Pester tests for the Phase 2A.1 top bar: exact supplied-spec values,
  structure, states, and engine isolation. No installs, no network.
#>

$Script:UiDir = 'D:\Art Craft\tools\ui\ArtCraftUpdater'

Describe 'ArtCraft WPF prototype build' {
    It 'builds with zero warnings and zero errors' {
        $out = dotnet build (Join-Path $Script:UiDir 'ArtCraftUpdater.Wpf.csproj') -v minimal --nologo 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'Build succeeded'
        $out | Should Match '0 Warning\(s\)'
        $out | Should Match '0 Error\(s\)'
    }
    It 'produces a runnable framework-dependent executable' {
        $exe = Join-Path $Script:UiDir 'bin\Debug\net9.0-windows\ArtCraftUpdater.Wpf.exe'
        (Test-Path -LiteralPath $exe) | Should Be $true
    }
}

Describe 'ArtCraft WPF theme tokens' {
    It 'uses the single specified dark theme' {
        (Test-Path -LiteralPath (Join-Path $Script:UiDir 'Themes\Dark.xaml')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $Script:UiDir 'Themes\Light.xaml')) | Should Be $false
        $app = Get-Content -LiteralPath (Join-Path $Script:UiDir 'App.xaml') -Raw
        ($app -match 'Themes/Dark\.xaml') | Should Be $true
    }
    It 'defines the exact specified token values' {
        $tokens = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Themes\Dark.xaml') -Raw
        foreach ($hex in @('#0F1115', '#14171C', '#22262E', '#181B21', '#272B34', '#1C2230',
                '#E7E9EE', '#C5CAD3', '#9AA1AE', '#6AA5FF', '#0B1220',
                '#6EE0A8', '#16301F', '#F5C26B', '#3A2D12', '#2A2E37',
                '#232730', '#343945', '#2A2F3A', '#3F4552', '#1D2027',
                '#1A1D23', '#5B6270', '#85B6FF', '#4F90F0', '#26324A', '#6F7A90')) {
            ($tokens -match [regex]::Escape($hex)) | Should Be $true
        }
    }
    It 'is well-formed XAML' {
        $xamls = @(Get-ChildItem -LiteralPath $Script:UiDir -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Extension -eq '.xaml' } |
            Select-Object -ExpandProperty FullName)
        ($xamls.Count -ge 3) | Should Be $true
        foreach ($f in $xamls) {
            { [xml](Get-Content -LiteralPath $f -Raw) } | Should Not Throw
        }
    }
}

Describe 'ArtCraft top bar to specification' {
    It 'shows the specified heading and subheader' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml') -Raw
        ($xaml -match 'Text="Updates"') | Should Be $true
        ($xaml -match 'last checked today at 22:11') | Should Be $true
        ($xaml -match 'Style="\{StaticResource HeadingText\}"') | Should Be $true
        ($xaml -match 'Style="\{StaticResource SubheaderText\}"') | Should Be $true
        $theme = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Themes\Dark.xaml') -Raw
        ($theme -match 'HeadingText') | Should Be $true
        ($theme -match 'FontSize" Value="24"') | Should Be $true
        ($theme -match 'FontSize" Value="14"') | Should Be $true
        ($theme -match 'FontWeight" Value="Bold"') | Should Be $true
        ($theme -match 'Margin" Value="0,4,0,0"') | Should Be $true
    }
    It 'orders buttons Check again, Update selected, Update all with roles' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml') -Raw
        $check = $xaml.IndexOf('CheckAgainButton')
        $sel = $xaml.IndexOf('UpdateSelectedButton')
        $all = $xaml.IndexOf('UpdateAllButton')
        ($check -lt $sel -and $sel -lt $all) | Should Be $true
        ($xaml -match 'Text="Check again"') | Should Be $true
        ($xaml -match 'Content="Update selected"') | Should Be $true
        ($xaml -match 'Content="Update all"') | Should Be $true
    }
    It 'renders labels literally with no access-key underscores' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml') -Raw
        ($xaml -match '_Update|Update _|_Check|Check _|_all|_All') | Should Be $false
        ($xaml -match 'TabIndex="0"') | Should Be $true
        ($xaml -match 'TabIndex="1"') | Should Be $true
        ($xaml -match 'TabIndex="2"') | Should Be $true
    }
    It 'pins the button group right with a Grid, not a filling DockPanel' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml') -Raw
        ($xaml -match 'DockPanel Dock=') | Should Be $false
        ($xaml -match 'Grid\.Column="0"') | Should Be $true
        ($xaml -match 'Grid\.Column="1"') | Should Be $true
        ($xaml -match 'HorizontalAlignment="Right"') | Should Be $true
        ($xaml -match 'Width="\*"') | Should Be $true
        ($xaml -match 'Padding="0,0,0,16"') | Should Be $true
    }
    It 'uses 40px buttons with 8px radius, 1px border, 18px padding, 14px semibold' {
        $theme = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Themes\Dark.xaml') -Raw
        ($theme -match 'Height" Value="40"') | Should Be $true
        ($theme -match 'ButtonCornerRadius">8,8,8,8') | Should Be $true
        ($theme -match 'Padding" Value="18,0,18,0"') | Should Be $true
        ($theme -match 'FontSize" Value="14"') | Should Be $true
        ($theme -match 'FontWeight" Value="SemiBold"') | Should Be $true
        ($theme -match 'BorderThickness" Value="1"') | Should Be $true
    }
    It 'carries the Segoe Fluent Icons refresh glyph with an 8px label gap' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml') -Raw
        ($xaml -match 'FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"') | Should Be $true
        ($xaml -match '&#xE72C;') | Should Be $true
        ($xaml -match 'FontSize="16"') | Should Be $true
        ($xaml -match 'Margin="0,0,8,0"') | Should Be $true
        ($xaml -match 'Margin="10,0,0,0"') | Should Be $true
        ($xaml -match '<Path ') | Should Be $false
    }
    It 'implements hover, pressed, focus, and hover-inert disabled states' {
        $theme = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Themes\Dark.xaml') -Raw
        ($theme -match 'MultiTrigger') | Should Be $true
        ($theme -match 'FocusVisualStyle') | Should Be $true
        ($theme -match 'StrokeThickness="2"') | Should Be $true
        ($theme -match '#26324A') | Should Be $true
        ($theme -match '#6F7A90') | Should Be $true
    }
    It 'implements all status variants and selection gating in mock state' {
        $code = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\TopBar.xaml.cs') -Raw
        foreach ($token in @('TopBarStatus', 'Default', 'Checking', 'Error', 'UpToDate',
                'Checking...', 'Checking for updates...', 'WarningBrush', 'SuccessBrush',
                'CheckingSpinner', 'hasSelection', 'hasUpdates')) {
            ($code -match [regex]::Escape($token)) | Should Be $true
        }
        ($code -match 'Update-ArtCraftApp|HttpClient|WebClient|Process\.Start') | Should Be $false
    }
}

Describe 'ArtCraft application list' {
    It 'renders rows with name, versions, and status badge bindings' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml') -Raw
        ($xaml -match 'AppRowTemplate') | Should Be $true
        ($xaml -match 'Text="\{Binding Name\}"') | Should Be $true
        ($xaml -match 'Text="\{Binding InstalledVersion\}"') | Should Be $true
        ($xaml -match 'Text="\{Binding LatestVersion\}"') | Should Be $true
        ($xaml -match 'Kind="\{Binding StatusKind\}"') | Should Be $true
        ($xaml -match 'Text="\{Binding StatusText\}"') | Should Be $true
        ($xaml -match 'Text="\{Binding Initial\}"') | Should Be $true
    }
    It 'uses live data in MainWindow, mock data only for tests' {
        $mock = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Models\MockData.cs') -Raw
        ($mock -match 'MOCK') | Should Be $true
        foreach ($kind in @('UpdateAvailable', 'UpToDate', 'Checking', 'Failed')) {
            ($mock -match [regex]::Escape("StatusKind.$kind")) | Should Be $true
        }
        $main = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml.cs') -Raw
        ($main -match 'MockData\.GetApps') | Should Be $false
        ($main -match 'UpdateCheckService|GetRowsAsync') | Should Be $true
    }
    It 'styles badges per status with text, reusing tokens' {
        $code = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\StatusBadge.xaml.cs') -Raw
        ($code -match 'WarningBrush') | Should Be $true
        ($code -match 'SuccessBrush') | Should Be $true
        ($code -match 'TryFindResource') | Should Be $true
        ($code -match 'amber-toned') | Should Be $true
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Controls\StatusBadge.xaml') -Raw
        ($xaml -match 'CornerRadius="10"') | Should Be $true
    }
    It 'keeps selection state separate with enablement rules' {
        $state = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Models\AppListState.cs') -Raw
        foreach ($token in @('Toggle(', 'HasSelection', 'HasUpdates', 'CanUpdateSelected', 'CanUpdateAll', 'globallyDisabled')) {
            ($state -match [regex]::Escape($token)) | Should Be $true
        }
        ($state -match 'System\.Windows') | Should Be $false
        $main = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml.cs') -Raw
        ($main -match 'SelectionChanged') | Should Be $true
        ($main -match 'SetStatus') | Should Be $true
    }
    It 'highlights selected rows and stays keyboard accessible' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml') -Raw
        ($xaml -match 'SelectedRowBrush') | Should Be $true
        ($xaml -match 'SelectionMode="Extended"') | Should Be $true
        ($xaml -match 'FocusVisualStyle') | Should Be $true
    }
}
Describe 'ArtCraft WPF isolation guards' {
    It 'contains no network, arbitrary process-launch, or PowerShell-hosting code' {
        $sources = @(Get-ChildItem -LiteralPath $Script:UiDir -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and ($_.Extension -in '.cs', '.xaml') } |
            Select-Object -ExpandProperty FullName)
        foreach ($f in $sources) {
            $text = Get-Content -LiteralPath $f -Raw
            $banned = @('HttpClient', 'WebClient', 'HttpWebRequest', 'Management.Automation', 'System.Management')
            if ($f -notlike '*Services\BridgeClient.cs') { $banned += 'Process.Start' }
            foreach ($b in $banned) {
                ($text -match [regex]::Escape($b)) | Should Be $false
            }
        }
        $bridge = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Services\BridgeClient.cs') -Raw
        ($bridge -match 'Process\.Start') | Should Be $true
        ($bridge -match 'powershell\.exe') | Should Be $true
        ($bridge -match '-File \\"" \+ _bridgeScript') | Should Be $true
    }
    It 'uses BOM-less UTF-8 for bridge stdio' {
        $client = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Services\BridgeClient.cs') -Raw
        ($client -match 'UTF8Encoding\(encoderShouldEmitUTF8Identifier: false\)') | Should Be $true
        ($client -match 'StandardInputEncoding = Encoding\.UTF8\b') | Should Be $false
        ($client -match 'StandardOutputEncoding = Encoding\.UTF8\b') | Should Be $false
    }
    It 'references no PowerShell or network NuGet packages' {
        $proj = Get-Content -LiteralPath (Join-Path $Script:UiDir 'ArtCraftUpdater.Wpf.csproj') -Raw
        ($proj -match 'PackageReference') | Should Be $false
    }
}

$Script:CorrRoots = @()
$Script:CorrRunnerExe = $null

function Get-CorrRunner {
    # Builds (once per session) a tiny console runner that links the REAL
    # BridgeClient.cs and exercises InvokeAsync against a stub bridge script.
    # Everything lives under TEMP; the repository gains no new files.
    if ($Script:CorrRunnerExe -and (Test-Path -LiteralPath $Script:CorrRunnerExe)) {
        return $Script:CorrRunnerExe
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftCorr-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $Script:CorrRoots += $work
    $clientCs = Join-Path $Script:UiDir 'Services\BridgeClient.cs'
    $csproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>disable</Nullable>
    <AssemblyName>CorrRunner</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="__CLIENTCS__" />
  </ItemGroup>
</Project>
'@ -replace '__CLIENTCS__', $clientCs
    Set-Content -LiteralPath (Join-Path $work 'CorrRunner.csproj') -Value $csproj -NoNewline
    $program = @'
using System;
using System.Threading;
using System.Threading.Tasks;
using ArtCraftUpdater.Wpf;
class CorrRunner
{
    static int Main(string[] args)
    {
        string script = args[0];
        string op = args.Length > 1 ? args[1] : "discover";
        try
        {
            using (var client = new BridgeClient(script, 60000))
            {
                using (var doc = client.InvokeAsync(op, CancellationToken.None).GetAwaiter().GetResult())
                {
                    Console.WriteLine("OK id=" + doc.RootElement.GetProperty("id").GetString());
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine("EX " + ex.GetType().Name + ": " + ex.Message);
            return 0;
        }
    }
}
'@
    Set-Content -LiteralPath (Join-Path $work 'Program.cs') -Value $program -NoNewline
    $out = Join-Path $work 'out'
    $buildLog = dotnet build (Join-Path $work 'CorrRunner.csproj') -o $out --nologo -v minimal 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "CorrRunner build failed: $buildLog" }
    $Script:CorrRunnerExe = Join-Path $out 'CorrRunner.exe'
    return $Script:CorrRunnerExe
}

function New-CorrStub {
    param([string]$Body)
    $stub = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftStub-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $stub -Value $Body -NoNewline
    $Script:CorrRoots += $stub
    return $stub
}

Describe 'ArtCraft bridge client correlation' {
    It 'accepts a valid echoed response and sends BOM-free stdin (original defect setup)' {
        # Reproduces the original failure setup end to end: the real C# client
        # drives a real out-of-process script over redirected stdin/stdout and
        # the response id must correlate. The historic defect was 3 invisible
        # BOM bytes (EF BB BF) prepended to stdin, which made the bridge answer
        # malformed-request with an empty id and surfaced as "id mismatch".
        $dump = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftStdin-' + [guid]::NewGuid().ToString('N') + '.bin')
        $Script:CorrRoots += $dump
        $echoStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$bytes = $ms.ToArray()
[System.IO.File]::WriteAllBytes($env:BRIDGE_STDIN_DUMP, $bytes)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$text = $text.TrimStart([char]0xFEFF).Trim()
$id = ''
if ($text -match '"id"\s*:\s*"([^"]+)"') { $id = $Matches[1] }
[Console]::Out.WriteLine(('{"protocol":1,"id":"' + $id + '","ok":true,"data":{}}'))
'@
        $stub = New-CorrStub -Body $echoStub
        $exe = Get-CorrRunner
        $env:BRIDGE_STDIN_DUMP = $dump
        try {
            $out = & $exe $stub 'discover' 2>&1 | Out-String
        } finally {
            Remove-Item Env:\BRIDGE_STDIN_DUMP -ErrorAction SilentlyContinue
        }
        ($out -match 'OK id=[0-9a-f]{32}') | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes($dump)
        ($bytes.Length -gt 3) | Should Be $true
        $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasBom | Should Be $false
        ($bytes[0] -eq 0x7B) | Should Be $true
    }
    It 'rejects a genuinely mismatched response id' {
        # A foreign or crossed response must never be accepted: strict
        # correlation stays intact even though spurious mismatches are fixed.
        $wrongStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
[Console]::Out.WriteLine('{"protocol":1,"id":"ffffffffffffffffffffffffffffffff","ok":true,"data":{}}')
'@
        $stub = New-CorrStub -Body $wrongStub
        $exe = Get-CorrRunner
        $out = & $exe $stub 'discover' 2>&1 | Out-String
        ($out -match 'Bridge response id mismatch') | Should Be $true
    }
    It 'rejects an empty-id error response instead of accepting it' {
        # This is the exact shape the bridge returns for an unparseable
        # request (malformed-request with id ""). It must stay rejected.
        $emptyStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
[Console]::Out.WriteLine('{"protocol":1,"id":"","ok":false,"error":{"code":"malformed-request","message":"request is not valid JSON"}}')
'@
        $stub = New-CorrStub -Body $emptyStub
        $exe = Get-CorrRunner
        $out = & $exe $stub 'discover' 2>&1 | Out-String
        ($out -match 'Bridge response id mismatch') | Should Be $true
    }
}

Describe 'ArtCraft main window dimensions' {
    It 'uses an 880x520 default window preserving height, minima, and resize behavior' {
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml') -Raw
        ($xaml -match 'Width="880"') | Should Be $true
        ($xaml -match 'Height="520"') | Should Be $true
        ($xaml -match 'MinWidth="640"') | Should Be $true
        ($xaml -match 'MinHeight="360"') | Should Be $true
        ($xaml -match 'ResizeMode') | Should Be $false
    }
}

Describe 'ArtCraft correlation fixture cleanup' {
    It 'removes temporary runner and stub files' {
        foreach ($r in $Script:CorrRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:CorrRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}

Describe 'ArtCraft confirmed update execution UI' {
    It 'routes a current approval to the install dialog and consumes it' {
        $main = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml.cs') -Raw
        ($main -match 'ApprovalValidation\.Validate') | Should Be $true
        ($main -match 'RunInstallAsync') | Should Be $true
        ($main -match 'new InstallDialog') | Should Be $true
        ($main -match '_tracker') | Should Be $true
        ($main -match '_lastApproval = null') | Should Be $true
        ($main -match 'MockData\.GetApps') | Should Be $false
    }
    It 'executes only through the validating bridge install operation with a long timeout' {
        $svc = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Services\UpdateExecutionService.cs') -Raw
        ($svc -match '"install-update"') | Should Be $true
        ($svc -match 'InstallTimeoutMs') | Should Be $true
        ($svc -match 'CancellationToken\.None') | Should Be $true
        ($svc -match 'TryBegin|TryEnd|tracker\.End') | Should Be $true
        ($svc -match 'Start-Process|Update-ArtCraftApp|Invoke-Expression') | Should Be $false
    }
    It 'keeps the install dialog explicit, non-cancellable mid-run, and truthful' {
        $dlg = Get-Content -LiteralPath (Join-Path $Script:UiDir 'InstallDialog.xaml.cs') -Raw
        ($dlg -match 'InstallAttempted') | Should Be $true
        ($dlg -match 'args\.Cancel = true') | Should Be $true
        ($dlg -match 'RollbackSucceeded') | Should Be $true
        ($dlg -match 'InstalledVersionAfter') | Should Be $true
        ($dlg -match 'AllSucceeded') | Should Be $true
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'InstallDialog.xaml') -Raw
        ($xaml -match 'Content="Install"') | Should Be $true
        ($xaml -match 'cannot be cancelled') | Should Be $true
    }
    It 'validates approvals purely: missing, expired, stale, mismatched, unknown' {
        $v = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Models\ApprovalValidation.cs') -Raw
        foreach ($token in @('no-approval', 'approval-expired', 'approval-stale', 'approval-mismatch', 'unknown-app', 'ApprovalTtlMinutes')) {
            ($v -match [regex]::Escape($token)) | Should Be $true
        }
    }
    It 'guards duplicate and overlapping installs with a tracker' {
        $t = Get-Content -LiteralPath (Join-Path $Script:UiDir 'Models\InstallTracker.cs') -Raw
        foreach ($token in @('TryBegin', 'End(', 'IsActive', 'AnyActive', 'HashSet')) {
            ($t -match [regex]::Escape($token)) | Should Be $true
        }
    }
    It 'preserves review Confirm/Cancel behavior, theme, and dimensions' {
        $review = Get-Content -LiteralPath (Join-Path $Script:UiDir 'ReviewDialog.xaml.cs') -Raw
        ($review -match 'ConfirmButton') | Should Be $true
        ($review -match 'CancelButton') | Should Be $true
        ($review -match 'Approval = new ApprovalRecord') | Should Be $true
        $xaml = Get-Content -LiteralPath (Join-Path $Script:UiDir 'MainWindow.xaml') -Raw
        ($xaml -match 'Width="880"') | Should Be $true
        ($xaml -match 'Height="520"') | Should Be $true
    }
}

$Script:ExecRoots = @()
$Script:ExecRunnerExe = $null

function Get-ExecRunner {
    # Builds (once per session) a console runner that links the REAL
    # execution sources (validation, tracker, service, bridge client) and
    # runs a behavioral matrix against stub bridge scripts in TEMP.
    if ($Script:ExecRunnerExe -and (Test-Path -LiteralPath $Script:ExecRunnerExe)) {
        return $Script:ExecRunnerExe
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftExec-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $Script:ExecRoots += $work
    $links = @(
        'Services\BridgeClient.cs',
        'Models\ApprovalValidation.cs',
        'Models\InstallTracker.cs',
        'Services\UpdateExecutionService.cs',
        'Models\AppListItem.cs'
    ) | ForEach-Object { '    <Compile Include="' + (Join-Path $Script:UiDir $_) + '" />' }
    $csproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>disable</Nullable>
    <AssemblyName>ExecRunner</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
__LINKS__
  </ItemGroup>
</Project>
'@ -replace '__LINKS__', ($links -join "`r`n")
    Set-Content -LiteralPath (Join-Path $work 'ExecRunner.csproj') -Value $csproj -NoNewline
    $program = @'
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using ArtCraftUpdater.Wpf;
class ExecRunner
{
    static int pass = 0;
    static void Check(string name, bool cond, string detail)
    {
        if (cond) { Console.WriteLine("PASS " + name); pass++; }
        else { Console.WriteLine("FAIL " + name + " :: " + detail); }
    }
    static AppListItem Row(string id, string inst, string latest, AppStatusKind kind)
    {
        return new AppListItem { Id = id, Name = id + "-name", Initial = "X", InstalledVersion = inst, LatestVersion = latest, StatusKind = kind, StatusText = kind.ToString() };
    }
    static int Main(string[] args)
    {
        DateTime now = DateTime.UtcNow;
        var approved = new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        var current = new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        var targets = new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        ApprovalCheck c0 = ApprovalValidation.Validate(null, now, current, targets, now);
        Check("approval-missing", !c0.Ok && c0.Reason == "no-approval", c0.Reason);
        ApprovalCheck c1 = ApprovalValidation.Validate(approved, now - TimeSpan.FromMinutes(31), current, targets, now);
        Check("approval-expired", !c1.Ok && c1.Reason == "approval-expired", c1.Reason);
        ApprovalCheck c1b = ApprovalValidation.Validate(approved, now - TimeSpan.FromMinutes(29), current, targets, now);
        Check("approval-fresh", c1b.Ok, c1b.Reason);
        var staleT = new List<AppListItem> { Row("photocraft", "1.5.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        ApprovalCheck c2 = ApprovalValidation.Validate(approved, now, current, staleT, now);
        Check("approval-stale-installed", !c2.Ok && c2.Reason == "approval-stale", c2.Reason);
        var staleL = new List<AppListItem> { Row("photocraft", "1.0.0", "3.0.0", AppStatusKind.UpdateAvailable) };
        ApprovalCheck c3 = ApprovalValidation.Validate(approved, now, current, staleL, now);
        Check("approval-stale-latest", !c3.Ok && c3.Reason == "approval-stale", c3.Reason);
        var other = new List<AppListItem> { Row("filmcraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        ApprovalCheck c4 = ApprovalValidation.Validate(approved, now, current, other, now);
        Check("approval-mismatch", !c4.Ok && c4.Reason == "approval-mismatch", c4.Reason);
        var moved = new List<AppListItem> { Row("photocraft", "2.0.0", "2.0.0", AppStatusKind.UpToDate) };
        ApprovalCheck c5 = ApprovalValidation.Validate(approved, now, moved, targets, now);
        Check("approval-stale-current", !c5.Ok && c5.Reason == "approval-stale", c5.Reason);
        var emptyT = new List<AppListItem> { Row("", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) };
        ApprovalCheck c6 = ApprovalValidation.Validate(approved, now, current, emptyT, now);
        Check("approval-unknown-app", !c6.Ok && c6.Reason == "unknown-app", c6.Reason);
        ApprovalCheck c7 = ApprovalValidation.Validate(approved, now, current, targets, now);
        Check("approval-current", c7.Ok && c7.Reason == "approval-current", c7.Reason);
        var tr = new InstallTracker();
        Check("tracker-begin", tr.TryBegin("photocraft"), "");
        Check("tracker-duplicate", !tr.TryBegin("photocraft"), "");
        Check("tracker-active", tr.IsActive("photocraft"), "");
        Check("tracker-any", tr.AnyActive, "");
        tr.End("photocraft");
        Check("tracker-reacquire", tr.TryBegin("photocraft"), "");
        tr.End("photocraft");
        Check("tracker-empty", !tr.AnyActive, "");
        Check("tracker-empty-id", !tr.TryBegin(null) && !tr.TryBegin(""), "");
        InstallAttempt m1 = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":true,\"data\":{\"success\":true,\"outcome\":\"installed and verified\",\"stageReached\":\"manifest-write\",\"rollbackPerformed\":false,\"installedVersionAfter\":\"2.0.0\"}}");
        Check("map-success", m1.Success && m1.Outcome == "installed and verified" && m1.StageReached == "manifest-write" && m1.InstalledVersionAfter == "2.0.0" && !m1.RollbackPerformed && m1.RollbackSucceeded == null, m1.Outcome);
        InstallAttempt m2 = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":false,\"error\":{\"code\":\"stale-approval\",\"message\":\"installed version changed\"}}");
        Check("map-refusal", !m2.Success && m2.Outcome.Contains("stale-approval") && m2.Outcome.Contains("installed version changed"), m2.Outcome);
        InstallAttempt m3 = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":true,\"data\":{\"success\":false,\"outcome\":\"install refused/failed: commit: boom\",\"stageReached\":\"commit\",\"rollbackPerformed\":true,\"rollbackSucceeded\":false}}");
        Check("map-failure-rollback", !m3.Success && m3.RollbackPerformed && m3.RollbackSucceeded == false && m3.StageReached == "commit", m3.Outcome);
        InstallAttempt m3b = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":true,\"data\":{\"success\":false,\"outcome\":\"install refused/failed: x\",\"rollbackPerformed\":true,\"rollbackSucceeded\":true}}");
        Check("map-rollback-ok", !m3b.Success && m3b.RollbackPerformed && m3b.RollbackSucceeded == true, m3b.Outcome);
        InstallAttempt m4 = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":true}");
        Check("map-no-data", !m4.Success && m4.Outcome.Length > 0, m4.Outcome);
        InstallAttempt m5 = UpdateExecutionService.MapResponseLine("{\"protocol\":1,\"id\":\"abc\",\"ok\":true,\"data\":{\"success\":true,\"outcome\":\"\"}}");
        Check("map-success-default-outcome", m5.Success && m5.Outcome == "installed and verified", m5.Outcome);
        bool threw = false;
        try { UpdateExecutionService.MapResponseLine("not json{{{"); } catch { threw = true; }
        Check("map-malformed-throws", threw, "");
        string p = UpdateExecutionService.BuildParams(Row("a\"b\\c", "1.0", "2.0", AppStatusKind.UpdateAvailable));
        Check("buildparams-escape", p.Contains("a\\\"b\\\\c"), p);
        var svc = new UpdateExecutionService(args[0], new InstallTracker(), 1500);
        List<InstallAttempt> t1 = svc.ExecuteAsync(new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) }, CancellationToken.None).GetAwaiter().GetResult();
        Check("live-timeout", t1.Count == 1 && !t1[0].Success && t1[0].Outcome.Contains("timed out"), t1.Count > 0 ? t1[0].Outcome : "no attempts");
        var svc2t = new InstallTracker();
        var svc2 = new UpdateExecutionService(args[1], svc2t);
        List<InstallAttempt> t2 = svc2.ExecuteAsync(new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) }, CancellationToken.None).GetAwaiter().GetResult();
        Check("live-malformed", t2.Count == 1 && !t2[0].Success, t2.Count > 0 ? t2[0].Outcome : "no attempts");
        Check("live-malformed-cleanup", !svc2t.AnyActive, "");
        var svc3 = new UpdateExecutionService(args[2], new InstallTracker());
        List<InstallAttempt> t3 = svc3.ExecuteAsync(new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) }, CancellationToken.None).GetAwaiter().GetResult();
        Check("live-success", t3.Count == 1 && t3[0].Success && t3[0].InstalledVersionAfter == "2.0.0", t3.Count > 0 ? t3[0].Outcome : "no attempts");
        var svc4 = new UpdateExecutionService(args[3], new InstallTracker());
        List<InstallAttempt> t4 = svc4.ExecuteAsync(new List<AppListItem> { Row("photocraft", "1.0.0", "2.0.0", AppStatusKind.UpdateAvailable) }, CancellationToken.None).GetAwaiter().GetResult();
        Check("live-refusal", t4.Count == 1 && !t4[0].Success && t4[0].Outcome.Contains("stale-approval"), t4.Count > 0 ? t4[0].Outcome : "no attempts");
        Console.WriteLine("TOTALPASS " + pass);
        return 0;
    }
}
'@
    Set-Content -LiteralPath (Join-Path $work 'Program.cs') -Value $program -NoNewline
    $out = Join-Path $work 'out'
    $buildLog = dotnet build (Join-Path $work 'ExecRunner.csproj') -o $out --nologo -v minimal 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ExecRunner build failed: $buildLog" }
    $Script:ExecRunnerExe = Join-Path $out 'ExecRunner.exe'
    return $Script:ExecRunnerExe
}

Describe 'ArtCraft execution behavioral matrix' {
    It 'passes validation, tracker, mapping, timeout, malformed, and live stub scenarios' {
        $sleepStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
Start-Sleep -Seconds 20
[Console]::Out.WriteLine('{"protocol":1,"id":"late","ok":true,"data":{"success":true,"outcome":"x"}}')
'@
        $garbageStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
[Console]::Out.WriteLine('this is not json')
'@
        $okStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
$id = ''
if ($text -match '"id"\s*:\s*"([^"]+)"') { $id = $Matches[1] }
[Console]::Out.WriteLine(('{"protocol":1,"id":"' + $id + '","ok":true,"data":{"success":true,"outcome":"installed and verified","stageReached":"manifest-write","rollbackPerformed":false,"installedVersionAfter":"2.0.0"}}'))
'@
        $refuseStub = @'
param()
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
$id = ''
if ($text -match '"id"\s*:\s*"([^"]+)"') { $id = $Matches[1] }
[Console]::Out.WriteLine(('{"protocol":1,"id":"' + $id + '","ok":false,"error":{"code":"stale-approval","message":"installed version changed since review"}}'))
'@
        $stubs = @($sleepStub, $garbageStub, $okStub, $refuseStub) | ForEach-Object {
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ('ArtCraftExecStub-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $f -Value $_ -NoNewline
            $Script:ExecRoots += $f
            $f
        }
        $exe = Get-ExecRunner
        $out = & $exe $stubs[0] $stubs[1] $stubs[2] $stubs[3] 2>&1 | Out-String
        ($out -match 'FAIL ') | Should Be $false
        ($out -match 'TOTALPASS 29') | Should Be $true
    }
}

Describe 'ArtCraft execution fixture cleanup' {
    It 'removes temporary runner and stub files' {
        foreach ($r in $Script:ExecRoots) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($r in $Script:ExecRoots) {
            (Test-Path -LiteralPath $r) | Should Be $false
        }
    }
}
