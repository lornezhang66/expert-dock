//go:build windows

package main

// Windows GUI：wails v2（WebView2 渲染 HTML/CSS 界面）+ energye/systray（独立线程托盘）。
// 设计取舍记录（v0.9.0）：walk 原生控件天花板是 Win95 观感，无法满足产品化视觉要求；
// wails v3 的 SystemTray 尚处 alpha（依赖钉死纪律，产品不上 alpha），故 v2 + 独立托盘线程。
// 线程模型：wails 主循环持有窗口；托盘 goroutine LockOSThread 自泵消息；
// 托盘菜单回调经 wails runtime（内部分发主线程）操控窗口。

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"github.com/energye/systray"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed frontend
var frontendFS embed.FS

//go:embed assets/expertdock.ico
var appIconBytes []byte // 托盘图标（windows 托盘吃 ico 容器）

const relaunchSentinel = "expertdock://relaunch"

// UI/通知/下载进度钩子：声明在 main.go（跨平台）；此处赋值与消费。
var (
	lastUIStatus = map[string]string{"state": "ready", "message": "正在就绪…"}
)

type App struct {
	ctx context.Context
}

// ---- 前端绑定（wails 注入为 window.go.main.App.*） ----

func (a *App) GetVersion() string { return helperVersion }

func (a *App) GetStatus() map[string]string { return lastUIStatus }

func (a *App) Quit() {
	if a.ctx != nil {
		wailsruntime.Quit(a.ctx)
		return
	}
	os.Exit(0)
}

// CheckUpdate 对应蓝本「检查更新」：换血触发后立即退出——换血子进程先 copyFile
// （约百毫秒）再拉起新实例，本进程先死才能让新实例拿到单实例锁。
func (a *App) CheckUpdate() {
	writeStatus("updating", "正在检查更新…")
	updated, err := maybeSelfUpdate(relaunchSentinel)
	switch {
	case err != nil:
		writeStatus("ready", "检查更新失败："+err.Error())
	case !updated:
		writeStatus("ready", "已是最新版本 v"+helperVersion)
	default:
		writeStatus("updating", "发现新版本，正在切换…")
		os.Exit(0)
	}
}

func (a *App) SyncMcp() mcpSyncResult {
	writeStatus("installing", "正在同步专家 MCP 配置…")
	result := syncWorkBuddyMcp()
	writeStatus("ready", fmt.Sprintf("同步完成：更新 %d / 跳过 %d / 扫描 %d",
		result.Updated, result.Skipped, result.Scanned))
	return result
}

// ---- runGUI：Windows 常驻入口（不返回） ----

func runGUI(rawURL string) {
	// ps1→Go 迁移清扫只挂在真实使用入口（常驻/安装），工具型调用（--version 等）不触发
	takeOverLegacyInstall()
	if strings.HasPrefix(rawURL, relaunchSentinel) {
		rawURL = "" // 自更新换血回来的实例：常驻启动，不重放安装
	}

	app := &App{}
	content, subErr := fs.Sub(frontendFS, "frontend")
	if subErr != nil {
		helperLog("ERROR", "界面", "前端资源挂载失败："+subErr.Error())
		os.Exit(1)
	}

	err := wails.Run(&options.App{
		Title:             "专家云盘小助手",
		Width:             420,
		Height:            306,
		MinWidth:          420,
		MinHeight:         306,
		MaxWidth:          420,
		MaxHeight:         306,
		HideWindowOnClose: true, // 关窗=隐藏到托盘；退出走托盘菜单/按钮
		BackgroundColour:  &options.RGBA{R: 255, G: 255, B: 255, A: 255},
		AssetServer:       &assetserver.Options{Assets: content},
		Bind:              []interface{}{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId: "expertdock-helper-gui-9f2c1b34-7b0d-4f47-9f2a-66d504a21f31",
			OnSecondInstanceLaunch: func(data options.SecondInstanceData) {
				// 协议二次唤起：URL 经单实例锁转发到常驻实例（老版是静默退出，这里修正为接续安装）
				if app.ctx == nil {
					return
				}
				wailsruntime.WindowShow(app.ctx)
				for _, arg := range data.Args {
					if strings.HasPrefix(arg, "expertdock://") && !strings.HasPrefix(arg, relaunchSentinel) {
						go runInstallFlowUI(app.ctx, arg)
						break
					}
				}
			},
		},
		OnStartup: func(ctx context.Context) {
			app.ctx = ctx
			wireUIHooks(ctx)
			go startTray(ctx)
			// 启动序列（蓝本口径）：常驻先同步一次 MCP；带 URL 直接进安装流程
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
				runInstallFlowUI(ctx, rawURL)
			}()
		},
		Windows: &windows.Options{
			Theme:                windows.Light,
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			CustomTheme: &windows.ThemeSettings{
				LightModeTitleBar:  windows.RGB(255, 255, 255),
				LightModeTitleText: windows.RGB(23, 24, 28),
				LightModeBorder:    windows.RGB(240, 241, 244),
			},
		},
	})
	if err != nil {
		helperLog("ERROR", "界面", "应用启动失败："+err.Error())
		notify("专家云盘", "界面初始化失败："+err.Error())
		os.Exit(1)
	}
}

func wireUIHooks(ctx context.Context) {
	uiStatusHook = func(state, message string) {
		lastUIStatus = map[string]string{"state": state, "message": message}
		wailsruntime.EventsEmit(ctx, "ui:status", lastUIStatus)
	}
	notifyHook = func(title, message string) {
		wailsruntime.EventsEmit(ctx, "ui:notify", title+"："+message)
	}
	downloadProgress = func(done, total int64) {
		wailsruntime.EventsEmit(ctx, "ui:progress", map[string]int64{"done": done, "total": total})
	}
}

// runInstallFlowUI 常驻 GUI 的安装序列（文案与 main.go 无头版保持同口径）
func runInstallFlowUI(ctx context.Context, rawURL string) {
	writeStatus("installing", "正在安装专家…")
	message, err := install(rawURL)
	if err != nil {
		writeStatus("failed", "安装失败："+err.Error())
		return
	}
	writeStatus("ready", message)
	if message != "" {
		// GMSCP-7877：安装成功后刷一次 MCP 版本；环境层尽力而为，均不回滚安装结果
		syncWorkBuddyMcp()
		if envErr := prepareHelperEnvironment(); envErr != nil {
			helperLog("WARN", "环境", "运行环境准备失败（不影响本次安装）："+envErr.Error())
		}
	}
}

// startTray 托盘：独立锁线程自泵消息（Shell_NotifyIcon 回调窗口在该线程，主循环无关）
func startTray(ctx context.Context) {
	systray.Run(func() { // onReady
		systray.SetIcon(appIconBytes)
		systray.SetTooltip("专家云盘小助手 v" + helperVersion)
		mOpen := systray.AddMenuItem("打开主窗口", "显示主窗口")
		mSync := systray.AddMenuItem("同步 MCP 配置", "刷新专家 MCP 版本")
		systray.AddSeparator()
		mQuit := systray.AddMenuItem("退出", "退出小助手")
		mOpen.Click(func() {
			if ctx != nil {
				wailsruntime.WindowShow(ctx)
			}
		})
		mSync.Click(func() {
			if ctx == nil {
				return
			}
			go func() {
				writeStatus("installing", "正在同步专家 MCP 配置…")
				result := syncWorkBuddyMcp()
				writeStatus("ready", fmt.Sprintf("同步完成：更新 %d / 跳过 %d / 扫描 %d",
					result.Updated, result.Skipped, result.Scanned))
			}()
		})
		mQuit.Click(func() { wailsruntime.Quit(ctx) })
	}, nil)
}
