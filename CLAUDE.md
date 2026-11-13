# CLAUDE.md — 专家云盘（ExpertDock）

> 面向 AI 会话的项目事实源。基线版本 **v0.9.1**（2026-11-13 起）。历史细节见 `docs/ARCHITECTURE.md`（有历史标记头）与跨项目记忆库 `facts/projects/ExpertDock.md`。

## 产品是什么

WorkBuddy「专家」分享平台。管理员在 Worker 上传专家 ZIP 包（WorkBuddy 2.4 规范）→ 生成分享链接 → 访客点「安装到 WorkBuddy」唤起 `expertdock://` 协议 → 本地 Helper 下载校验安装，并同步专家包的 MCP 依赖版本到用户级 `~/.workbuddy/mcp.json`。

- 线上：https://ed.lorne.top （workers.dev：18660190869.workers.dev）
- 双端 Helper：Windows（wails v2 GUI + systray 托盘）/ macOS（Swift launcher + Go core，universal binary）
- pi 适配已剔除（2026-11 产品决策），勿再加回

## 目录布局

```
repo/
├── worker/index.js      Worker 事实源（esbuild bundle，明文可读，--no-bundle 直接部署）
├── wrangler.jsonc        Worker 配置（HELPER_VERSION 等 vars）
├── helper/               Go helper（跨平台核心 + 平台 UI）
│   ├── main.go           核心：install/自更新/协议注册/状态文件（--version --sync-mcp --prepare-env --replace）
│   ├── sync.go           GMSCP-7877：包内 .mcp.json → 用户级 mcp.json 合并（硬约束见文件头注释）
│   ├── env.go/env_windows.go 环境层：受管 Node 22.22.2 + npm-workbuddy.rc（内网 nexus 凭据在此）
│   ├── ui_windows.go     wails 窗口 + systray 托盘 + 前端绑定
│   ├── ui_other.go       非 Windows 占位桩（mac 由 Swift launcher 无头驱动）
│   ├── frontend/         HTML/CSS 界面（设计令牌在 :root）
│   ├── winres/           go-winres 配置（manifest/版本/图标；图标组必须 "#3" 供 wails 标题栏用）
│   ├── assets/           expertdock.ico（托盘）+ icon.png（头部/资源）
│   └── macos/AppDelegate.swift  mac 托盘 launcher（CI 上 swiftc 编译）
├── build/
│   ├── build-release.ps1 发布编排（汇总产物→ZIP→Inno→latest.json→R2→线上校验）
│   ├── legacy-shim.ps1   v0.7.x 旧更新链路的过渡 helper-ui.ps1（头部版本标记是防降级依据）
│   ├── install.cmd       ZIP 手动安装入口
│   └── runtime/          node-runtime-win-x64.zip（37MB，gitignore，哈希钉死在 env.go）
├── installer/            Inno Setup 脚本（AppId 不变保证原地升级）
├── docs/                 ARCHITECTURE（历史）/ ENVIRONMENT / legacy-windows-helper/（ps1 蓝本）
├── migrations/ test/     D1 迁移与历史测试
└── .github/workflows/    ci.yml（PR 门禁）+ release-helper.yml（tag 触发双端构建）
```

## 常用命令

```bash
# Helper 测试（25 组，含 7877 硬约束 + zip-slip 用例）
cd helper && go test -count=1 .

# Helper 本机构建（Windows GUI）
go build -tags "desktop,production" -ldflags "-H windowsgui -s -w -X main.helperVersion=X.Y.Z" -o out.exe .

# Worker 本地/部署
npx wrangler dev
npx wrangler deploy --keep-vars --no-bundle   # 凭据在本机 wrangler OAuth

# 发布（CI tag 构建后，产物落 build/release/vX.Y.Z，再执行）
powershell build/build-release.ps1 -Version X.Y.Z -MacosZipPath <CI mac zip> -Publish -DeployWorker
```

## 发布纪律（不可破坏，教训固化）

1. **latest.json 必须最后上传**——先传三包（windows zip/macos zip/setup exe）→ Worker 部署 → 版本声明，避免"版本已更新但包缺失"窗口
2. **wrangler r2 object put 必须 --remote**——默认写本地 Miniflate 模拟器，是假象
3. **线上回读校验带随机 nonce**——下载响应 max-age=3600 immutable，同版本重发有缓存窗口
4. **更新 ZIP 六件套**：exe + shim(helper-ui.ps1) + ico + install.cmd + helper-env.ps1 + node zip——v0.7.x 旧更新器强制校验四件套，缺任一将永久卡旧版；shim 头 20 行必须含 vX.Y.Z（包内防降级检查）
5. macOS zip 先传、latest.json 最后

## 版本号五处对齐（每次发版）

`helper/main.go` helperVersion / `wrangler.jsonc` HELPER_VERSION / `build/legacy-shim.ps1` 头部 v 标记 / `helper/winres/winres.json`（改后必须 `go-winres make` 重生成 syso）/ git tag 名

## 高频踩坑（已付过学费，勿重蹈）

- **PS5.1**：跑 build/测试脚本前先重置 `PSModulePath`（否则 Get-FileHash 不可见）；`-File` 脚本里 `& gui-exe --version` 管道捕获返回空，用 `System.Diagnostics.Process` 重定向
- **wails**：生产构建必须 `-tags "desktop,production"`；v2 无 SystemTray（systray 独立线程补位）；标题栏图标取 RT_GROUP_ICON **#3**；go-winres 配置各段必须包语言层（RT_VERSION "0000"、RT_MANIFEST "0409"）；多帧 ICO 需抽 PNG 帧喂给 go-winres
- **GUI 测试**：多实例前先清场进程（单实例锁静默重试 8s）；windowsgui 构建的日志不可见，调试用 console 版；截图被遮挡用 `PrintWindow + PW_RENDERFULLCONTENT`
- **迁移清扫**：takeOverLegacyInstall 只在 runGUI 入口调用，绝不放 main() 顶部（--version 等工具调用会误删发布 staging 的 shim——真踩过）
- **测试脚本**：dot-source helper-ui.ps1 会挂起常驻托盘；AST 抽函数（Parser::ParseFile）跑
- **凭据**：内网 nexus 只读账密嵌在 env.go（公开仓库，定位是公开只读访客）；轮换时三处同步（env.go + docs legacy 两份 ps1），发布前 curl 实测新旧凭据

## 语言与风格

中文交流；方案先行，高影响改动先给方案；>3 文件改动分段执行；写完带 Bug 清单与测试用例。
