$ErrorActionPreference = 'Stop'
$helperRoot = Split-Path $PSScriptRoot
$versionDir = Join-Path $helperRoot 'v0.7.2'
. (Join-Path $versionDir 'helper-env.ps1')

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $thrown = $false
  try { & $Action | Out-Null } catch { $thrown = $true }
  Assert $thrown $Message
}

$testRoot = Join-Path $helperRoot ('.env-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedProfile = $env:USERPROFILE
$savedPath = $env:Path
$savedNpmConfig = $env:NPM_CONFIG_USERCONFIG
$savedTemp = $env:TEMP
New-Item -ItemType Directory -Force $testRoot | Out-Null
try {
  $env:USERPROFILE = Join-Path $testRoot 'user'
  New-Item -ItemType Directory -Force $env:USERPROFILE | Out-Null
  Assert (-not (Test-HelperNode (Join-Path $testRoot 'missing.exe'))) 'Missing Node must be rejected.'
  $archive = Join-Path $versionDir 'node-runtime-win-x64.zip'
  $manager = Join-Path $testRoot 'manager with spaces'
  $runtime = Install-HelperNodeRuntime $manager $archive
  Assert $runtime.Installed 'First preparation must deploy the bundled runtime.'
  Assert (Test-HelperNodeTools (Split-Path $runtime.Path)) 'Node/npm/npx must all exist and Node must run.'
  $npmCli = Join-Path (Split-Path $runtime.Path) 'node_modules\npm\bin\npm-cli.js'
  $npxCli = Join-Path (Split-Path $runtime.Path) 'node_modules\npm\bin\npx-cli.js'
  $npmVersion = & $runtime.Path $npmCli --version
  Assert ($LASTEXITCODE -eq 0 -and $npmVersion -match '^\d+\.') 'Bundled npm must execute offline.'
  $npxVersion = & $runtime.Path $npxCli --version
  Assert ($LASTEXITCODE -eq 0 -and $npxVersion -match '^\d+\.') 'Bundled npx must execute offline.'
  $reused = Install-HelperNodeRuntime $manager (Join-Path $testRoot 'missing.zip')
  Assert (-not $reused.Installed -and $reused.Path -eq $runtime.Path) 'Repeat preparation must reuse the managed runtime without extraction.'
  $badZip = Join-Path $testRoot 'bad.zip'
  [IO.File]::WriteAllText($badZip, 'corrupted runtime')
  Assert-Throws { Install-HelperNodeRuntime (Join-Path $testRoot 'bad-manager') $badZip } 'Corrupt runtime archives must be rejected.'
  Write-Output 'PASS: bundled Node/npm/npx execute offline; reuse and corrupt-archive checks.'

  # Fake only the persistent user-environment boundary. No real registry writes
  # or environment-change broadcasts occur anywhere in this test process.
  $script:fakeEnvironment = @{
    Path = [pscustomobject]@{ Value = '%USERPROFILE%\bin;C:\Tools'; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    NPM_CONFIG_USERCONFIG = [pscustomobject]@{ Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::String }
  }
  function Get-HelperUserEnvironment([string]$Name) { return $script:fakeEnvironment[$Name] }
  function Set-HelperUserEnvironment([string]$Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    $script:fakeEnvironment[$Name] = [pscustomobject]@{ Value = $Value; Kind = $Kind }
  }
  function Send-HelperEnvironmentChange {}
  [IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.npmrc'), "registry=https://example.invalid/`r`ncustom-key=keep")
  Set-HelperNpxEnvironment $manager (Split-Path $runtime.Path)
  $firstPath = $script:fakeEnvironment.Path.Value
  $configPath = $script:fakeEnvironment.NPM_CONFIG_USERCONFIG.Value
  $config = [IO.File]::ReadAllText($configPath)
  Assert ($config.Contains('custom-key=keep') -and $config.Contains('registry=https://example.invalid/')) 'Existing npm settings must survive preparation.'
  Assert ($config.Contains($script:EnvironmentNpmAuthKey + '=')) 'Registry-scoped read-only auth must be configured.'
  Assert ($script:fakeEnvironment.Path.Kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'PATH registry value type must be retained.'
  Assert ($firstPath.Contains('%USERPROFILE%\bin')) 'Expandable user PATH entries must remain unexpanded.'
  Set-HelperNpxEnvironment $manager (Split-Path $runtime.Path)
  Assert ($script:fakeEnvironment.Path.Value -ceq $firstPath) 'Repeated preparation must not duplicate PATH entries.'
  Assert ([IO.File]::ReadAllText($configPath) -ceq $config) 'Repeated preparation must preserve npm config without duplicate auth.'
  Assert ($env:NPM_CONFIG_USERCONFIG -eq $configPath) 'The current protocol-handler process must receive npm config immediately.'
  Write-Output 'PASS: isolated PATH/npm config, preservation and idempotency; no persistent host changes.'

  $prepared = Initialize-HelperEnvironment -ManagerHome $manager -ArchivePath $archive
  Assert (-not $prepared.InstalledManagedNode) 'Full preparation should reuse an existing managed runtime.'
  Assert (Test-HelperNode $prepared.NodePath) 'Full preparation must return a working Node.'
  & {
    function Get-Command { param($Name, $CommandType, $ErrorAction) return $null }
    $fallback = Initialize-HelperEnvironment -ManagerHome $manager -ArchivePath $archive
    Assert ($fallback.NodePath -eq $runtime.Path) 'Without system Node, the managed runtime must be selected.'
  }
  & {
    $script:existingNode = Join-Path (Split-Path $runtime.Path) '.\node.exe'
    function Get-Command { param($Name, $CommandType, $ErrorAction) return [pscustomobject]@{ Source = $script:existingNode } }
    $existing = Initialize-HelperEnvironment -ManagerHome $manager -ArchivePath $archive
    Assert ($existing.NodePath -ceq $script:existingNode) 'A suitable existing Node must be reused.'
  }
  Write-Output 'PASS: complete environment preparation with mocked persistent environment.'

  # Extract the integration function without executing the UI, installing the
  # Helper, starting a browser, or touching the real user profile.
  $tokens = $null; $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $versionDir 'helper-ui.ps1'), [ref]$tokens, [ref]$parseErrors)
  Assert ($parseErrors.Count -eq 0) 'Helper UI must parse.'
  $prepare = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Prepare-HelperEnvironment' }, $true)
  Invoke-Expression $prepare.Extent.Text
  function Set-Status([string]$State, [string]$Step, [string]$Message) { $script:testStatus = $State }
  function Write-Log([string]$Level, [string]$Step, [string]$Text) {}
  $installDir = Join-Path $testRoot 'helper'
  $helperVersion = '0.7.0'
  $env:TEMP = Join-Path $testRoot 'temp'
  $stage = Join-Path $env:TEMP 'expertdock-update-0.7.0'
  New-Item -ItemType Directory -Force $installDir, $stage | Out-Null
  Assert (-not (Prepare-HelperEnvironment)) 'Missing environment assets must fail instead of reporting success.'
  Assert ($script:testStatus -eq 'failed') 'Preparation errors must reach the UI status.'
  [IO.File]::WriteAllText((Join-Path $stage 'helper-env.ps1'), 'function Initialize-HelperEnvironment { param($ArchivePath) [pscustomobject]@{NodePath="mock";ManagedNodePath="mock";InstalledManagedNode=$false} }')
  [IO.File]::WriteAllText((Join-Path $stage 'node-runtime-win-x64.zip'), 'mock')
  Assert (Prepare-HelperEnvironment) 'Old self-updaters must recover the new assets from staging.'
  Assert (Test-Path -LiteralPath (Join-Path $installDir 'helper-env.ps1')) 'Recovered environment module must be installed.'
  Assert (Test-Path -LiteralPath (Join-Path $installDir 'node-runtime-win-x64.zip')) 'Recovered runtime archive must be installed.'
  Assert (Prepare-HelperEnvironment -ContinueInstall) 'Preparation before WorkBuddy installation must succeed.'
  Assert ($script:testStatus -eq 'installing') 'Environment preparation must not report the expert installation as completed.'
  Write-Output 'PASS: Helper error status and asset recovery after old-client updates.'

  # ---------- GMSCP-7877：MCP 依赖合并同步（只刷已配条目，绝不覆盖 PAT/URL） ----------
  function Write-Utf8NoBom([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
  }
  $syncFn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-ExpertMcpDependencies' }, $true)
  Assert ($null -ne $syncFn) 'Sync-ExpertMcpDependencies must exist in helper-ui.ps1.'
  Invoke-Expression $syncFn.Extent.Text

  $mkt = Join-Path $testRoot 'mkt'
  $pluginDir = Join-Path $mkt 'experts\plugins\jiuqi-gbc-dev-team'
  New-Item -ItemType Directory -Force (Join-Path $pluginDir '.codebuddy-plugin') | Out-Null
  # 包内声明：钉死版本 + 占位符 env（模拟生成器新产物，含 x-workbuddy/x-gbc 附属键与第二个未配置的 server）
  $decl = @'
{
  "mcpServers": {
    "jiuqi-gbc-mcp": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "jiuqi-gbc-mcp@0.5.0", "serve"],
      "x-gbc": { "expectedVersion": "0.5.0" },
      "runtime": { "type": "node", "version": "^20.0.0" },
      "env": { "GBC_TOKEN": "${GBC_TOKEN}", "GBC_BASE_URL": "${GBC_BASE_URL}", "GBC_PROFILE": "prod", "GBC_NEW": "${GBC_NEW}" },
      "x-workbuddy": { "auth": { "type": "token" } }
    },
    "other-mcp": { "type": "stdio", "command": "x", "args": ["a"], "env": {} }
  }
}
'@
  Write-Utf8NoBom (Join-Path $pluginDir '.mcp.json') $decl

  $userMcp = Join-Path $testRoot 'user-mcp.json'
  # 用户既有配置带 BOM（模拟 PS5.1 写盘产物）：@latest 旧 args + 手加的 --registry + PAT/地址/headers/自定义键
  $existingCfg = @'
{
  "mcpServers": {
    "jiuqi-gbc-mcp": {
      "type": "stdio",
      "command": "npx",
      "args": ["--registry", "https://nvwa.example/nexus/", "-y", "jiuqi-gbc-mcp@latest", "serve"],
      "headers": { "GBC_TOKEN": "header-token" },
      "customTop": "keep-me",
      "env": { "GBC_TOKEN": "user-pat-value", "GBC_BASE_URL": "http://user-gbc.example.com/", "GBC_PROFILE": "prod" }
    }
  }
}
'@
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [IO.File]::WriteAllText($userMcp, $existingCfg, $utf8Bom)

  $r1 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt -McpJsonPath $userMcp
  Assert ($r1.updated -eq 1 -and $r1.skipped -eq 1) 'One configured entry (in experts marketplace, not just my-experts) must be refreshed; the unconfigured one must be skipped.'
  $rawAfter = [IO.File]::ReadAllBytes($userMcp)
  Assert (-not ($rawAfter[0] -eq 0xEF -and $rawAfter[1] -eq 0xBB -and $rawAfter[2] -eq 0xBF)) 'Written mcp.json must not carry a BOM.'
  $after = ([IO.File]::ReadAllText($userMcp) | ConvertFrom-Json).mcpServers
  $svc = $after.'jiuqi-gbc-mcp'
  Assert ((@($svc.args) -join '|') -ceq '-y|jiuqi-gbc-mcp@0.5.0|serve') 'Args must be taken verbatim from the package declaration (user-added --registry is overwritten away).'
  Assert ($svc.env.GBC_TOKEN -ceq 'user-pat-value') 'Configured PAT must survive the sync.'
  Assert ($svc.env.GBC_BASE_URL -ceq 'http://user-gbc.example.com/') 'Configured base URL must survive the sync.'
  Assert ($svc.env.GBC_PROFILE -ceq 'prod') 'Literal env values must come from the package.'
  Assert (-not ($svc.env.PSObject.Properties['GBC_NEW'])) 'Placeholders without a configured value must be omitted, never written literally.'
  Assert ($svc.headers.GBC_TOKEN -ceq 'header-token') 'Existing headers must be preserved.'
  Assert ($svc.customTop -ceq 'keep-me') 'Unknown existing keys must be preserved.'
  Assert (-not ($svc.PSObject.Properties['x-workbuddy'])) 'Package-only x-workbuddy metadata must not leak into user config.'
  Assert (-not ($svc.PSObject.Properties['x-gbc'])) 'Package-only x-gbc metadata must not leak into user config.'
  Assert (-not ($after.PSObject.Properties['other-mcp'])) 'Unconfigured servers must never be created.'
  Write-Output 'PASS: MCP sync overwrites the launch command verbatim while preserving PAT/URL/headers; never creates entries; no BOM; no x-* leakage.'

  $beforeSecondRun = [IO.File]::ReadAllText($userMcp)
  $r2 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt -McpJsonPath $userMcp
  Assert ($r2.updated -eq 0) 'Re-running the sync must be idempotent.'
  Assert (([IO.File]::ReadAllText($userMcp)) -ceq $beforeSecondRun) 'Second sync must not rewrite or corrupt the file.'
  Write-Output 'PASS: MCP sync is idempotent.'

  # 占位符连已配值一起缺失的极端（用户条目 env 没有 GBC_TOKEN）→ 省略键而非写死字面量
  $userMcp2 = Join-Path $testRoot 'user-mcp2.json'
  $bare = '{"mcpServers":{"jiuqi-gbc-mcp":{"type":"stdio","command":"npx","args":["-y","jiuqi-gbc-mcp@0.4.0","serve"],"env":{"GBC_PROFILE":"old"}}}}'
  Write-Utf8NoBom $userMcp2 $bare
  $r3 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt -McpJsonPath $userMcp2
  Assert ($r3.updated -eq 1) 'An entry missing placeholder values must still refresh its launch definition.'
  $svc2 = (([IO.File]::ReadAllText($userMcp2) | ConvertFrom-Json).mcpServers).'jiuqi-gbc-mcp'
  Assert ($svc2.env.PSObject.Properties['GBC_TOKEN'] -eq $null) 'Missing PAT must be omitted, not written as a literal placeholder.'
  Assert ($svc2.args -contains 'jiuqi-gbc-mcp@0.5.0') 'Launch definition must still be refreshed.'
  Write-Output 'PASS: missing placeholder values are omitted while the version pin still lands.'

  # 用户 mcp.json 不存在 → 不代建文件（首装由 WorkBuddy 连接卡引导）
  $absent = Join-Path $testRoot 'no-such-mcp.json'
  $r4 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt -McpJsonPath $absent
  Assert ($r4.updated -eq 0 -and -not (Test-Path $absent)) 'Sync must not create the user mcp.json.'
  Write-Output 'PASS: sync never creates the user-level mcp.json.'

  # 用户 mcp.json 损坏 → 原样保留不破坏
  $broken = Join-Path $testRoot 'broken-mcp.json'
  [IO.File]::WriteAllText($broken, '{ mcpServers: ')
  $r5 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt -McpJsonPath $broken
  Assert ($r5.updated -eq 0 -and (([IO.File]::ReadAllText($broken)) -ceq '{ mcpServers: ')) 'Unparseable mcp.json must be left untouched.'
  Write-Output 'PASS: unparseable mcp.json is preserved for manual inspection.'

  # ---------- 执行命令整段覆盖（GMSCP-7877 口径：包是版本决策的唯一事实源） ----------
  # 旧 ZIP 声明 @latest 的也照搬覆盖——包声明什么就跑什么，registry 由环境层全局 npm 配置兜底
  $mkt2 = Join-Path $testRoot 'mkt-legacy'
  $legacyDir = Join-Path $mkt2 'my-experts\plugins\legacy-team'
  New-Item -ItemType Directory -Force $legacyDir | Out-Null
  Write-Utf8NoBom (Join-Path $legacyDir '.mcp.json') '{"mcpServers":{"jiuqi-gbc-mcp":{"type":"stdio","command":"npx","args":["-y","jiuqi-gbc-mcp@latest","serve"],"env":{"GBC_TOKEN":"${GBC_TOKEN}","GBC_BASE_URL":"${GBC_BASE_URL}"}}}}'
  $userMcp3 = Join-Path $testRoot 'user-mcp3.json'
  Write-Utf8NoBom $userMcp3 '{"mcpServers":{"jiuqi-gbc-mcp":{"type":"stdio","command":"npx","args":["--registry","https://nvwa.example/nexus/","-y","jiuqi-gbc-mcp@0.2.1","serve"],"env":{"GBC_TOKEN":"pat","GBC_BASE_URL":"http://u/"}}}}'
  $r6 = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt2 -McpJsonPath $userMcp3
  Assert ($r6.updated -eq 1) 'A legacy @latest declaration must refresh the entry.'
  $svc3 = (([IO.File]::ReadAllText($userMcp3) | ConvertFrom-Json).mcpServers).'jiuqi-gbc-mcp'
  Assert ((@($svc3.args) -join '|') -ceq '-y|jiuqi-gbc-mcp@latest|serve') 'The declared command is copied verbatim, overwriting the old pinned args and --registry.'
  Assert ($svc3.env.GBC_TOKEN -ceq 'pat' -and $svc3.env.GBC_BASE_URL -ceq 'http://u/') 'PAT/URL placeholders still resolve to the user-configured values.'
  Write-Output 'PASS: declared command overwrites the entry verbatim while PAT/URL survive.'

  $beforeAgain = [IO.File]::ReadAllText($userMcp3)
  $r6b = Sync-ExpertMcpDependencies -MarketplacesRoot $mkt2 -McpJsonPath $userMcp3
  Assert ($r6b.updated -eq 0 -and (([IO.File]::ReadAllText($userMcp3) -ceq $beforeAgain))) 'Re-sync with identical declarations must be a no-op.'
  Write-Output 'PASS: verbatim overwrite is idempotent.'

  # ---------- GMSCP-7878：自更新不得投递/执行临时切换器脚本 ----------
  # 现场缺陷：火绒把 %TEMP%\expertdock-update-<ver>\expertdock-update.cmd 判为
  # HEUR:TrojanDownloader/PS.NetLoader.am（脚本宿主落盘批处理 → cmd /c 执行 →
  # 自删除，整条链全中启发式），文件被直接删除，检查更新必然失败。
  # 约束：更新全程零多余进程形态、零临时脚本；对"运行中"的文件换名替换必须依然成立。
  $helperText = [IO.File]::ReadAllText((Join-Path $versionDir 'helper-ui.ps1'))
  Assert (-not ($helperText.Contains('@echo off') -or $helperText.Contains('del "%~f0"'))) 'Self-update must not generate a batch switcher script (GMSCP-7878).'
  Assert (-not $helperText.Contains('cmd.exe')) 'Self-update must never launch cmd.exe (GMSCP-7878).'

  # 进程内换名替换：运行中的 exe（加载器句柄带 FILE_SHARE_DELETE）也必须能替换
  $swapFn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Swap-InstalledFile' }, $true)
  Assert ($null -ne $swapFn) 'Swap-InstalledFile must exist for in-process self-update replacement.'
  Invoke-Expression $swapFn.Extent.Text
  $swapDir = Join-Path $testRoot 'swap'
  New-Item -ItemType Directory -Force $swapDir | Out-Null
  $target = Join-Path $swapDir 'app.exe'
  [IO.File]::WriteAllText($target, 'old-image')
  $shareDelete = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $imageLock = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareDelete)
  try {
    [IO.File]::WriteAllText((Join-Path $swapDir 'new.exe'), 'new-image')
    Swap-InstalledFile -Staged (Join-Path $swapDir 'new.exe') -Target $target
    Assert (([IO.File]::ReadAllText($target)) -ceq 'new-image') 'A running-image target must be replaced via rename.'
    Assert (([IO.File]::ReadAllText((Join-Path $swapDir 'app.exe.old'))) -ceq 'old-image') 'The previous image must be kept as the .old backup.'
  } finally { $imageLock.Dispose() }
  # 无 FILE_SHARE_DELETE 的硬锁：必须干净失败且不破坏原文件
  $hardTarget = Join-Path $swapDir 'locked.exe'
  [IO.File]::WriteAllText($hardTarget, 'hard-old')
  [IO.File]::WriteAllText((Join-Path $swapDir 'hard-new.exe'), 'hard-new')
  $hardLock = [IO.File]::Open($hardTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    Assert-Throws { Swap-InstalledFile -Staged (Join-Path $swapDir 'hard-new.exe') -Target $hardTarget } 'A non-renameable target must fail cleanly.'
    Assert (([IO.File]::ReadAllText($hardTarget)) -ceq 'hard-old') 'A failed swap must leave the original target intact.'
  } finally { $hardLock.Dispose() }
  Write-Output 'PASS: in-process swap replaces running-image targets and fails cleanly on hard locks.'

  # 启动清扫：换名残留（.old/.new）必须清理；被占用就静默跳过、下次启动再试
  $cleanFn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-UpdateLeftovers' }, $true)
  Assert ($null -ne $cleanFn) 'Remove-UpdateLeftovers must exist to sweep renamed leftovers at startup.'
  Invoke-Expression $cleanFn.Extent.Text
  $core = Join-Path $swapDir 'core.exe'
  $script = Join-Path $swapDir 'ui.ps1'
  foreach ($leftoverName in @('core.exe.old', 'core.exe.new', 'ui.ps1.old', 'ui.ps1.new')) { [IO.File]::WriteAllText((Join-Path $swapDir $leftoverName), 'x') }
  Remove-UpdateLeftovers
  foreach ($leftoverName in @('core.exe.old', 'core.exe.new', 'ui.ps1.old', 'ui.ps1.new')) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $swapDir $leftoverName))) ('Startup sweep must remove leftover ' + $leftoverName + '.')
  }
  [IO.File]::WriteAllText((Join-Path $swapDir 'core.exe.old'), 'x')
  $sweepLock = [IO.File]::Open((Join-Path $swapDir 'core.exe.old'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try { Remove-UpdateLeftovers } finally { $sweepLock.Dispose() }
  Assert (Test-Path -LiteralPath (Join-Path $swapDir 'core.exe.old')) 'A locked leftover must be skipped silently and retried next startup.'
  Write-Output 'PASS: startup sweep removes renamed leftovers and tolerates locked ones.'

  # 集成：mock 网络/进程边界，完整跑一遍自更新（模拟 0.7.0 → 0.7.1），断言
  # 全程零切换脚本、零多余进程形态、替换成功、回执正确、重启命令干净。
  foreach ($fnName in @('Write-Utf8NoBom', 'Enable-Tls', 'Test-VersionNewer', 'Invoke-WithRetry', 'Invoke-SelfUpdate')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
    Assert ($null -ne $fn) ('Helper UI must define ' + $fnName + '.')
    Invoke-Expression $fn.Extent.Text
  }
  $fakeInstall = Join-Path $testRoot 'installed-helper'
  New-Item -ItemType Directory -Force $fakeInstall | Out-Null
  $core = Join-Path $fakeInstall 'expertdock-helper.exe'
  $script = Join-Path $fakeInstall 'helper-ui.ps1'
  $iconFile = Join-Path $fakeInstall 'expertdock.ico'
  $installDir = $fakeInstall
  $updateReceipt = Join-Path $testRoot 'update-receipt.json'
  $defaultOrigin = 'https://mock.invalid'
  $helperVersion = '0.7.0'
  [IO.File]::WriteAllText($core, 'old-exe-image')
  [IO.File]::WriteAllText($script, 'old-ui v0.7.0')
  [IO.File]::WriteAllText($iconFile, 'old-ico')
  $tray = [pscustomobject]@{ Visible = $true }
  $form = New-Object PSObject
  Add-Member -InputObject $form -MemberType ScriptMethod -Name Dispose -Value { }

  # 造假新版暂存区 + 更新包（entry 名显式传入，与 build-release.ps1 的做法一致）
  $newVersion = '0.7.1'
  $stage = Join-Path $env:TEMP ('expertdock-update-' + $newVersion)
  New-Item -ItemType Directory -Force $stage | Out-Null
  $stagedUi = 'v0.7.1 stub helper-ui.ps1'
  [IO.File]::WriteAllText((Join-Path $stage 'helper-ui.ps1'), $stagedUi)
  [IO.File]::WriteAllText((Join-Path $stage 'expertdock-helper.exe'), 'new-exe-image')
  [IO.File]::WriteAllText((Join-Path $stage 'expertdock.ico'), 'new-ico')
  [IO.File]::WriteAllText((Join-Path $stage 'install.cmd'), 'new-install-cmd')
  [IO.File]::WriteAllText((Join-Path $stage 'helper-env.ps1'), 'new-env')
  [IO.File]::WriteAllText((Join-Path $stage 'node-runtime-win-x64.zip'), 'new-runtime')
  $fakeZip = Join-Path $testRoot 'fake-update.zip'
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipStream = [IO.File]::Open($fakeZip, [IO.FileMode]::Create)
  $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($entryName in @('helper-ui.ps1', 'expertdock-helper.exe', 'expertdock.ico', 'install.cmd', 'helper-env.ps1', 'node-runtime-win-x64.zip')) {
      [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $stage $entryName), $entryName) | Out-Null
    }
  } finally { $archive.Dispose(); $zipStream.Dispose() }
  $zipHash = (Get-FileHash $fakeZip -Algorithm SHA256).Hash.ToLower()

  # -UseBasicParsing 是开关参数，桩签名必须同样声明为 [switch]，否则绑定即报缺参
  function Invoke-RestMethod { param($Uri, $TimeoutSec, [switch]$UseBasicParsing) [pscustomobject]@{ version = $newVersion; downloadUrl = 'https://mock.invalid/update.zip'; sha256 = $zipHash } }
  function Invoke-WebRequest { param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing) Copy-Item $fakeZip $OutFile -Force }
  $started = New-Object System.Collections.Generic.List[object]
  function Start-Process { param($FilePath, $ArgumentList, $WindowStyle) $started.Add(@{ FilePath = $FilePath; ArgumentList = @($ArgumentList) }) }
  function Start-Sleep { param($Seconds) }
  # 真机托盘在按钮回调前已加载 WinForms；测试进程需自行加载同一程序集（Exit 无消息循环时为空操作）
  Add-Type -AssemblyName System.Windows.Forms

  $ok = Invoke-SelfUpdate
  Assert $ok 'Self-update must succeed on the mocked happy path.'
  Assert (([IO.File]::ReadAllText($core)) -ceq 'new-exe-image') 'The running exe must be swapped in-process, with no script host detour.'
  Assert (([IO.File]::ReadAllText($script)) -ceq $stagedUi) 'The running ui ps1 must be swapped in-process.'
  Assert (([IO.File]::ReadAllText($iconFile)) -ceq 'new-ico') 'The staged icon must be copied into the install dir.'
  Assert (([IO.File]::ReadAllText((Join-Path $fakeInstall 'install.cmd'))) -ceq 'new-install-cmd') 'install.cmd must be refreshed from the update package.'
  Assert (([IO.File]::ReadAllText((Join-Path $fakeInstall 'helper-env.ps1'))) -ceq 'new-env') 'helper-env.ps1 must land in the install dir.'
  Assert (([IO.File]::ReadAllText((Join-Path $fakeInstall 'node-runtime-win-x64.zip'))) -ceq 'new-runtime') 'The runtime archive must land in the install dir.'
  Assert (([IO.File]::ReadAllText(($core + '.old'))) -ceq 'old-exe-image') 'The previous exe must remain as the .old rollback image.'
  Assert (([IO.File]::ReadAllText(($script + '.old'))) -ceq 'old-ui v0.7.0') 'The previous ps1 must remain as the .old rollback copy.'
  Assert ($started.Count -eq 1) 'Self-update must start exactly one restart process.'
  $restart = $started[0]
  Assert ($restart.FilePath -eq 'powershell.exe') 'Restart must launch powershell directly (GMSCP-7878: never a script host detour).'
  Assert (@($restart.ArgumentList) -contains '-File') 'Restart must use -File like the protocol and autostart launches.'
  Assert (-not (Test-Path -LiteralPath (Join-Path $stage 'expertdock-update.cmd'))) 'No switcher script may be written into the staging dir.'
  $receipt = Get-Content $updateReceipt -Raw | ConvertFrom-Json
  Assert ($receipt.state -eq 'pending' -and $receipt.to -eq $newVersion) 'The receipt must stay pending for the new version.'
  Assert ($receipt.sha256 -eq $zipHash -and $receipt.from -eq '0.7.0') 'The receipt must record the verified hash and the previous version.'
  Write-Output 'PASS: full self-update flow swaps in-process with zero switcher scripts and a clean powershell restart.'
} finally {
  $env:USERPROFILE = $savedProfile
  $env:Path = $savedPath
  $env:NPM_CONFIG_USERCONFIG = $savedNpmConfig
  $env:TEMP = $savedTemp
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $allowed = [IO.Path]::GetFullPath($helperRoot) + [IO.Path]::DirectorySeparatorChar
  if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
