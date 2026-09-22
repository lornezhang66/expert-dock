# WorkBuddy 专家开发规范 2.4 — ExpertDock 校验摘要

来源：项目所有者提供，日期 2026-07-31。上传端和 Helper 均以此版本为兼容基线。

## 包结构

- 插件根目录必须包含 `.codebuddy-plugin/plugin.json`、`agents/`、`avatars/`。
- `skills/`、`bin/`、`settings.json`、`.mcp.json` 按需位于插件根目录，不能放入 `.codebuddy-plugin/`。
- Team 型必须包含 `settings.json`。

## plugin.json 必检规则

- `name`：小写字母、数字、连字符；`version`：语义化版本。
- `expertType`：`agent` 或 `team`。
- `author`、`agents`、`agentName` 及全部展示字段齐全。
- `plugin === name`。
- `displayDescription.zh` 为 40–50 字符。
- `categoryId` 属于规范定义的 15 个分类之一。
- `tags` 与 `quickPrompts` 各 3 项，均含中英文。
- `defaultInitPrompt` 与第一条 `quickPrompts` 一致。
- Agent、Skill、头像、MCP 路径必须真实存在且不能逃逸插件根目录。

## Agent 必检规则

- Agent MD 文件包含合法 YAML frontmatter。
- frontmatter `name` 与文件名一致，并包含 `description`、`displayName`、`profession`。
- frontmatter 禁止声明 `tools`。

## Team 必检规则

- `agentName`、`teamInfo.leadAgent`、主理人 MD 文件名和 `settings.json.agent` 一致。
- `teamInfo.memberAgents`、`members[].id`、Agent MD 文件相互一致。
- 主理人不能命名为通用 `team-lead`。
- 主理人正文包含“团队协作机制（铁律）”并明确使用 `AgentTool`。

## 头像与依赖

- 头像只能使用包内 PNG/JPG，512×512，单张不超过 500 KB。
- Token MCP 的 `tokenSchema.fields[].key` 必须与 headers 中 `${VAR}` 一一对应。
- 专家包禁止硬编码真实 Token 或密钥；此项仍需开发者人工复核。

完整规范以项目所有者提供的 2.4 原文为准；本文件只记录当前可自动验证的规则。
