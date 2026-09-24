param(
  [switch]$Install,
  [switch]$Silent,
  [string]$Url
)

$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:LOCALAPPDATA "ExpertDock"
$core = Join-Path $installDir "expertdock-helper.exe"
$script = Join-Path $installDir "helper-ui.ps1"
$statusFile = Join-Path $env:APPDATA "ExpertDock\status.json"

if ($Install) {
  New-Item -ItemType Directory -Force $installDir | Out-Null
  Copy-Item (Join-Path $PSScriptRoot "expertdock-helper.exe") $core -Force
  Copy-Item $PSCommandPath $script -Force
  $command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Url `"%1`""
  New-Item -Path "HKCU:\Software\Classes\expertdock" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "(default)" -Value "URL:ExpertDock Protocol"
  New-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "URL Protocol" -Value "" -Force | Out-Null
  New-Item -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Name "(default)" -Value $command
  New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ExpertDock Helper" -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`""
  if (-not $Silent) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("ExpertDock Helper 已安装并在系统托盘中运行。", "ExpertDock") | Out-Null
  }
  exit
}

if ($Url) {
  & $core $Url
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`""
  exit $LASTEXITCODE
}

$created = $false
$mutex = New-Object Threading.Mutex($true, "Local\ExpertDockHelperUI", [ref]$created)
if (-not $created) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "ExpertDock Helper"
$form.Size = New-Object Drawing.Size(460, 280)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Text = "ExpertDock Helper"
$title.Font = New-Object Drawing.Font("Segoe UI", 18, [Drawing.FontStyle]::Bold)
$title.SetBounds(28, 24, 380, 38)
$form.Controls.Add($title)

$state = New-Object System.Windows.Forms.Label
$state.Text = "已就绪"
$state.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$state.SetBounds(30, 78, 380, 26)
$form.Controls.Add($state)

$message = New-Object System.Windows.Forms.Label
$message.Text = "等待安装请求"
$message.ForeColor = [Drawing.Color]::DimGray
$message.SetBounds(30, 110, 380, 48)
$form.Controls.Add($message)

$version = New-Object System.Windows.Forms.Label
$version.Text = "版本 " + (& $core --version)
$version.ForeColor = [Drawing.Color]::DimGray
$version.SetBounds(30, 164, 180, 24)
$form.Controls.Add($version)

$update = New-Object System.Windows.Forms.Button
$update.Text = "检查更新"
$update.SetBounds(230, 164, 90, 32)
$update.Add_Click({ Start-Process "https://ed.lorne.top/helper" })
$form.Controls.Add($update)

$close = New-Object System.Windows.Forms.Button
$close.Text = "隐藏"
$close.SetBounds(330, 164, 80, 32)
$close.Add_Click({ $form.Hide() })
$form.Controls.Add($close)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [Drawing.SystemIcons]::Application
$tray.Text = "ExpertDock Helper"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add("打开 ExpertDock Helper")
$openItem.Add_Click({ $form.Show(); $form.Activate() })
$updateItem = $menu.Items.Add("检查更新")
$updateItem.Add_Click({ Start-Process "https://ed.lorne.top/helper" })
$exitItem = $menu.Items.Add("退出")
$exitItem.Add_Click({ $tray.Visible = $false; $form.Dispose(); [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })
$form.Add_FormClosing({ $_.Cancel = $true; $form.Hide() })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  if (Test-Path $statusFile) {
    try {
      $status = Get-Content $statusFile -Raw | ConvertFrom-Json
      $state.Text = switch ($status.state) { "installing" { "正在安装" } "failed" { "最近安装失败" } default { "已就绪" } }
      $message.Text = if ($status.message) { $status.message } else { "等待安装请求" }
    } catch {}
  }
})
$timer.Start()
$form.Show()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$mutex.ReleaseMutex()
