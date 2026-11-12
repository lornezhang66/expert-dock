//go:build windows

package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func osPathSeparator() rune { return os.PathSeparator }

var _ = osPathSeparator // 占位：保留与 env_test.go 一致的辅助命名空间，避免误删

// zip-slip 防护：压缩包内绝对路径/相对穿越必须被拒绝
func TestExtractZipRejectsPathTraversal(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "evil.zip")
	target := filepath.Join(t.TempDir(), "out")
	f, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	for _, name := range []string{`..\evil.txt`, `..` + string(os.PathSeparator) + `evil2.txt`} {
		entry, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		entry.Write([]byte("x"))
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	err = extractZip(archive, target)
	if err == nil || !strings.Contains(err.Error(), "越界") {
		t.Fatalf("路径穿越必须被拒绝：%v", err)
	}
}

// 正常解压：文件落位
func TestExtractZipNormal(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "good.zip")
	target := filepath.Join(t.TempDir(), "out")
	f, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	entry, err := w.Create("node-v22.22.2-win-x64/node.exe")
	if err != nil {
		t.Fatal(err)
	}
	entry.Write([]byte("fake"))
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if err := extractZip(archive, target); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(target, "node-v22.22.2-win-x64", "node.exe"))
	if err != nil || string(got) != "fake" {
		t.Fatalf("解压产物不符：%v %q", err, got)
	}
}
