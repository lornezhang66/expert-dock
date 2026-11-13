//go:build windows

package main

// Windows 常驻 GUI：托盘 + 状态窗 + 进度条（walk / Win32 原生控件）。
// v0.8.0 起 Windows 裸进程即 GUI：无 URL 启动=常驻托盘；带 expertdock:// URL=进 GUI 跑安装流程。
// 线程纪律：walk 非线程安全——一切 UI 变更经 mw.Synchronize 编组回主线程；文件/网络照旧后台 goroutine。

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lxn/walk"
	dec "github.com/lxn/walk/declarative"
	"golang.org/x/sys/windows"
)

//go:embed assets/expertdock.ico
var appIconBytes []byte

//go:embed assets/icon.png
var appIconPNG []byte

// UI/通知/下载进度钩子的变量声明在 main.go（跨平台）；此处只赋值与消费。

const (
	relaunchSentinel  = "expertdock://relaunch"
	guiMutexName      = `Local\ExpertDockHelperGUI`
	guiMutexAcquireMs = 1000
	guiMutexMaxWait   = 8 // 更新换血竞态：旧实例 1.5s 内退出，新实例最多等 8s
)

type guiApp struct {
	mw       *walk.MainWindow
	ni       *walk.NotifyIcon
	status   *walk.Label
	progress *walk.ProgressBar
	sync     func(fn func()) // 编组到 UI 线程
}

// runGUI Windows 常驻入口，不返回（内部 mw.Run() 阻塞或直接退出）
func runGUI(rawURL string) {
	// ps1→Go 迁移清扫只挂在真实使用入口（常驻/安装），工具型调用（--version 等）不触发
	takeOverLegacyInstall()
	if strings.HasPrefix(rawURL, relaunchSentinel) {
		rawURL = "" // 自更新换血回来的实例：常驻启动，不重放安装
	}
	acquireGUIMutexOrFail()

	app := &guiApp{}
	icon := loadAppIcon()
	headerImg := loadHeaderImage()

	err := dec.MainWindow{
		AssignTo: &app.mw,
		Title:    "专家云盘小助手",
		Font:     dec.Font{Family: "Microsoft YaHei UI", PointSize: 9},
		MinSize:  dec.Size{Width: 460, Height: 250},
		Size:     dec.Size{Width: 460, Height: 250},
		Layout:   dec.VBox{Margins: dec.Margins{Left: 18, Top: 16, Right: 18, Bottom: 14}, Spacing: 12},
		Children: []dec.Widget{
			// 品牌头部：图标 + 产品名 + 版本副标题
			dec.Composite{
				Layout: dec.HBox{Spacing: 12, Margins: dec.Margins{Left: 0, Top: 0, Right: 0, Bottom: 2}},
				Children: []dec.Widget{
					dec.ImageView{Image: headerImg, Mode: dec.ImageViewModeZoom, MinSize: dec.Size{Width: 48, Height: 48}},
					dec.Composite{
						Layout: dec.VBox{Spacing: 3},
						Children: []dec.Widget{
							dec.Label{Text: "专家云盘小助手", Font: dec.Font{Family: "Microsoft YaHei UI", PointSize: 14, Bold: true}, TextColor: walk.RGB(0x1F, 0x1F, 0x1F)},
							dec.Label{Text: "版本 v" + helperVersion + " · WorkBuddy 本地安装器", TextColor: walk.RGB(0x8C, 0x8C, 0x8C)},
						},
					},
				},
			},
			dec.Label{AssignTo: &app.status, Text: "正在就绪…", MinSize: dec.Size{Height: 56}, TextColor: walk.RGB(0x59, 0x59, 0x59)},
			dec.ProgressBar{AssignTo: &app.progress, MinSize: dec.Size{Height: 14}, Visible: false},
			dec.VSpacer{},
			dec.Composite{
				Layout: dec.HBox{Spacing: 8},
				Children: []dec.Widget{
					dec.HSpacer{},
					dec.PushButton{Text: "检查更新", MinSize: dec.Size{Width: 96}, OnClicked: func() { go app.actionCheckUpdate() }},
					dec.PushButton{Text: "同步 MCP 配置", MinSize: dec.Size{Width: 124}, OnClicked: func() { go app.actionSyncMcp() }},
					dec.PushButton{Text: "退出", MinSize: dec.Size{Width: 88}, OnClicked: func() { exitGUI(app) }},
				},
			},
		},
	}.Create()
	if err != nil {
		helperLog("ERROR", "界面", "主窗口创建失败："+err.Error())
		notify("专家云盘", "界面初始化失败："+err.Error())
		os.Exit(1)
	}
	if icon != nil {
		app.mw.SetIcon(icon) // 标题栏品牌图标（此前只有托盘有，窗口用的是 walk 默认图标）
	}
	// 关窗=隐藏到托盘，不退出（托盘菜单/退出按钮才是真退出）
	app.mw.Closing().Attach(func(canceled *bool, _ walk.CloseReason) {
		*canceled = true
		app.mw.Hide()
	})
	app.sync = func(fn func()) { app.mw.Synchronize(fn) }

	if ni, err := walk.NewNotifyIcon(app.mw); err == nil {
		app.ni = ni
		if icon != nil {
			ni.SetIcon(icon)
		}
		ni.SetToolTip("专家云盘小助手 v" + helperVersion)
		ni.SetVisible(true)
		_ = ni.ContextMenu().Actions().Add(walk.NewAction())
		for _, item := range []struct {
			text    string
			handler func()
		}{
			{"打开主窗口", func() { app.sync(func() { app.mw.Show(); app.mw.Activate() }) }},
			{"检查更新", func() { go app.actionCheckUpdate() }},
			{"退出", func() { exitGUI(app) }},
		} {
			action := walk.NewAction()
			action.SetText(item.text)
			action.Triggered().Attach(item.handler)
			_ = ni.ContextMenu().Actions().Add(action)
		}
		ni.MouseDown().Attach(func(x, y int, _ walk.MouseButton) {
			app.sync(func() { app.mw.Show(); app.mw.Activate() })
		})
	} else {
		helperLog("WARN", "界面", "托盘图标创建失败："+err.Error())
	}

	// 通知/状态/下载进度三路钩子接到 GUI；writeStatus 的 status.json 文件契约保持不变
	notifyHook = func(title, message string) {
		app.sync(func() {
			if app.ni != nil {
				_ = app.ni.ShowInfo(title, message)
			}
		})
	}
	uiStatusHook = func(state, message string) {
		text := message
		busy := state == "installing" || state == "updating"
		// 状态着色：失败红 / 进行中品牌蓝 / 就绪灰
		var color walk.Color
		switch {
		case state == "failed":
			color = walk.RGB(0xD4, 0x38, 0x0D)
		case busy:
			color = walk.RGB(0x16, 0x77, 0xFF)
		default:
			color = walk.RGB(0x59, 0x59, 0x59)
		}
		app.sync(func() {
			app.status.SetText(text)
			app.status.SetTextColor(color)
			app.progress.SetVisible(busy) // 进度条只在忙时出现，空闲不占视觉
			if busy {
				app.progress.SetMarqueeMode(true)
				app.mw.Show()
				app.mw.Activate()
			} else {
				app.progress.SetMarqueeMode(false)
				app.progress.SetValue(0)
			}
		})
	}
	downloadProgress = func(done, total int64) {
		app.sync(func() {
			if total <= 0 {
				return
			}
			if app.progress.MarqueeMode() {
				app.progress.SetMarqueeMode(false)
			}
			app.progress.SetRange(0, 100)
			app.progress.SetValue(int(done * 100 / total))
		})
	}

	// 启动序列（蓝本口径）：常驻启动先同步一次 MCP；带 URL 则直接进安装流程。
	// 状态一律走 writeStatus 漏斗（标签 + status.json 双路）——驻留路径只刷标签不落盘
	// 是迁移演练抓出的缺陷：status.json 是 launcher/外部消费契约，不能只在装包时更新。
	go func() {
		if rawURL == "" {
			writeStatus("ready", "正在就绪…同步专家 MCP 配置")
			syncWorkBuddyMcp()
			if envErr := prepareHelperEnvironment(); envErr != nil {
				helperLog("WARN", "环境", "运行环境准备失败："+envErr.Error())
			}
			writeStatus("ready", "就绪。在分享页点「安装到 WorkBuddy」即可自动安装")
			return
		}
		if err := runInstallFlow(rawURL); err != nil {
			writeStatus("failed", "安装失败："+err.Error())
		} else {
			writeStatus("ready", "安装完成。")
		}
	}()

	app.mw.Run()
}

func exitGUI(app *guiApp) {
	if app.ni != nil {
		app.ni.SetVisible(false)
		app.ni.Dispose()
	}
	walk.App().Exit(0)
}

// acquireGUIMutexOrFail 单实例锁：更新换血场景下旧实例尚未退出时，新实例最多等 guiMutexMaxWait 秒
func acquireGUIMutexOrFail() {
	name, _ := windows.UTF16PtrFromString(guiMutexName)
	for attempt := 0; ; attempt++ {
		handle, err := windows.CreateMutex(nil, false, name)
		if err == nil {
			// 持锁不放：进程退出即释放
			_ = handle
			return
		}
		if err != windows.ERROR_ALREADY_EXISTS {
			helperLog("ERROR", "界面", "单实例锁异常："+err.Error())
			return // 锁机制失效时宁可放行也不挡安装
		}
		if attempt >= guiMutexMaxWait {
			helperLog("INFO", "界面", "已有小助手实例在运行，本次启动退出")
			os.Exit(0)
		}
		time.Sleep(time.Duration(guiMutexAcquireMs) * time.Millisecond)
	}
}

// loadAppIcon 从内嵌 ico 字节加载托盘/窗口图标；失败不致命，托盘退化为系统默认图标
func loadAppIcon() *walk.Icon {
	tmp := filepath.Join(os.TempDir(), fmt.Sprintf("expertdock-%d.ico", os.Getpid()))
	if err := os.WriteFile(tmp, appIconBytes, 0o600); err != nil {
		helperLog("WARN", "界面", "图标落盘失败："+err.Error())
		return nil
	}
	defer os.Remove(tmp) // LR_LOADFROMFILE 语义：HICON 已完整载入内存，临时文件可立即删
	icon, err := walk.NewIconFromFile(tmp)
	if err != nil {
		helperLog("WARN", "界面", "图标加载失败："+err.Error())
		return nil
	}
	return icon
}

// loadHeaderImage 从内嵌 PNG 加载窗口头部品牌图（walk.Image 仅支持 png/jpeg 解码，
// ico 容器不行——icon.png 是从多帧 ico 抽出的 256px 帧）
func loadHeaderImage() walk.Image {
	tmp := filepath.Join(os.TempDir(), fmt.Sprintf("expertdock-%d.png", os.Getpid()))
	if err := os.WriteFile(tmp, appIconPNG, 0o600); err != nil {
		helperLog("WARN", "界面", "头部图标落盘失败："+err.Error())
		return nil
	}
	defer os.Remove(tmp)
	img, err := walk.NewImageFromFile(tmp)
	if err != nil {
		helperLog("WARN", "界面", "头部图标解码失败："+err.Error())
		return nil
	}
	return img
}

func (app *guiApp) actionCheckUpdate() {
	writeStatus("updating", "正在检查更新…")
	updated, err := maybeSelfUpdate(relaunchSentinel)
	if err != nil {
		writeStatus("ready", "检查更新失败："+err.Error())
		return
	}
	if !updated {
		writeStatus("ready", "已是最新版本 v"+helperVersion)
		return
	}
	// 换血进行中：给 --replace 子进程留出换文件+拉起新实例的时间，然后本进程退出放行单实例锁
	writeStatus("updating", "发现新版本，正在切换…")
	time.Sleep(1500 * time.Millisecond)
	os.Exit(0)
}

func (app *guiApp) actionSyncMcp() {
	writeStatus("installing", "正在同步专家 MCP 配置…")
	result := syncWorkBuddyMcp()
	writeStatus("ready", fmt.Sprintf("同步完成：更新 %d / 跳过 %d / 扫描 %d", result.Updated, result.Skipped, result.Scanned))
}

// openLogsDir 供托盘/窗口扩展使用（阶段 3 接日志汇后启用）
func logsDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "ExpertDock", "logs")
}
