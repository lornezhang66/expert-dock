//go:build windows

package main

// 环境层 Windows 实现，逐段对应 docs/legacy-windows-helper/helper-env.ps1：
// Install-HelperNodeRuntime / Get|Set-HelperUserEnvironment / Set-HelperNpxEnvironment /
// Send-HelperEnvironmentChange / Initialize-HelperEnvironment。

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	waitAbandoned      = 0x00000080 // 蓝本把 AbandonedMutexException 视为已获锁：前任持有者死了，锁归我们
	helperEnvMutex     = `Local\ExpertDockEnvironment`
	helperEnvAcquireMs = 60000
)

// prepareHelperEnvironment 对应蓝本 Initialize-HelperEnvironment。
// 注意与蓝本一致的两个口径：x64 限定；系统 node 可用也必装受管运行时。
func prepareHelperEnvironment() error {
	if runtime.GOARCH != "amd64" {
		return errors.New("当前内置运行时适用于 Windows x64")
	}
	mutexName, err := windows.UTF16PtrFromString(helperEnvMutex)
	if err != nil {
		return err
	}
	handle, err := windows.CreateMutex(nil, false, mutexName)
	if err != nil && err != windows.ERROR_ALREADY_EXISTS {
		return err
	}
	defer windows.CloseHandle(handle)
	switch event, werr := windows.WaitForSingleObject(handle, helperEnvAcquireMs); {
	case werr != nil:
		return werr
	case event == uint32(windows.WAIT_OBJECT_0) || event == waitAbandoned:
		// 已获锁
	case event == uint32(windows.WAIT_TIMEOUT):
		return errors.New("其他任务正在准备运行环境，请稍后重试")
	default:
		return fmt.Errorf("等待环境锁异常：%d", event)
	}
	defer windows.ReleaseMutex(handle)

	nodePath := ""
	if existing, lookErr := exec.LookPath("node.exe"); lookErr == nil && verifyHelperNode(existing) {
		nodePath = existing
	}
	managedPath, installed, err := installHelperNodeRuntime(helperManagerHome(), helperNodeArchivePath())
	if err != nil {
		return err
	}
	if nodePath == "" {
		nodePath = managedPath
	}
	if err := setNpxEnvironment(helperManagerHome(), filepath.Dir(managedPath)); err != nil {
		return err
	}
	helperLog("INFO", "环境", fmt.Sprintf("运行环境就绪：node=%s（受管运行时本次安装=%v）", nodePath, installed))
	return nil
}

// helperNodeToolsOK 对应蓝本 Test-HelperNodeTools：node/npm/npx 及其 CLI 入口齐全且 node 可运行
func helperNodeToolsOK(directory string) bool {
	for _, name := range []string{
		"node.exe", "npm.cmd", "npx.cmd",
		filepath.Join("node_modules", "npm", "bin", "npm-cli.js"),
		filepath.Join("node_modules", "npm", "bin", "npx-cli.js"),
	} {
		if info, err := os.Stat(filepath.Join(directory, name)); err != nil || info.IsDir() {
			return false
		}
	}
	return verifyHelperNode(filepath.Join(directory, "node.exe"))
}

// installHelperNodeRuntime 对应蓝本 Install-HelperNodeRuntime：哈希校验 → 解压到暂存 →
// 完整性验证 → 越界检查 → 原子换目录。返回（node.exe 路径, 本次是否安装）。
func installHelperNodeRuntime(managerHome, archivePath string) (string, bool, error) {
	nodeParent := filepath.Join(managerHome, "runtimes", "node")
	nodeDir := filepath.Join(nodeParent, helperNodeVersion)
	if helperNodeToolsOK(nodeDir) {
		return filepath.Join(nodeDir, "node.exe"), false, nil
	}
	if info, err := os.Stat(archivePath); err != nil || info.IsDir() {
		return "", false, errors.New("缺少内置 Node 运行时，请重新安装完整的 Helper。")
	}
	sum, err := fileSha256(archivePath)
	if err != nil {
		return "", false, err
	}
	if sum != helperNodeSha256 {
		return "", false, errors.New("内置 Node 运行时校验失败，请重新安装 Helper。")
	}
	if err := os.MkdirAll(nodeParent, 0o700); err != nil {
		return "", false, err
	}
	stage := filepath.Join(nodeParent, ".prepare-"+randomID())
	remove := func() {
		if target, relErr := filepath.Rel(nodeParent, stage); relErr == nil && !strings.HasPrefix(target, "..") {
			os.RemoveAll(stage)
		}
	}
	if err := extractZip(archivePath, stage); err != nil {
		remove()
		return "", false, err
	}
	if !helperNodeToolsOK(stage) {
		remove()
		return "", false, errors.New("内置 Node/npm/npx 运行时不完整或无法运行。")
	}
	// 越界防护（蓝本同款语义）：所有删除目标必须落在受管运行时目录内
	if !strings.HasPrefix(strings.ToLower(nodeDir+string(os.PathSeparator)), strings.ToLower(nodeParent+string(os.PathSeparator))) {
		remove()
		return "", false, errors.New("运行时目录越界。")
	}
	if info, err := os.Stat(nodeDir); err == nil && info.IsDir() {
		if err := os.RemoveAll(nodeDir); err != nil {
			remove()
			return "", false, err
		}
	}
	if err := renameWithRetry(stage, nodeDir); err != nil {
		remove()
		return "", false, err
	}
	return filepath.Join(nodeDir, "node.exe"), true, nil
}

// extractZip 解压 zip 到 target，含路径穿越防护（zip-slip）与总量上限
func extractZip(archivePath, target string) error {
	reader, err := zip.OpenReader(archivePath)
	if err != nil {
		return err
	}
	defer reader.Close()
	if err := os.MkdirAll(target, 0o700); err != nil {
		return err
	}
	prefix := target + string(os.PathSeparator)
	var total int64
	for _, file := range reader.File {
		dest := filepath.Join(target, filepath.FromSlash(file.Name))
		if dest != target && !strings.HasPrefix(dest, prefix) {
			return fmt.Errorf("压缩包内路径越界：%s", file.Name)
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(dest, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return err
		}
		src, err := file.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			src.Close()
			return err
		}
		// total 上限对齐包校验口径（maxUnpacked），单文件超限视为损坏
		if total += int64(file.UncompressedSize64); total > maxUnpacked {
			src.Close()
			out.Close()
			return errors.New("内置运行时解压总量超限，压缩包疑似损坏。")
		}
		_, copyErr := io.Copy(out, src)
		closeErr := out.Close()
		src.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func fileSha256(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

// getUserEnv 对应蓝本 Get-HelperUserEnvironment：读 HKCU\Environment，值不做环境变量展开
func getUserEnv(name string) (string, uint32, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, `Environment`, registry.QUERY_VALUE)
	if err != nil {
		return "", registry.SZ, nil // 键不存在视同未设置（蓝本行为）
	}
	defer key.Close()
	value, kind, err := key.GetStringValue(name)
	if err != nil {
		if err == registry.ErrNotExist {
			return "", registry.SZ, nil
		}
		return "", registry.SZ, err
	}
	return value, uint32(kind), nil
}

// setUserEnv 对应蓝本 Set-HelperUserEnvironment：保留原值类型（EXPAND_SZ 值可能含 %VAR% 引用）
func setUserEnv(name, value string, kind uint32) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, `Environment`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if kind == uint32(registry.EXPAND_SZ) {
		return key.SetExpandStringValue(name, value)
	}
	return key.SetStringValue(name, value)
}

// setNpxEnvironment 对应蓝本 Set-HelperNpxEnvironment：写全局 npm rc（无 BOM）+ 用户级
// NPM_CONFIG_USERCONFIG + 用户 Path 前置受管目录 + 广播环境变更。
// rc 直接截断重写（蓝本 WriteAllText 语义）：文件极小且非数据态，原子性收益为零。
func setNpxEnvironment(managerHome, nodeDirectory string) error {
	if err := os.MkdirAll(managerHome, 0o700); err != nil {
		return err
	}
	configPath := filepath.Join(managerHome, "npm-workbuddy.rc")
	previous, _, err := getUserEnv("NPM_CONFIG_USERCONFIG")
	if err != nil {
		return err
	}
	if previous == "" {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			home = "."
		}
		previous = filepath.Join(home, ".npmrc")
	}
	var previousLines []string
	if data, readErr := os.ReadFile(previous); readErr == nil {
		previousLines = strings.Split(strings.TrimPrefix(string(data), "\xEF\xBB\xBF"), "\r\n")
	}
	if err := os.WriteFile(configPath, []byte(npmWorkbuddyRcContent(previousLines)), 0o600); err != nil {
		return err
	}
	if err := setUserEnv("NPM_CONFIG_USERCONFIG", configPath, uint32(registry.SZ)); err != nil {
		return err
	}
	pathValue, pathKind, err := getUserEnv("Path")
	if err != nil {
		return err
	}
	if updated := addUserPathEntry(pathValue, nodeDirectory); updated != pathValue {
		if err := setUserEnv("Path", updated, pathKind); err != nil {
			return err
		}
	}
	// 协议处理器继承的是浏览器的旧环境：当前进程同样刷新，保证下一个 WorkBuddy 安装器能用上 node/npx
	os.Setenv("Path", addUserPathEntry(os.Getenv("Path"), nodeDirectory))
	os.Setenv("NPM_CONFIG_USERCONFIG", configPath)
	broadcastEnvironmentChange()
	return nil
}

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	procSendMessageTimeoutW = user32.NewProc("SendMessageTimeoutW")
)

// broadcastEnvironmentChange 对应蓝本 Send-HelperEnvironmentChange：WM_SETTINGCHANGE 广播，
// 让资源管理器等进程刷新环境变量（协议唤起新进程才能拿到新 Path）
func broadcastEnvironmentChange() {
	const (
		hwndBroadcast   = 0xffff
		wmSettingChange = 0x001A
		smtoAbortIfHung = 0x0002
		timeoutMs       = 5000
	)
	param, err := windows.UTF16PtrFromString("Environment")
	if err != nil {
		return
	}
	procSendMessageTimeoutW.Call(
		uintptr(hwndBroadcast), uintptr(wmSettingChange), 0,
		uintptr(unsafe.Pointer(param)), uintptr(smtoAbortIfHung), uintptr(timeoutMs), 0)
}
