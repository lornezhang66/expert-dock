package main

// 环境层：受管 Node 运行时 + 全局 npm 配置。移植自 docs/legacy-windows-helper/helper-env.ps1
// （原始出处 gbc-expert-manager）。目的：MCP server 的 npx 依赖不赌用户机器上的 Node 状态——
// 即使系统 Node 可用也照样安装受管运行时：后续 WorkBuddy 市场更新需要一个确定的 npm/npx 运行时。
// 本文件只放跨平台的纯逻辑与常量；Windows 特有部分在 env_windows.go，其余平台在 env_other.go。

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	helperNodeVersion = "22.22.2"
	helperNodeMinimum = 20
	// node-runtime-win-x64.zip 发布随包内置的 SHA-256（发布链固化，防分发链篡改）
	helperNodeSha256   = "65b064aec5a84388d356225c49f1fcc96e684f0c9a46168296cf78598a90f89a"
	helperNpmAuthKey   = "//nvwa.jiuqi.com.cn/nexus/repository/npm-gov-group/:_auth"
	helperNpmAuthValue = "Z292Z3Vlc3Q6ZnZvVU16VDdyaVNl" // 内网 nexus 只读凭据（与蓝本一致，非机密）
)

var (
	npmAuthLineRe    = regexp.MustCompile(`^\s*` + regexp.QuoteMeta(helperNpmAuthKey) + `\s*=`)
	alwaysAuthLineRe = regexp.MustCompile(`^\s*always-auth\s*=`)
	nodeVersionRe    = regexp.MustCompile(`^v(\d+)\.`)
)

func helperManagerHome() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".workbuddy", "expert-manager")
}

// 内置 Node 压缩包与 Helper 同目录分发（对齐蓝本 PSScriptRoot 约定）
func helperNodeArchivePath() string {
	exe, err := os.Executable()
	if err != nil {
		return "node-runtime-win-x64.zip"
	}
	return filepath.Join(filepath.Dir(exe), "node-runtime-win-x64.zip")
}

// npmWorkbuddyRcContent 对应蓝本 Set-HelperNpxEnvironment 的 rc 合成：
// 固定头两行（always-auth + 内网只读认证）+ 既有 npmrc 其余行（剔除旧 auth 行与 always-auth 行）。
// CRLF 行尾与蓝本逐字节同构，便于 diff 验证。
func npmWorkbuddyRcContent(previousLines []string) string {
	extra := make([]string, 0, len(previousLines))
	for _, line := range previousLines {
		if npmAuthLineRe.MatchString(line) || alwaysAuthLineRe.MatchString(line) {
			continue
		}
		extra = append(extra, line)
	}
	return "always-auth=true\r\n" + helperNpmAuthKey + "=" + helperNpmAuthValue + "\r\n" + strings.Join(extra, "\r\n")
}

// addUserPathEntry 对应蓝本 Add-HelperNodePath：逐段去重（引号/尾分隔符/大小写不敏感）；
// 已存在则原样返回；当前值空 → directory；否则新目录前置（受管运行时优先于系统 PATH）
func addUserPathEntry(current, directory string) string {
	separator := ";"
	if os.PathSeparator == '/' {
		separator = ":"
	}
	target := strings.TrimRight(directory, separator)
	for _, entry := range strings.Split(current, separator) {
		norm := strings.TrimRight(strings.Trim(strings.TrimSpace(entry), `"`), separator)
		if norm != "" && strings.EqualFold(norm, target) {
			return current
		}
	}
	if strings.TrimSpace(current) == "" {
		return directory
	}
	return directory + separator + current
}

// nodeMajorOK 对应蓝本 Test-HelperNode 的版本判定：^v(\d+)\. 且主版本达标
func nodeMajorOK(versionOutput string, minimum int) bool {
	m := nodeVersionRe.FindStringSubmatch(strings.TrimSpace(versionOutput))
	if m == nil {
		return false
	}
	major, err := strconv.Atoi(m[1])
	return err == nil && major >= minimum
}

// verifyHelperNode 执行 node --version（5 秒超时），返回版本是否达标（跨平台）
func verifyHelperNode(path string) bool {
	if path == "" {
		return false
	}
	if info, err := os.Stat(path); err != nil || info.IsDir() {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "--version").Output()
	if err != nil {
		return false
	}
	return nodeMajorOK(string(out), helperNodeMinimum)
}
