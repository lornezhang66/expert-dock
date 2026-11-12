# ExpertDock Helper 过渡启动器 v0.8.0 —— Go 版已接管全部能力
# 本文件只为 v0.7.x 旧自更新链路兜底：旧更新器强制要求更新包内存在 helper-ui.ps1
# （缺了会报"更新包内容不完整"并永久卡死在旧版），v0.8.0 起包内放本 stub 顶位；
# 它只把协议唤起参数转发给新版 expertdock-helper.exe 后立即退出。
# 新版首次启动会重注册协议到 exe 本体并删除本文件（helper/main.go takeOverLegacyInstall）。
param([string]$Url = "", [string]$Install = "")
$ErrorActionPreference = 'SilentlyContinue'
$exe = Join-Path $PSScriptRoot 'expertdock-helper.exe'
if (Test-Path $exe) {
  if ($Url) { Start-Process -FilePath $exe -ArgumentList $Url }
  else { Start-Process -FilePath $exe }
}
