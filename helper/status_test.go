package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// redirectConfigDir 把当前平台 os.UserConfigDir() 依赖的环境变量重定向到临时目录，
// 返回该平台上 status.json 的期望落盘路径——测试绝不写真实用户目录。
// 三平台变量不同（Windows %AppData% / darwin $HOME / Linux $XDG_CONFIG_HOME），
// 旧版只设 APPDATA 在 Linux CI 上无效，写读路径错位导致 CI 红灯（本文件要修的根因）。
func redirectConfigDir(t *testing.T, dir string) string {
	t.Helper()
	switch runtime.GOOS {
	case "windows":
		t.Setenv("AppData", dir)
		return filepath.Join(dir, "ExpertDock", "status.json")
	case "darwin":
		t.Setenv("HOME", dir)
		return filepath.Join(dir, "Library", "Application Support", "ExpertDock", "status.json")
	default: // linux 及其他 unix：XDG 优先，缺失时回落 $HOME/.config
		t.Setenv("XDG_CONFIG_HOME", dir)
		return filepath.Join(dir, "ExpertDock", "status.json")
	}
}

// writeStatus 全链路：配置目录重定向到临时目录，验证 status.json 真实落盘且字段符合契约。
// 起因：本机迁移演练发现安装版 GUI 启动后 status.json 仍是 v0.7.2 旧格式——
// 该文件自 0.2.5 时代可能从未被 Go 核心成功写过（现场文件一直是 ps1 格式）。
func TestWriteStatusWritesFile(t *testing.T) {
	fakeConfig := t.TempDir()
	wantPath := redirectConfigDir(t, fakeConfig)
	if uiStatusHook != nil {
		orig := uiStatusHook
		uiStatusHook = nil
		defer func() { uiStatusHook = orig }()
	}
	writeStatus("ready", "测试状态写入")
	raw, err := os.ReadFile(wantPath)
	if err != nil {
		t.Fatalf("status.json 未落盘（期望路径 %s）：%v", wantPath, err)
	}
	var cfg map[string]string
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("status.json 不是合法 JSON：%v", err)
	}
	if cfg["state"] != "ready" || cfg["message"] != "测试状态写入" || cfg["version"] != helperVersion {
		t.Fatalf("字段不符：%v", cfg)
	}
}

// 路径解析单测：statusJSONPath 必须落在当前平台用户配置目录的 ExpertDock/ 下，
// 与 mac launcher 读侧（AppDelegate.swift applicationSupportDirectory）同一契约。
func TestStatusJSONPathResolvesConfigDir(t *testing.T) {
	fakeConfig := t.TempDir()
	want := redirectConfigDir(t, fakeConfig)
	got, err := statusJSONPath()
	if err != nil {
		t.Fatalf("statusJSONPath 解析失败：%v", err)
	}
	if got != want {
		t.Fatalf("路径错位：got=%s want=%s", got, want)
	}
}

// UserConfigDir 可能失败（HOME/AppData 未设的极端环境）：statusJSONPath 必须返回错误
// 而不是半途拼路径，writeStatus 侧据此降级为跳过落盘、只走 GUI 钩子。
func TestStatusJSONPathErrorsWithoutConfigDir(t *testing.T) {
	switch runtime.GOOS {
	case "windows":
		t.Setenv("AppData", "")
	case "darwin":
		t.Setenv("HOME", "")
	default:
		t.Setenv("XDG_CONFIG_HOME", "")
		t.Setenv("HOME", "")
	}
	if path, err := statusJSONPath(); err == nil {
		t.Fatalf("无配置目录时应返回错误，实际得到 %s", path)
	}
}
