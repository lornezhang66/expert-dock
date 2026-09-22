import { inspectExpertZip } from "./zip.js";

const encoder = new TextEncoder();
const MAX_AGE = 7 * 24 * 60 * 60;

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      console.error(error);
      return page("出错了", `<section class="card"><h1>操作失败</h1><p class="error">${escapeHtml(error.message || "服务器错误")}</p><p><a href="javascript:history.back()">返回</a></p></section>`, 500);
    }
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/$/, "") || "/";
  const method = request.method;

  if (method === "GET" && path === "/") return Response.redirect(`${url.origin}/dashboard`, 302);
  if (method === "GET" && path === "/health") return json({ ok: true });
  if (method === "GET" && path === "/login") return loginPage();
  if (method === "POST" && path === "/login") return login(request, env);
  if (method === "POST" && path === "/logout") return logout(request);

  let match = path.match(/^\/s\/([A-Za-z0-9_-]+)$/);
  if (method === "GET" && match) return sharePage(match[1], env);
  match = path.match(/^\/api\/helper\/install\/([A-Za-z0-9_-]+)$/);
  if (method === "GET" && match) return helperMetadata(match[1], url.origin, env);
  match = path.match(/^\/api\/shares\/([A-Za-z0-9_-]+)\/download$/);
  if (method === "GET" && match) return downloadPackage(match[1], env);
  match = path.match(/^\/api\/shares\/([A-Za-z0-9_-]+)\/install-click$/);
  if (method === "POST" && match) return countInstall(match[1], request, env);

  if (!(await isAuthenticated(request, env))) return Response.redirect(`${url.origin}/login`, 302);

  if (method === "GET" && path === "/dashboard") return dashboard(env);
  if (method === "GET" && path === "/dashboard/experts/new") return newExpertPage();
  if (method === "POST" && path === "/api/experts") return createExpert(request, env);
  match = path.match(/^\/dashboard\/experts\/([a-f0-9-]+)$/);
  if (method === "GET" && match) return expertPage(match[1], env);
  match = path.match(/^\/api\/experts\/([a-f0-9-]+)\/versions$/);
  if (method === "POST" && match) return addVersion(match[1], request, env);
  match = path.match(/^\/api\/versions\/([a-f0-9-]+)\/shares$/);
  if (method === "POST" && match) return createShare(match[1], request, env);
  match = path.match(/^\/api\/shares\/([a-f0-9-]+)\/toggle$/);
  if (method === "POST" && match) return toggleShare(match[1], request, env);

  return page("未找到", `<section class="card"><h1>404</h1><p>页面不存在。</p></section>`, 404);
}

function page(title, body, status = 200, extra = "") {
  return new Response(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)} · ExpertDock</title><style>
:root{font-family:Inter,ui-sans-serif,system-ui,-apple-system,"PingFang SC",sans-serif;color:#17202a;background:#f5f7fa}*{box-sizing:border-box}body{margin:0}header{background:#111827;color:white}nav{max-width:980px;margin:auto;padding:16px 20px;display:flex;align-items:center;justify-content:space-between}nav a{color:inherit;text-decoration:none}.brand{font-weight:800;font-size:20px}.container{max-width:980px;margin:36px auto;padding:0 20px}.card{background:white;border:1px solid #e5e7eb;border-radius:14px;padding:24px;margin-bottom:18px;box-shadow:0 4px 18px #1118270a}h1,h2{margin-top:0}h1{font-size:28px}h2{font-size:19px}label{display:block;font-weight:650;margin:14px 0 6px}input,textarea,select{width:100%;padding:11px 12px;border:1px solid #cbd5e1;border-radius:8px;font:inherit}textarea{min-height:100px}.button,button{display:inline-block;border:0;border-radius:9px;background:#2563eb;color:white;padding:10px 16px;font:inherit;font-weight:700;text-decoration:none;cursor:pointer}.button.secondary,button.secondary{background:#e5e7eb;color:#17202a}.button.danger,button.danger{background:#b91c1c}.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.between{justify-content:space-between}.muted{color:#64748b}.error{color:#b91c1c}.success{color:#047857}.tag{display:inline-block;background:#eef2ff;color:#3730a3;border-radius:999px;padding:4px 9px;font-size:13px}.expert{display:block;color:inherit;text-decoration:none}.expert:hover{border-color:#93c5fd}.meta{font-size:14px;color:#64748b}.code{font-family:ui-monospace,monospace;overflow-wrap:anywhere;background:#f1f5f9;padding:2px 6px;border-radius:5px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #e5e7eb}@media(max-width:600px){.container{margin-top:20px}.card{padding:18px}table{font-size:13px}.hide-mobile{display:none}}
</style></head><body><header><nav><a class="brand" href="/dashboard">ExpertDock</a>${extra}</nav></header><main class="container">${body}</main></body></html>`, { status, headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff", "content-security-policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'", "referrer-policy": "same-origin" } });
}

function adminNav() {
  return `<form method="post" action="/logout"><button class="secondary">退出</button></form>`;
}

function loginPage(message = "") {
  return page("登录", `<section class="card" style="max-width:440px;margin:auto"><h1>开发者登录</h1><p class="muted">管理私域 WorkBuddy 专家。</p>${message ? `<p class="error">${escapeHtml(message)}</p>` : ""}<form method="post" action="/login"><label for="password">管理密码</label><input id="password" name="password" type="password" required autofocus><p><button type="submit">登录</button></p></form></section>`);
}

async function login(request, env) {
  checkOrigin(request);
  const form = await request.formData();
  if (!env.ADMIN_PASSWORD || !env.SESSION_SECRET) return loginPage("服务端尚未配置登录密钥。");
  if (!(await secureEqual(String(form.get("password") || ""), env.ADMIN_PASSWORD))) return loginPage("密码错误。");
  const expires = Math.floor(Date.now() / 1000) + MAX_AGE;
  const value = `${expires}.${await sign(String(expires), env.SESSION_SECRET)}`;
  return new Response(null, { status: 302, headers: { location: "/dashboard", "set-cookie": `ed_session=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${MAX_AGE}` } });
}

function logout(request) {
  checkOrigin(request);
  return new Response(null, { status: 302, headers: { location: "/login", "set-cookie": "ed_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0" } });
}

async function isAuthenticated(request, env) {
  if (!env.SESSION_SECRET) return false;
  const cookie = request.headers.get("cookie") || "";
  const value = cookie.split(/;\s*/).find((v) => v.startsWith("ed_session="))?.slice(11);
  if (!value) return false;
  const [expires, signature] = value.split(".");
  return Number(expires) > Date.now() / 1000 && secureEqual(signature || "", await sign(expires, env.SESSION_SECRET));
}

async function dashboard(env) {
  const { results } = await env.DB.prepare(`SELECT e.*, v.version, COUNT(DISTINCT s.id) share_count
    FROM experts e LEFT JOIN expert_versions v ON v.id=(SELECT id FROM expert_versions WHERE expert_id=e.id ORDER BY created_at DESC LIMIT 1)
    LEFT JOIN shares s ON s.expert_version_id=v.id WHERE e.status='active' GROUP BY e.id ORDER BY e.updated_at DESC`).all();
  const items = results.length ? results.map((e) => `<a class="card expert" href="/dashboard/experts/${e.id}"><div class="row between"><div><h2>${escapeHtml(e.name)}</h2><p>${escapeHtml(e.description || "暂无简介")}</p></div><span class="tag">${e.type === "team" ? "专家团" : "专家"}</span></div><div class="meta">版本 ${escapeHtml(e.version || "-")} · ${e.share_count} 个分享链接</div></a>`).join("") : `<section class="card"><p>还没有专家，先上传一个 ZIP 包。</p></section>`;
  return page("专家管理", `<div class="row between"><div><h1>专家管理</h1><p class="muted">上传、发版并生成私域分享链接。</p></div><a class="button" href="/dashboard/experts/new">上传专家</a></div>${items}`, 200, adminNav());
}

function newExpertPage() {
  return page("上传专家", `<section class="card"><h1>上传专家</h1><form method="post" action="/api/experts" enctype="multipart/form-data"><label for="package">专家 ZIP 包</label><input id="package" name="package" type="file" accept=".zip,application/zip" required><label for="description">展示简介</label><textarea id="description" name="description" maxlength="500" placeholder="留空时使用 plugin.json 的描述"></textarea><label for="releaseNotes">版本说明</label><textarea id="releaseNotes" name="releaseNotes" maxlength="1000"></textarea><p><button type="submit">上传并创建</button> <a class="button secondary" href="/dashboard">取消</a></p></form></section>`, 200, adminNav());
}

async function createExpert(request, env) {
  checkOrigin(request);
  const upload = await readUpload(request, env);
  const id = crypto.randomUUID();
  const versionId = crypto.randomUUID();
  const key = `packages/${id}/${upload.manifest.version}-${crypto.randomUUID()}.zip`;
  await env.PACKAGES.put(key, upload.bytes, { httpMetadata: { contentType: "application/zip" }, customMetadata: { sha256: upload.sha256 } });
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO experts (id,name,description,type) VALUES (?,?,?,?)").bind(id, upload.manifest.name, upload.description, upload.manifest.expertType === "team" ? "team" : "expert"),
      env.DB.prepare("INSERT INTO expert_versions (id,expert_id,version,package_key,package_sha256,package_size,manifest,release_notes) VALUES (?,?,?,?,?,?,?,?)").bind(versionId, id, upload.manifest.version, key, upload.sha256, upload.bytes.length, JSON.stringify(upload.manifest), upload.releaseNotes),
    ]);
  } catch (error) {
    await env.PACKAGES.delete(key);
    throw error;
  }
  return redirect(`/dashboard/experts/${id}`);
}

async function expertPage(id, env) {
  const expert = await env.DB.prepare("SELECT * FROM experts WHERE id=?").bind(id).first();
  if (!expert) return page("未找到", `<section class="card"><h1>专家不存在</h1></section>`, 404, adminNav());
  const { results: versions } = await env.DB.prepare("SELECT * FROM expert_versions WHERE expert_id=? ORDER BY created_at DESC").bind(id).all();
  const { results: shares } = await env.DB.prepare(`SELECT s.*,v.version FROM shares s JOIN expert_versions v ON v.id=s.expert_version_id WHERE v.expert_id=? ORDER BY s.created_at DESC`).bind(id).all();
  const versionRows = versions.map((v) => `<tr><td>${escapeHtml(v.version)}</td><td>${formatBytes(v.package_size)}</td><td>${escapeHtml(v.created_at)}</td><td><form method="post" action="/api/versions/${v.id}/shares"><button>生成分享链接</button></form></td></tr>`).join("");
  const shareRows = shares.map((s) => `<tr><td>${escapeHtml(s.version)}</td><td><a href="/s/${s.token}" target="_blank">/s/${escapeHtml(s.token.slice(0, 10))}…</a></td><td>${s.enabled ? "有效" : "停用"}</td><td>${s.install_clicks}</td><td><form method="post" action="/api/shares/${s.id}/toggle"><button class="${s.enabled ? "danger" : ""}">${s.enabled ? "停用" : "启用"}</button></form></td></tr>`).join("") || `<tr><td colspan="5" class="muted">暂无分享链接</td></tr>`;
  return page(expert.name, `<p><a href="/dashboard">← 返回</a></p><section class="card"><div class="row between"><div><h1>${escapeHtml(expert.name)}</h1><p>${escapeHtml(expert.description)}</p></div><span class="tag">${expert.type === "team" ? "专家团" : "专家"}</span></div></section><section class="card"><h2>版本</h2><table><thead><tr><th>版本</th><th>大小</th><th class="hide-mobile">上传时间</th><th></th></tr></thead><tbody>${versionRows}</tbody></table><details><summary style="margin-top:18px;cursor:pointer;font-weight:700">上传新版本</summary><form method="post" action="/api/experts/${id}/versions" enctype="multipart/form-data"><label>专家 ZIP 包</label><input name="package" type="file" accept=".zip,application/zip" required><label>版本说明</label><textarea name="releaseNotes" maxlength="1000"></textarea><p><button>上传版本</button></p></form></details></section><section class="card"><h2>分享链接</h2><table><thead><tr><th>版本</th><th>链接</th><th>状态</th><th>安装</th><th></th></tr></thead><tbody>${shareRows}</tbody></table></section>`, 200, adminNav());
}

async function addVersion(expertId, request, env) {
  checkOrigin(request);
  const expert = await env.DB.prepare("SELECT * FROM experts WHERE id=?").bind(expertId).first();
  if (!expert) throw new Error("专家不存在");
  const upload = await readUpload(request, env);
  if (upload.manifest.name !== expert.name) throw new Error("新版本 plugin.json.name 与专家不一致");
  const id = crypto.randomUUID();
  const key = `packages/${expertId}/${upload.manifest.version}-${crypto.randomUUID()}.zip`;
  await env.PACKAGES.put(key, upload.bytes, { httpMetadata: { contentType: "application/zip" }, customMetadata: { sha256: upload.sha256 } });
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO expert_versions (id,expert_id,version,package_key,package_sha256,package_size,manifest,release_notes) VALUES (?,?,?,?,?,?,?,?)").bind(id, expertId, upload.manifest.version, key, upload.sha256, upload.bytes.length, JSON.stringify(upload.manifest), upload.releaseNotes),
      env.DB.prepare("UPDATE experts SET description=?,type=?,updated_at=CURRENT_TIMESTAMP WHERE id=?").bind(upload.description || expert.description, upload.manifest.expertType === "team" ? "team" : "expert", expertId),
    ]);
  } catch (error) {
    await env.PACKAGES.delete(key);
    throw error;
  }
  return redirect(`/dashboard/experts/${expertId}`);
}

async function createShare(versionId, request, env) {
  checkOrigin(request);
  const version = await env.DB.prepare("SELECT expert_id FROM expert_versions WHERE id=?").bind(versionId).first();
  if (!version) throw new Error("版本不存在");
  const token = randomToken();
  await env.DB.prepare("INSERT INTO shares (id,expert_version_id,token) VALUES (?,?,?)").bind(crypto.randomUUID(), versionId, token).run();
  return redirect(`/dashboard/experts/${version.expert_id}`);
}

async function toggleShare(shareId, request, env) {
  checkOrigin(request);
  const share = await env.DB.prepare("SELECT s.enabled,v.expert_id FROM shares s JOIN expert_versions v ON v.id=s.expert_version_id WHERE s.id=?").bind(shareId).first();
  if (!share) throw new Error("分享链接不存在");
  await env.DB.prepare("UPDATE shares SET enabled=? WHERE id=?").bind(share.enabled ? 0 : 1, shareId).run();
  return redirect(`/dashboard/experts/${share.expert_id}`);
}

async function sharePage(token, env) {
  const item = await getShare(token, env);
  if (!item) return page("链接不可用", `<section class="card"><h1>分享链接不可用</h1><p>链接不存在、已停用或已过期。</p></section>`, 404);
  const manifest = JSON.parse(item.manifest);
  const displayName = manifest.displayName?.zh || manifest.displayName?.en || item.name;
  const dependencies = manifest.dependencies ? `<h2>依赖声明</h2><pre class="code">${escapeHtml(JSON.stringify(manifest.dependencies, null, 2))}</pre>` : "";
  return page(displayName, `<section class="card"><span class="tag">${item.type === "team" ? "专家团" : "专家"}</span><h1 style="margin-top:14px">${escapeHtml(displayName)}</h1><p>${escapeHtml(item.description)}</p><p class="meta">版本 ${escapeHtml(item.version)} · SHA-256 <span class="code">${escapeHtml(item.package_sha256.slice(0, 16))}…</span></p>${dependencies}<p class="muted">此内容来自第三方开发者。安装前请确认来源和所需权限。</p><p><button id="install">安装到 WorkBuddy</button> <a class="button secondary" href="${escapeHtml(env.HELPER_DOWNLOAD_URL || "#")}" target="_blank" rel="noopener">首次使用？安装 Helper</a></p><p id="hint" class="muted"></p></section><script>document.getElementById('install').onclick=async()=>{document.getElementById('hint').textContent='正在唤起 ExpertDock Helper…';fetch('/api/shares/${encodeURIComponent(token)}/install-click',{method:'POST',keepalive:true});location.href='expertdock://install?token=${encodeURIComponent(token)}';setTimeout(()=>document.getElementById('hint').textContent='未唤起？请先安装 ExpertDock Helper，然后重试。',1800)}</script>`);
}

async function helperMetadata(token, origin, env) {
  const item = await getShare(token, env);
  if (!item) return json({ error: "分享链接不存在、已停用或已过期" }, 404);
  return json({ name: item.name, type: item.type, version: item.version, sha256: item.package_sha256, size: item.package_size, downloadUrl: `${origin}/api/shares/${encodeURIComponent(token)}/download` }, 200, { "cache-control": "no-store" });
}

async function downloadPackage(token, env) {
  const item = await getShare(token, env);
  if (!item) return json({ error: "分享链接不存在、已停用或已过期" }, 404);
  const object = await env.PACKAGES.get(item.package_key);
  if (!object) return json({ error: "专家包不存在" }, 404);
  return new Response(object.body, { headers: { "content-type": "application/zip", "content-length": String(item.package_size), "content-disposition": `attachment; filename="${item.name}-${item.version}.zip"`, "x-expertdock-sha256": item.package_sha256, "cache-control": "private, no-store", "x-content-type-options": "nosniff" } });
}

async function countInstall(token, request, env) {
  checkOrigin(request);
  await env.DB.prepare("UPDATE shares SET install_clicks=install_clicks+1 WHERE token=? AND enabled=1 AND (expires_at IS NULL OR expires_at>CURRENT_TIMESTAMP)").bind(token).run();
  return new Response(null, { status: 204 });
}

async function getShare(token, env) {
  return env.DB.prepare(`SELECT s.id,e.name,e.description,e.type,v.version,v.package_key,v.package_sha256,v.package_size,v.manifest
    FROM shares s JOIN expert_versions v ON v.id=s.expert_version_id JOIN experts e ON e.id=v.expert_id
    WHERE s.token=? AND s.enabled=1 AND e.status='active' AND (s.expires_at IS NULL OR s.expires_at>CURRENT_TIMESTAMP)`).bind(token).first();
}

async function readUpload(request, env) {
  checkOrigin(request);
  const form = await request.formData();
  const file = form.get("package");
  if (!file || typeof file.arrayBuffer !== "function") throw new Error("请选择 ZIP 文件");
  const max = Number(env.MAX_UPLOAD_BYTES || 20971520);
  if (file.size < 1 || file.size > max) throw new Error(`ZIP 大小必须小于 ${formatBytes(max)}`);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const inspected = inspectExpertZip(bytes);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  const sha256 = [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const description = String(form.get("description") || inspected.manifest.displayDescription?.zh || inspected.manifest.description || "").trim().slice(0, 500);
  return { bytes, manifest: inspected.manifest, sha256, description, releaseNotes: String(form.get("releaseNotes") || "").trim().slice(0, 1000) };
}

function checkOrigin(request) {
  const origin = request.headers.get("origin");
  if (origin && origin !== new URL(request.url).origin) throw new Error("拒绝跨站请求");
}

async function sign(value, secret) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const result = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return base64url(new Uint8Array(result));
}

async function secureEqual(a, b) {
  const [ah, bh] = await Promise.all([crypto.subtle.digest("SHA-256", encoder.encode(a)), crypto.subtle.digest("SHA-256", encoder.encode(b))]);
  const av = new Uint8Array(ah), bv = new Uint8Array(bh);
  let diff = 0;
  for (let i = 0; i < av.length; i++) diff |= av[i] ^ bv[i];
  return diff === 0;
}

function randomToken() {
  return base64url(crypto.getRandomValues(new Uint8Array(24)));
}

function base64url(bytes) {
  let value = "";
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[c]);
}

function formatBytes(bytes) {
  return bytes < 1024 * 1024 ? `${Math.ceil(bytes / 1024)} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function redirect(location) {
  return new Response(null, { status: 303, headers: { location } });
}

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });
}
