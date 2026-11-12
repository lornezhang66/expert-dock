//go:build !windows

package main

import (
	"errors"
	"os/exec"
)

// macOS/其他平台首版环境层：只探测系统 Node。
// 蓝本 helper-env.ps1 本就只有 Windows 实现；受管运行时（macOS 版 tar.gz 分发）留待后续版本，
// 届时 MCP server 的 npx 依赖同样不能赌用户机器状态。
func prepareHelperEnvironment() error {
	node, err := exec.LookPath("node")
	if err != nil {
		return errors.New("未找到系统 Node（请先 brew install node）；macOS 受管运行时将在后续版本提供")
	}
	if !verifyHelperNode(node) {
		return errors.New("系统 Node 版本过低（需要 v20+）")
	}
	helperLog("INFO", "环境", "运行环境就绪：使用系统 Node "+node)
	return nil
}
