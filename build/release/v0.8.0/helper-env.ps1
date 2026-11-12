# Shared Windows environment preparation, ported from gbc-expert-manager.
# Loading this file defines functions only; preparation is explicitly invoked.
$script:EnvironmentNodeVersion = '22.22.2'
$script:EnvironmentNodeMinimum = 20
$script:EnvironmentNodeSha256 = '65b064aec5a84388d356225c49f1fcc96e684f0c9a46168296cf78598a90f89a'
$script:EnvironmentNpmAuthKey = '//nvwa.jiuqi.com.cn/nexus/repository/npm-gov-group/:_auth'
$script:EnvironmentNpmAuth = 'Z292Z3Vlc3Q6cDR0YWJnMnE0cDV3'

function Test-HelperNode([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $process = New-Object Diagnostics.Process
  try {
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = '--version'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if (-not $process.Start()) { return $false }
    if (-not $process.WaitForExit(5000)) { $process.Kill(); return $false }
    $version = $process.StandardOutput.ReadToEnd().Trim()
    return ($process.ExitCode -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge $script:EnvironmentNodeMinimum)
  } catch { return $false } finally { $process.Dispose() }
}

function Test-HelperNodeTools([string]$Directory) {
  foreach ($name in @('node.exe', 'npm.cmd', 'npx.cmd', 'node_modules\npm\bin\npm-cli.js', 'node_modules\npm\bin\npx-cli.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) { return $false }
  }
  return (Test-HelperNode (Join-Path $Directory 'node.exe'))
}

function Install-HelperNodeRuntime([string]$ManagerHome, [string]$ArchivePath) {
  $nodeParent = [IO.Path]::GetFullPath((Join-Path $ManagerHome 'runtimes\node'))
  $nodeDir = [IO.Path]::GetFullPath((Join-Path $nodeParent $script:EnvironmentNodeVersion))
  if (Test-HelperNodeTools $nodeDir) {
    return [pscustomobject]@{ Path = (Join-Path $nodeDir 'node.exe'); Installed = $false }
  }
  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw '缺少内置 Node 运行时，请重新安装完整的 Helper。' }
  if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $script:EnvironmentNodeSha256) {
    throw '内置 Node 运行时校验失败，请重新安装 Helper。'
  }
  New-Item -ItemType Directory -Force $nodeParent | Out-Null
  $stage = [IO.Path]::GetFullPath((Join-Path $nodeParent ('.prepare-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($ArchivePath), $stage)
    if (-not (Test-HelperNodeTools $stage)) { throw '内置 Node/npm/npx 运行时不完整或无法运行。' }
    # All deletion targets are checked against this managed runtime directory.
    if (-not $nodeDir.StartsWith($nodeParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '运行时目录越界。' }
    if (Test-Path -LiteralPath $nodeDir) { Remove-Item -LiteralPath $nodeDir -Recurse -Force }
    Move-Item -LiteralPath $stage -Destination $nodeDir
  } finally {
    if ($stage.StartsWith($nodeParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stage)) {
      Remove-Item -LiteralPath $stage -Recurse -Force
    }
  }
  return [pscustomobject]@{ Path = (Join-Path $nodeDir 'node.exe'); Installed = $true }
}

function Get-HelperUserEnvironment([string]$Name) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try {
    if ($key -and $key.GetValueNames() -contains $Name) {
      return [pscustomobject]@{
        Value = [string]$key.GetValue($Name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind = $key.GetValueKind($Name)
      }
    }
    return [pscustomobject]@{ Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
  } finally { if ($key) { $key.Dispose() } }
}

function Set-HelperUserEnvironment([string]$Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try { $key.SetValue($Name, $Value, $Kind) } finally { $key.Dispose() }
}

function Add-HelperNodePath([string]$Path, [string]$Directory) {
  foreach ($entry in $Path.Split(';')) {
    if ($entry.Trim().Trim('"').TrimEnd('\') -ieq $Directory.TrimEnd('\')) { return $Path }
  }
  if (-not $Path) { return $Directory }
  return $Directory + ';' + $Path
}

function Send-HelperEnvironmentChange {
  if (-not ('ExpertDock.EnvironmentNotification' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ExpertDock {
  public static class EnvironmentNotification {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
  }
}
'@
  }
  $result = [UIntPtr]::Zero
  [ExpertDock.EnvironmentNotification]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [IntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
}

function Set-HelperNpxEnvironment([string]$ManagerHome, [string]$NodeDirectory) {
  New-Item -ItemType Directory -Force $ManagerHome | Out-Null
  $configPath = Join-Path $ManagerHome 'npm-workbuddy.rc'
  $previous = (Get-HelperUserEnvironment 'NPM_CONFIG_USERCONFIG').Value
  if (-not $previous) { $previous = Join-Path $env:USERPROFILE '.npmrc' }
  $extra = @()
  if (Test-Path -LiteralPath $previous -PathType Leaf) {
    $authPattern = '^\s*' + [regex]::Escape($script:EnvironmentNpmAuthKey) + '\s*='
    $extra = @([IO.File]::ReadAllLines($previous) | Where-Object { $_ -notmatch $authPattern -and $_ -notmatch '^\s*always-auth\s*=' })
  }
  $config = "always-auth=true`r`n" + $script:EnvironmentNpmAuthKey + '=' + $script:EnvironmentNpmAuth + "`r`n" + ($extra -join "`r`n")
  [IO.File]::WriteAllText($configPath, $config, (New-Object Text.UTF8Encoding($false)))
  Set-HelperUserEnvironment 'NPM_CONFIG_USERCONFIG' $configPath ([Microsoft.Win32.RegistryValueKind]::String)
  $path = Get-HelperUserEnvironment 'Path'
  $updated = Add-HelperNodePath $path.Value $NodeDirectory
  if ($updated -cne $path.Value) { Set-HelperUserEnvironment 'Path' $updated $path.Kind }
  # The protocol handler inherits the browser's old environment. Refresh this
  # process as well so the WorkBuddy installer launched next can use Node/npx.
  $env:Path = Add-HelperNodePath $env:Path $NodeDirectory
  $env:NPM_CONFIG_USERCONFIG = $configPath
  Send-HelperEnvironmentChange
}

function Initialize-HelperEnvironment([string]$ManagerHome = (Join-Path $env:USERPROFILE '.workbuddy\expert-manager'), [string]$ArchivePath = (Join-Path $PSScriptRoot 'node-runtime-win-x64.zip')) {
  if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw '当前内置运行时适用于 Windows x64。' }
  $lock = New-Object Threading.Mutex($false, 'Local\ExpertDockEnvironment')
  $locked = $false
  try {
    try { $locked = $lock.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw '其他任务正在准备运行环境，请稍后重试。' }
    $existing = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $nodePath = $null
    if ($existing -and (Test-HelperNode $existing.Source)) { $nodePath = $existing.Source }
    # As in the installer, retain a managed Node even when system Node is valid:
    # subsequent WorkBuddy marketplace updates need a known npm/npx runtime.
    $managed = Install-HelperNodeRuntime $ManagerHome $ArchivePath
    if (-not $nodePath) { $nodePath = $managed.Path }
    Set-HelperNpxEnvironment $ManagerHome (Split-Path $managed.Path)
    return [pscustomobject]@{ NodePath = $nodePath; ManagedNodePath = $managed.Path; InstalledManagedNode = $managed.Installed }
  } finally {
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
  }
}
