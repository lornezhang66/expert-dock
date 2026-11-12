param(
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = "0.7.0",
  [string]$IsccPath,
  [switch]$ZipOnly,
  [string]$SignToolName,
  [string]$SignToolCommand,
  [switch]$Publish,
  [string]$R2Bucket = "expert-dock-packages",
  [string]$PublicBaseUrl = "https://expert-dock.18660190869.workers.dev"
)

$ErrorActionPreference = "Stop"
$helperRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$versionDir = [IO.Path]::GetFullPath((Join-Path $helperRoot ("v" + $Version)))
$installerScript = Join-Path $helperRoot "installer\ExpertDock-Helper.iss"
$requiredFiles = @("expertdock-helper.exe", "helper-ui.ps1", "install.cmd", "helper-env.ps1", "node-runtime-win-x64.zip")

if (-not $versionDir.StartsWith($helperRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "版本目录越界：$versionDir" }
foreach ($name in $requiredFiles) {
  if (-not (Test-Path (Join-Path $versionDir $name))) { throw "缺少发布文件：$name" }
}
if (-not (Test-Path $installerScript)) { throw "缺少安装器脚本：$installerScript" }
if ([bool]$SignToolName -xor [bool]$SignToolCommand) { throw "签名时必须同时提供 SignToolName 和 SignToolCommand" }
if ($Publish -and $ZipOnly) { throw "-Publish 不能与 -ZipOnly 同时使用：ZipOnly 不生成安装器和 latest.json" }

$helperScript = Join-Path $versionDir "helper-ui.ps1"
$helperText = [IO.File]::ReadAllText($helperScript)
if ($helperText -notmatch ('\$helperVersion\s*=\s*"' + [regex]::Escape($Version) + '"')) { throw "helper-ui.ps1 版本与 $Version 不一致" }
foreach ($marker in @("ProgressBar", '$Shutdown', '$Startup', "shutdown.request")) {
  if (-not $helperText.Contains($marker)) { throw "helper-ui.ps1 缺少产品化标记：$marker" }
}

function New-BrandIcon([string]$Path) {
  Add-Type -AssemblyName System.Drawing
  $images = New-Object System.Collections.Generic.List[object]
  foreach ($size in @(16, 32, 48, 256)) {
    $bitmap = New-Object Drawing.Bitmap($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object Drawing.Rectangle(1, 1, ($size - 2), ($size - 2))
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, [Drawing.Color]::FromArgb(22, 119, 255), [Drawing.Color]::FromArgb(38, 198, 155), 45)
    $graphics.FillEllipse($brush, $rect)
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, [single][Math]::Max(2, $size * 0.085))
    $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $graphics.TranslateTransform($size / 2, $size / 2)
    $graphics.RotateTransform(-42)
    $graphics.DrawEllipse($pen, [single](-$size * 0.34), [single](-$size * 0.13), [single]($size * 0.42), [single]($size * 0.26))
    $graphics.DrawEllipse($pen, [single](-$size * 0.08), [single](-$size * 0.13), [single]($size * 0.42), [single]($size * 0.26))
    $stream = New-Object IO.MemoryStream
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $images.Add([pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() })
    $stream.Dispose(); $pen.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
  }

  $file = [IO.File]::Create($Path)
  $writer = New-Object IO.BinaryWriter($file)
  try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
      $dimension = if ($image.Size -eq 256) { 0 } else { $image.Size }
      $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
      $writer.Write([byte]0); $writer.Write([byte]0)
      $writer.Write([uint16]1); $writer.Write([uint16]32)
      $writer.Write([uint32]$image.Bytes.Length); $writer.Write([uint32]$offset)
      $offset += $image.Bytes.Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image.Bytes) }
  } finally {
    $writer.Dispose(); $file.Dispose()
  }

  $icon = New-Object Drawing.Icon($Path)
  try { if ($icon.Width -lt 16 -or $icon.Height -lt 16) { throw "生成的图标无效" } } finally { $icon.Dispose() }
}

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

# 发布产物到 R2。--remote 是硬要求：wrangler 4.x 的 r2 object 命令默认写本地
# Miniflare 模拟器（.wrangler/state/），不带 --remote 的"上传成功"是假象。
function Publish-ToR2 {
  param([string]$Bucket, [string]$ReleaseVersion, [object[]]$Artifacts)
  if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) { throw "发布需要 wrangler CLI，未在 PATH 中找到。" }
  foreach ($artifact in $Artifacts) {
    & wrangler r2 object put "$Bucket/$($artifact.Key)" --file $artifact.Path --remote
    if ($LASTEXITCODE -ne 0) { throw "R2 上传失败：$($artifact.Key)（退出码 $LASTEXITCODE）" }
    Write-Host "已上传 R2：$($artifact.Key)"
  }
}

# 从公网侧回读校验，而不是用 wrangler 回读——只有线上 URL 能证明
# "Worker 绑定读到的"就是刚上传的字节。下载 URL 带随机查询参数绕过边缘缓存
# （下载响应带 max-age=3600, immutable，同版本重发布会让缓存短期内容不一致）。
function Test-LiveRelease {
  param([string]$BaseUrl, [string]$ReleaseVersion, [string]$ZipHash, [long]$ZipSize, [string]$SetupHash, [object]$Latest)
  $ProgressPreference = "SilentlyContinue"
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $base = $BaseUrl.TrimEnd("/")
  $nonce = [Guid]::NewGuid().ToString("N")
  $meta = Invoke-RestMethod -Uri "$base/api/helper/latest/windows?publish-check=$nonce"
  if ($meta.version -ne $ReleaseVersion) { throw "线上 latest 版本为 $($meta.version)，期望 $ReleaseVersion。可能是部署传播延迟，稍后重跑。" }
  if ($meta.sha256 -ne $ZipHash) { throw "线上 latest 的 windows sha256 不匹配：$($meta.sha256) ≠ $ZipHash" }
  if ($meta.size -ne $ZipSize) { throw "线上 latest 的 windows size 不匹配：$($meta.size) ≠ $ZipSize" }
  $macosMeta = Invoke-RestMethod -Uri "$base/api/helper/latest/macos?publish-check=$nonce"
  if ($macosMeta.version -ne $ReleaseVersion) { throw "线上 macos latest 版本为 $($macosMeta.version)，期望 $ReleaseVersion" }
  if ($macosMeta.sha256 -ne $Latest.platforms.macos.sha256) { throw "线上 macos 声明哈希与本次 latest.json 不一致：$($macosMeta.sha256) ≠ $($Latest.platforms.macos.sha256)" }
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) "publish-check-$nonce"
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  try {
    $checks = @(
      @{ Name = "update.zip"; Url = "$base/downloads/helper/windows?publish-check=$nonce"; Hash = $ZipHash },
      @{ Name = "setup.exe"; Url = "$base/downloads/helper/windows/setup?publish-check=$nonce"; Hash = $SetupHash }
    )
    foreach ($check in $checks) {
      $target = Join-Path $tempDir $check.Name
      Invoke-WebRequest -Uri $check.Url -OutFile $target -UseBasicParsing
      $actual = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $check.Hash) { throw "线上文件哈希不匹配：$($check.Name) 期望 $($check.Hash) 实际 $actual" }
      Write-Host "线上校验通过：$($check.Name)  $actual"
    }
    $macosTarget = Join-Path $tempDir "macos.zip"
    try {
      Invoke-WebRequest -Uri "$base/downloads/helper/macos?publish-check=$nonce" -OutFile $macosTarget -UseBasicParsing
    } catch {
      throw "macOS 包下载失败（helpers/v$ReleaseVersion/expertdock-helper-macos.zip 可能未上传），请手动上传后重跑。原因：$($_.Exception.Message)"
    }
    $macosHash = (Get-FileHash $macosTarget -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($macosHash -ne $macosMeta.sha256) { throw "线上 macOS 包哈希不匹配：$macosHash ≠ $($macosMeta.sha256)" }
    Write-Host "线上校验通过：macos.zip  $macosHash"
  } finally {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$iconPath = Join-Path $versionDir "expertdock.ico"
New-BrandIcon $iconPath

$zipPath = Join-Path $versionDir "expertdock-helper-windows.zip"
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

if ($ZipOnly) {
  $zip = Get-Item $zipPath
  Write-Host "更新 ZIP 构建完成：$($zip.FullName) ($($zip.Length) bytes)"
  Write-Host "SHA256: $((Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant())"
  return
}

$iscc = Find-Iscc
$isccArguments = @(
  "/DAppVersion=$Version",
  "/DSourceDir=$versionDir",
  "/DOutputDir=$versionDir"
)
if ($SignToolName) {
  $isccArguments += "/DSignToolName=$SignToolName"
  $isccArguments += "/S$SignToolName=$SignToolCommand"
}
$isccArguments += $installerScript
& $iscc @isccArguments
if ($LASTEXITCODE -ne 0) { throw "Inno Setup 编译失败，退出码：$LASTEXITCODE" }

$setupPath = Join-Path $versionDir ("ExpertDock-Helper-Setup-" + $Version + ".exe")
if (-not (Test-Path $setupPath)) { throw "安装器未生成：$setupPath" }

$zipInfo = Get-Item $zipPath
$setupInfo = Get-Item $setupPath
$zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$setupHash = (Get-FileHash $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previous = Get-Content (Join-Path $helperRoot "v0.5.0\latest.json") -Raw | ConvertFrom-Json
$latest = [ordered]@{
  version = $Version
  sha256 = $zipHash
  size = $zipInfo.Length
  platforms = [ordered]@{
    windows = [ordered]@{ sha256 = $zipHash; size = $zipInfo.Length }
    macos = [ordered]@{ sha256 = $previous.platforms.macos.sha256; size = $previous.platforms.macos.size }
  }
  installers = [ordered]@{
    windows = [ordered]@{ name = $setupInfo.Name; sha256 = $setupHash; size = $setupInfo.Length }
  }
}
$latestPath = Join-Path $versionDir "latest.json"
[IO.File]::WriteAllText($latestPath, ($latest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $actualEntries = @($zip.Entries | ForEach-Object FullName | Sort-Object)
  $expectedEntries = @("expertdock-helper.exe", "expertdock.ico", "helper-ui.ps1", "install.cmd", "helper-env.ps1", "node-runtime-win-x64.zip") | Sort-Object
  if (($actualEntries -join "|") -ne ($expectedEntries -join "|")) { throw "更新 ZIP 内容不符合预期：$($actualEntries -join ', ')" }
} finally { $zip.Dispose() }

Write-Host "发布物构建完成：v$Version"
Write-Host "Setup : $($setupInfo.Name)  $($setupInfo.Length) bytes  $setupHash"
Write-Host "Update: $($zipInfo.Name)  $($zipInfo.Length) bytes  $zipHash"
Write-Host "签名  : $(if ($SignToolName) { '已启用' } else { '未启用（内测包）' })"

if ($Publish) {
  # latest.json 必须最后上传：先传包、后传版本声明，中途失败不会出现
  # "版本号已更新但安装包缺失"的窗口期。
  $artifacts = @(
    @{ Key = "helpers/v$Version/expertdock-helper-windows.zip"; Path = $zipPath },
    @{ Key = "helpers/v$Version/ExpertDock-Helper-Setup-$Version.exe"; Path = $setupPath },
    @{ Key = "helpers/latest.json"; Path = $latestPath }
  )
  Write-Host "开始发布到 R2（bucket: $R2Bucket）..."
  Publish-ToR2 -Bucket $R2Bucket -ReleaseVersion $Version -Artifacts $artifacts
  $verifyMb = [Math]::Round(($zipInfo.Length + $setupInfo.Length + $Latest.platforms.macos.size) / 1MB)
  Write-Host "开始线上回读校验（将下载约 ${verifyMb}MB）..."
  Test-LiveRelease -BaseUrl $PublicBaseUrl -ReleaseVersion $Version -ZipHash $zipHash -ZipSize $zipInfo.Length -SetupHash $setupHash -Latest $Latest
  Write-Host "发布校验全部通过：v$Version 已上线。"
}
