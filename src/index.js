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

  if (method === "GET" && path === "/") return homePage();
  if (method === "GET" && path === "/experts") return sharedExpertsPage(env);
  if (method === "GET" && path === "/health") return json({ ok: true });
  if (method === "GET" && path === "/login") return loginPage();
  if (method === "GET" && path === "/helper") return helperPage(env);
  if (method === "GET" && path === "/downloads/helper/macos") return downloadHelper("macos", env);
  if (method === "GET" && path === "/downloads/helper/windows") return downloadHelper("windows", env);
  if (method === "POST" && path === "/login") return login(request, env);
  if (method === "POST" && path === "/open") return openShareLink(request);
  if (method === "POST" && path === "/logout") return logout(request);

  let match = path.match(/^\/s\/([A-Za-z0-9_-]+)$/);
  if (method === "GET" && match) return sharePage(match[1], env);
  match = path.match(/^\/api\/helper\/install\/([A-Za-z0-9_-]+)$/);
  if (method === "GET" && match) return helperMetadata(match[1], url.origin, env);
  match = path.match(/^\/api\/helper\/latest\/(macos|windows)$/);
  if (method === "GET" && match) return helperLatest(match[1], url.origin, env);
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
:root{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text","Helvetica Neue","PingFang SC",Arial,sans-serif;color:#1d1d1f;background:#f5f5f7;font-synthesis:none}*{box-sizing:border-box}html{min-height:100%;background:#f5f5f7}body{margin:0;min-height:100vh;background:radial-gradient(circle at 50% -10%,#fff 0,#f5f5f7 38rem);letter-spacing:-.011em}header{position:sticky;top:0;z-index:10;background:#fbfbfdcc;border-bottom:1px solid #0000000d;-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px)}nav{max-width:1040px;height:56px;margin:auto;padding:0 24px;display:flex;align-items:center;justify-content:space-between}nav a{color:inherit;text-decoration:none}.brand{display:inline-flex;align-items:center;gap:10px;font-weight:650;font-size:16px;letter-spacing:-.02em}.brand-mark{display:grid;place-items:center;width:28px;height:28px;border-radius:9px;background:linear-gradient(145deg,#111,#3a3a3c);color:#fff;font-size:10px;font-weight:750;letter-spacing:-.04em;box-shadow:inset 0 1px #ffffff3d,0 2px 8px #0002}.container{max-width:1040px;margin:0 auto;padding:64px 24px 96px}.card{background:#fff;border:1px solid #0000000a;border-radius:24px;padding:30px;margin-bottom:20px;box-shadow:0 1px 2px #00000008,0 12px 36px #0000000a;overflow-x:auto}h1,h2{margin:0;color:#1d1d1f;letter-spacing:-.035em}h1{font-size:clamp(32px,5vw,48px);line-height:1.04;font-weight:700}h2{font-size:21px;line-height:1.2;font-weight:650;margin-bottom:12px}p{line-height:1.55}.page-heading{margin-bottom:34px}.page-heading p{font-size:18px;margin:10px 0 0}.eyebrow{color:#6e6e73;font-size:13px;font-weight:650;letter-spacing:.04em;text-transform:uppercase}.hero-card{padding:clamp(30px,6vw,64px);background:linear-gradient(145deg,#fff 0%,#fafafa 65%,#f1f5ff 100%)}.hero-card>p{max-width:720px}.share-card{max-width:800px;margin:24px auto;padding:clamp(32px,7vw,68px)}.share-card h1{margin:18px 0}.share-card>.summary{font-size:19px;color:#424245;max-width:640px}.login-card{max-width:440px;margin:7vh auto 0;padding:42px}.login-card h1{font-size:40px}.login-card button{width:100%;margin-top:8px}label{display:block;font-size:14px;font-weight:600;margin:20px 0 8px;color:#3a3a3c}input,textarea,select{width:100%;padding:13px 14px;border:1px solid #d2d2d7;border-radius:12px;background:#fff;color:#1d1d1f;font:inherit;outline:none;transition:border-color .18s,box-shadow .18s}input:focus,textarea:focus,select:focus{border-color:#0071e3;box-shadow:0 0 0 4px #0071e31f}input[type=file]{background:#f5f5f7}textarea{min-height:112px;resize:vertical}.button,button{display:inline-flex;align-items:center;justify-content:center;min-height:42px;border:0;border-radius:999px;background:#0071e3;color:#fff;padding:10px 19px;font:inherit;font-size:15px;font-weight:600;text-decoration:none;cursor:pointer;transition:transform .16s,background .16s,box-shadow .16s}.button:hover,button:hover{background:#0077ed;box-shadow:0 5px 14px #0071e326}.button:active,button:active{transform:scale(.98)}.button:focus-visible,button:focus-visible,a:focus-visible{outline:3px solid #0071e34d;outline-offset:3px}.button.secondary,button.secondary{background:#e8e8ed;color:#1d1d1f}.button.secondary:hover,button.secondary:hover{background:#dedee3;box-shadow:none}.button.danger,button.danger{background:#ff3b30}.row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.between{justify-content:space-between}.muted{color:#6e6e73}.error{color:#d70015;background:#fff2f2;border-radius:12px;padding:11px 13px}.success{color:#248a3d}.tag{display:inline-flex;align-items:center;background:#e8f2ff;color:#06c;border-radius:999px;padding:6px 11px;font-size:13px;font-weight:600}.expert{display:block;color:inherit;text-decoration:none;transition:transform .2s,box-shadow .2s,border-color .2s}.expert h2{margin-bottom:8px}.expert p{color:#515154;margin:0 0 18px}.expert:hover{transform:translateY(-2px);border-color:#0000000f;box-shadow:0 2px 4px #00000008,0 18px 48px #00000012}.meta{font-size:13px;color:#86868b}.code{font-family:"SFMono-Regular",Consolas,monospace;font-size:.88em;overflow-wrap:anywhere;background:#f2f2f7;padding:3px 7px;border-radius:7px}pre.code{padding:16px;white-space:pre-wrap;border:1px solid #0000000a}details{border-top:1px solid #e5e5ea;padding-top:18px}summary{list-style:none}summary::-webkit-details-marker{display:none}table{width:100%;border-collapse:collapse;min-width:560px}th,td{text-align:left;padding:14px 12px;border-bottom:1px solid #e5e5ea}th{font-size:12px;color:#86868b;text-transform:uppercase;letter-spacing:.04em;font-weight:600}td{font-size:14px}td a{color:#06c;text-decoration:none}.card>a,.container>p>a{color:#06c;text-decoration:none}.nav-links{display:flex;align-items:center;gap:20px;font-size:13px}.nav-links a{color:#424245}.nav-links a:hover,.nav-links a.active{color:#06c}.expert-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}.expert-grid .card{margin:0}.landing{margin-top:-20px}.landing-hero{text-align:center;padding:72px 0 58px}.landing-hero h1{max-width:820px;margin:14px auto;font-size:clamp(44px,7vw,76px);line-height:.98}.landing-hero .lead{max-width:680px;margin:22px auto 30px;color:#6e6e73;font-size:clamp(18px,2.5vw,23px);line-height:1.45}.hero-actions{display:flex;justify-content:center;gap:12px;flex-wrap:wrap}.link-box{max-width:760px;margin:0 auto 72px;padding:34px;background:#fff;border:1px solid #0000000a;border-radius:26px;box-shadow:0 18px 50px #0000000d}.link-box h2{text-align:center;font-size:26px}.link-box>p{text-align:center}.link-form{display:grid;grid-template-columns:1fr auto;gap:10px;margin-top:22px}.link-form input{height:48px;border-radius:14px}.link-form button{border-radius:14px;min-width:108px}.steps-section{padding:28px 0 76px}.section-heading{text-align:center;max-width:650px;margin:0 auto 34px}.section-heading h2{font-size:36px}.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}.step{padding:28px;background:#fff;border:1px solid #0000000a;border-radius:22px}.step-number{display:grid;place-items:center;width:34px;height:34px;margin-bottom:24px;border-radius:50%;background:#1d1d1f;color:#fff;font-size:14px;font-weight:700}.step h3{margin:0 0 8px;font-size:20px;letter-spacing:-.025em}.step p{margin:0;color:#6e6e73}.trust-panel{display:grid;grid-template-columns:1.15fr .85fr;gap:18px;padding:clamp(28px,6vw,56px);background:linear-gradient(145deg,#101114,#25262a);color:#f5f5f7;border-radius:28px}.trust-panel h2{color:#fff;font-size:36px}.trust-panel p{color:#aeaeb2}.trust-points{display:grid;gap:12px}.trust-point{padding:14px 16px;background:#ffffff0d;border:1px solid #ffffff12;border-radius:15px;font-size:14px}.landing-footer{text-align:center;padding:54px 0 0;color:#86868b;font-size:13px}@media(max-width:700px){nav{padding:0 18px}.container{padding:38px 16px 64px}.expert-grid{grid-template-columns:1fr}.card{padding:22px;border-radius:20px}.hero-card,.share-card{padding:28px}.login-card{margin-top:3vh}.page-heading{align-items:flex-start}h1{font-size:34px}.button,button{min-height:44px}.hide-mobile{display:none}.nav-links a:first-child{display:none}.landing{margin-top:-12px}.landing-hero{padding:50px 0 42px}.landing-hero h1{font-size:46px}.link-box{padding:24px;margin-bottom:52px}.link-form{grid-template-columns:1fr}.link-form button{width:100%}.steps{grid-template-columns:1fr}.trust-panel{grid-template-columns:1fr}.section-heading h2,.trust-panel h2{font-size:30px}}
</style></head><body><header><nav><a class="brand" href="/" aria-label="ExpertDock 首页"><span class="brand-mark">ED</span><span>ExpertDock</span></a>${extra}</nav></header><main class="container">${body}</main></body></html>`, { status, headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff", "content-security-policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'", "referrer-policy": "same-origin" } });
}

function adminNav() {
  return `<div class="nav-links"><a href="/helper">下载 Helper</a><a href="/dashboard">管理后台</a></div><form method="post" action="/logout"><button class="secondary">退出</button></form>`;
}

function publicNav(active) {
  return `<div class="nav-links"><a${active === "home" ? ' class="active"' : ""} href="/">首页</a><a${active === "experts" ? ' class="active"' : ""} href="/experts">已分享专家</a><a href="/helper">下载 Helper</a></div>`;
}

function homePage() {
  return page("首页", `
  <section class="landing">
    <div class="landing-hero">
      <p class="eyebrow">WorkBuddy 专家分享平台</p>
      <h1>好专家，<br>一键安装。</h1>
      <p class="lead">打开朋友分享的专家链接，点击安装，ExpertDock 会自动把它装进你的 WorkBuddy。不套壳、不登录、不需要等官方审核。</p>
      <div class="hero-actions"><a class="button" href="#open">打开分享链接</a><a class="button secondary" href="/helper">安装 Helper</a></div>
    </div>
    <div class="link-box" id="open">
      <h2>有分享链接？</h2>
      <p class="muted">粘贴朋友发给你的专家链接，立即查看详情。</p>
      <form class="link-form" action="/open" method="post">
        <input type="text" name="link" placeholder="例如 https://ed.lorne.top/s/xxxxxx" aria-label="分享链接" required>
        <button type="submit">打开</button>
      </form>
    </div>
    <div class="steps-section">
      <div class="section-heading"><p class="eyebrow">How it works</p><h2>三步用上专家</h2><p class="muted">第一次多装一个 Helper，之后每次安装只要点一下。</p></div>
      <div class="steps">
        <div class="step"><span class="step-number">1</span><h3>打开链接</h3><p>点击朋友分享的专家链接，查看专家介绍、版本和依赖。</p></div>
        <div class="step"><span class="step-number">2</span><h3>点击安装</h3><p>浏览器唤起 ExpertDock Helper，自动完成下载与安装。</p></div>
        <div class="step"><span class="step-number">3</span><h3>召唤专家</h3><p>重启 WorkBuddy，在专家列表里找到它，开始对话。</p></div>
      </div>
    </div>
    <div class="trust-panel">
      <div>
        <p class="eyebrow" style="color:#aeaeb2">安装即校验</p>
        <h2>你装进去的，就是朋友发你的。</h2>
        <p>每个专家包都经过完整校验，来源、版本、内容一一对应，安装失败自动回滚，不留半成品。</p>
      </div>
      <div class="trust-points">
        <div class="trust-point">包内容与分享版本严格一致（SHA-256）</div>
        <div class="trust-point">只写入 WorkBuddy 专家目录，不碰其他文件</div>
        <div class="trust-point">覆盖安装前自动备份，失败立即恢复</div>
      </div>
    </div>
    <p class="landing-footer">ExpertDock · 私域 WorkBuddy 专家分享 · 需要分享自己的专家？<a href="/dashboard">进入管理后台</a></p>
  </section>`, 200, publicNav("home"));
}

async function sharedExpertsPage(env) {
  const { results } = await env.DB.prepare(`SELECT s.token,e.id AS expert_id,e.name,e.description,e.type,v.version,v.manifest
    FROM shares s JOIN expert_versions v ON v.id=s.expert_version_id JOIN experts e ON e.id=v.expert_id
    WHERE s.enabled=1 AND e.status='active' AND (s.expires_at IS NULL OR s.expires_at>CURRENT_TIMESTAMP)
    ORDER BY s.created_at DESC`).all();
  const experts = new Map();
  for (const item of results) if (!experts.has(item.expert_id)) experts.set(item.expert_id, item);
  const items = experts.size ? `<div class="expert-grid">${[...experts.values()].map((item) => {
    const manifest = JSON.parse(item.manifest);
    const name = manifest.displayName?.zh || manifest.displayName?.en || item.name;
    return `<a class="card expert" href="/s/${encodeURIComponent(item.token)}"><div class="row between"><h2>${escapeHtml(name)}</h2><span class="tag">${item.type === "team" ? "专家团" : "专家"}</span></div><p>${escapeHtml(item.description || "暂无简介")}</p><div class="meta">版本 ${escapeHtml(item.version)}</div></a>`;
  }).join("")}</div>` : `<section class="card"><p>暂时还没有正在分享的专家。</p></section>`;
  return page("已分享专家", `<div class="page-heading"><p class="eyebrow">Shared Experts</p><h1>已分享专家</h1><p class="muted">查看当前可用的专家和专家团。</p></div>${items}`, 200, publicNav("experts"));
}

function loginPage(message = "") {
  return page("登录", `<section class="card login-card"><p class="eyebrow">Developer Console</p><h1>欢迎回来</h1><p class="muted">登录以管理你的 WorkBuddy 专家。</p>${message ? `<p class="error">${escapeHtml(message)}</p>` : ""}<form method="post" action="/login"><label for="password">管理密码</label><input id="password" name="password" type="password" autocomplete="current-password" required autofocus><p><button type="submit">登录</button></p></form></section>`);
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

async function openShareLink(request) {
  checkOrigin(request);
  const form = await request.formData();
  const link = String(form.get("link") || "").trim();
  let token = "";
  if (link.includes("/s/")) {
    token = link.slice(link.lastIndexOf("/s/") + 3).split(/[?#]/)[0];
  } else if (/^[A-Za-z0-9_-]{20,128}$/.test(link)) {
    token = link;
  }
  token = token.replace(/[^A-Za-z0-9_-]/g, "");
  if (token.length < 20 || token.length > 128) {
    return page("链接无效", `<section class="card share-card"><h1>链接无法识别</h1><p class="summary">请粘贴完整的分享链接，例如 <span class="code">https://ed.lorne.top/s/xxxxxx</span>。</p><div class="row" style="margin-top:26px"><a class="button" href="/">返回首页</a></div></section>`, 400);
  }
  return Response.redirect(`${new URL(request.url).origin}/s/${encodeURIComponent(token)}`, 303);
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
  return page("专家管理", `<div class="row between page-heading"><div><p class="eyebrow">Your Experts</p><h1>专家管理</h1><p class="muted">上传、发版并生成私域分享链接。</p></div><a class="button" href="/dashboard/experts/new">上传专家</a></div>${items}`, 200, adminNav());
}

function helperPage(env) {
  const version = escapeHtml(env.HELPER_VERSION || "0.1.0");
  return page("下载 Helper", `<section class="card hero-card"><p class="eyebrow">One-time Setup</p><h1>安装 ExpertDock Helper</h1><p class="muted" style="font-size:19px">只需安装一次。之后点击“安装到 WorkBuddy”，Helper 会自动、安全地完成安装。</p><div class="row" style="margin:28px 0"><a class="button" href="/downloads/helper/macos">下载 macOS 版</a><a class="button secondary" href="/downloads/helper/windows">下载 Windows 版</a></div><p class="meta">版本 ${version} · 文件直接由 ExpertDock 提供</p></section><section class="card"><p class="eyebrow">Installation</p><h2>两步完成</h2><p><strong>macOS</strong><br><span class="muted">解压后打开 ExpertDock Helper，它会自动固定安装到“应用程序”并显示在菜单栏。可在 Helper 页面清理旧版本。若系统拦截，请右键应用并选择“打开”。</span></p><p><strong>Windows</strong><br><span class="muted">解压后运行 <span class="code">install.cmd</span> 注册协议。</span></p><p><a href="javascript:history.back()">← 返回分享页</a></p></section>`);
}

async function downloadHelper(platform, env) {
  const version = env.HELPER_VERSION || "0.1.0";
  const name = `expertdock-helper-${platform}.zip`;
  const object = await env.PACKAGES.get(`helpers/v${version}/${name}`);
  if (!object) return page("文件不存在", `<section class="card"><h1>Helper 暂不可用</h1><p>当前平台安装包尚未上传，请稍后重试。</p></section>`, 404);
  return new Response(object.body, { headers: {
    "content-type": "application/zip",
    "content-length": String(object.size),
    "content-disposition": `attachment; filename="${name}"`,
    "cache-control": "public, max-age=3600, immutable",
    "x-content-type-options": "nosniff",
  } });
}

function newExpertPage() {
  return page("上传专家", `<div class="page-heading"><p class="eyebrow">New Expert</p><h1>上传专家</h1><p class="muted">上传符合 WorkBuddy 2.4 规范的专家包。</p></div><section class="card"><form method="post" action="/api/experts" enctype="multipart/form-data"><label for="package">专家 ZIP 包</label><input id="package" name="package" type="file" accept=".zip,application/zip" required><label for="description">展示简介</label><textarea id="description" name="description" maxlength="500" placeholder="留空时使用 plugin.json 的描述"></textarea><label for="releaseNotes">版本说明</label><textarea id="releaseNotes" name="releaseNotes" maxlength="1000"></textarea><p><button type="submit">上传并创建</button> <a class="button secondary" href="/dashboard">取消</a></p></form></section>`, 200, adminNav());
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
  return page(displayName, `<section class="card share-card"><span class="tag">${item.type === "team" ? "专家团" : "专家"}</span><h1>${escapeHtml(displayName)}</h1><p class="summary">${escapeHtml(item.description)}</p><p class="meta">版本 ${escapeHtml(item.version)} · SHA-256 <span class="code">${escapeHtml(item.package_sha256.slice(0, 16))}…</span></p>${dependencies}<p class="muted">此内容来自第三方开发者。安装前请确认来源和所需权限。</p><div class="row" style="margin-top:26px"><button id="install">安装到 WorkBuddy</button><a class="button secondary" href="/helper">首次使用？安装 Helper</a></div><p id="hint" class="muted"></p></section><script>document.getElementById('install').onclick=async()=>{document.getElementById('hint').textContent='正在唤起 ExpertDock Helper…';fetch('/api/shares/${encodeURIComponent(token)}/install-click',{method:'POST',keepalive:true});location.href='expertdock://install?token=${encodeURIComponent(token)}';setTimeout(()=>document.getElementById('hint').textContent='未唤起？请先安装 ExpertDock Helper，然后重试。',1800)}</script>`);
}

async function helperMetadata(token, origin, env) {
  const item = await getShare(token, env);
  if (!item) return json({ error: "分享链接不存在、已停用或已过期" }, 404);
  const manifest = JSON.parse(item.manifest);
  const displayName = manifest.displayName?.zh || manifest.displayName?.en || item.name;
  return json({ name: item.name, displayName, type: item.type, version: item.version, sha256: item.package_sha256, size: item.package_size, downloadUrl: `${origin}/api/shares/${encodeURIComponent(token)}/download` }, 200, { "cache-control": "no-store" });
}

async function helperLatest(platform, origin, env) {
  const object = await env.PACKAGES.get("helpers/latest.json");
  if (!object) return json({ error: "Helper 升级信息不可用" }, 503);
  let manifest;
  try { manifest = JSON.parse(await object.text()); } catch { return json({ error: "Helper 升级信息损坏" }, 503); }
  const item = manifest.platforms?.[platform];
  if (!manifest.version || !item?.sha256 || !item?.size) return json({ error: "Helper 升级信息不完整" }, 503);
  return json({ version: manifest.version, sha256: item.sha256, size: item.size, downloadUrl: `${origin}/downloads/helper/${platform}` }, 200, { "cache-control": "no-store" });
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
