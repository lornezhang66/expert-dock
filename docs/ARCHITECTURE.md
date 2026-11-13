# ExpertDock Worker 架构理解

> **⚠️ 历史文档（v0.7.x 时代快照，2026-11 之前）**：Helper 已换血为 Go 双端（wails GUI / Swift launcher），
> Worker 事实源已迁至 `worker/index.js`，pi 适配已剔除。时效性内容以根目录 `CLAUDE.md` 与
> `docs/ENVIRONMENT.md` 为准；本文保留作路由表、校验规则、D1 表结构等设计事实的参考。

> **产品显示名：专家云盘**（代码标识 expertdock://、域名、helper 文件名不变）。
> 从 Cloudflare API 拉取的生产打包产物：`source/index.js`（esbuild bundle，含 esbuild 辅助头 + src/zip.js + src/index.js + yaml/fflate 依赖；中文为明文 UTF-8）。
> 线上地址：https://ed.lorne.top （workers.dev 子域：18660190869.workers.dev）
> 2026-10-09：全新文案（专家云盘口径）+ 重写 CSS 皮肤 + Helper v0.3.0（新 UI + 安装到 pi），已上线。

## 是什么
WorkBuddy「专家」分享平台（产品显示名：**专家云盘**）：
- 管理员登录后上传专家 ZIP 包（WorkBuddy 2.4 规范），生成版本和分享链接
- 访客打开 `/s/<token>` 分享页，选「安装到 WorkBuddy」或「安装到 pi」→ 唤起 `expertdock://install?token=...[&target=pi&origin=...]` 协议
- Windows：ps1 按 target 分发——无 target 走老 exe 装 WorkBuddy；`target=pi` 由 ps1 直接安装（不改制品）
- 本地 ExpertDock Helper（Windows exe / macOS app）通过 `/api/helper/install/<token>` 拿元数据 → 下载 ZIP → 校验 SHA-256 → 装

## 多智能体安装（不改变制品）
ZIP 永远是唯一制品；目标智能体适配发生在安装端（helper-ui.ps1）：
| ZIP 内容 | pi 落点 |
|---|---|
| 整包原树 | `~/.pi/agent/expertdock/<name>/package/`（含回执 expertdock.json） |
| skills/* | `~/.agents/skills/*`（Agent Skills 标准位，pi 原生发现） |
| agents/<agentName>.md 人设 + quickPrompts×3 | 生成 `~/.pi/agent/prompts/<name>.md / -2 / -3`，用法 `/name 问题` |
| MCP 依赖 | 不自动改 `~/.pi/agent/mcp.json`（信任边界），状态栏提示手动接入 |

新增智能体目标：在 ps1 加 `Install-ExpertTo<X>` 函数 + `-Url` 分发处加一行。注意：macOS helper 未适配 pi（target=pi 会被旧程序忽略/按 WorkBuddy 处理）；旧 Windows helper 同理，分享页已注明「装进 pi 需 Helper 0.3.0 以上」。

## 绑定（bindings）
| 名称 | 类型 | 值 |
|---|---|---|
| ADMIN_PASSWORD | secret | 登录密码 |
| SESSION_SECRET | secret | 会话 HMAC 密钥 |
| DB | D1 | 2267365e-04e3-4933-beba-0cd3ae9396c7 |
| PACKAGES | R2 | expert-dock-packages（包 + helpers/vX/… + helpers/latest.json） |
| HELPER_VERSION | text | 0.7.2 |
| MAX_UPLOAD_BYTES | text | 20971520（20MB） |

## 路由（route()）
公开：
- `GET /` 落地页（粘贴分享链接 → POST /open → 303 跳 /s/<token>）
- `GET /experts` 已分享专家列表（D1 join shares+expert_versions+experts）
- `GET /s/<token>` 分享详情页（含唤起 Helper 的内联 JS）
- `GET /login`、`POST /login`（密码 → HMAC 签名 cookie `ed_session=<exp>.<sig>`，7 天）
- `GET /health`
- `GET /helper`、`GET /downloads/helper/<macos|windows>`（更新 ZIP）、`GET /downloads/helper/windows/setup`（Windows 图形安装器）
- `GET /api/helper/install/<token>` Helper 安装元数据 JSON（downloadUrl、sha256、size）
- `GET /api/helper/latest/<platform>` Helper 升级检查（R2 helpers/latest.json）
- `GET /api/shares/<token>/download` 下载专家 ZIP（R2 stream）
- `POST /api/shares/<token>/install-click` 安装计数

需登录（否则 302 /login）：
- `GET /dashboard`、`GET /dashboard/experts/new`、`GET /dashboard/experts/<uuid>`
- `POST /api/experts` 上传新专家（formData：package ZIP + description + releaseNotes）
- `POST /api/experts/<uuid>/versions` 追加版本（校验 plugin.json.name 一致）
- `POST /api/versions/<uuid>/shares` 生成分享 token（24 字节 base64url）
- `POST /api/shares/<uuid>/toggle` 启停分享

## 上传校验（src/zip.js inspectExpertZip）
1. 手写 ZIP 中央目录解析：EOCD → entries（文件数 ≤1000，解压总量 ≤100MB，拒符号链接/路径穿越）
2. 必须恰好一个 `.codebuddy-plugin/plugin.json`（可在子目录内，整个包只能有该目录树）
3. plugin.json 强校验：name 正则、semver、expertType(agent|team)、author、agents 非空且指向 agents/*.md、agentName 对应文件、displayName/profession/displayDescription 双语、displayDescription.zh 40-50 字、categoryId 枚举(15 类)、defaultInitPrompt=quickPrompts[0]、tags 恰 3 项、quickPrompts 恰 3 项
4. 头像：avatars/ 下 PNG/JPG ≤500KB 且必须 512×512（手写 PNG/JPG 尺寸解析）
5. skills：skills/<name>/SKILL.md 存在
6. MCP：dependencies.mcpServers 字符串/数组指向配置文件，或内联对象，或包根 .mcp.json；token 型 auth 校验 header 占位符与 tokenSchema.fields 互相匹配
7. team 型：teamInfo.leadAgent=agentName、members≥2 且唯一 lead、memberAgents 与 members/agents 三方一致、settings.json.agent 一致、主理人 MD 必须含「团队协作机制」「铁律」「AgentTool」、禁用 team-lead 文件名
8. agents/*.md YAML frontmatter 校验（yaml 库）：name=文件名、description、displayName、profession，禁止 tools 字段

## 安全机制
- checkOrigin：带 body 的 POST 校验 Origin 头（仅当浏览器带 Origin 时）
- secureEqual：SHA-256 后逐字节异或比较（防时序）
- 页面 CSP：default-src 'self'; style/script 'unsafe-inline'；escapeHtml 全量转义
- 下载响应 nosniff、分享页链接仅前 10 位展示
- 上传失败（DB batch 失败）回滚删除 R2 对象

## D1 表（从 SQL 推断，Token 无 D1 权限未直接验证）
- experts(id, name, description, type, status, created_at, updated_at)
- expert_versions(id, expert_id, version, package_key, package_sha256, package_size, manifest, release_notes, created_at)
- shares(id, expert_version_id, token, enabled, expires_at, install_clicks, created_at)

## Helper 客户端（本地）
- `C:/Users/18660/Downloads/expertdock-helper-windows/`：expertdock-helper.exe + helper-ui.ps1（注册 expertdock:// 协议、开机自启、托盘 UI）
- 安装目录 %LOCALAPPDATA%/ExpertDock，状态文件 %APPDATA%/ExpertDock/status.json
- **v0.4.0（2026-10-13，已上线）**：可观测性专项——全流程日志（%APPDATA%/ExpertDock/logs/helper-YYYYMMDD.log，留 14 天，含环境快照 PS/.NET/OS、唤起 URL、逐步耗时、重试、失败堆栈）；网络限超时（meta 30s/下载 300s）+ 自动重试 3 次；TLS12/13 显式启用；安装并发锁（Local\ExpertDockInstall）；解压优先 .NET ZipFile；status.json 增加 step/version/updatedAt；托盘气泡通知安装结果，「打开日志/查看日志」入口
- **v0.6.0（2026-10-14，已上线）**：Windows 首次安装改用 Inno Setup 单 EXE，提供标准图形安装进度、按用户安装、覆盖升级和卸载；Helper 窗口增加安装进度条，浏览器点击“安装到 WorkBuddy/pi”后主动显示并前置，后台启动保持仅驻托盘。Cloudflare Worker 版本 ID：`377418b6-00bd-4547-96b2-1cd211a56d94`。
- 构建：`powershell -ExecutionPolicy Bypass -File helper/build-release.ps1 -Version 0.6.0`。上传时 Setup 放到 `helpers/v0.6.0/ExpertDock-Helper-Setup-0.6.0.exe`，更新 ZIP 仍放到 `helpers/v0.6.0/expertdock-helper-windows.zip`，避免破坏旧客户端自更新。
- **v0.7.0（2026-11-04，已上线）**：修复 GMSCP-7877「更新专家团后 MCP 版本不更新」。①环境准备移植 gbc-expert-manager（helper-env.ps1：受管 Node 22.22.2 到 ~/.workbuddy/expert-manager/runtimes/ + nexus 只读 npm 认证 npm-workbuddy.rc）；②新增 MCP 依赖同步 `Sync-ExpertMcpDependencies`——WorkBuddy 专家安装成功后把包内 .mcp.json 合并刷进用户级 mcp.json：只更新已存在条目（首装归 WorkBuddy 连接卡）、执行命令 type/command/args/runtime 整段按包声明直接覆盖（包是版本决策的唯一事实源，@latest 与固定版本均照搬；registry 由环境层全局 npm 配置兜底）、${GBC_TOKEN}/${GBC_BASE_URL} 沿用已配值（PAT/URL 不丢）、headers/自定义键保留、无 BOM 写回。发布：update.zip sha256 e1b1b2b7…、Setup EXE、macOS 包（78a97117… 自 v0.6.0 平移）均经公网哈希回读校验；Worker Version ID `78f54641-7335-45e7-8323-ab7220aae130`。修复方案已回写 Jira 评论（975902）。
- 线上排查：让用户点托盘右键「查看日志」把当天 helper-*.log 发回来即可定位卡在哪一步

## 部署方式（已验证）
Worker 无本地源码仓（bundle 直接上传）。

1. 改 `source/index.js` → `node --check` + `node source/_smoke.mjs`（stub DB/R2 渲染各页面自检）
2. 部署：`PUT /accounts/{acc}/workers/scripts/expert-dock`，multipart：
   - `metadata=@source/meta.json;type=application/json`（main_module + bindings + `keep_bindings:["secret_text"]`，**保留 ADMIN_PASSWORD/SESSION_SECRET 不被抹掉**，已实测）
   - `index.js=@source/index.js;type=application/javascript+module`（content-type 必须带 `+module`）
3. 验证：curl 线上 `/`、`/login`、`/helper`、`/experts`、`/health`、`/api/helper/latest/windows`、`/downloads/helper/*`（注意别用 `curl -I`，路由只认 GET，HEAD 会掉进登录跳转）
4. Helper 升版：改 ps1 → .NET ZipFile 打平铺 zip（bsdtar 的 zip .NET 读不了）→ PUT R2 `helpers/vX/…-windows.zip`，macos 从旧版拷同 key，更新 `helpers/latest.json`，再部署 worker 带 HELPER_VERSION 新值

注：`source/meta.json` 为部署清单（bindings 快照，不含 secret 值）；`raw.script/raw.multipart` 为改动前的线上原包备份。当前通过 Wrangler OAuth 登录发布，不依赖旧的 `/tmp/cf_token`。

当前仓库已增加 `wrangler.jsonc`，后续可直接执行 `wrangler deploy --config wrangler.jsonc --keep-vars --no-bundle`；`--keep-vars` 保留控制台配置的普通变量，Worker secrets 在部署时不会被删除。
