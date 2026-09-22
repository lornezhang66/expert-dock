import { unzipSync, strFromU8 } from "fflate";
import { parse as parseYaml } from "yaml";

const MAX_FILES = 1000;
const MAX_UNPACKED = 100 * 1024 * 1024;
const MAX_IMAGE = 500 * 1024;
const CATEGORIES = new Set([
  "01-ProductDesign", "02-Engineering", "03-GameSpatial", "04-DataAI", "05-MarketingGrowth",
  "06-ContentCreative", "07-SalesCommerce", "08-FinanceInvestment", "09-OperationsHR", "10-ProjectQuality",
  "11-SecurityCompliance", "12-IndustryConsultant", "13-TencentZone", "14-WorldWise", "15-Education",
]);

function cleanPath(name) {
  const path = name.replaceAll("\\", "/").replace(/^\.\//, "");
  if (!path || path.startsWith("/") || /^[A-Za-z]:\//.test(path) || path.split("/").includes("..")) {
    throw new Error(`压缩包包含不安全路径：${name}`);
  }
  return path;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function localized(value, field) {
  assert(value && typeof value === "object" && typeof value.zh === "string" && value.zh.trim() && typeof value.en === "string" && value.en.trim(), `${field} 必须包含非空的 zh 和 en`);
}

function packagePath(value, field) {
  assert(typeof value === "string" && value.trim(), `${field} 路径无效`);
  const path = cleanPath(value);
  assert(!path.startsWith(".codebuddy-plugin/"), `${field} 不能位于 .codebuddy-plugin/ 内`);
  return path;
}

function readCentralDirectory(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
    if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("不是有效的 ZIP 文件");
  const count = view.getUint16(eocd + 10, true);
  assert(count && count <= MAX_FILES, `压缩包文件数必须在 1-${MAX_FILES} 之间`);

  let offset = view.getUint32(eocd + 16, true), total = 0;
  const entries = [];
  const decoder = new TextDecoder();
  for (let i = 0; i < count; i++) {
    assert(offset + 46 <= bytes.length && view.getUint32(offset, true) === 0x02014b50, "ZIP 中央目录损坏");
    const size = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true);
    const extraLength = view.getUint16(offset + 30, true);
    const commentLength = view.getUint16(offset + 32, true);
    const external = view.getUint32(offset + 38, true);
    const end = offset + 46 + nameLength;
    assert(end <= bytes.length, "ZIP 文件名损坏");
    const name = cleanPath(decoder.decode(bytes.subarray(offset + 46, end)));
    assert(((external >>> 16) & 0xf000) !== 0xa000, `压缩包不允许符号链接：${name}`);
    total += size;
    assert(total <= MAX_UNPACKED, "解压后总大小超过 100 MB");
    entries.push({ name, size });
    offset = end + extraLength + commentLength;
  }
  return { entries, total };
}

function imageDimensions(bytes) {
  if (bytes.length >= 36 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const ihdr = String.fromCharCode(...bytes.subarray(12, 16));
    const iend = String.fromCharCode(...bytes.subarray(bytes.length - 8, bytes.length - 4));
    assert(ihdr === "IHDR" && iend === "IEND", "头像 PNG 结构无效");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return [view.getUint32(16), view.getUint32(20)];
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9) {
    let i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] !== 0xff) { i++; continue; }
      const marker = bytes[i + 1];
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
        return [(bytes[i + 7] << 8) | bytes[i + 8], (bytes[i + 5] << 8) | bytes[i + 6]];
      }
      const length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length < 2) break;
      i += length + 2;
    }
  }
  throw new Error("头像必须是有效的 PNG 或 JPG");
}

function validateMcpServers(servers, field) {
  if (!servers || typeof servers !== "object" || Array.isArray(servers)) return;
  for (const [name, server] of Object.entries(servers)) {
    assert(server && typeof server === "object", `${field}.${name} 配置无效`);
    const auth = server["x-workbuddy"]?.auth;
    if (auth?.type !== "token") continue;
    const fields = auth.tokenSchema?.fields;
    assert(Array.isArray(fields) && fields.length, `${field}.${name} 的 tokenSchema.fields 不能为空`);
    const headers = JSON.stringify(server.headers || {});
    for (const item of fields) {
      assert(item?.key && headers.includes(`\${${item.key}}`), `${field}.${name} 缺少 \${${item?.key || "VAR"}} 请求头占位`);
    }
    const placeholders = [...headers.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map((m) => m[1]);
    const keys = new Set(fields.map((item) => item.key));
    for (const key of placeholders) assert(keys.has(key), `${field}.${name} 的 \${${key}} 没有对应 tokenSchema 字段`);
  }
}

function unzipSelected(bytes, wanted) {
  const raw = unzipSync(bytes, { filter: ({ name }) => wanted.has(cleanPath(name)) });
  return new Map(Object.entries(raw).map(([name, data]) => [cleanPath(name), data]));
}

function parseFrontmatter(text, file) {
  const match = text.match(/^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  assert(match, `${file} 缺少 YAML frontmatter`);
  let data;
  try { data = parseYaml(match[1]); } catch { throw new Error(`${file} 的 YAML frontmatter 无效`); }
  assert(data && typeof data === "object", `${file} 的 frontmatter 无效`);
  assert(!Object.hasOwn(data, "tools"), `${file} 的 frontmatter 不可声明 tools`);
  assert(typeof data.name === "string" && data.name, `${file} 缺少 frontmatter.name`);
  assert(typeof data.description === "string" && data.description.trim(), `${file} 缺少 frontmatter.description`);
  localized(data.displayName, `${file} displayName`);
  localized(data.profession, `${file} profession`);
  return { data, body: text.slice(match[0].length) };
}

export function inspectExpertZip(bytes) {
  const { entries, total } = readCentralDirectory(bytes);
  const manifestEntries = entries.filter(({ name }) => name === ".codebuddy-plugin/plugin.json" || name.endsWith("/.codebuddy-plugin/plugin.json"));
  assert(manifestEntries.length === 1, manifestEntries.length ? "压缩包只能包含一个 plugin.json" : "缺少 .codebuddy-plugin/plugin.json");
  const manifestPath = manifestEntries[0].name;
  const root = manifestPath.slice(0, -".codebuddy-plugin/plugin.json".length).replace(/\/$/, "");
  const prefix = root ? `${root}/` : "";
  for (const { name } of entries) assert(!root || name === root || name.startsWith(prefix), "压缩包包含专家目录以外的文件");

  const byRelative = new Map(entries.map((entry) => [entry.name.slice(prefix.length), entry]));
  const manifestFiles = unzipSelected(bytes, new Set([manifestPath]));
  const manifestBytes = manifestFiles.get(manifestPath);
  assert(manifestBytes && manifestBytes.length <= 1024 * 1024, "plugin.json 无效或超过 1 MB");
  let manifest;
  try { manifest = JSON.parse(strFromU8(manifestBytes)); } catch { throw new Error("plugin.json 不是有效 JSON"); }

  assert(/^[a-z0-9][a-z0-9-]{1,63}$/.test(manifest.name || "") && !manifest.name.endsWith("-"), "plugin.json.name 必须是 2-64 位小写字母、数字或连字符");
  assert(/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(manifest.version || ""), "plugin.json.version 必须是语义化版本号");
  assert(["agent", "team"].includes(manifest.expertType), "plugin.json.expertType 必须是 agent 或 team");
  assert(typeof manifest.description === "string" && manifest.description.trim(), "plugin.json.description 不能为空");
  assert(manifest.author?.name && manifest.author?.email, "plugin.json.author 必须包含 name 和 email");
  assert(Array.isArray(manifest.agents) && manifest.agents.length, "plugin.json.agents 不能为空");
  assert(typeof manifest.agentName === "string" && manifest.agentName, "plugin.json.agentName 不能为空");
  localized(manifest.displayName, "displayName"); localized(manifest.profession, "profession"); localized(manifest.displayDescription, "displayDescription");
  assert(Array.from(manifest.displayDescription.zh.trim()).length >= 40 && Array.from(manifest.displayDescription.zh.trim()).length <= 50, "displayDescription.zh 必须为 40-50 个字符");
  assert(CATEGORIES.has(manifest.categoryId), "categoryId 不在 WorkBuddy 行业分类中");
  localized(manifest.defaultInitPrompt, "defaultInitPrompt");
  assert(manifest.plugin === manifest.name, "plugin 必须与 name 一致");
  assert(Array.isArray(manifest.tags) && manifest.tags.length === 3, "tags 必须恰好包含 3 项");
  manifest.tags.forEach((item, i) => localized(item, `tags[${i}]`));
  assert(Array.isArray(manifest.quickPrompts) && manifest.quickPrompts.length === 3, "quickPrompts 必须恰好包含 3 项");
  manifest.quickPrompts.forEach((item, i) => localized(item, `quickPrompts[${i}]`));
  assert(manifest.defaultInitPrompt.zh === manifest.quickPrompts[0].zh && manifest.defaultInitPrompt.en === manifest.quickPrompts[0].en, "defaultInitPrompt 必须与 quickPrompts 第一项一致");

  const required = new Set([manifestPath]);
  const agentPaths = manifest.agents.map((path, i) => {
    const clean = packagePath(path, `agents[${i}]`);
    assert(clean.startsWith("agents/") && clean.endsWith(".md"), `agents[${i}] 必须指向 agents/ 下的 MD 文件`);
    assert(byRelative.has(clean), `缺少 Agent 文件：${clean}`);
    required.add(prefix + clean); return clean;
  });
  assert(agentPaths.some((path) => path === `agents/${manifest.agentName}.md`), "agentName 必须对应 agents/ 中的 MD 文件");

  const imagePaths = new Set();
  const addImage = (value, field) => {
    const clean = packagePath(value, field);
    assert(/^avatars\/.+\.(png|jpe?g)$/i.test(clean), `${field} 必须是 avatars/ 下的 PNG 或 JPG`);
    const entry = byRelative.get(clean);
    assert(entry, `缺少头像：${clean}`); assert(entry.size <= MAX_IMAGE, `${clean} 超过 500 KB`);
    imagePaths.add(clean); required.add(prefix + clean);
  };
  addImage(manifest.avatar, "avatar");

  if (Array.isArray(manifest.skills)) for (const [i, path] of manifest.skills.entries()) {
    const clean = packagePath(path, `skills[${i}]`).replace(/\/$/, "");
    assert(clean.startsWith("skills/") && byRelative.has(`${clean}/SKILL.md`), `缺少 ${clean}/SKILL.md`);
  }

  let mcpPath = null;
  const mcp = manifest.dependencies?.mcpServers;
  if (typeof mcp === "string" || Array.isArray(mcp)) for (const [i, value] of (Array.isArray(mcp) ? mcp : [mcp]).entries()) {
    const clean = packagePath(value, `dependencies.mcpServers[${i}]`);
    assert(byRelative.has(clean), `缺少 MCP 配置：${clean}`); required.add(prefix + clean); mcpPath ||= clean;
  } else validateMcpServers(mcp, "dependencies.mcpServers");
  if (!mcp && byRelative.has(".mcp.json")) { mcpPath = ".mcp.json"; required.add(prefix + mcpPath); }

  if (manifest.expertType === "team") {
    assert(manifest.teamInfo && typeof manifest.teamInfo === "object", "Team 型必须提供 teamInfo");
    assert(manifest.teamInfo.leadAgent === manifest.agentName, "teamInfo.leadAgent 必须与 agentName 一致");
    assert(Array.isArray(manifest.teamInfo.memberAgents), "teamInfo.memberAgents 必须是数组");
    assert(Array.isArray(manifest.members) && manifest.members.length >= 2, "Team 型必须提供至少两位 members");
    assert(JSON.stringify(manifest.profession) === JSON.stringify(manifest.displayName), "Team 型 profession 必须与 displayName 一致");
    const ids = new Set(); let leads = 0;
    for (const [i, member] of manifest.members.entries()) {
      assert(member?.id && !ids.has(member.id), `members[${i}].id 缺失或重复`); ids.add(member.id);
      localized(member.name, `members[${i}].name`); localized(member.profession, `members[${i}].profession`); addImage(member.avatar, `members[${i}].avatar`);
      assert(["lead", "member"].includes(member.role), `members[${i}].role 无效`); if (member.role === "lead") leads++;
    }
    assert(leads === 1 && manifest.members.find((m) => m.id === manifest.agentName)?.role === "lead", "members 必须包含唯一且正确的主理人");
    const memberIds = new Set(manifest.teamInfo.memberAgents);
    const agentIds = new Set(agentPaths.map((path) => path.slice(7, -3)));
    assert(memberIds.size === manifest.teamInfo.memberAgents.length && [...ids].every((id) => id === manifest.agentName || memberIds.has(id)) && memberIds.size === ids.size - 1, "teamInfo.memberAgents 与 members 不一致");
    assert([...ids].every((id) => agentIds.has(id)) && agentIds.size === ids.size, "agents 文件与 members 不一致");
    assert(manifest.agentName !== "team-lead" && !agentPaths.includes("agents/team-lead.md"), "主理人不可使用通用 team-lead 文件名");
    assert(byRelative.has("settings.json"), "Team 型缺少 settings.json"); required.add(prefix + "settings.json");
  }

  const selected = unzipSelected(bytes, required);
  const agentDocs = new Map();
  for (const path of agentPaths) {
    const doc = parseFrontmatter(strFromU8(selected.get(prefix + path)), path);
    const fileName = path.slice(path.lastIndexOf("/") + 1, -3);
    assert(doc.data.name === fileName, `${path} 的 frontmatter.name 必须与文件名一致`);
    agentDocs.set(fileName, doc);
  }
  assert(agentDocs.has(manifest.agentName), "找不到主 Agent 定义");
  if (manifest.expertType === "team") {
    let settings;
    try { settings = JSON.parse(strFromU8(selected.get(prefix + "settings.json"))); } catch { throw new Error("settings.json 不是有效 JSON"); }
    assert(settings.agent === manifest.agentName, "settings.json.agent 必须与 agentName 一致");
    const leadBody = agentDocs.get(manifest.agentName).body;
    assert(leadBody.includes("团队协作机制") && leadBody.includes("铁律") && leadBody.includes("AgentTool"), "主理人 MD 必须包含团队协作机制（铁律）并明确使用 AgentTool");
  }
  for (const path of imagePaths) {
    const [width, height] = imageDimensions(selected.get(prefix + path));
    assert(width === 512 && height === 512, `${path} 必须为 512×512，当前为 ${width}×${height}`);
  }
  if (mcpPath) {
    let config;
    try { config = JSON.parse(strFromU8(selected.get(prefix + mcpPath))); } catch { throw new Error(`${mcpPath} 不是有效 JSON`); }
    validateMcpServers(config.mcpServers || config, mcpPath);
  }

  return { manifest, manifestPath, fileCount: entries.length, unpackedSize: total };
}
