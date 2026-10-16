<#
.SYNOPSIS
  ArtCraft Updater desktop GUI (Windows Forms, PowerShell 5.1).
.DESCRIPTION
  Central updater: discovers installed apps on open, checks official GitHub
  releases in the background, and offers per-app Update (confirmed, verified)
  plus Update All. Thin interface over ArtCraftUpdater.Controller.psm1 (all
  workflow logic) and ArtCraftInstall.psm1 (verification and execution).
  Long operations run on BackgroundWorker threads; UI updates happen on the
  UI thread. Launch: powershell -NoProfile -STA -File ArtCraftUpdater.Gui.ps1
#>
param([string]$ToolsDir = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $ToolsDir 'ArtCraftUpdater.Controller.psm1') -Force

$Script:Busy = $false
$Script:Statuses = @()

function Write-UiLog([string]$Text) {
    $log.AppendText(("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $Text))
}

function Set-Busy([bool]$Busy, [string]$Status) {
    $Script:Busy = $Busy
    $statusLabel.Text = $Status
    $progressBar.Style = if ($Busy) { 'Marquee' } else { 'Blocks' }
    $btnCheck.Enabled = (-not $Busy)
    $btnUpdate.Enabled = ((-not $Busy) -and (Test-SelectedUpdatable))
    $btnUpdateAll.Enabled = ((-not $Busy) -and (Test-AnyUpdatable))
}

function Test-SelectedUpdatable {
    if ($appList.SelectedItems.Count -eq 0) { return $false }
    $st = $appList.SelectedItems[0].Tag
    if ($null -eq $st) { return $false }
    return [bool](Get-RowActions -Status $st).CanUpdate
}

function Test-AnyUpdatable {
    foreach ($item in $appList.Items) {
        if ($null -ne $item.Tag -and [bool](Get-RowActions -Status $item.Tag).CanUpdate) { return $true }
    }
    return $false
}

function Refresh-RowStates {
    foreach ($item in $appList.Items) {
        $st = $item.Tag
        if ($null -eq $st) { continue }
        while ($item.SubItems.Count -lt 4) { $item.SubItems.Add('') | Out-Null }
        $item.SubItems[1].Text = if ($st.InstalledVersion) { [string]$st.InstalledVersion } else { 'unknown' }
        $item.SubItems[2].Text = if ($st.LatestVersion) { [string]$st.LatestVersion } else { '-' }
        $item.SubItems[3].Text = "$($st.State): $($st.Reason)"
    }
    Set-Busy $false 'Check complete.'
}

function Start-UpdateForStatuses {
    param([array]$Targets)
    if ($Script:Busy) { return }
    $names = @(foreach ($t in $Targets) { "$($t.DisplayName) $($t.InstalledVersion) -> $($t.LatestVersion)" })
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Install updates for:`r`n- " + ($names -join "`r`n- ") + "`r`n`r`nArchives download from official GitHub releases and are hash-verified before anything is installed."),
        'Confirm updates', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') {
        Write-UiLog 'Update cancelled at confirmation.'
        return
    }
    Start-UpdateJobs $Targets
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ArtCraft Updater'
$form.Size = New-Object System.Drawing.Size(780, 660)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(700, 560)

$appList = New-Object System.Windows.Forms.ListView
$appList.Location = New-Object System.Drawing.Point(12, 12)
$appList.Size = New-Object System.Drawing.Size(740, 180)
$appList.View = 'Details'
$appList.FullRowSelect = $true
$appList.MultiSelect = $false
$appList.Columns.Add('Application', 140) | Out-Null
$appList.Columns.Add('Installed', 110) | Out-Null
$appList.Columns.Add('Latest', 110) | Out-Null
$appList.Columns.Add('Status', 360) | Out-Null

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check Again'
$btnCheck.Location = New-Object System.Drawing.Point(12, 200)
$btnCheck.Size = New-Object System.Drawing.Size(140, 30)
$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text = 'Update Selected'
$btnUpdate.Location = New-Object System.Drawing.Point(160, 200)
$btnUpdate.Size = New-Object System.Drawing.Size(140, 30)
$btnUpdate.Enabled = $false
$btnUpdateAll = New-Object System.Windows.Forms.Button
$btnUpdateAll.Text = 'Update All'
$btnUpdateAll.Location = New-Object System.Drawing.Point(308, 200)
$btnUpdateAll.Size = New-Object System.Drawing.Size(140, 30)
$btnUpdateAll.Enabled = $false

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Starting update check...'
$statusLabel.Location = New-Object System.Drawing.Point(12, 236)
$statusLabel.Size = New-Object System.Drawing.Size(740, 20)
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(12, 258)
$progressBar.Size = New-Object System.Drawing.Size(740, 14)
$progressBar.Style = 'Marquee'

$summaryList = New-Object System.Windows.Forms.ListBox
$summaryList.Location = New-Object System.Drawing.Point(12, 280)
$summaryList.Size = New-Object System.Drawing.Size(740, 130)
$summaryList.HorizontalScrollbar = $true
$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 418)
$log.Size = New-Object System.Drawing.Size(740, 194)
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'

$form.Controls.AddRange(@($appList, $btnCheck, $btnUpdate, $btnUpdateAll, $statusLabel, $progressBar, $summaryList, $log))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($null -eq $Script:Job) { $timer.Stop(); return }
    try {
        $done = $Script:Job.Handle.AsyncWaitHandle.WaitOne(0)
    } catch {
        $done = $true
    }
    if ($done) { Complete-Job }
})
$form.Add_FormClosing({
    $timer.Stop()
    if ($null -ne $Script:Job) {
        try { $Script:Job.PowerShell.Stop() } catch { }
    }
})

$Script:Job = $null
$Script:JobKind = $null

function Start-CheckWorker {
    if ($Script:Busy) { return }
    Set-Busy $true 'Discovering apps and checking releases...'
    Write-UiLog 'Update check started.'
    $appList.Items.Clear()
    $Script:Statuses = @()
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($ToolsDir)
        Import-Module (Join-Path $ToolsDir 'ArtCraftUpdater.Controller.psm1') -Force
        $reg = Read-AppRegistry
        $out = @()
        foreach ($app in (Find-InstalledApps -Root 'D:\Art Craft' -Registry $reg)) {
            if ($app.Status -ne 'Identified') {
                $out += [PSCustomObject]@{ App = $app; Status = [PSCustomObject]@{
                    AppId = $app.AppId; DisplayName = $app.DisplayName; InstalledVersion = $app.InstalledVersion
                    LatestVersion = $null; State = 'Unknown'; Reason = $app.Reason
                    AssetUrl = $null; ChecksumUrl = $null; InstallSupported = $false } }
                continue
            }
            $entry = @($reg.Entries | Where-Object { $_.AppId -eq $app.AppId })[0]
            $st = Get-AppReleaseStatus -RegistryEntry $entry -InstalledVersion $app.InstalledVersion
            $out += [PSCustomObject]@{ App = $app; Status = $st }
        }
        return @($out)
    }).AddArgument($ToolsDir)
    $Script:Job = [PSCustomObject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Kind = 'check' }
    $Script:JobKind = 'check'
    $timer.Start()
}

function Start-UpdateJobs {
    param([array]$Targets)
    if ($Script:Busy) { return }
    Set-Busy $true 'Downloading, verifying, and installing...'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($ToolsDir, $Items)
        Import-Module (Join-Path $ToolsDir 'ArtCraftUpdater.Controller.psm1') -Force
        $results = @()
        foreach ($st in $Items) {
            $results += Install-AppUpdate -Status $st
        }
        return @($results)
    }).AddArgument($ToolsDir).AddArgument(@($Targets))
    $Script:Job = [PSCustomObject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Kind = 'update' }
    $Script:JobKind = 'update'
    $timer.Start()
}

function Complete-Job {
    $job = $Script:Job
    $Script:Job = $null
    $timer.Stop()
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        $job.PowerShell.Dispose()
    } catch {
        $kind = $Script:JobKind
        $Script:JobKind = $null
        Write-UiLog "$kind worker failed: $($_.Exception.Message)"
        Set-Busy $false "$kind failed."
        return
    }
    $kind = $Script:JobKind
    $Script:JobKind = $null
    if ($kind -eq 'check') {
        foreach ($row in $output) {
            if ($null -eq $row) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$row.App.DisplayName)
            $item.SubItems.Add('') | Out-Null
            $item.SubItems.Add('') | Out-Null
            $item.SubItems.Add('') | Out-Null
            $item.Tag = $row.Status
            $item.Name = [string]$row.App.AppId
            $appList.Items.Add($item) | Out-Null
            $Script:Statuses += $row.Status
            Write-UiLog "$($row.App.DisplayName): $($row.Status.State) - $($row.Status.Reason)"
        }
        Refresh-RowStates
    } else {
        foreach ($r in $output) {
            if ($null -eq $r) { continue }
            Write-UiLog "$($r.DisplayName): $($r.Outcome)"
            $summaryList.Items.Add("$($r.DisplayName): $($r.Outcome)") | Out-Null
        }
        Set-Busy $false 'Update pass complete. Re-checking versions...'
        Start-CheckWorker
    }
}

$appList.Add_SelectedIndexChanged({
    if (-not $Script:Busy) { Set-Busy $false 'Ready.' }
    if ($appList.SelectedItems.Count -eq 0) { return }
    $st = $appList.SelectedItems[0].Tag
    if ($null -eq $st) { return }
    $summaryList.Items.Clear()
    $summaryList.Items.Add("Application : $($st.DisplayName)") | Out-Null
    $summaryList.Items.Add("Installed   : $($st.InstalledVersion)") | Out-Null
    $summaryList.Items.Add("Latest      : $($st.LatestVersion)") | Out-Null
    $summaryList.Items.Add("Status      : $($st.State) - $($st.Reason)") | Out-Null
    if ($st.AssetUrl) { $summaryList.Items.Add("Installer   : $($st.AssetUrl)") | Out-Null }
    if ($st.ChecksumUrl) { $summaryList.Items.Add("Checksums   : $($st.ChecksumUrl)") | Out-Null }
})
$btnCheck.Add_Click({ Start-CheckWorker })
$btnUpdate.Add_Click({
    if ($Script:Busy -or $appList.SelectedItems.Count -eq 0) { return }
    $st = $appList.SelectedItems[0].Tag
    if ($null -eq $st -or -not [bool](Get-RowActions -Status $st).CanUpdate) {
        Write-UiLog 'Update not available for the selected application.'
        return
    }
    Start-UpdateForStatuses @($st)
})
$btnUpdateAll.Add_Click({
    if ($Script:Busy) { return }
    $eligible = @()
    foreach ($item in $appList.Items) {
        if ($null -ne $item.Tag -and [bool](Get-RowActions -Status $item.Tag).CanUpdate) { $eligible += $item.Tag }
    }
    if ($eligible.Count -eq 0) {
        Write-UiLog 'No eligible updates.'
        return
    }
    Start-UpdateForStatuses $eligible
})

Write-UiLog 'ArtCraft Updater ready. Checking for updates...'
Start-CheckWorker
[void]$form.ShowDialog()
