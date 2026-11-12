package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeStatus 全链路：APPDATA 重定向到临时目录，验证 status.json 真实落盘。
// 起因：本机迁移演练发现安装版 GUI 启动后 status.json 仍是 v0.7.2 旧格式——
// 该文件自 0.2.5 时代可能从未被 Go 核心成功写过（现场文件一直是 ps1 格式）。
func TestWriteStatusWritesFile(t *testing.T) {
	fakeAppData := t.TempDir()
	t.Setenv("APPDATA", fakeAppData)
	if uiStatusHook != nil {
		orig := uiStatusHook
		uiStatusHook = nil
		defer func() { uiStatusHook = orig }()
	}
	writeStatus("ready", "测试状态写入")
	path := filepath.Join(fakeAppData, "ExpertDock", "status.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("status.json 未落盘：%v", err)
	}
	var cfg map[string]string
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("status.json 不是合法 JSON：%v", err)
	}
	if cfg["state"] != "ready" || cfg["message"] != "测试状态写入" || cfg["version"] != helperVersion {
		t.Fatalf("字段不符：%v", cfg)
	}
}
