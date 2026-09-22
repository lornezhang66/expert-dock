# WorkBuddy 专家分享器 — Agent 开发说明

## 1. 产品目标

构建一个私域 Web 应用，让开发者无需等待 WorkBuddy 官方专家市场审核即可：

1. 上传和管理自己创建的 WorkBuddy 专家或专家团。
2. 为每个版本生成可分享链接。
3. 用户打开链接后查看详情，点击“安装到 WorkBuddy”，由本地安装器直接写入用户目录完成安装。

本项目不是新的专家市场。MVP 只服务可信开发者的私域分发，不做公开搜索、推荐、评论、交易和社交功能。产品由 Web 应用和 **ExpertDock Helper** 组成；用户只需首次安装一次 Helper，后续从网页点击即可自动安装。纯浏览器无权修改用户目录，因此不得假装仅靠网页即可完成安装。

## 2. 关键限制

- 不调用 WorkBuddy 官方市场接口；安装通过修改当前用户目录下的 WorkBuddy 本地文件完成。
- Web 页面不得直接声称拥有文件系统权限。“一键安装”依赖用户首次安装并授权 **ExpertDock Helper**。
- Helper 注册并仅处理 `expertdock://` 自定义协议。
- Helper 只允许写入检测到的当前用户 WorkBuddy 目录，不申请管理员权限，不修改 WorkBuddy 程序文件。
- 默认专家安装目录结构为 `~/.workbuddy/plugins/marketplaces/my-experts/plugins/{expert-name}/`，但每次安装前都必须自动扫描并校验实际 WorkBuddy 用户目录。
- 正常流程不显示目录选择器，也不允许分享链接提供安装目录。
- 扫描结果为空、存在多个候选、目录结构不完整或无法可靠确认时，立即报错并停止；不得猜测路径、创建疑似 WorkBuddy 根目录或让用户随意选择目录继续。
- Helper 复制文件后，直接维护 WorkBuddy 的 `my-experts` 市场清单、版本缓存、安装登记表和启用状态；任一步骤失败都回滚本次写入。
- Helper 未安装或无法唤起时，页面提供 Helper 安装入口；专家包手动下载仅作为故障排查入口。
- 不收集用户的 WorkBuddy 密码、Token 或 Cookie。
- 专家包中的密钥必须使用环境变量或 WorkBuddy 的 Token 配置能力，不得硬编码。
- 上传内容默认不可信，必须校验格式、大小、文件名和压缩包路径，防止 Zip Slip、恶意脚本及覆盖文件。

## 3. 用户角色

### 开发者

- 登录管理后台。
- 创建专家条目。
- 上传专家包并填写名称、简介、图标和版本说明。
- 创建或撤销分享链接。
- 查看基础访问量与安装按钮点击量。

### 访问用户

- 无需登录即可打开有效分享链接。
- 查看专家或专家团的名称、介绍、作者、版本和权限说明。
- 首次使用时安装一次 ExpertDock Helper。
- 点击安装；网页通过 `expertdock://` 唤起 Helper，Helper 自动检测目录并完成安装。
- Helper 不可用时显示 Helper 安装入口和故障排查说明。

## 4. MVP 功能

### 4.1 开发者后台

- 邮箱登录。
- 专家列表：创建、编辑、归档。
- 上传 `.zip` 专家包。
- 从包内 `.codebuddy-plugin/plugin.json` 读取可用元数据，但允许开发者补充展示信息。
- 每次上传生成不可变版本；历史分享链接仍指向原版本。
- 分享链接支持：随机 Token、启用/停用、可选过期时间。

### 4.2 分享页面

路由建议：`/s/{token}`。

展示：

- 专家/专家团名称、图标、作者和简介。
- 当前分享的固定版本及更新时间。
- 包声明的 MCP、权限或外部服务依赖。
- “安装到 WorkBuddy”主按钮。
- 未安装 ExpertDock Helper 时的 Helper 下载入口。
- 安装失败时的明确错误和故障排查说明；不使用目录选择器绕过检测错误。
- 风险提示：内容来自第三方开发者，安装前确认来源和权限。

### 4.3 ExpertDock Helper 安装流程

MVP 固定采用以下流程：

1. 用户首次安装一次 ExpertDock Helper，Helper 注册 `expertdock://` 自定义协议。
2. 用户在分享页点击“安装到 WorkBuddy”。
3. 网页打开 `expertdock://install?token={share-token}` 唤起 Helper；这是 ExpertDock 自有协议，不是 WorkBuddy 官方协议。
4. Helper 从当前操作系统用户主目录开始扫描 WorkBuddy 数据目录，并校验目录特征、插件目录结构及注册工具；只有唯一候选完整通过校验才继续。
5. Helper 使用 HTTPS 根据分享 Token 获取元数据和短时下载地址。
6. Helper 下载 ZIP 并校验 SHA-256，在临时目录安全解压并验证 `.codebuddy-plugin/plugin.json`。
7. Helper 备份已安装的同名专家，再将完整专家目录原子写入检测到的 `plugins/marketplaces/my-experts/plugins/{expert-name}/`。
8. Helper 原子更新 `marketplace.json`、版本缓存、`installed_plugins.json` 和 `settings.json`，回读校验通过后提示重启或刷新 WorkBuddy。
9. 任一步骤失败都恢复安装前状态并显示具体错误。

正常流程不出现目录选择器。扫描不到唯一可信目录时直接失败，不猜测、不自动创建 WorkBuddy 根目录、不允许远程参数覆盖目录。更新已有专家时先备份旧目录，安装成功后删除备份。不得执行专家包内携带的脚本。`expertdock://` 链接生成集中在一个小型适配模块中，禁止在页面组件里散落拼接。

### 4.4 专家团

专家团是一个包含多个专家引用或配置的分发单元：

- 分享页面列出团内专家。
- 专家团使用与单专家相同的本地目录安装与注册流程。
- 若一个分享包含多个独立专家包，安装器逐个校验，全部成功才提交；任一失败则整体回滚。

## 5. 数据模型

保持最少实体：

### User

- `id`
- `email`
- `createdAt`

### Expert

- `id`
- `ownerId`
- `type`: `expert | team`
- `name`
- `description`
- `iconUrl`
- `status`: `active | archived`
- `createdAt`
- `updatedAt`

### ExpertVersion

- `id`
- `expertId`
- `version`
- `packageUrl`
- `packageSha256`
- `manifest`（解析后的 JSON）
- `releaseNotes`
- `createdAt`

### Share

- `id`
- `expertVersionId`
- `token`（高熵、不可预测、唯一）
- `enabled`
- `expiresAt`（可空）
- `createdAt`

MVP 统计直接记录结构化日志或聚合计数，不先建设事件平台。

## 6. API 边界

建议最小接口：

- `POST /api/experts`
- `PATCH /api/experts/:id`
- `POST /api/experts/:id/versions`
- `POST /api/versions/:id/shares`
- `PATCH /api/shares/:id`
- `GET /api/shares/:token`
- `GET /api/shares/:token/download`
- `POST /api/shares/:token/install-click`

要求：

- 写接口必须鉴权并校验资源所有权。
- 公共接口只返回分享页所需字段，不暴露存储路径、内部 ID 或开发者隐私。
- 下载使用短时签名 URL，或由服务端鉴权后流式返回。
- 相同版本文件用 SHA-256 校验完整性。
- ExpertDock Helper 只接收分享 Token，不接收远程传入的命令、脚本或本地目标路径。

## 7. 安全要求

- 限制上传扩展名和大小；MVP 默认最大 20 MB，并允许通过环境变量调整。
- 解压前检查文件数量、解压后总大小和路径；拒绝绝对路径及 `..`。
- 严格解析 `plugin.json`，只读取所需字段；解析失败时返回明确错误。
- 上传文件使用随机对象键，不使用原始文件名作为存储路径。
- 分享 Token 至少包含 128 bit 随机性。
- 登录、上传、分享创建和公共下载均限流。
- HTML 中不直接渲染包内富文本；需要展示 Markdown 时必须安全转义或净化。
- 记录上传、发布、撤销和下载操作日志。
- ExpertDock Helper 必须防止 Zip Slip、符号链接逃逸和大小膨胀；最终路径必须位于已校验的 WorkBuddy 插件目录内。
- 扫描只检查当前用户范围内的已知 WorkBuddy 路径；必须将候选路径规范化，并拒绝不可信符号链接、零候选和多候选结果。
- 覆盖安装前备份旧版本，使用同一文件系统内的临时目录重命名实现原子替换，失败立即回滚。
- Helper 不依赖外部注册脚本，不执行专家包内的可执行文件；所有 WorkBuddy 登记文件都先备份、原子写入并回读校验。
- Helper 只处理显式的 `expertdock://install` 请求；同一请求不得重复安装。
- 删除专家时先归档；文件物理清理由独立保留策略执行，避免误删仍被版本引用的包。

## 8. 技术实现原则

- 优先沿用仓库现有技术栈和组件，不为本功能引入第二套框架。
- 如果仓库为空，先完成：一个 Web 单体应用、一个关系数据库、一个对象存储，以及 ExpertDock Helper。
- Helper 优先使用单一跨平台代码库，但不要为了复用引入 Electron；只需注册 `expertdock://`、自动升级、扫描并校验目录、下载、校验、解压、备份、原子写入和登记插件。
- 使用数据库唯一约束保证 Token、版本号等唯一性，不在业务代码重复造锁。
- 使用对象存储保存专家包，数据库只保存元数据。
- 服务端完成鉴权、上传校验和签名下载；客户端不持有存储密钥。
- 先验证目录扫描规则，再实现 ExpertDock Helper 和 `expertdock://` 唤起；手动下载只作为故障排查能力。
- 不提前实现微服务、消息队列、插件系统、审核工作流或复杂 RBAC。

## 9. 页面范围

MVP 只包含：

1. `/login`：开发者登录。
2. `/dashboard`：专家列表。
3. `/dashboard/experts/new`：创建并上传。
4. `/dashboard/experts/:id`：编辑、发版、生成/撤销链接。
5. `/s/:token`：公开分享与安装页。

移动端优先保证分享页可用；后台保持基础响应式即可。

## 10. 验收标准

- 开发者能够上传一个合法专家包并创建分享链接。
- 非所有者不能编辑、发版或管理分享链接。
- 有效链接可匿名访问；停用、过期或不存在的链接返回统一的不可用页面。
- 分享链接固定指向创建时选择的版本，后续上传不改变旧链接内容。
- 用户能看到来源、版本、依赖和风险提示。
- 用户只需首次安装一次 ExpertDock Helper，后续点击安装可通过 `expertdock://` 唤起。
- Helper 能自动找到并校验唯一的 WorkBuddy 用户目录，正常安装不出现目录选择器。
- 零候选、多候选或校验不完整时直接报错，且不会写入任何候选目录。
- 安装成功后，专家源码、版本缓存、市场清单、安装登记和启用状态全部存在且回读校验通过。
- 覆盖安装、校验失败或注册失败时，不残留半安装目录，旧版本仍可使用。
- 非法压缩包、超限文件、路径穿越、符号链接逃逸和无效 `plugin.json` 均被拒绝。
- 下载文件的 SHA-256 与数据库记录一致。
- 核心流程至少有一条端到端检查：上传 → 分享 → 匿名访问 → 下载/安装跳转。

## 11. 开发顺序

1. 在目标 Windows/macOS 环境验证 WorkBuddy 用户目录、专家目录、市场清单、版本缓存、安装登记表和启用状态的实际结构，并据此固定扫描与登记规则。
2. 完成数据表、登录和资源所有权校验。
3. 完成安全上传、Manifest 解析和对象存储。
4. 完成版本管理及分享 Token。
5. 完成公开分享页、Helper 下载入口和手动安装故障排查流程。
6. 完成 ExpertDock Helper、`expertdock://`、可靠目录扫描、原子写入、注册与回滚。
7. 添加最小端到端检查并部署。

## 12. 明确不做

除非用户再次明确要求，否则不实现：

- 面向公众的专家市场。
- 站内审核流、推荐算法、评分评论。
- 付费、订阅、分成和发票。
- 多租户企业组织与复杂权限。
- 专家包在线编辑器。
- 用户行为画像或完整数据看板。
- WorkBuddy 官方市场接口和逆向网络接口。
- 未由用户点击网页安装按钮触发的后台静默安装。
- 修改 `~/.workbuddy/` 之外的用户文件或 WorkBuddy 程序文件。
