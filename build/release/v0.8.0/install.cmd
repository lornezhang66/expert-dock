@echo off
rem 更新 ZIP 手动安装入口：注册协议到 exe 本体并启动常驻 GUI
"%~dp0expertdock-helper.exe" --install-protocol
start "" "%~dp0expertdock-helper.exe"
