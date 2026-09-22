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

var apiBase = "https://expert-dock.workers.dev"

const (
	maxDownload = 20 << 20
	maxUnpacked = 100 << 20
	maxFiles    = 1000
)

type metadata struct {
	Name        string `json:"name"`
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
	if base := os.Getenv("EXPERTDOCK_API_BASE"); base != "" {
		apiBase = strings.TrimRight(base, "/")
	}
	if len(os.Args) == 2 && os.Args[1] == "--install-protocol" {
		fatal(registerProtocol())
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
	if err := install(rawURL); err != nil {
		notify("ExpertDock 安装失败", err.Error())
		os.Exit(1)
	}
	notify("ExpertDock", "专家安装成功。请重启或刷新 WorkBuddy。")
}

func install(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme != "expertdock" || u.Host != "install" {
		return errors.New("无效的 ExpertDock 安装链接")
	}
	token := u.Query().Get("token")
	if len(token) < 20 || len(token) > 128 || strings.ContainsAny(token, "/\\") {
		return errors.New("无效的分享 Token")
	}

	workBuddy, pluginDir, registerScript, err := scanWorkBuddy()
	if err != nil {
		return err
	}
	_ = workBuddy

	meta, err := fetchMetadata(token)
	if err != nil {
		return err
	}
	if !validName(meta.Name) || meta.Size < 1 || meta.Size > maxDownload {
		return errors.New("服务端返回了无效的专家元数据")
	}

	zipPath, err := download(meta)
	if err != nil {
		return err
	}
	defer os.Remove(zipPath)

	stage := filepath.Join(pluginDir, ".expertdock-tmp-"+randomID())
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return fmt.Errorf("创建临时目录：%w", err)
	}
	defer os.RemoveAll(stage)
	if err := extractAndValidate(zipPath, stage, meta); err != nil {
		return err
	}

	target := filepath.Join(pluginDir, meta.Name)
	backup := ""
	if _, err := os.Stat(target); err == nil {
		backupDir := filepath.Join(filepath.Dir(pluginDir), ".expertdock-backups")
		if err := os.MkdirAll(backupDir, 0o700); err != nil {
			return fmt.Errorf("创建备份目录：%w", err)
		}
		backup = filepath.Join(backupDir, meta.Name+"-"+time.Now().Format("20060102-150405"))
		if err := os.Rename(target, backup); err != nil {
			return fmt.Errorf("备份旧版本：%w", err)
		}
	}

	if err := os.Rename(stage, target); err != nil {
		restore(target, backup)
		return fmt.Errorf("安装专家文件：%w", err)
	}
	if err := runRegistration(registerScript, target); err != nil {
		restore(target, backup)
		return fmt.Errorf("WorkBuddy 注册失败，已回滚：%w", err)
	}
	if backup != "" {
		_ = os.RemoveAll(backup)
	}
	return nil
}

func scanWorkBuddy() (root, pluginDir, registerScript string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", fmt.Errorf("读取用户目录：%w", err)
	}
	candidate := filepath.Join(home, ".workbuddy")
	if !isDir(candidate) || !isDir(filepath.Join(candidate, "plugins")) || (!exists(filepath.Join(candidate, "workbuddy.db")) && !isDir(filepath.Join(candidate, "app"))) {
		return "", "", "", errors.New("无法可靠识别 WorkBuddy 用户目录；未写入任何文件")
	}
	realHome, _ := filepath.EvalSymlinks(home)
	realRoot, err := filepath.EvalSymlinks(candidate)
	if err != nil || (realRoot != realHome && !strings.HasPrefix(realRoot, realHome+string(os.PathSeparator))) {
		return "", "", "", errors.New("WorkBuddy 用户目录路径不可信；未写入任何文件")
	}

	scripts := registerScriptCandidates(home)
	found := make([]string, 0, 1)
	for _, path := range scripts {
		if exists(path) {
			found = append(found, path)
		}
	}
	if len(found) != 1 {
		return "", "", "", fmt.Errorf("需要唯一的 WorkBuddy 注册工具，实际找到 %d 个；未写入任何文件", len(found))
	}

	plugins := filepath.Join(realRoot, "plugins", "marketplaces", "my-experts", "plugins")
	if err := os.MkdirAll(plugins, 0o700); err != nil {
		return "", "", "", fmt.Errorf("创建私域专家目录：%w", err)
	}
	return realRoot, plugins, found[0], nil
}

func registerScriptCandidates(home string) []string {
	rel := filepath.FromSlash("resources/app.asar.unpacked/resources/plugins/workbuddy-builtin/skills/expert-manager/scripts/register_expert.py")
	switch runtime.GOOS {
	case "darwin":
		appRel := filepath.FromSlash("Contents/Resources/app.asar.unpacked/resources/plugins/workbuddy-builtin/skills/expert-manager/scripts/register_expert.py")
		return []string{filepath.Join("/Applications/WorkBuddy.app", appRel), filepath.Join(home, "Applications/WorkBuddy.app", appRel)}
	case "windows":
		var out []string
		for _, base := range []string{os.Getenv("LOCALAPPDATA"), os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)")} {
			if base != "" {
				out = append(out, filepath.Join(base, "Programs", "WorkBuddy", rel), filepath.Join(base, "WorkBuddy", rel))
			}
		}
		return out
	default:
		return []string{filepath.Join(home, ".local", "share", "WorkBuddy", rel), filepath.Join("/opt/WorkBuddy", rel)}
	}
}

func fetchMetadata(token string) (metadata, error) {
	var result metadata
	endpoint := apiBase + "/api/helper/install/" + url.PathEscape(token)
	response, err := httpClient().Get(endpoint)
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
	response, err := httpClient().Get(meta.DownloadURL)
	if err != nil {
		return "", fmt.Errorf("下载专家包：%w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("下载专家包失败：HTTP %d", response.StatusCode)
	}
	file, err := os.CreateTemp("", "expertdock-*.zip")
	if err != nil {
		return "", err
	}
	path := file.Name()
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, maxDownload+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written > maxDownload || written != meta.Size {
		os.Remove(path)
		return "", errors.New("专家包下载不完整或超过大小限制")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), meta.SHA256) {
		os.Remove(path)
		return "", errors.New("专家包 SHA-256 校验失败")
	}
	return path, nil
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
		dst, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
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

func runRegistration(script, expertDir string) error {
	commands := [][]string{{"python3", script, expertDir}, {"python", script, expertDir}}
	if runtime.GOOS == "windows" {
		commands = [][]string{{"py", "-3", script, expertDir}, {"python", script, expertDir}}
	}
	var last error
	for _, args := range commands {
		if _, err := exec.LookPath(args[0]); err != nil {
			last = err
			continue
		}
		output, err := exec.Command(args[0], args[1:]...).CombinedOutput()
		if err == nil {
			return nil
		}
		last = fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
	}
	return last
}

func restore(target, backup string) {
	_ = os.RemoveAll(target)
	if backup != "" {
		_ = os.Rename(backup, target)
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
