# ExpertDock

WorkBuddy 专家/专家团私域分享器。开发者上传符合 WorkBuddy 2.4 规范的 ZIP，生成分享链接；用户点击安装后通过 `expertdock://` 唤起 ExpertDock Helper，直接安装到已验证的 WorkBuddy 用户目录。

## MVP

- 单管理员密码登录
- 专家 ZIP 安全校验、版本管理、R2 存储
- 固定版本分享链接、启停和安装点击统计
- 匿名分享页与 `expertdock://` 安装入口
- Helper 自动扫描、下载、SHA-256 校验、备份、原子安装、注册和失败回滚
- WorkBuddy 2.4 包结构、配置、Agent、Team、头像和 MCP 依赖校验

## 架构

- Cloudflare Workers：Web 与 API
- Cloudflare D1：专家、版本和分享元数据
- Cloudflare R2：ZIP 包
- Go：macOS/Windows ExpertDock Helper

## 本地开发

```bash
npm install
cp .dev.vars.example .dev.vars
npm run db:local
npm run dev
```

打开 <http://localhost:8787>。测试：

```bash
npm test
```

Helper 本地测试需要 Go 1.22：

```bash
cd helper
go test ./...
EXPERTDOCK_API_BASE=http://localhost:8787 go run . 'expertdock://install?token=TOKEN'
```

## Cloudflare 部署

```bash
npx wrangler login
npx wrangler d1 create expert-dock
npx wrangler r2 bucket create expert-dock-packages
```

把 D1 返回的 `database_id` 写入 `wrangler.jsonc`，然后：

```bash
npm run db:remote
npx wrangler secret put ADMIN_PASSWORD
npx wrangler secret put SESSION_SECRET
npm run deploy
```

`SESSION_SECRET` 使用至少 32 字节随机值。部署后在 GitHub 仓库变量中设置：

```text
EXPERTDOCK_API_BASE=https://你的正式域名
```

推送 `v*` 标签会构建并发布 macOS/Windows Helper。将发布产物上传到 R2 后，网站通过 `/helper` 和 `/downloads/helper/*` 直接提供文件，不跳转 GitHub：

```bash
npx wrangler r2 object put expert-dock-packages/helpers/v版本号/expertdock-helper-macos.zip --remote --file ./expertdock-helper-macos.zip
npx wrangler r2 object put expert-dock-packages/helpers/v版本号/expertdock-helper-windows.zip --remote --file ./expertdock-helper-windows.zip
```

同时将 `wrangler.jsonc` 中的 `HELPER_VERSION` 更新为对应版本号。

## Helper 目录判定

Helper 只检查当前用户的已知 WorkBuddy 位置。只有 WorkBuddy 数据目录和唯一注册脚本同时通过校验时才写入；零候选、多候选或结构不完整会立即报错，正常流程没有目录选择器。

详细产品边界见 [`agent.md`](agent.md)，自动校验规则见 [`docs/workbuddy-expert-spec-2.4.md`](docs/workbuddy-expert-spec-2.4.md)。
