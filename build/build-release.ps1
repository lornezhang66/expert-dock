<#
.SYNOPSIS
  v0.8.0（Go 双端）发布编排：汇总产物 → 构建 Windows 更新 ZIP → Inno Setup → latest.json → 发布 R2 → 线上校验。

.DESCRIPTION
  产物分工：Windows exe / macOS zip 由 GitHub Actions（tag 触发 release-helper.yml）产出，
  本脚本在本机汇总发布（wrangler 凭据在本机）。
  发布纪律（继承 v0.7.x 教训，不可破坏）：
    1. latest.json 必须最后上传——先传包后传版本声明，中途失败不会出现"版本已更新但安装包缺失"窗口；
    2. wrangler r2 object put 必须 --remote——默认写本地 Miniflare 模拟器，不上 --remote 是假象；
    3. 线上校验用随机 nonce 绕过边缘缓存（下载响应 max-age=3600 immutable）。

.PARAMETER Version
  发布版本号（x.y.z）。
.PARAMETER StagingDir
  产物汇总目录，默认 build/release/v<Version>。CI 产物（windows zip 内的 exe、macos zip）需先放/解到这里。
.PARAMETER MacosZipPath
  CI 产出的 macOS zip 路径；发布时上传并写入 latest.json（v0.8.0 起 mac 不再平移旧包）。
.PARAMETER NodeZipPath
  受管 Node 运行时 zip（默认回退到 legacy 目录 helper/v0.7.2/）；进 ZIP 前校验 SHA-256 与 env.go 钉死值一致。
.PARAMETER DeployWorker
  发布时同时 wrangler deploy（--keep-vars --no-bundle，仓库根 wrangler.jsonc）。
#>
param(
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = "0.8.0",
  [string]$StagingDir,
  [string]$MacosZipPath,
  [string]$NodeZipPath,
  [string]$IsccPath,
  [switch]$ZipOnly,
  [switch]$DeployWorker,
  [switch]$Publish,
  [string]$R2Bucket = "expert-dock-packages",
  [string]$PublicBaseUrl = "https://ed.lorne.top",
  [string]$RepoRoot
)

$ErrorActionPreference = "Stop"

# ---- 路径定位：脚本在 <repo>/build/ 下，仓库根为其父目录 ----
$buildRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot "..")) }
if (-not $StagingDir) { $StagingDir = Join-Path $buildRoot ("release\v" + $Version) }
$versionDir = [IO.Path]::GetFullPath($StagingDir)
$repoRootFull = [IO.Path]::GetFullPath($RepoRoot)
$assetsDir = Join-Path $repoRootFull "helper\assets"
$installerScript = Join-Path $repoRootFull "installer\ExpertDock-Helper.iss"
$legacyDir = Join-Path $repoRootFull "docs\legacy-windows-helper"

if (-not $versionDir.StartsWith($repoRootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "版本目录越界：$versionDir" }

# ---- 受管 Node zip：定位 + 钉死哈希校验（helper/env.go helperNodeSha256 单一事实源） ----
$envGo = [IO.File]::ReadAllText((Join-Path $repoRootFull "helper\env.go"))
$pinnedSha = if ($envGo -match 'helperNodeSha256\s+=\s+"([0-9a-f]{64})"') { $Matches[1] } else { throw "无法从 env.go 读取 helperNodeSha256" }
if (-not $NodeZipPath) {
  $legacy = Get-ChildItem $repoRootFull -Recurse -Filter "node-runtime-win-x64.zip" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\v0\.7\.' } | Select-Object -First 1
  if ($legacy) { $NodeZipPath = $legacy.FullName }
}
if (-not ($NodeZipPath -and (Test-Path $NodeZipPath))) { throw "找不到受管 Node 运行时 zip，请用 -NodeZipPath 指定。" }
$nodeSha = (Get-FileHash $NodeZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($nodeSha -ne $pinnedSha) { throw "Node 运行时哈希不匹配：$nodeSha ≠ 钉死值 $pinnedSha（env.go）" }

# ---- 汇总产物到 staging ----
New-Item -ItemType Directory -Force $versionDir | Out-Null
$exePath = Join-Path $versionDir "expertdock-helper.exe"
$shimPath = Join-Path $versionDir "helper-ui.ps1"
$icoPath = Join-Path $versionDir "expertdock.ico"
$envPs1Path = Join-Path $versionDir "helper-env.ps1"
$cmdPath = Join-Path $versionDir "install.cmd"
$stagedNode = Join-Path $versionDir "node-runtime-win-x64.zip"
$zipPath = Join-Path $versionDir "expertdock-helper-windows.zip"
$macosStaged = Join-Path $versionDir "expertdock-helper-macos.zip"

$missing = @("expertdock-helper.exe", "helper-ui.ps1") | Where-Object { -not (Test-Path (Join-Path $versionDir $_)) }
if ($missing) { throw "staging 缺少 CI 产物（先从 Actions 工件取回放入 $versionDir）：$($missing -join ', ')" }
if ($MacosZipPath) {
  if (-not (Test-Path $MacosZipPath)) { throw "MacosZipPath 不存在：$MacosZipPath" }
  Copy-Item $MacosZipPath $macosStaged -Force
}
Copy-Item $NodeZipPath $stagedNode -Force
Copy-Item (Join-Path $assetsDir "expertdock.ico") $icoPath -Force
Copy-Item (Join-Path $legacyDir "helper-env.ps1") $envPs1Path -Force
Copy-Item (Join-Path $buildRoot "install.cmd") $cmdPath -Force

# ---- 版本一致性：exe --version 必须等于 $Version；shim 头部必须声明 v$Version（旧更新器包内防降级检查的依据） ----
# PS 5.1 实测坑：-File 脚本里 `& gui-exe --version` 的管道捕获返回空（-Command 却正常）。
# 用 Process 重定向（helper-env.ps1 Test-HelperNode 的既定模式），对 windowsgui 程序可靠。
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.Arguments = '--version'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$verProc = [Diagnostics.Process]::Start($psi)
$exeVersion = $verProc.StandardOutput.ReadToEnd().Trim()
if (-not $verProc.WaitForExit(5000)) { $verProc.Kill(); throw "exe --version 执行超时" }
if ($verProc.ExitCode -ne 0 -or $exeVersion -ne $Version) { throw "exe --version 返回 '$exeVersion'，与 $Version 不一致" }
$shimText = [IO.File]::ReadAllText($shimPath)
if ($shimText -notmatch ('v' + [regex]::Escape($Version))) { throw "helper-ui.ps1（shim）未声明 v$Version——旧更新器会拒绝本包" }
foreach ($marker in @('expertdock-helper.exe', 'Start-Process')) {
  if (-not $shimText.Contains($marker)) { throw "shim 缺少转发标记：$marker" }
}

# ---- Windows 更新 ZIP：6 文件定案（exe + shim + ico + install.cmd + helper-env + node zip）——
#      旧 v0.7.x 更新器硬性要求四件套齐全，缺任一将永久卡旧版 ----
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
$archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($name in @("expertdock-helper.exe", "helper-ui.ps1", "expertdock.ico", "install.cmd", "helper-env.ps1", "node-runtime-win-x64.zip")) {
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $versionDir $name), $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
} finally {
  $archive.Dispose(); $zipStream.Dispose()
}
$zipEntries = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $actual = @($zipEntries.Entries | ForEach-Object FullName | Sort-Object)
  $expected = @("expertdock-helper.exe", "expertdock.ico", "helper-ui.ps1", "install.cmd", "helper-env.ps1", "node-runtime-win-x64.zip") | Sort-Object
  if (($actual -join "|") -ne ($expected -join "|")) { throw "更新 ZIP 内容不符合预期：$($actual -join ', ')" }
} finally { $zipEntries.Dispose() }

$zipInfo = Get-Item $zipPath
$zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "更新 ZIP 构建完成：$($zipInfo.FullName) ($($zipInfo.Length) bytes)"
Write-Host "SHA256: $zipHash"
if ($ZipOnly) { return }

# ---- Inno Setup ----
function Find-Iscc {
  if ($IsccPath) {
    if (-not (Test-Path $IsccPath)) { throw "找不到 ISCC：$IsccPath" }
    return (Resolve-Path $IsccPath).Path
  }
  $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA "Programs")) | Where-Object { $_ }
  foreach ($root in $roots) {
    foreach ($version in @(7, 6)) {
      $candidate = Join-Path $root ("Inno Setup " + $version + "\ISCC.exe")
      if (Test-Path $candidate) { return $candidate }
    }
  }
  throw "未安装 Inno Setup。请从 https://jrsoftware.org/isdl.php 安装后重试。"
}
$iscc = Find-Iscc
$isccArguments = @(
  "/DAppVersion=$Version",
  "/DSourceDir=$versionDir",
  "/DOutputDir=$versionDir",
  $installerScript
)
& $iscc @isccArguments
if ($LASTEXITCODE -ne 0) { throw "Inno Setup 编译失败，退出码：$LASTEXITCODE" }
$setupPath = Join-Path $versionDir ("ExpertDock-Helper-Setup-" + $Version + ".exe")
if (-not (Test-Path $setupPath)) { throw "安装器未生成：$setupPath" }
$setupInfo = Get-Item $setupPath
$setupHash = (Get-FileHash $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()

# ---- latest.json：macos 条目取实际 mac zip（v0.8.0 起不再平移旧包哈希） ----
if (-not ($MacosZipPath -or (Test-Path $macosStaged))) { throw "缺少 macOS zip：用 -MacosZipPath 提供 CI 产物。" }
$macosInfo = Get-Item $macosStaged
$macosHash = (Get-FileHash $macosStaged -Algorithm SHA256).Hash.ToLowerInvariant()
$latest = [ordered]@{
  version = $Version
  sha256 = $zipHash
  size = $zipInfo.Length
  platforms = [ordered]@{
    windows = [ordered]@{ sha256 = $zipHash; size = $zipInfo.Length }
    macos = [ordered]@{ sha256 = $macosHash; size = $macosInfo.Length }
  }
  installers = [ordered]@{
    windows = [ordered]@{ name = $setupInfo.Name; sha256 = $setupHash; size = $setupInfo.Length }
  }
}
$latestPath = Join-Path $versionDir "latest.json"
[IO.File]::WriteAllText($latestPath, ($latest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-Host "发布物构建完成：v$Version"
Write-Host "Setup : $($setupInfo.Name)  $($setupInfo.Length) bytes  $setupHash"
Write-Host "Update: $($zipInfo.Name)  $($zipInfo.Length) bytes  $zipHash"
Write-Host "macOS : $($macosInfo.Name)  $($macosInfo.Length) bytes  $macosHash"

# ---- 发布到 R2。--remote 是硬要求：wrangler 4.x 默认写本地 Miniflare 模拟器 ----
#      （不带 --remote 的"上传成功"是假象，见 v0.7.0 发布教训）。
function Publish-ToR2 {
  param([object[]]$Artifacts)
  if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) { throw "发布需要 wrangler CLI，未在 PATH 中找到。" }
  foreach ($artifact in $Artifacts) {
    & wrangler r2 object put "$R2Bucket/$($artifact.Key)" --file $artifact.Path --remote
    if ($LASTEXITCODE -ne 0) { throw "R2 上传失败：$($artifact.Key)（退出码 $LASTEXITCODE）" }
    Write-Host "已上传 R2：$($artifact.Key)"
  }
}

# ---- 线上回读校验：从公网侧回读，随机 nonce 绕过边缘缓存（max-age=3600 immutable） ----
function Test-LiveRelease {
  param([string]$BaseUrl, [string]$ReleaseVersion, [string]$ZipHash, [long]$ZipSize, [string]$SetupHash, [string]$MacosHash, [long]$MacosSize)
  $ProgressPreference = "SilentlyContinue"
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $base = $BaseUrl.TrimEnd("/")
  $nonce = [Guid]::NewGuid().ToString("N")
  $meta = Invoke-RestMethod -Uri "$base/api/helper/latest/windows?publish-check=$nonce"
  if ($meta.version -ne $ReleaseVersion) { throw "线上 latest 版本为 $($meta.version)，期望 $ReleaseVersion。可能是部署传播延迟，稍后重跑。" }
  if ($meta.sha256 -ne $ZipHash) { throw "线上 latest 的 windows sha256 不匹配" }
  if ($meta.size -ne $ZipSize) { throw "线上 latest 的 windows size 不匹配" }
  $macosMeta = Invoke-RestMethod -Uri "$base/api/helper/latest/macos?publish-check=$nonce"
  if ($macosMeta.version -ne $ReleaseVersion) { throw "线上 macos latest 版本为 $($macosMeta.version)，期望 $ReleaseVersion" }
  if ($macosMeta.sha256 -ne $MacosHash) { throw "线上 macos sha256 不匹配：$($macosMeta.sha256) ≠ $MacosHash" }
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) "publish-check-$nonce"
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  try {
    $checks = @(
      @{ Name = "update.zip"; Url = "$base/downloads/helper/windows?publish-check=$nonce"; Hash = $ZipHash },
      @{ Name = "setup.exe"; Url = "$base/downloads/helper/windows/setup?publish-check=$nonce"; Hash = $SetupHash },
      @{ Name = "macos.zip"; Url = "$base/downloads/helper/macos?publish-check=$nonce"; Hash = $MacosHash }
    )
    foreach ($check in $checks) {
      $target = Join-Path $tempDir $check.Name
      Invoke-WebRequest -Uri $check.Url -OutFile $target -UseBasicParsing
      $actual = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $check.Hash) { throw "线上文件哈希不匹配：$($check.Name) 期望 $($check.Hash) 实际 $actual" }
      Write-Host "线上校验通过：$($check.Name)  $actual"
    }
  } finally {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Publish) {
  if (-not (Test-Path $macosStaged)) { throw "发布缺少 macOS zip" }
  # 顺序（教训固化）：三包先传 → Worker 部署（可选）→ latest.json 最后 → 线上校验
  $artifacts = @(
    @{ Key = "helpers/v$Version/expertdock-helper-windows.zip"; Path = $zipPath },
    @{ Key = "helpers/v$Version/expertdock-helper-macos.zip"; Path = $macosStaged },
    @{ Key = "helpers/v$Version/ExpertDock-Helper-Setup-$Version.exe"; Path = $setupPath }
  )
  Write-Host "开始发布到 R2（bucket: $R2Bucket）..."
  Publish-ToR2 -Artifacts $artifacts
  if ($DeployWorker) {
    Write-Host "部署 Worker（--keep-vars --no-bundle）..."
    Push-Location $repoRootFull
    try {
      & wrangler deploy --keep-vars --no-bundle
      if ($LASTEXITCODE -ne 0) { throw "wrangler deploy 失败（退出码 $LASTEXITCODE）" }
    } finally { Pop-Location }
  }
  # latest.json 必须最后上传：先传包、后传版本声明，中途失败不会出现
  # "版本号已更新但安装包缺失"的窗口期。
  Publish-ToR2 -Artifacts @(@{ Key = "helpers/latest.json"; Path = $latestPath })
  $verifyMb = [Math]::Round(($zipInfo.Length + $setupInfo.Length + $macosInfo.Length) / 1MB)
  Write-Host "开始线上回读校验（将下载约 ${verifyMb}MB）..."
  Test-LiveRelease -BaseUrl $PublicBaseUrl -ReleaseVersion $Version -ZipHash $zipHash -ZipSize $zipInfo.Length -SetupHash $setupHash -MacosHash $macosHash -MacosSize $macosInfo.Length
  Write-Host "发布校验全部通过：v$Version 已上线。"
}
