//go:build !windows

package main

import "errors"

// 非 Windows 占位桩：macOS 由 ExpertDock Helper.app（Swift launcher）无头驱动，
// main.go 的调用点被 runtime.GOOS == "windows" 守卫，运行时不会到达这里；
// 此桩仅为满足跨平台编译（CI ubuntu/mac runner 编译核心库代码）。
func runGUI(rawURL string) {
	fatal(errors.New("GUI 仅支持 Windows；macOS 请使用 ExpertDock Helper.app"))
}
