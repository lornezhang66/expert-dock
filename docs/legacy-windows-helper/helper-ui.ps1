param(
  [switch]$Install,
  [switch]$Silent,
  [switch]$Shutdown,
  [switch]$Startup,
  [switch]$PrepareEnvironment,
  [string]$Url
)

# ExpertDock Helper UI v0.7.2
# v0.7.2（GMSCP-7878 修复 + GMSCP-7877 补发）：
#    0) 7878：自更新不再在 %TEMP% 落盘批处理切换器——原实现由脚本宿主写出切换脚本、
#       再经 cmd /c 执行并自删除，被火绒等启发式判为 TrojanDownloader/PS.NetLoader，
#       文件被实时监控直接删除，检查更新必败。改为进程内"复制→换名"替换：
#       Windows 允许重命名运行中的 exe 与已解析完的 ps1（句柄带 FILE_SHARE_DELETE），
#       无需"等本进程退出"，随后按协议唤起/开机自启的同一命令形态直接拉起新托盘；
#       全程零临时脚本，启动时清扫换名残留（.old/.new）。
#    1) 版本号递增——0.7.0 同版本重发永远到不了已装 0.7.0 的机器（自更新版本门判定"不比本地新"）
#    2) 同步触发点从"仅 expertdock:// 安装后"扩为"常驻启动时也同步一次"——团队包可能经
#       WorkBuddy 市场更新（不经过 Helper 安装流程），开机/托盘启动兜住该路径
#    3) 扫描范围从单一 my-experts 扩为全部 marketplace（experts/my-experts/cb_teams_marketplace 等）
# —— v0.7.0: shared Node/npm/npx environment preparation from the GBC installer.
#    WorkBuddy 专家安装后同步刷新用户级 mcp.json 的 MCP 依赖（合并式更新，绝不覆盖用户已配的 PAT/地址）
# —— 本版 v0.7.0 其他：安装进度可视化、任务唤起时主动显示窗口、安装器安全退出协议、品牌图标。
# —— v0.5.0（自更新闭环 + 自检）：
#    1) 「检查更新」从「开网页」升级为真正的自更新：版本门(latest.json) → 下载 → SHA-256 校验
#       → stage 解压 → 等本进程退出后原子替换 → 写回执 update.json → 自动重启，重启后核对结果
#    2) 新增「自检」：程序文件 / expertdock:// 协议 / 开机自启，可一键修复；启动时静默自检记日志
#    3) 启动后静默检查新版本：只气泡提醒，不自动下载
# —— v0.4.0：全流程日志 / 每步计时 / 网络超时+重试 / 安装并发锁 / 环境快照
# 目标注册表：新增智能体 = 加一个 Install-ExpertTo<X> 函数 + 一行分发
$ErrorActionPreference = "Stop"
$helperVersion = "0.7.2"
$installDir = Join-Path $env:LOCALAPPDATA "ExpertDock"
$core = Join-Path $installDir "expertdock-helper.exe"
$script = Join-Path $installDir "helper-ui.ps1"
$iconFile = Join-Path $installDir "expertdock.ico"
$statusFile = Join-Path $env:APPDATA "ExpertDock\status.json"
$updateReceipt = Join-Path $env:APPDATA "ExpertDock\update.json"
$logDir = Join-Path $env:APPDATA "ExpertDock\logs"
$shutdownRequest = Join-Path $env:APPDATA "ExpertDock\shutdown.request"
$defaultOrigin = "https://ed.lorne.top"
$logKeepDays = 14

# ---------- 安装器退出协议 ----------
if ($Shutdown) {
  $requestDir = Split-Path $shutdownRequest
  if (-not (Test-Path $requestDir)) { New-Item -ItemType Directory -Force $requestDir | Out-Null }
  [IO.File]::WriteAllText($shutdownRequest, (Get-Date).ToString("s"))
  $targets = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -match '^(powershell|pwsh)\.exe$' -and $_.CommandLine -and
    $_.CommandLine.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0
  })
  for ($i = 0; $i -lt 30 -and $targets.Count -gt 0; $i++) {
    Start-Sleep -Milliseconds 100
    $targets = @($targets | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
  }
  foreach ($process in $targets) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item $shutdownRequest -Force -ErrorAction SilentlyContinue
  exit
}

# ---------- 日志 ----------
function Write-Log {
  param([string]$Level = "INFO", [string]$Step = "-", [string]$Text = "")
  try {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $file = Join-Path $logDir ("helper-" + (Get-Date -Format "yyyyMMdd") + ".log")
    $line = "{0} [{1,-5}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Step, $Text
    [IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Open-LogFolder {
  try {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    Start-Process explorer.exe $logDir
  } catch { Write-Log "ERROR" "日志" ("打开日志目录失败：" + $_.Exception.Message) }
}

function Rotate-Logs {
  try {
    if (-not (Test-Path $logDir)) { return }
    $cutoff = (Get-Date).AddDays(-$logKeepDays)
    Get-ChildItem $logDir -Filter "helper-*.log" | Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
  } catch {}
}

function Log-Env {
  $bits = "x86"; if ([Environment]::Is64BitOperatingSystem) { $bits = "x64" }
  $psv = $PSVersionTable.PSVersion.ToString()
  $osv = [Environment]::OSVersion.VersionString
  $netv = [Environment]::Version.ToString()
  $admin = "否"
  try { $admin = if ((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { "是" } else { "否" } } catch {}
  Write-Log "INFO" "环境" ("小助手 v{0} | PS {1} | .NET {2} | {3} | {4} | 管理员={5}" -f $helperVersion, $psv, $netv, $osv, $bits, $admin)
}

# ---------- 版本比较：优先语义化比较，解析不了退回字符串不等 ----------
function Test-VersionNewer([string]$Remote, [string]$Local) {
  try { return ([version]$Remote -gt [version]$Local) } catch { return ($Remote -ne $Local) }
}

# ---------- 更新回执闭环：重启后核对自更新结果 ----------
function Read-UpdateReceiptAction {
  try {
    if (-not (Test-Path $updateReceipt)) { return }
    $r = Get-Content $updateReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($r.state -ne "pending") { return }
    $r | Add-Member -NotePropertyName finishedAt -NotePropertyValue (Get-Date).ToString("s") -Force
    if ($r.to -eq $helperVersion) {
      $r.state = "ok"
      Write-Utf8NoBom $updateReceipt ($r | ConvertTo-Json)
      Write-Log "INFO" "更新" ("自更新成功：v" + $r.from + " → v" + $r.to)
      Set-Status "ready" "更新" ("已更新到 v" + $r.to)
    } else {
      $r.state = "failed"
      Write-Utf8NoBom $updateReceipt ($r | ConvertTo-Json)
      Write-Log "WARN" "更新" ("更新回执核对不符：期望 v" + $r.to + "，实际 v" + $helperVersion)
      Set-Status "failed" "更新" ("更新没成功（仍为 v" + $helperVersion + "），可点「检查更新」重试")
    }
  } catch { Write-Log "WARN" "更新" ("读取更新回执失败：" + $_.Exception.Message) }
}

# ---------- 安装自检（-Fix 一键修复；-Quiet 静默：正常时只记日志不改状态） ----------
function Invoke-SelfCheck([switch]$Fix, [switch]$Quiet) {
  $issues = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path $core)) { $issues.Add("主程序缺失") }
  if (-not (Test-Path $script)) { $issues.Add("脚本缺失") }
  $proto = $null
  try { $proto = (Get-ItemProperty -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -ErrorAction Stop)."(default)" } catch {}
  if (-not $proto -or $proto -notlike "*$script*") { $issues.Add("expertdock:// 协议未注册或指向异常") }
  $run = $null
  try { $run = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction Stop)."ExpertDock Helper" } catch {}
  if (-not $run -or $run -notlike "*$script*") { $issues.Add("开机自启未注册或指向异常") }

  if ($issues.Count -eq 0) {
    Write-Log "INFO" "自检" "通过：程序文件、协议、自启均正常"
    if (-not $Quiet) { Set-Status "ready" "自检" "一切正常（程序 / 协议 / 自启）" }
    return $true
  }
  $detail = $issues -join "；"
  Write-Log "WARN" "自检" ("发现问题：" + $detail)
  if ($Fix) {
    Write-Log "INFO" "自检" "开始自动修复"
    try {
      if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Force $installDir | Out-Null }
      $srcExe = Join-Path $PSScriptRoot "expertdock-helper.exe"
      if ((-not (Test-Path $core)) -and (Test-Path $srcExe)) { Copy-Item $srcExe $core -Force }
      $command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Url `"%1`""
      New-Item -Path "HKCU:\Software\Classes\expertdock" -Force | Out-Null
      Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "(default)" -Value "URL:ExpertDock Protocol"
      New-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "URL Protocol" -Value "" -Force | Out-Null
      New-Item -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Force | Out-Null
      Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Name "(default)" -Value $command
      New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
      Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ExpertDock Helper" -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Startup"
      Write-Log "INFO" "自检" "修复完成，复核中"
      return (Invoke-SelfCheck)
    } catch {
      Write-Log "ERROR" "自检" ("修复失败：" + $_.Exception.Message)
      Set-Status "failed" "自检" ("修复失败：" + $_.Exception.Message + "（点「打开日志」看详情）")
      return $false
    }
  }
  Set-Status "failed" "自检" ("发现 " + $issues.Count + " 个问题：" + $detail + "（点「自检」可修复）")
  return $false
}

# ---------- GMSCP-7878：进程内换名替换（自更新专用，替代落盘切换器脚本） ----------
# 运行中的 exe / 已被解析完的 ps1 不能覆盖写，但都允许重命名（句柄带 FILE_SHARE_DELETE）。
# 顺序固定：新文件先落 .new → 旧文件让位 .old → .new 转正；任一步失败即抛，
# 由调用方统一走「更新失败 + 打开下载页」兜底，绝不出现半新半旧还报成功的情况。
function Swap-InstalledFile([string]$Staged, [string]$Target) {
  $pending = "$Target.new"
  $backup = "$Target.old"
  Copy-Item -LiteralPath $Staged -Destination $pending -Force
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $Target) { Move-Item -LiteralPath $Target -Destination $backup -Force }
  Move-Item -LiteralPath $pending -Destination $Target -Force
}

# 换名残留清扫：正常更新留下的 .old/.new 在下次启动时删除；被占用（如杀软正在扫描）
# 就静默跳过、下次启动再试，绝不影响启动。
function Remove-UpdateLeftovers {
  foreach ($leftover in @("$core.old", "$core.new", "$script.old", "$script.new")) {
    if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
  }
}

# ---------- 自更新：检查 → 下载 → 校验 → 进程内换名替换 → 重启（零临时脚本） ----------
function Invoke-SelfUpdate {
  Write-Log "INFO" "更新" ("检查更新：当前 v" + $helperVersion)
  Set-Status "updating" "更新" "正在检查更新…"
  Enable-Tls
  try {
    $meta = Invoke-WithRetry -Step "更新检查" -Tries 2 -Action {
      Invoke-RestMethod -Uri ("$defaultOrigin/api/helper/latest/windows") -TimeoutSec 15 -UseBasicParsing
    }
  } catch {
    Write-Log "WARN" "更新" ("检查失败：" + $_.Exception.Message + "，兜底打开下载页")
    Set-Status "ready" "更新" "检查更新失败，已打开下载页"
    Start-Process ("$defaultOrigin/helper")
    return $false
  }
  if (-not (Test-VersionNewer ([string]$meta.version) $helperVersion)) {
    Write-Log "INFO" "更新" ("已是最新（远端 v" + $meta.version + "）")
    Set-Status "ready" "更新" ("已是最新版本 v" + $helperVersion)
    return $true
  }
  Write-Log "INFO" "更新" ("发现新版本 v" + $meta.version + "，开始下载")
  Set-Status "updating" "更新" ("发现新版本 v" + $meta.version + "，正在下载…")
  $safeVer = ([string]$meta.version) -replace '[^a-zA-Z0-9.\-]', ''
  $tmpZip = Join-Path $env:TEMP ("expertdock-update-" + $safeVer + ".zip")
  $stage = Join-Path $env:TEMP ("expertdock-update-" + $safeVer)
  try {
    for ($i = 1; $i -le 3; $i++) {
      try {
        Invoke-WebRequest -Uri $meta.downloadUrl -OutFile $tmpZip -TimeoutSec 300 -UseBasicParsing
        break
      } catch {
        Write-Log "WARN" "更新" ("下载失败 第" + $i + "/3 次：" + $_.Exception.Message)
        if ($i -ge 3) { throw }
        Set-Status "updating" "更新" ("网络不给力，" + (2 * $i) + " 秒后自动重试…")
        Start-Sleep -Seconds (2 * $i)
      }
    }
    $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash.ToLower()
    if ($meta.sha256 -and $hash -ne ([string]$meta.sha256).ToLower()) {
      throw ("更新包校验不一致 本地=" + $hash.Substring(0, [Math]::Min(8, $hash.Length)) + " 服务器=" + ([string]$meta.sha256).ToLower())
    }
    Write-Log "INFO" "更新" ("校验通过 sha256=" + $hash.Substring(0, [Math]::Min(8, $hash.Length)) + "…")
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $stage)
    } catch {
      Write-Log "WARN" "更新" ("ZipFile 失败，改用 Expand-Archive：" + $_.Exception.Message)
      Expand-Archive -Path $tmpZip -DestinationPath $stage -Force
    }
    $newPs1 = Join-Path $stage "helper-ui.ps1"
    $newExe = Join-Path $stage "expertdock-helper.exe"
    if ((-not (Test-Path $newPs1)) -or (-not (Test-Path $newExe))) { throw "更新包内容不完整（缺 helper-ui.ps1 或 expertdock-helper.exe）" }
    foreach ($name in @('helper-env.ps1', 'node-runtime-win-x64.zip')) {
      if (-not (Test-Path -LiteralPath (Join-Path $stage $name))) { throw ('更新包缺少环境准备文件：' + $name) }
    }
    # 防降级：以包内声明版本为准，服务端 latest.json 标错也不至于把版本拉回去
    $declared = $null
    foreach ($line in ([IO.File]::ReadAllLines($newPs1) | Select-Object -First 20)) {
      if ($line -match 'v(\d+\.\d+\.\d+)') { $declared = $Matches[1]; break }
    }
    if ($declared -and -not (Test-VersionNewer $declared $helperVersion)) { throw ("更新包版本 v" + $declared + " 不高于当前 v" + $helperVersion + "，已取消") }
    $toVersion = if ($declared) { $declared } else { [string]$meta.version }
    if ($declared -and ($declared -ne [string]$meta.version)) { Write-Log "WARN" "更新" ("包内声明 v" + $declared + " 与 latest.json v" + $meta.version + " 不一致，以包内为准") }

    # GMSCP-7878：不再生成 %TEMP% 下的批处理切换器（脚本宿主落盘脚本 → 经 cmd 执行 →
    # 自删除，正是杀软启发式的完整命中链）。运行中的 exe / 已解析完的 ps1 都允许重命名，
    # 进程内换名替换即可原子生效，无需"等本进程退出"的外部脚本。
    Swap-InstalledFile -Staged $newExe -Target $core
    Swap-InstalledFile -Staged $newPs1 -Target $script
    foreach ($name in @('expertdock.ico', 'install.cmd', 'helper-env.ps1', 'node-runtime-win-x64.zip')) {
      $stagedFile = Join-Path $stage $name
      if (Test-Path -LiteralPath $stagedFile) { Copy-Item -LiteralPath $stagedFile -Destination (Join-Path $installDir $name) -Force }
    }

    Write-Utf8NoBom $updateReceipt (@{ from = $helperVersion; to = $toVersion; sha256 = $hash; state = "pending"; startedAt = (Get-Date).ToString("s") } | ConvertTo-Json)
    Set-Status "updating" "更新" ("正在切换到 v" + $toVersion + "，几秒后自动回来…")
    Write-Log "INFO" "更新" ("进程内换名替换完成，当前 PID=" + $PID + "，让出单实例锁后直接拉起新实例")
    $tray.Visible = $false
    $form.Dispose()
    # 先释放单实例锁让位新实例（脚本尾部释放已改成 try/catch 兼容二次释放），再按协议唤起/
    # 开机自启的同一命令形态直接拉起新托盘——零临时脚本；旧实例毫秒级收尾退出，新实例
    # 数秒后才检查互斥锁，无竞态。
    try { $mutex.ReleaseMutex() } catch {}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`""
    [System.Windows.Forms.Application]::Exit()
    return $true
  } catch {
    Write-Log "ERROR" "更新" ("更新失败：" + $_.Exception.Message)
    Set-Status "ready" "更新" ("更新没成功：" + $_.Exception.Message + "（已打开下载页，可手动安装）")
    try { Start-Process ("$defaultOrigin/helper") } catch {}
    return $false
  }
}

# ---------- 状态（托盘 UI 每秒读取） ----------
function Set-Status([string]$state, [string]$step, [string]$message) {
  try {
    $dir = Split-Path $statusFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    @{
      state = $state; step = $step; message = $message
      version = $helperVersion; updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $statusFile -Encoding UTF8
  } catch { Write-Log "WARN" "状态" ("写状态文件失败：" + $_.Exception.Message) }
}

function Write-Utf8NoBom([string]$path, [string]$text) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path, $text, $utf8)
}

# ---------- 网络：显式 TLS + 有限超时 + 重试（治「卡住没反应」） ----------
function Enable-Tls {
  # 老版 Windows 常缺 TLS1.2 默认开关，这是「一直转圈」的常见根因；逐项 -bor，失败忽略
  foreach ($p in @([Net.SecurityProtocolType]::Tls12)) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $p } catch {}
  }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 12288 } catch {} # Tls13（部分 .NET 不支持，忽略）
}

function Invoke-WithRetry {
  param([string]$Step, [int]$Tries = 3, [scriptblock]$Action)
  for ($i = 1; $i -le $Tries; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $result = & $Action
      $sw.Stop()
      Write-Log "INFO" $Step ("成功 第{0}/{1}次 耗时{2:n1}s" -f $i, $Tries, $sw.Elapsed.TotalSeconds)
      return $result
    } catch {
      $sw.Stop()
      Write-Log "WARN" $Step ("失败 第{0}/{1}次 耗时{2:n1}s：{3}" -f $i, $Tries, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
      if ($i -ge $Tries) { throw }
      Start-Sleep -Seconds (2 * $i)
    }
  }
}

function Prepare-HelperEnvironment([switch]$ContinueInstall) {
  Set-Status "installing" "环境准备" "正在准备 Node.js / npm / npx 运行环境…"
  try {
    # Older self-updaters copy only the original files. Recover the new assets
    # from their verified update staging directory before using them.
    foreach ($name in @('helper-env.ps1', 'node-runtime-win-x64.zip')) {
      $destination = Join-Path $installDir $name
      if (-not (Test-Path -LiteralPath $destination)) {
        $source = Join-Path (Join-Path $env:TEMP ('expertdock-update-' + $helperVersion)) $name
        if (-not (Test-Path -LiteralPath $source)) { throw ('缺少环境准备文件：' + $name + '，请重新安装完整的 Helper。') }
        Copy-Item -LiteralPath $source -Destination $destination -Force
      }
    }
    . (Join-Path $installDir 'helper-env.ps1')
    $result = Initialize-HelperEnvironment -ArchivePath (Join-Path $installDir 'node-runtime-win-x64.zip')
    Write-Log "INFO" "环境准备" ('成功 Node=' + $result.NodePath + ' managedNode=' + $result.ManagedNodePath + ' installed=' + $result.InstalledManagedNode)
    if (-not $ContinueInstall) { Set-Status "ready" "环境准备" "Node.js / npm / npx 环境已就绪，已配置企业 npm 仓库访问。" }
    return $true
  } catch {
    Write-Log "ERROR" "环境准备" $_.Exception.ToString()
    Set-Status "failed" "环境准备" ('运行环境准备失败：' + $_.Exception.Message)
    return $false
  }
}

if ($PrepareEnvironment) {
  Rotate-Logs
  Log-Env
  if (Prepare-HelperEnvironment) { exit 0 } else { exit 1 }
}

# ---------- target: pi ----------
# ZIP 制品不动：整包留档 ~/.pi/agent/expertdock/<name>/package/，
# skills/* 复制到 ~/.agents/skills/（Agent Skills 标准位），
# 主角人设 + quickPrompts 生成 ~/.pi/agent/prompts/<name>.md 等三个 / 命令。
function Install-ExpertToPi([string]$Token, [string]$Origin) {
  $ProgressPreference = "SilentlyContinue"
  $total = [Diagnostics.Stopwatch]::StartNew()
  $tag = $Token.Substring(0, [Math]::Min(8, $Token.Length))
  Write-Log "INFO" "安装" ("开始 target=pi token={0}…(长度{1}) 来源={2}" -f $tag, $Token.Length, $Origin)

  # 安装并发锁：防止双击两次、两个安装互相踩
  $mutex = New-Object Threading.Mutex($false, "Local\ExpertDockInstall")
  $gotLock = $false
  try { $gotLock = $mutex.WaitOne(15000) } catch { $gotLock = $false; Write-Log "WARN" "安装" "等锁时发现上一次异常退出，继续执行" }
  if (-not $gotLock) {
    Write-Log "WARN" "安装" "等锁 15s 超时：上一次安装还没结束，本次放弃"
    Set-Status "failed" "安装" "上一次还没装完，稍等一下再试"
    return $false
  }

  try {
    Enable-Tls
    # 1) 取安装信息
    Set-Status "installing" "取信息" "正在获取安装信息…"
    $meta = Invoke-WithRetry -Step "取信息" -Tries 3 -Action {
      Invoke-RestMethod -Uri ("$Origin/api/helper/install/$Token") -TimeoutSec 30 -UseBasicParsing
    }
    Write-Log "INFO" "取信息" ("专家={0} 版本={1} 大小={2}B sha256={3}…" -f $meta.name, $meta.version, $meta.size, ([string]$meta.sha256).Substring(0, [Math]::Min(8, ([string]$meta.sha256).Length)))

    # 2) 下载（有限超时 + 自动重试）
    $tmpZip = Join-Path $env:TEMP ("expertdock-" + $tag + ".zip")
    for ($i = 1; $i -le 3; $i++) {
      Set-Status "installing" "下载" ("正在下载专家包（第 $i 次）…")
      $sw = [Diagnostics.Stopwatch]::StartNew()
      try {
        Invoke-WebRequest -Uri $meta.downloadUrl -OutFile $tmpZip -TimeoutSec 300 -UseBasicParsing
        $sw.Stop()
        $got = (Get-Item $tmpZip).Length
        Write-Log "INFO" "下载" ("成功 第{0}/3次 耗时{1:n1}s 实际{2}B 预期{3}B" -f $i, $sw.Elapsed.TotalSeconds, $got, $meta.size)
        break
      } catch {
        $sw.Stop()
        Write-Log "WARN" "下载" ("失败 第{0}/3次 耗时{1:n1}s：{2}" -f $i, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
        if ($i -ge 3) { throw }
        Set-Status "installing" "下载" ("网络不给力，$(2 * $i) 秒后自动重试…")
        Start-Sleep -Seconds (2 * $i)
      }
    }

    # 3) 校验完整性
    Set-Status "installing" "校验" "正在校验文件完整性…"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash.ToLower()
    $sw.Stop()
    Write-Log "INFO" "校验" ("本地sha256={0}… 耗时{1:n1}s" -f $hash.Substring(0, 8), $sw.Elapsed.TotalSeconds)
    if ($meta.sha256 -and $hash -ne ([string]$meta.sha256).ToLower()) {
      Write-Log "ERROR" "校验" ("不一致 本地={0} 服务器={1}" -f $hash, ([string]$meta.sha256).ToLower())
      throw "文件不完整，已放弃安装（重新点一次安装通常能好）"
    }

    # 4) 解压（优先 .NET ZipFile，更快；失败退回 Expand-Archive）
    Set-Status "installing" "解压" "正在解压…"
    $stage = Join-Path $env:TEMP ("expertdock-unzip-" + $tag)
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $stage)
    } catch {
      Write-Log "WARN" "解压" ("ZipFile 失败，改用 Expand-Archive：" + $_.Exception.Message)
      Expand-Archive -Path $tmpZip -DestinationPath $stage -Force
    }
    $sw.Stop()
    $fileCount = @(Get-ChildItem $stage -Recurse -File).Count
    Write-Log "INFO" "解压" ("完成 {0} 个文件 耗时{1:n1}s" -f $fileCount, $sw.Elapsed.TotalSeconds)

    # 5) 找到包根
    $pluginJson = Get-ChildItem $stage -Recurse -Filter plugin.json |
      Where-Object { $_.FullName -like "*.codebuddy-plugin*" } | Select-Object -First 1
    if (-not $pluginJson) { Write-Log "ERROR" "解压" "包里没有 .codebuddy-plugin/plugin.json"; throw "包里缺少 plugin.json" }
    $root = $pluginJson.Directory.Parent.FullName
    $manifest = [IO.File]::ReadAllText($pluginJson.FullName) | ConvertFrom-Json
    $name = $manifest.name
    if (-not $name -or $name -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') { Write-Log "ERROR" "解压" ("专家名无效：" + $name); throw "专家名无效：" + $name }

    # 6) 整包留档（原树不动）
    Set-Status "installing" "写入" "正在写入专家目录…"
    $homeDir = Join-Path (Join-Path $env:USERPROFILE ".pi\agent\expertdock") $name
    $pkgDir = Join-Path $homeDir "package"
    New-Item -ItemType Directory -Force $homeDir | Out-Null
    if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
    Copy-Item $stage $pkgDir -Recurse -Force
    Write-Log "INFO" "写入" ("整包留档 " + $pkgDir)

    # 7) skills -> ~/.agents/skills/
    $copiedSkills = New-Object System.Collections.Generic.List[string]
    $skillsSrc = Join-Path $root "skills"
    if (Test-Path $skillsSrc) {
      Set-Status "installing" "技能" "正在安装技能…"
      $skillsRoot = Join-Path $env:USERPROFILE ".agents\skills"
      New-Item -ItemType Directory -Force $skillsRoot | Out-Null
      Get-ChildItem $skillsSrc -Directory | ForEach-Object {
        $safe = $_.Name -replace '[\\/:\*\?"<>\|]', '-'
        $dest = Join-Path $skillsRoot $safe
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item $_.FullName $dest -Recurse -Force
        $copiedSkills.Add($safe)
      }
    }
    Write-Log "INFO" "技能" ("装了 {0} 个：{1}" -f $copiedSkills.Count, ($copiedSkills -join ", "))

    # 8) 主角人设 + quickPrompts -> /命令
    Set-Status "installing" "指令" "正在生成快捷指令…"
    $disp = $manifest.displayName.zh; if (-not $disp) { $disp = $manifest.displayName.en }
    $prof = $manifest.profession.zh; if (-not $prof) { $prof = $manifest.profession.en }
    $agentFile = Join-Path $root ("agents\" + $manifest.agentName + ".md")
    $persona = ""
    if (Test-Path $agentFile) {
      $persona = [IO.File]::ReadAllText($agentFile) -replace '(?s)^---.*?\r?\n---\s*\r?\n', ''
    } else {
      Write-Log "WARN" "指令" ("没找到人设文件 " + $manifest.agentName + ".md，快捷指令里只有问题没有角色")
    }
    $promptsDir = Join-Path $env:USERPROFILE ".pi\agent\prompts"
    New-Item -ItemType Directory -Force $promptsDir | Out-Null
    $sub = if ($prof -and $prof -ne $disp) { $disp + " · " + $prof } else { $disp }
    $prompts = New-Object System.Collections.Generic.List[string]
    $qi = 0
    foreach ($qp in @($manifest.quickPrompts)) {
      $text = $qp.zh; if (-not $text) { $text = $qp.en }
      if (-not $text) { continue }
      $suffix = if ($qi -eq 0) { "" } else { "-" + ($qi + 1) }
      $file = Join-Path $promptsDir ($name + $suffix + ".md")
      $desc = $disp; if ($prof) { $desc = $disp + " · " + $prof }
      $content = "---`r`n"
      $content += "description: """ + $sub + """`r`n"
      $content += "argument-hint: ""[想说的话]""`r`n"
      $content += "---`r`n`r`n"
      $content += "请进入下面这位专家的角色，以此身份回答我的问题。`r`n`r`n"
      if ($prof -and $prof -ne $disp) { $content += "【" + $sub + "】`r`n`r`n" }
      $content += $persona + "`r`n`r`n"
      $content += "我的问题：" + $text + "`r`n`r`n" + '$ARGUMENTS' + "`r`n"
      Write-Utf8NoBom $file $content
      $prompts.Add($name + $suffix)
      $qi++
    }
    Write-Log "INFO" "指令" ("生成了 {0} 个 / 命令：/{1}" -f $prompts.Count, ($prompts -join " /"))

    # 9) 安装回执
    Set-Status "installing" "回执" "马上就好…"
    $hasMcp = ($manifest.dependencies -and $manifest.dependencies.mcpServers) -or (Test-Path (Join-Path $root ".mcp.json"))
    $receipt = @{ target = "pi"; name = $name; displayName = $disp; version = $manifest.version; sha256 = $hash; size = (Get-Item $tmpZip).Length; installedAt = (Get-Date).ToString("s"); skills = $copiedSkills; prompts = $prompts; mcpPending = [bool]$hasMcp }
    Write-Utf8NoBom (Join-Path $homeDir "expertdock.json") ($receipt | ConvertTo-Json)

    $total.Stop()
    $msg = "已装进 pi，重启 pi 后 /" + $name + " 开始"
    if ($hasMcp) { $msg += "；随包工具请手动接入" }
    Set-Status "ready" "完成" $msg
    Write-Log "INFO" "完成" ("结果=成功 总耗时{0:n1}s 技能{1}个 指令{2}个 随包工具={3}" -f $total.Elapsed.TotalSeconds, $copiedSkills.Count, $prompts.Count, $hasMcp)
    return $true
  } catch {
    $total.Stop()
    Write-Log "ERROR" "安装" ("结果=失败 总耗时{0:n1}s" -f $total.Elapsed.TotalSeconds)
    Write-Log "ERROR" "安装" $_.Exception.ToString()
    Set-Status "failed" "安装" ("没装成：" + $_.Exception.Message + "（点「打开日志」看详情）")
    return $false
  } finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
  }
}

# ---------- WorkBuddy 专家 MCP 依赖同步（GMSCP-7877） ----------
# 缺陷机制：首装的 PAT/地址由 WorkBuddy 连接卡（tokenSchema）写入用户级 ~/.workbuddy/mcp.json，
# 专家团更新只刷新包文件、不重放该文件——于是 MCP 版本冻在首次解析结果，用户只能删掉重配。
# 本函数在每次 WorkBuddy 目标安装成功后做「合并式同步」：
#   - 只更新已存在的同名条目，绝不新建（首装占位符填写属 WorkBuddy 连接卡职责，抢写会破坏首装体验）；
#   - type/command/args/runtime 以包内 .mcp.json 声明为准、整段直接覆盖（包是版本决策的唯一事实源，
#     声明 @latest 或精确版本都照搬；registry 解析由环境层全局 npm 配置兜底）；
#   - env 中声明为 ${占位符} 的键（GBC_TOKEN/GBC_BASE_URL 等）沿用用户已配值，声明为字面值的键以包为准；
#   - 既有条目的其余键（headers、自定义项）原样保留；
#   - 日志只记键名，绝不回显 PAT 原文。
function Sync-ExpertMcpDependencies {
  param(
    # marketplaces 根：扫描其下所有 marketplace 的 plugins/*（团队包可能装在 my-experts，
    # 也可能在 WorkBuddy 官方 experts / cb_teams_marketplace 等市场目录——市场更新不经过 Helper）
    [string]$MarketplacesRoot = (Join-Path $env:USERPROFILE ".workbuddy\plugins\marketplaces"),
    [string]$McpJsonPath = (Join-Path $env:USERPROFILE ".workbuddy\mcp.json")
  )

  function Read-JsonNoBom([string]$path) {
    # 剥 BOM：PS5.1 的 Set-Content 默认写带 BOM 的 UTF-8，WorkBuddy 严格 JSON 解析会整体失败（实测教训）
    $bytes = [IO.File]::ReadAllBytes($path)
    $offset = 0; $count = $bytes.Length
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3; $count = $bytes.Length - 3 }
    $enc = New-Object System.Text.UTF8Encoding($false)
    return ($enc.GetString($bytes, $offset, $count) | ConvertFrom-Json)
  }
  function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.PSObject.Properties[$name].Value = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
  }
  # 读取一个专家包的 MCP 声明：.mcp.json > plugin.json dependencies.mcpServers（字符串/内联对象）
  function Get-PluginMcpDeclaration([string]$pluginDir) {
    $declPath = Join-Path $pluginDir ".mcp.json"
    if (-not (Test-Path $declPath)) {
      $pluginJsonPath = Join-Path $pluginDir ".codebuddy-plugin\plugin.json"
      if (Test-Path $pluginJsonPath) {
        try {
          $pj = Read-JsonNoBom $pluginJsonPath
          $dep = $pj.dependencies.mcpServers
          if ($dep -is [string]) {
            $candidate = Join-Path $pluginDir ($dep -replace '^\./', '')
            if (Test-Path $candidate) { $declPath = $candidate }
          }
        } catch { Write-Log "WARN" "MCP同步" ("plugin.json 解析失败，跳过 " + $pluginDir + "：" + $_.Exception.Message); return $null }
      }
    }
    if (-not (Test-Path $declPath)) { return $null }
    try {
      $decl = Read-JsonNoBom $declPath
    } catch { Write-Log "WARN" "MCP同步" ("声明文件解析失败，跳过 " + $declPath + "：" + $_.Exception.Message); return $null }
    if ($decl.mcpServers) { return $decl.mcpServers }
    return $decl  # 裸对象形态（顶层即 server 映射）
  }

  if (-not (Test-Path $McpJsonPath)) {
    Write-Log "INFO" "MCP同步" "用户级 mcp.json 不存在（尚未配置过任何 MCP），跳过——首装由 WorkBuddy 连接引导完成"
    return @{ updated = 0; skipped = 0; scanned = 0 }
  }
  $cfg = $null
  try { $cfg = Read-JsonNoBom $McpJsonPath }
  catch {
    Write-Log "ERROR" "MCP同步" ("用户级 mcp.json 解析失败，不动它（请人工检查）：" + $_.Exception.Message)
    return @{ updated = 0; skipped = 0; scanned = 0 }
  }
  if (-not $cfg.mcpServers) { return @{ updated = 0; skipped = 0; scanned = 0 } }
  $servers = $cfg.mcpServers

  $result = @{ updated = 0; skipped = 0; scanned = 0 }
  if (-not (Test-Path $MarketplacesRoot)) { return $result }
  foreach ($market in (Get-ChildItem $MarketplacesRoot -Directory)) {
  $pluginsDir = Join-Path $market.FullName "plugins"
  if (Test-Path $pluginsDir) {
    foreach ($plugin in (Get-ChildItem $pluginsDir -Directory)) {
      $declServers = Get-PluginMcpDeclaration $plugin.FullName
      if (-not $declServers) { continue }
      foreach ($p in $declServers.PSObject.Properties) {
        $result.scanned++
        $name = $p.Name
        $declServer = $p.Value
        if (-not $servers.PSObject.Properties[$name]) {
          $result.skipped++
          Write-Log "INFO" "MCP同步" ($name + "：用户尚未配置过（无既有条目），首装由 WorkBuddy 连接引导完成，不代写")
          continue
        }
        $existing = $servers.$name
        $oldJson = ($existing | ConvertTo-Json -Depth 20)

        # --- 执行命令整段以包声明为准，直接覆盖（GMSCP-7877 口径：包是版本决策的唯一事实源——
        # 声明 @latest 就跑 @latest、声明精确版本就跑精确版本；registry 由环境层兜底：
        # helper-env 已把既有 npmrc 的 registry 与内网只读认证并入全局 npm-workbuddy.rc）---
        Set-Prop $existing "type" ([string]$declServer.type)
        Set-Prop $existing "command" ([string]$declServer.command)
        Set-Prop $existing "args" (@($declServer.args | ForEach-Object { [string]$_ }))
        if ($declServer.runtime) { Set-Prop $existing "runtime" $declServer.runtime }

        # --- env 合并：占位符沿用已配值，字面值以包为准 ---
        $preservedKeys = @()
        $omittedKeys = @()
        $mergedEnv = New-Object PSObject
        if ($declServer.env) {
          foreach ($e in $declServer.env.PSObject.Properties) {
            $v = [string]$e.Value
            if ($v -match '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$') {
              $oldVal = $null
              if ($existing.env -and $existing.env.PSObject.Properties[$e.Name]) { $oldVal = [string]$existing.env.PSObject.Properties[$e.Name].Value }
              if ($oldVal) {
                $mergedEnv | Add-Member -NotePropertyName $e.Name -NotePropertyValue $oldVal
                $preservedKeys += $e.Name
              } else {
                # 占位符且无已配值：宁缺勿错——写死 "${KEY}" 字面量会被当环境变量原样传入
                $omittedKeys += $e.Name
                Write-Log "WARN" "MCP同步" ($name + "：" + $e.Name + " 无已配值，本次省略（请在 WorkBuddy 连接卡补配）")
              }
            } else {
              $mergedEnv | Add-Member -NotePropertyName $e.Name -NotePropertyValue $v
            }
          }
        }
        Set-Prop $existing "env" $mergedEnv

        $newJson = ($existing | ConvertTo-Json -Depth 20)
        if ($newJson -cne $oldJson) {
          $result.updated++
          $keep = if ($preservedKeys.Count -gt 0) { $preservedKeys -join "/" } else { "-" }
          Write-Log "INFO" "MCP同步" ($name + "：已按包声明刷新（沿用已配值：" + $keep + "；" + $omittedKeys.Count + " 个键待补配）")
        }
      }
    }
  }
  }
  if ($result.updated -gt 0) {
    Write-Utf8NoBom $McpJsonPath ($cfg | ConvertTo-Json -Depth 20)
    Write-Log "INFO" "MCP同步" ("写回 " + $McpJsonPath + "（更新 " + $result.updated + " 个条目，无 BOM）")
  } else {
    Write-Log "INFO" "MCP同步" "无变更，不写回"
  }
  return $result
}

# ---------- 首次安装（注册协议 + 开机自启） ----------
if ($Install) {
  Rotate-Logs
  Log-Env
  Write-Log "INFO" "安装" "开始注册小助手（协议 + 开机自启）"
  New-Item -ItemType Directory -Force $installDir | Out-Null
  Copy-Item (Join-Path $PSScriptRoot "expertdock-helper.exe") $core -Force
  Copy-Item $PSCommandPath $script -Force
  $sourceIcon = Join-Path $PSScriptRoot "expertdock.ico"
  if (Test-Path $sourceIcon) { Copy-Item $sourceIcon $iconFile -Force }
  foreach ($name in @('helper-env.ps1', 'node-runtime-win-x64.zip')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $installDir $name) -Force
  }
  if (-not (Prepare-HelperEnvironment)) {
    if (-not $Silent) {
      Add-Type -AssemblyName PresentationFramework
      [System.Windows.MessageBox]::Show("运行环境准备失败，请查看 %APPDATA%\ExpertDock\logs 后重试。", "专家云盘") | Out-Null
    }
    exit 1
  }
  $command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Url `"%1`""
  New-Item -Path "HKCU:\Software\Classes\expertdock" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "(default)" -Value "URL:ExpertDock Protocol"
  New-ItemProperty -Path "HKCU:\Software\Classes\expertdock" -Name "URL Protocol" -Value "" -Force | Out-Null
  New-Item -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Classes\expertdock\shell\open\command" -Name "(default)" -Value $command
  New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
  Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ExpertDock Helper" -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Startup"
  Write-Log "INFO" "安装" "注册完成"
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`""
  if (-not $Silent) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("小助手装好了，正在后台待命。", "专家云盘") | Out-Null
  }
  exit
}

# ---------- 协议唤起入口 ----------
if ($Url) {
  Rotate-Logs
  Log-Env
  Write-Log "INFO" "唤起" ("收到链接：" + $Url)
  $q = @{}
  try {
    $raw = $Url -replace '^expertdock://', ''
    if ($raw.Contains('?')) {
      foreach ($p in ($raw.Split('?', 2)[1].Split('&'))) {
        $kv = $p.Split('=', 2)
        if ($kv.Count -eq 2 -and $kv[0]) { $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
      }
    }
    $tokenHint = ""
    if ($q['token']) { $tokenHint = $q['token'].Substring(0, [Math]::Min(8, $q['token'].Length)) + "…(长度" + $q['token'].Length + ")" }
    Write-Log "INFO" "唤起" ("解析结果 target=" + $q['target'] + " token=" + $tokenHint + " origin=" + $q['origin'])
  } catch {
    Write-Log "ERROR" "唤起" ("链接解析失败：" + $_.Exception.ToString())
  }
  # 先拉起托盘，让用户实时看到进度和结果（已常驻则秒退，互斥锁兑底）
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`""
  $code = 0
  if ($q['target'] -eq 'pi' -and $q['token']) {
    $origin = if ($q['origin']) { $q['origin'] } else { $defaultOrigin }
    if (-not (Install-ExpertToPi -Token $q['token'] -Origin $origin)) { $code = 1 }
  } else {
    if (-not (Prepare-HelperEnvironment -ContinueInstall)) { exit 1 }
    Write-Log "INFO" "唤起" "非 pi 目标，交给 WorkBuddy 安装器"
    Set-Status "installing" "安装" "正在装进 WorkBuddy…"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $core $Url
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Log "INFO" "唤起" ("WorkBuddy 安装器退出码={0} 耗时{1:n1}s" -f $code, $sw.Elapsed.TotalSeconds)
    if ($code -eq 0) {
      Set-Status "ready" "完成" "已装进 WorkBuddy，重启后能用"
      # GMSCP-7877：包更新后合并刷新用户已配的 MCP 条目（版本跟包走，保留 PAT/地址）
      try {
        $sync = Sync-ExpertMcpDependencies
        if ($sync.updated -gt 0) {
          Set-Status "ready" "完成" ("已装进 WorkBuddy，并刷新了 " + $sync.updated + " 个 MCP 配置（保留你的 PAT/地址），重启 WorkBuddy 后生效")
        }
      } catch {
        # 同步失败不推翻安装成功，但必须响亮记日志——静默失败等于缺陷复发
        Write-Log "ERROR" "MCP同步" ("合并刷新失败（安装本身已成功）：" + $_.Exception.Message)
      }
    }
    else { Set-Status "failed" "安装" ("WorkBuddy 安装没成功（代码 $code），点「打开日志」看详情") }
  }
  exit $code
}

# ---------- 常驻托盘 ----------
$created = $false
$mutex = New-Object Threading.Mutex($true, "Local\ExpertDockHelperUI", [ref]$created)
if (-not $created) { exit }

Rotate-Logs
Log-Env
Write-Log "INFO" "托盘" "小助手常驻启动"
Read-UpdateReceiptAction
Invoke-SelfCheck -Quiet | Out-Null
# GMSCP-7878：清扫上次自更新留下的换名残留（.old/.new；被占用则静默跳过、下次再试）
Remove-UpdateLeftovers

# GMSCP-7877：团队包也可能经 WorkBuddy 市场更新（不经过 Helper 安装流程）——
# 常驻启动时同步一次，兜住该路径；失败只记日志，不影响托盘启动
try {
  $sync = Sync-ExpertMcpDependencies
  if ($sync.updated -gt 0) {
    Write-Log "INFO" "MCP同步" ("启动同步：已刷新 " + $sync.updated + " 个 MCP 配置（保留已配 PAT/地址）——重启 WorkBuddy 后生效")
  }
} catch { Write-Log "WARN" "MCP同步" ("启动同步失败：" + $_.Exception.Message) }

# v0.5.0 的切换器只复制 EXE/PS1；从该版本自更新时补回留在暂存区的图标。
$stagedIcon = Join-Path (Join-Path $env:TEMP ("expertdock-update-" + $helperVersion)) "expertdock.ico"
if ((-not (Test-Path $iconFile)) -and (Test-Path $stagedIcon)) {
  try { Copy-Item $stagedIcon $iconFile -Force; Write-Log "INFO" "更新" "已补齐品牌图标" } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$brandIcon = $null
try { if (Test-Path $iconFile) { $brandIcon = New-Object Drawing.Icon($iconFile) } } catch {}

# ---- 皮肤：浅色、留白、一个强调色 ----
$ink    = [Drawing.Color]::FromArgb(29, 29, 31)     # 主文字
$ink2   = [Drawing.Color]::FromArgb(110, 110, 115)  # 次文字
$accent = [Drawing.Color]::FromArgb(0, 113, 227)    # 唯一强调色
$green  = [Drawing.Color]::FromArgb(36, 138, 61)
$orange = [Drawing.Color]::FromArgb(201, 52, 0)
$red    = [Drawing.Color]::FromArgb(215, 0, 21)

$form = New-Object System.Windows.Forms.Form
$form.Text = "专家云盘小助手"
$form.Size = New-Object Drawing.Size(480, 330)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
if ($brandIcon) { $form.Icon = $brandIcon }

$title = New-Object System.Windows.Forms.Label
$title.Text = "专家云盘小助手"
$title.Font = New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)
$title.ForeColor = $ink
$title.SetBounds(28, 24, 400, 38)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "朋友发的专家，一点就装好"
$subtitle.ForeColor = $ink2
$subtitle.SetBounds(30, 64, 400, 22)
$form.Controls.Add($subtitle)

$dot = New-Object System.Windows.Forms.Label
$dot.Text = "●"
$dot.Font = New-Object Drawing.Font("Segoe UI", 10)
$dot.ForeColor = $green
$dot.SetBounds(30, 106, 22, 26)
$form.Controls.Add($dot)

$state = New-Object System.Windows.Forms.Label
$state.Text = "已就绪"
$state.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$state.ForeColor = $green
$state.SetBounds(52, 106, 340, 26)
$form.Controls.Add($state)

$message = New-Object System.Windows.Forms.Label
$message.Text = "暂无安装任务"
$message.ForeColor = $ink2
$message.SetBounds(52, 136, 380, 44)
$form.Controls.Add($message)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Minimum = 0
$progress.Maximum = 100
$progress.Value = 0
$progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progress.SetBounds(30, 184, 422, 10)
$form.Controls.Add($progress)

$sep = New-Object System.Windows.Forms.Label
$sep.BackColor = [Drawing.Color]::FromArgb(232, 232, 237)
$sep.SetBounds(28, 211, 424, 1)
$form.Controls.Add($sep)

$version = New-Object System.Windows.Forms.Label
$version.Text = "版本 " + $helperVersion
$version.ForeColor = $ink2
$version.BackColor = [Drawing.Color]::White
$version.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$version.TabStop = $false
$version.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$version.SetBounds(30, 229, 100, 24)
$form.Controls.Add($version)

function New-FlatButton([string]$text, [int]$x, [Drawing.Color]$back, [Drawing.Color]$fore) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.SetBounds($x, 225, 100, 34)
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $back
  $b.ForeColor = $fore
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $form.Controls.Add($b)
  return $b
}

$selfCheck = New-FlatButton "自检" 28 ([Drawing.Color]::FromArgb(232, 232, 237)) $ink
$selfCheck.Add_Click({ Invoke-SelfCheck -Fix | Out-Null })

$update = New-FlatButton "检查更新" 132 $accent ([Drawing.Color]::White)
$update.Add_Click({ Invoke-SelfUpdate | Out-Null })

$logBtn = New-FlatButton "打开日志" 236 ([Drawing.Color]::FromArgb(232, 232, 237)) $ink
$logBtn.Add_Click({ Open-LogFolder })

$close = New-FlatButton "隐藏" 340 ([Drawing.Color]::FromArgb(232, 232, 237)) $ink
$close.Add_Click({ $form.Hide() })

$tray = New-Object System.Windows.Forms.NotifyIcon
if ($brandIcon) { $tray.Icon = $brandIcon } else { $tray.Icon = [Drawing.SystemIcons]::Application }
$tray.Text = "专家云盘小助手"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add("显示窗口")
$openItem.Add_Click({ $form.Show(); $form.Activate() })
$checkItem = $menu.Items.Add("自检修复")
$checkItem.Add_Click({ Invoke-SelfCheck -Fix | Out-Null })
$logItem = $menu.Items.Add("查看日志")
$logItem.Add_Click({ Open-LogFolder })
$updateItem = $menu.Items.Add("检查更新")
$updateItem.Add_Click({ Invoke-SelfUpdate | Out-Null })
$exitItem = $menu.Items.Add("退出")
$exitItem.Add_Click({ Write-Log "INFO" "托盘" "用户退出小助手"; $tray.Visible = $false; $form.Dispose(); [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })
$form.Add_FormClosing({ $_.Cancel = $true; $form.Hide() })

$script:lastState = $null
$script:bootTick = 0
$stepProgress = @{
  "取信息" = 10
  "环境准备" = 5
  "校验" = 60
  "解压" = 70
  "写入" = 80
  "技能" = 88
  "指令" = 94
  "回执" = 98
  "完成" = 100
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  if (Test-Path $shutdownRequest) {
    Write-Log "INFO" "托盘" "收到安装器退出请求"
    Remove-Item $shutdownRequest -Force -ErrorAction SilentlyContinue
    $timer.Stop()
    $tray.Visible = $false
    $form.Dispose()
    [System.Windows.Forms.Application]::Exit()
    return
  }
  # 启动后第 3 秒静默检查新版本：只气泡提醒，不自动下载（失败忽略）
  $script:bootTick = $script:bootTick + 1
  if ($script:bootTick -eq 3) {
    try {
      Enable-Tls
      $meta = Invoke-RestMethod -Uri ("$defaultOrigin/api/helper/latest/windows") -TimeoutSec 5 -UseBasicParsing
      if (Test-VersionNewer ([string]$meta.version) $helperVersion) {
        Write-Log "INFO" "更新" ("静默检查发现新版本 v" + $meta.version)
        $tray.ShowBalloonTip(6000, "有新版本", ("小助手 v" + $meta.version + " 已发布，点「检查更新」一键升级"), [System.Windows.Forms.ToolTipIcon]::Info)
      } else {
        Write-Log "INFO" "更新" ("静默检查：已是最新 v" + $helperVersion)
      }
    } catch { Write-Log "INFO" "更新" ("静默检查失败（忽略）：" + $_.Exception.Message) }
  }
  if (Test-Path $statusFile) {
    try {
      $status = Get-Content $statusFile -Raw | ConvertFrom-Json
      switch ($status.state) {
        "installing" { $state.Text = "正在安装"; $state.ForeColor = $orange; $dot.ForeColor = $orange }
        "updating"   { $state.Text = "正在更新"; $state.ForeColor = $orange; $dot.ForeColor = $orange }
        "failed"     { $state.Text = "上次失败"; $state.ForeColor = $red; $dot.ForeColor = $red }
        default      { $state.Text = "已就绪"; $state.ForeColor = $green; $dot.ForeColor = $green }
      }
      $message.Text = if ($status.message) { $status.message } else { "暂无安装任务" }
      $busy = $status.state -in @("installing", "updating")
      if ($busy -and ($status.state -eq "updating" -or $status.step -in @("下载", "安装", "更新"))) {
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progress.MarqueeAnimationSpeed = 24
      } else {
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $progress.MarqueeAnimationSpeed = 0
        $progress.Value = if ($busy -and $stepProgress.ContainsKey([string]$status.step)) { $stepProgress[[string]$status.step] } elseif ($status.state -eq "ready" -and $status.step -eq "完成") { 100 } else { 0 }
      }
      # 状态变化时：气泡提醒（用户在浏览器点了安装，右下角给结果）+ 动态托盘悬停文字
      if ($status.state -ne $script:lastState) {
        if ($busy) {
          $form.Show()
          $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
          $form.Activate()
          $form.TopMost = $true
          $form.TopMost = $false
        }
        if ($script:lastState -eq "installing") {
          if ($status.state -eq "ready")  { $tray.ShowBalloonTip(5000, "装好了", $status.message, [System.Windows.Forms.ToolTipIcon]::Info) }
          if ($status.state -eq "failed") { $tray.ShowBalloonTip(8000, "没装成", $status.message, [System.Windows.Forms.ToolTipIcon]::Warning) }
        }
        $script:lastState = $status.state
      }
      $tray.Text = "专家云盘小助手 · " + $state.Text
    } catch {}
  }
})
$timer.Start()
if (-not $Startup) { $form.Show() }
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
if ($brandIcon) { $brandIcon.Dispose() }
# 自更新路径已提前释放锁让位新实例，二次释放会抛——统一兜住
try { $mutex.ReleaseMutex() } catch {}
