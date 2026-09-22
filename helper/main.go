package main

import (
	"archive/zip"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var (
	apiBase       = "https://expert-dock.18660190869.workers.dev"
	helperVersion = "0.2.0"
)

const (
	maxDownload = 20 << 20
	maxUnpacked = 100 << 20
	maxFiles    = 1000
)

type metadata struct {
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
	Type        string `json:"type"`
	Version     string `json:"version"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
	DownloadURL string `json:"downloadUrl"`
	Error       string `json:"error"`
}

type manifest struct {
	Name       string `json:"name"`
	Version    string `json:"version"`
	ExpertType string `json:"expertType"`
}

func main() {
	if cleanup := os.Getenv("EXPERTDOCK_CLEANUP_DIR"); cleanup != "" {
		for attempt := 0; attempt < 20 && exists(cleanup); attempt++ {
			_ = os.RemoveAll(cleanup)
			if exists(cleanup) {
				time.Sleep(250 * time.Millisecond)
			}
		}
	}
	if base := os.Getenv("EXPERTDOCK_API_BASE"); base != "" {
		apiBase = strings.TrimRight(base, "/")
	}
	if len(os.Args) == 2 && os.Args[1] == "--install-protocol" {
		fatal(registerProtocol())
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "--replace" {
		fatal(replaceExecutable(os.Args[2], os.Args[3]))
		return
	}
	var rawURL string
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "expertdock://") {
			rawURL = arg
			break
		}
	}
	if rawURL == "" {
		fatal(errors.New("用法：expertdock-helper expertdock://install?token=..."))
		return
	}
	message, err := install(rawURL)
	if err != nil {
		notify("ExpertDock 安装失败", err.Error())
		os.Exit(1)
	}
	if message != "" {
		notify("ExpertDock", message)
	}
}

func install(rawURL string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme != "expertdock" || u.Host != "install" {
		return "", errors.New("无效的 ExpertDock 安装链接")
	}
	token := u.Query().Get("token")
	if len(token) < 20 || len(token) > 128 || strings.ContainsAny(token, "/\\") {
		return "", errors.New("无效的分享 Token")
	}

	if u.Query().Get("skip_update") != "1" {
		if updated, updateErr := maybeSelfUpdate(rawURL); updateErr != nil {
			fmt.Printf("ExpertDock 自动升级检查跳过：%v\n", updateErr)
		} else if updated {
			return "", nil
		}
	}

	workBuddy, pluginDir, err := scanWorkBuddy()
	if err != nil {
		return "", err
	}
	releaseLock, err := acquireInstallLock(workBuddy)
	if err != nil {
		return "", err
	}
	defer releaseLock()

	meta, err := fetchMetadata(token)
	if err != nil {
		return "", err
	}
	if !validName(meta.Name) || meta.Size < 1 || meta.Size > maxDownload {
		return "", errors.New("服务端返回了无效的专家元数据")
	}
	if meta.DisplayName == "" {
		meta.DisplayName = meta.Name
	}
	target := filepath.Join(pluginDir, meta.Name)
	if installationHealthy(workBuddy, target, meta) {
		return fmt.Sprintf("%s（%s）已经安装且检查正常，无需重复操作。", meta.DisplayName, meta.Version), nil
	}

	zipPath, err := download(meta)
	if err != nil {
		return "", err
	}
	defer os.Remove(zipPath)

	stage := filepath.Join(pluginDir, ".expertdock-tmp-"+randomID())
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return "", fmt.Errorf("创建临时目录：%w", err)
	}
	defer os.RemoveAll(stage)
	if err := extractAndValidate(zipPath, stage, meta); err != nil {
		return "", err
	}
	backup := ""
	if _, err := os.Stat(target); err == nil {
		backupDir := filepath.Join(filepath.Dir(pluginDir), ".expertdock-backups")
		if err := os.MkdirAll(backupDir, 0o700); err != nil {
			return "", fmt.Errorf("创建备份目录：%w", err)
		}
		backup = filepath.Join(backupDir, meta.Name+"-"+time.Now().Format("20060102-150405")+"-"+randomID())
		if err := renameWithRetry(target, backup); err != nil {
			return "", fmt.Errorf("备份旧版本：%w", err)
		}
	}

	if err := renameWithRetry(stage, target); err != nil {
		restore(target, backup)
		return "", fmt.Errorf("安装专家文件：%w", err)
	}
	if err := registerLocalPlugin(workBuddy, target, meta); err != nil {
		restore(target, backup)
		return "", fmt.Errorf("WorkBuddy 注册失败，已回滚：%w", err)
	}
	if backup != "" {
		_ = os.RemoveAll(backup)
	}
	return fmt.Sprintf("%s（%s）安装并检查完成。请重启或刷新 WorkBuddy。", meta.DisplayName, meta.Version), nil
}

func scanWorkBuddy() (root, pluginDir string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", fmt.Errorf("读取用户目录：%w", err)
	}
	candidate := filepath.Join(home, ".workbuddy")
	if !isDir(candidate) || !isDir(filepath.Join(candidate, "plugins")) || (!exists(filepath.Join(candidate, "workbuddy.db")) && !isDir(filepath.Join(candidate, "app"))) {
		return "", "", errors.New("无法可靠识别 WorkBuddy 用户目录；未写入任何文件")
	}
	realHome, _ := filepath.EvalSymlinks(home)
	realRoot, err := filepath.EvalSymlinks(candidate)
	if err != nil || (realRoot != realHome && !strings.HasPrefix(realRoot, realHome+string(os.PathSeparator))) {
		return "", "", errors.New("WorkBuddy 用户目录路径不可信；未写入任何文件")
	}
	plugins := filepath.Join(realRoot, "plugins", "marketplaces", "my-experts", "plugins")
	if err := os.MkdirAll(plugins, 0o700); err != nil {
		return "", "", fmt.Errorf("创建私域专家目录：%w", err)
	}
	return realRoot, plugins, nil
}

type fileSnapshot struct {
	path    string
	data    []byte
	mode    os.FileMode
	existed bool
}

func acquireInstallLock(workBuddy string) (func(), error) {
	lock := filepath.Join(workBuddy, ".expertdock-install.lock")
	for attempt := 0; attempt < 2; attempt++ {
		if err := os.Mkdir(lock, 0o700); err == nil {
			_ = os.WriteFile(filepath.Join(lock, "owner"), []byte(fmt.Sprintf("pid=%d\ntime=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339))), 0o600)
			return func() { _ = os.RemoveAll(lock) }, nil
		} else if !os.IsExist(err) {
			return nil, fmt.Errorf("创建安装锁：%w", err)
		}
		info, statErr := os.Stat(lock)
		if statErr == nil && time.Since(info.ModTime()) > 10*time.Minute {
			if removeErr := os.RemoveAll(lock); removeErr == nil {
				continue
			}
		}
		return nil, errors.New("另一个 ExpertDock 安装正在进行；如十分钟后仍出现此提示，请重启 Helper")
	}
	return nil, errors.New("无法获取 ExpertDock 安装锁")
}

func registerLocalPlugin(workBuddy, sourceDir string, meta metadata) (err error) {
	marketplaceRoot := filepath.Join(workBuddy, "plugins", "marketplaces", "my-experts")
	marketplaceFile := filepath.Join(marketplaceRoot, ".codebuddy-plugin", "marketplace.json")
	registryFile := filepath.Join(workBuddy, "plugins", "installed_plugins.json")
	settingsFile := filepath.Join(workBuddy, "settings.json")
	files, err := takeSnapshots(marketplaceFile, registryFile, settingsFile)
	if err != nil {
		return err
	}

	cacheRoot := filepath.Join(workBuddy, "plugins", "cache", "my-experts", meta.Name)
	cacheTarget := filepath.Join(cacheRoot, meta.Version)
	cacheStage := filepath.Join(cacheRoot, ".staging-"+randomID())
	cacheBackup := filepath.Join(cacheRoot, ".backup-"+randomID())
	backupExists := false
	cacheTouched := false
	committed := false
	defer func() {
		_ = os.RemoveAll(cacheStage)
		if committed {
			_ = os.RemoveAll(cacheBackup)
			return
		}
		if cacheTouched {
			_ = os.RemoveAll(cacheTarget)
			if backupExists {
				_ = renameWithRetry(cacheBackup, cacheTarget)
			}
		}
		_ = restoreSnapshots(files)
	}()

	if err := updateMarketplaceManifest(marketplaceFile, meta); err != nil {
		return err
	}
	if err := copyTree(sourceDir, cacheStage); err != nil {
		return fmt.Errorf("创建插件缓存：%w", err)
	}
	if err := validateInstalledManifest(cacheStage, meta); err != nil {
		return err
	}
	if exists(cacheTarget) {
		if err := renameWithRetry(cacheTarget, cacheBackup); err != nil {
			return fmt.Errorf("备份旧缓存：%w", err)
		}
		backupExists = true
		cacheTouched = true
	}
	if err := renameWithRetry(cacheStage, cacheTarget); err != nil {
		return fmt.Errorf("发布插件缓存：%w", err)
	}
	cacheTouched = true
	if err := updateInstalledRegistry(registryFile, meta, cacheTarget); err != nil {
		return err
	}
	if err := updateEnabledPlugins(settingsFile, meta.Name); err != nil {
		return err
	}
	if err := verifyRegistration(marketplaceFile, registryFile, settingsFile, cacheTarget, meta); err != nil {
		return err
	}
	committed = true
	return nil
}

func takeSnapshots(paths ...string) ([]fileSnapshot, error) {
	result := make([]fileSnapshot, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			result = append(result, fileSnapshot{path: path})
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("备份 %s：%w", path, err)
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		result = append(result, fileSnapshot{path: path, data: data, mode: info.Mode().Perm(), existed: true})
	}
	return result, nil
}

func restoreSnapshots(files []fileSnapshot) error {
	var first error
	for i := len(files) - 1; i >= 0; i-- {
		file := files[i]
		var err error
		if file.existed {
			err = writeFileAtomic(file.path, file.data, file.mode)
		} else {
			err = os.Remove(file.path)
			if os.IsNotExist(err) {
				err = nil
			}
		}
		if err != nil && first == nil {
			first = err
		}
	}
	return first
}

func readJSONObject(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil || value == nil {
		return nil, fmt.Errorf("%s 不是有效 JSON，请先修复，ExpertDock 未覆盖该文件", path)
	}
	return value, nil
}

func writeJSONAtomic(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeFileAtomic(path, data, 0o600)
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".expertdock-write-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err = temp.Write(data); err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Chmod(tempPath, mode); err != nil {
		return err
	}
	old := path + ".expertdock-replaced-" + randomID()
	hadOld := exists(path)
	if hadOld {
		if err := renameWithRetry(path, old); err != nil {
			return err
		}
	}
	if err := renameWithRetry(tempPath, path); err != nil {
		if hadOld {
			_ = renameWithRetry(old, path)
		}
		return err
	}
	if hadOld {
		_ = os.Remove(old)
	}
	return nil
}

func updateMarketplaceManifest(path string, meta metadata) error {
	manifest, err := readJSONObject(path)
	if err != nil {
		return err
	}
	if _, ok := manifest["name"]; !ok {
		manifest["name"] = "my-experts"
	}
	if _, ok := manifest["description"]; !ok {
		manifest["description"] = "my-experts marketplace (managed by ExpertDock)"
	}
	plugins, ok := manifest["plugins"].([]any)
	if manifest["plugins"] != nil && !ok {
		return errors.New("my-experts marketplace.json 的 plugins 必须是数组")
	}
	entry := map[string]any{"name": meta.Name, "source": "./plugins/" + meta.Name, "description": meta.Name + " installed by ExpertDock"}
	replaced := false
	for i, raw := range plugins {
		plugin, _ := raw.(map[string]any)
		if plugin != nil && (plugin["name"] == meta.Name || plugin["source"] == "./plugins/"+meta.Name) {
			plugins[i] = entry
			replaced = true
			break
		}
	}
	if !replaced {
		plugins = append(plugins, entry)
	}
	manifest["plugins"] = plugins
	return writeJSONAtomic(path, manifest)
}

func updateInstalledRegistry(path string, meta metadata, installPath string) error {
	registry, err := readJSONObject(path)
	if err != nil {
		return err
	}
	if _, ok := registry["version"]; !ok {
		registry["version"] = 2
	}
	plugins, ok := registry["plugins"].(map[string]any)
	if registry["plugins"] != nil && !ok {
		return errors.New("installed_plugins.json 的 plugins 必须是对象")
	}
	if plugins == nil {
		plugins = map[string]any{}
	}
	id := meta.Name + "@my-experts"
	records, ok := plugins[id].([]any)
	if plugins[id] != nil && !ok {
		return fmt.Errorf("installed_plugins.json 中 %s 必须是数组", id)
	}
	next := make([]any, 0, len(records)+1)
	installedAt := time.Now().UTC().Format(time.RFC3339)
	for _, raw := range records {
		record, _ := raw.(map[string]any)
		if record != nil && record["scope"] == "user" {
			if value, ok := record["installedAt"].(string); ok && value != "" {
				installedAt = value
			}
			continue
		}
		next = append(next, raw)
	}
	next = append(next, map[string]any{
		"scope": "user", "installPath": installPath, "version": meta.Version,
		"installedAt": installedAt, "lastUpdated": time.Now().UTC().Format(time.RFC3339),
	})
	plugins[id] = next
	registry["plugins"] = plugins
	return writeJSONAtomic(path, registry)
}

func updateEnabledPlugins(path, name string) error {
	settings, err := readJSONObject(path)
	if err != nil {
		return err
	}
	enabled, ok := settings["enabledPlugins"].(map[string]any)
	if settings["enabledPlugins"] != nil && !ok {
		return errors.New("settings.json 的 enabledPlugins 必须是对象")
	}
	if enabled == nil {
		enabled = map[string]any{}
	}
	enabled[name+"@my-experts"] = true
	settings["enabledPlugins"] = enabled
	return writeJSONAtomic(path, settings)
}

func verifyRegistration(marketplaceFile, registryFile, settingsFile, cacheTarget string, meta metadata) error {
	if err := validateInstalledManifest(cacheTarget, meta); err != nil {
		return fmt.Errorf("缓存回读校验失败：%w", err)
	}
	marketplace, err := readJSONObject(marketplaceFile)
	if err != nil {
		return err
	}
	found := false
	if plugins, ok := marketplace["plugins"].([]any); ok {
		for _, raw := range plugins {
			plugin, _ := raw.(map[string]any)
			if plugin != nil && plugin["name"] == meta.Name && plugin["source"] == "./plugins/"+meta.Name {
				found = true
			}
		}
	}
	if !found {
		return errors.New("市场清单回读校验失败")
	}
	registry, err := readJSONObject(registryFile)
	if err != nil {
		return err
	}
	plugins, _ := registry["plugins"].(map[string]any)
	records, ok := plugins[meta.Name+"@my-experts"].([]any)
	registered := false
	if ok {
		for _, raw := range records {
			record, _ := raw.(map[string]any)
			if record != nil && record["scope"] == "user" && record["version"] == meta.Version && record["installPath"] == cacheTarget {
				registered = true
			}
		}
	}
	if !registered {
		return errors.New("安装登记表回读校验失败")
	}
	settings, err := readJSONObject(settingsFile)
	if err != nil {
		return err
	}
	enabled, _ := settings["enabledPlugins"].(map[string]any)
	if enabled[meta.Name+"@my-experts"] != true {
		return errors.New("插件启用状态回读校验失败")
	}
	return nil
}

func validateInstalledManifest(root string, meta metadata) error {
	data, err := os.ReadFile(filepath.Join(root, ".codebuddy-plugin", "plugin.json"))
	if err != nil {
		return fmt.Errorf("读取已安装 plugin.json：%w", err)
	}
	var plugin manifest
	if err := json.Unmarshal(data, &plugin); err != nil || plugin.Name != meta.Name || plugin.Version != meta.Version {
		return errors.New("已安装 plugin.json 与下载元数据不一致")
	}
	return nil
}

func copyFile(source, target string, mode os.FileMode) error {
	src, err := os.Open(source)
	if err != nil {
		return err
	}
	defer src.Close()
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	dst, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(dst, src)
	if syncErr := dst.Sync(); copyErr == nil {
		copyErr = syncErr
	}
	if closeErr := dst.Close(); copyErr == nil {
		copyErr = closeErr
	}
	return copyErr
}

func copyTree(source, target string) error {
	return filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(target, rel)
		if entry.IsDir() {
			return os.MkdirAll(destination, 0o700)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("不支持的文件类型：%s", rel)
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
			return err
		}
		src, err := os.Open(path)
		if err != nil {
			return err
		}
		dst, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
		if err != nil {
			src.Close()
			return err
		}
		_, copyErr := io.Copy(dst, src)
		if syncErr := dst.Sync(); copyErr == nil {
			copyErr = syncErr
		}
		src.Close()
		dst.Close()
		return copyErr
	})
}

func renameWithRetry(oldPath, newPath string) error {
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		err = os.Rename(oldPath, newPath)
		if err == nil {
			return nil
		}
		time.Sleep(time.Duration(attempt+1) * 100 * time.Millisecond)
	}
	return err
}

type helperUpdate struct {
	Version     string `json:"version"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
	DownloadURL string `json:"downloadUrl"`
}

func maybeSelfUpdate(rawURL string) (bool, error) {
	platform := ""
	switch runtime.GOOS {
	case "darwin":
		platform = "macos"
	case "windows":
		platform = "windows"
	default:
		return false, nil
	}
	response, err := getWithRetry(apiBase + "/api/helper/latest/" + platform)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false, fmt.Errorf("升级检查返回 HTTP %d", response.StatusCode)
	}
	var update helperUpdate
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&update); err != nil {
		return false, errors.New("升级信息无效")
	}
	if !versionGreater(update.Version, helperVersion) {
		return false, nil
	}
	if update.Size < 1 || update.Size > maxDownload || len(update.SHA256) != 64 {
		return false, errors.New("升级包元数据无效")
	}
	base, _ := url.Parse(apiBase)
	downloadURL, err := url.Parse(update.DownloadURL)
	if err != nil || downloadURL.Scheme != "https" || downloadURL.Host != base.Host {
		return false, errors.New("升级包地址不可信")
	}
	archive, err := downloadVerified(update.DownloadURL, update.SHA256, update.Size, "expertdock-update-*.zip")
	if err != nil {
		return false, fmt.Errorf("下载 Helper 升级包：%w", err)
	}
	defer os.Remove(archive)
	staging, err := os.MkdirTemp("", "expertdock-update-*")
	if err != nil {
		return false, err
	}
	if err := extractUpdateArchive(archive, staging); err != nil {
		os.RemoveAll(staging)
		return false, err
	}
	if runtime.GOOS == "windows" {
		newExecutable := filepath.Join(staging, "expertdock-helper.exe")
		if !exists(newExecutable) {
			os.RemoveAll(staging)
			return false, errors.New("Windows 升级包缺少 expertdock-helper.exe")
		}
		current, _ := os.Executable()
		command := exec.Command(newExecutable, "--replace", current, rawURL)
		if err := command.Start(); err != nil {
			os.RemoveAll(staging)
			return false, err
		}
		return true, nil
	}

	current, _ := os.Executable()
	appRoot := filepath.Dir(filepath.Dir(filepath.Dir(current)))
	if filepath.Ext(appRoot) != ".app" {
		os.RemoveAll(staging)
		return false, errors.New("当前 Helper 不是标准 macOS 应用包，跳过自动升级")
	}
	newApp := filepath.Join(staging, "ExpertDock Helper.app")
	if !isDir(newApp) {
		os.RemoveAll(staging)
		return false, errors.New("macOS 升级包缺少 ExpertDock Helper.app")
	}
	script, err := os.CreateTemp("", "expertdock-update-*.sh")
	if err != nil {
		os.RemoveAll(staging)
		return false, err
	}
	scriptText := `#!/bin/sh
sleep 2
old="$1"
new="$2"
url="$3"
retry="${url}&skip_update=1"
backup="${old}.expertdock-old"
rm -rf "$backup"
if ! mv "$old" "$backup"; then open "$retry"; rm -rf "$(dirname "$new")"; rm -f "$0"; exit 0; fi
if ! mv "$new" "$old"; then mv "$backup" "$old"; open "$retry"; rm -rf "$(dirname "$new")"; rm -f "$0"; exit 0; fi
rm -rf "$backup" "$(dirname "$new")"
open "$retry"
rm -f "$0"
`
	if _, err = script.WriteString(scriptText); err == nil {
		err = script.Close()
	} else {
		script.Close()
	}
	if err != nil {
		os.Remove(script.Name())
		os.RemoveAll(staging)
		return false, err
	}
	if err := os.Chmod(script.Name(), 0o700); err != nil {
		return false, err
	}
	if err := exec.Command("/bin/sh", script.Name(), appRoot, newApp, rawURL).Start(); err != nil {
		return false, err
	}
	return true, nil
}

func replaceExecutable(oldExecutable, rawURL string) error {
	current, err := os.Executable()
	if err != nil {
		return err
	}
	staged := oldExecutable + ".expertdock-new"
	backup := oldExecutable + ".expertdock-old"
	_ = os.Remove(staged)
	_ = os.Remove(backup)
	retryURL := rawURL + "&skip_update=1"
	if err := copyFile(current, staged, 0o700); err != nil {
		command := exec.Command(oldExecutable, retryURL)
		_ = command.Start()
		return nil
	}
	var renameErr error
	for attempt := 0; attempt < 40; attempt++ {
		renameErr = os.Rename(oldExecutable, backup)
		if renameErr == nil {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if renameErr != nil {
		command := exec.Command(oldExecutable, retryURL)
		_ = command.Start()
		return nil
	}
	if err := os.Rename(staged, oldExecutable); err != nil {
		_ = os.Rename(backup, oldExecutable)
		command := exec.Command(oldExecutable, retryURL)
		_ = command.Start()
		return nil
	}
	_ = os.Remove(backup)
	command := exec.Command(oldExecutable, retryURL)
	command.Env = append(os.Environ(), "EXPERTDOCK_CLEANUP_DIR="+filepath.Dir(current))
	return command.Start()
}

func extractUpdateArchive(archivePath, target string) error {
	archive, err := zip.OpenReader(archivePath)
	if err != nil {
		return errors.New("Helper 升级包不是有效 ZIP")
	}
	defer archive.Close()
	if len(archive.File) == 0 || len(archive.File) > maxFiles {
		return errors.New("Helper 升级包文件数量不合法")
	}
	var total uint64
	for _, file := range archive.File {
		name, err := safeZipPath(file.Name)
		if err != nil {
			return err
		}
		if file.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("Helper 升级包不允许符号链接：%s", name)
		}
		total += file.UncompressedSize64
		if total > maxUnpacked {
			return errors.New("Helper 升级包解压后超过 100 MB")
		}
		destination := filepath.Join(target, filepath.FromSlash(name))
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(destination, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
			return err
		}
		src, err := file.Open()
		if err != nil {
			return err
		}
		mode := file.Mode().Perm()
		if mode == 0 {
			mode = 0o600
		}
		dst, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			src.Close()
			return err
		}
		_, copyErr := io.Copy(dst, src)
		src.Close()
		dst.Close()
		if copyErr != nil {
			return copyErr
		}
	}
	return nil
}

func versionGreater(candidate, current string) bool {
	parse := func(value string) [3]int {
		var result [3]int
		value = strings.TrimPrefix(value, "v")
		_, _ = fmt.Sscanf(strings.SplitN(value, "-", 2)[0], "%d.%d.%d", &result[0], &result[1], &result[2])
		return result
	}
	a, b := parse(candidate), parse(current)
	for i := 0; i < 3; i++ {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

func installationHealthy(workBuddy, sourceDir string, meta metadata) bool {
	if validateInstalledManifest(sourceDir, meta) != nil {
		return false
	}
	marketplaceFile := filepath.Join(workBuddy, "plugins", "marketplaces", "my-experts", ".codebuddy-plugin", "marketplace.json")
	registryFile := filepath.Join(workBuddy, "plugins", "installed_plugins.json")
	settingsFile := filepath.Join(workBuddy, "settings.json")
	cacheTarget := filepath.Join(workBuddy, "plugins", "cache", "my-experts", meta.Name, meta.Version)
	return verifyRegistration(marketplaceFile, registryFile, settingsFile, cacheTarget, meta) == nil
}

func fetchMetadata(token string) (metadata, error) {
	var result metadata
	endpoint := apiBase + "/api/helper/install/" + url.PathEscape(token)
	response, err := getWithRetry(endpoint)
	if err != nil {
		return result, fmt.Errorf("获取专家信息：%w", err)
	}
	defer response.Body.Close()
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&result); err != nil {
		return result, errors.New("服务端返回无效响应")
	}
	if response.StatusCode != http.StatusOK {
		if result.Error != "" {
			return result, errors.New(result.Error)
		}
		return result, fmt.Errorf("获取专家信息失败：HTTP %d", response.StatusCode)
	}
	base, _ := url.Parse(apiBase)
	download, err := url.Parse(result.DownloadURL)
	if err != nil || download.Scheme != "https" || download.Host != base.Host {
		return result, errors.New("下载地址不可信")
	}
	return result, nil
}

func download(meta metadata) (string, error) {
	path, err := downloadVerified(meta.DownloadURL, meta.SHA256, meta.Size, "expertdock-*.zip")
	if err != nil {
		return "", fmt.Errorf("下载专家包：%w", err)
	}
	return path, nil
}

func downloadVerified(downloadURL, expectedHash string, expectedSize int64, pattern string) (string, error) {
	response, err := getWithRetry(downloadURL)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", response.StatusCode)
	}
	file, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", err
	}
	path := file.Name()
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, maxDownload+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written > maxDownload || written != expectedSize {
		os.Remove(path)
		return "", errors.New("下载不完整或超过大小限制")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expectedHash) {
		os.Remove(path)
		return "", errors.New("SHA-256 校验失败")
	}
	return path, nil
}

func getWithRetry(endpoint string) (*http.Response, error) {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		response, err := httpClient().Get(endpoint)
		if err == nil && response.StatusCode != http.StatusTooManyRequests && response.StatusCode < 500 {
			return response, nil
		}
		if response != nil {
			io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			response.Body.Close()
			last = fmt.Errorf("HTTP %d", response.StatusCode)
		} else {
			last = err
		}
		time.Sleep(time.Duration(attempt+1) * 500 * time.Millisecond)
	}
	return nil, last
}

func extractAndValidate(zipPath, stage string, meta metadata) error {
	archive, err := zip.OpenReader(zipPath)
	if err != nil {
		return errors.New("专家包不是有效 ZIP")
	}
	defer archive.Close()
	if len(archive.File) == 0 || len(archive.File) > maxFiles {
		return errors.New("专家包文件数量不合法")
	}
	manifestPath := ""
	var total uint64
	for _, file := range archive.File {
		name, err := safeZipPath(file.Name)
		if err != nil {
			return err
		}
		if file.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("专家包不允许符号链接：%s", name)
		}
		total += file.UncompressedSize64
		if total > maxUnpacked {
			return errors.New("专家包解压后超过 100 MB")
		}
		if name == ".codebuddy-plugin/plugin.json" || strings.HasSuffix(name, "/.codebuddy-plugin/plugin.json") {
			if manifestPath != "" {
				return errors.New("专家包包含多个 plugin.json")
			}
			manifestPath = name
		}
	}
	if manifestPath == "" {
		return errors.New("专家包缺少 .codebuddy-plugin/plugin.json")
	}
	root := strings.TrimSuffix(manifestPath, ".codebuddy-plugin/plugin.json")
	root = strings.TrimSuffix(root, "/")
	for _, file := range archive.File {
		name, _ := safeZipPath(file.Name)
		rel := name
		if root != "" {
			prefix := root + "/"
			if name == root || !strings.HasPrefix(name, prefix) {
				return errors.New("专家包包含专家目录以外的文件")
			}
			rel = strings.TrimPrefix(name, prefix)
		}
		if rel == "" {
			continue
		}
		target := filepath.Join(stage, filepath.FromSlash(rel))
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		src, err := file.Open()
		if err != nil {
			return err
		}
		mode := file.Mode().Perm()
		if mode == 0 {
			mode = 0o600
		}
		dst, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			src.Close()
			return err
		}
		_, copyErr := io.Copy(dst, src)
		src.Close()
		dst.Close()
		if copyErr != nil {
			return copyErr
		}
	}
	data, err := os.ReadFile(filepath.Join(stage, ".codebuddy-plugin", "plugin.json"))
	if err != nil || len(data) > 1<<20 {
		return errors.New("无法读取 plugin.json")
	}
	var plugin manifest
	if json.Unmarshal(data, &plugin) != nil || plugin.Name != meta.Name || plugin.Version != meta.Version || !validName(plugin.Name) {
		return errors.New("plugin.json 与分享元数据不一致")
	}
	return nil
}

func safeZipPath(name string) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	clean := strings.TrimPrefix(name, "./")
	if clean == "" || strings.HasPrefix(clean, "/") || strings.Contains(clean, ":/") {
		return "", fmt.Errorf("ZIP 路径不安全：%s", name)
	}
	for _, part := range strings.Split(clean, "/") {
		if part == ".." {
			return "", fmt.Errorf("ZIP 路径不安全：%s", name)
		}
	}
	return clean, nil
}

func restore(target, backup string) {
	_ = os.RemoveAll(target)
	if backup != "" {
		_ = renameWithRetry(backup, target)
	}
}

func registerProtocol() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "windows":
		commands := [][]string{
			{"add", `HKCU\Software\Classes\expertdock`, "/ve", "/d", "URL:ExpertDock Protocol", "/f"},
			{"add", `HKCU\Software\Classes\expertdock`, "/v", "URL Protocol", "/d", "", "/f"},
			{"add", `HKCU\Software\Classes\expertdock\shell\open\command`, "/ve", "/d", fmt.Sprintf(`"%s" "%%1"`, exe), "/f"},
		}
		for _, args := range commands {
			if output, err := exec.Command("reg.exe", args...).CombinedOutput(); err != nil {
				return fmt.Errorf("注册协议：%w: %s", err, output)
			}
		}
	case "linux":
		home, _ := os.UserHomeDir()
		dir := filepath.Join(home, ".local", "share", "applications")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		content := fmt.Sprintf("[Desktop Entry]\nName=ExpertDock Helper\nExec=%s %%u\nType=Application\nNoDisplay=true\nMimeType=x-scheme-handler/expertdock;\n", exe)
		file := filepath.Join(dir, "expertdock-helper.desktop")
		if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
			return err
		}
		if output, err := exec.Command("xdg-mime", "default", "expertdock-helper.desktop", "x-scheme-handler/expertdock").CombinedOutput(); err != nil {
			return fmt.Errorf("注册协议：%w: %s", err, output)
		}
	case "darwin":
		return errors.New("macOS 请使用发布包中的 ExpertDock Helper.app；协议已由应用包注册")
	default:
		return errors.New("当前系统暂不支持")
	}
	notify("ExpertDock", "expertdock:// 协议注册成功。")
	return nil
}

func notify(title, message string) {
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("osascript", "-e", `on run argv`, "-e", `display dialog (item 2 of argv) with title (item 1 of argv) buttons {"好"} default button 1`, "-e", `end run`, "--", title, message).Run()
	case "windows":
		_ = exec.Command("msg.exe", "*", title+": "+message).Run()
	default:
		_ = exec.Command("zenity", "--info", "--title="+title, "--text="+message).Run()
	}
	fmt.Printf("%s: %s\n", title, message)
}

func httpClient() *http.Client { return &http.Client{Timeout: 60 * time.Second} }
func exists(path string) bool  { _, err := os.Stat(path); return err == nil }
func isDir(path string) bool   { info, err := os.Stat(path); return err == nil && info.IsDir() }
func validName(value string) bool {
	if len(value) < 2 || len(value) > 64 {
		return false
	}
	for i, char := range value {
		if !((char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || (char == '-' && i > 0)) {
			return false
		}
	}
	return !strings.HasSuffix(value, "-")
}
func randomID() string { b := make([]byte, 8); _, _ = rand.Read(b); return hex.EncodeToString(b) }
func fatal(err error) {
	if err != nil {
		notify("ExpertDock", err.Error())
		os.Exit(1)
	}
}
