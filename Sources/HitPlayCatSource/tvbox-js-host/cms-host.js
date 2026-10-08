/**
 * HitPlay TVBox 配置站源宿主（新协议：TVBox 点播配置 JSON）
 *
 * 支持（TVBox 生态）：
 *   1. type 0/1 CMS 站源（MacCMS vod json）：
 *      home     → GET {api}?ac=videolist            （class + 首页推荐）
 *      category → GET {api}?ac=videolist&t=id&pg=n
 *      search   → GET {api}?ac=videolist&wd=…&pg=n
 *      detail   → GET {api}?ac=detail&ids=id        （含 vod_play_from/url）
 *      play     → 直接返回集地址（CMS 站直链形态）
 *   2. type 3 且 api 为 http(s) *.js 的源：复用 tvbox-js-host 的 worker 会话池
 *      （runtime.js）直接运行远程 JS 源。
 *   3. type 3 jar / csp_ 源：需要 JVM + dex2jar 运行时，
 *      HitPlay 暂不支持——请求返回明确错误说明。
 *
 * 订阅侧（CatSourceStore，Swift）在导入/刷新时已把生态加密配置
 * （2423 / 2324 / 8位** 标记形态）解为明文后落盘 config.json；本宿主只读明文 JSON。
 *
 * 协议出口与 tvbox-js-host/host.js 完全一致（/config、/check、/spider/<key>/3/*、
 * /proxy、HITPLAY_PORT=<n>、stdin/SIGTERM/PPID 退出协议）。
 *
 * 用法：node tvbox-js-host/cms-host.js <packageDir>（包内需有 config.json）
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { SessionPool } = require('./runtime');
const { request } = require('./network');

// ---------- 输出护栏 ----------
// 与 tvbox-js-host/host.js 同款：console.* 大对象有界摘要 + stdout/stderr 单行限幅，
// 在装载源码（远程 JS 源经 worker 会话池）之前安装；worker 侧由 worker.js 自装。
(function installHitPlayOutputGuard () {
  if (globalThis.__hitplayOutputGuardInstalled) return;
  globalThis.__hitplayOutputGuardInstalled = true;
  const LABEL = 'hitplay-cms';
  const MAX_LINE_BYTES = 128 * 1024;
  const MAX_STRING_CHARS = 4 * 1024;
  const truncatedSuffix = `\n[${LABEL}] 超长输出行已截断（单行上限 ${MAX_LINE_BYTES} 字节）\n`;
  const truncatedEndMark = `[${LABEL}] 超长行残余已丢弃\n`;

  function compact (value) {
    if (value == null) return value;
    if (typeof value === 'string') {
      return value.length > MAX_STRING_CHARS
        ? value.slice(0, MAX_STRING_CHARS) + `…[截断，共 ${value.length} 字符]`
        : value;
    }
    if (Buffer.isBuffer(value)) return `[Buffer ${value.length}B]`;
    if (value instanceof Error) {
      const response = value.response;
      const status = response && response.status;
      const url = (value.config && value.config.url)
        || (response && response.config && response.config.url);
      if (status !== undefined || url) {
        return `[AxiosError ${value.message}${status !== undefined ? ' status=' + status : ''}${url ? ' url=' + url : ''}]`;
      }
      return value.stack || value.message || String(value);
    }
    if (Array.isArray(value) && value.length > 64) return `[Array(${value.length})]`;
    if (typeof value === 'object') {
      try {
        return require('util').inspect(value, {
          depth: 1, maxArrayLength: 10, maxStringLength: 256, breakLength: Infinity
        });
      } catch (_) {
        return `[${(value.constructor && value.constructor.name) || 'Object'}（不可检视）]`;
      }
    }
    return value;
  }

  for (const level of ['log', 'info', 'warn', 'error', 'debug', 'trace']) {
    if (typeof console[level] !== 'function') continue;
    const original = console[level].bind(console);
    console[level] = function (...args) {
      try { original(...args.map(compact)); } catch (_) { /* 日志失败不阻塞业务 */ }
    };
  }

  const newlineBuffer = Buffer.from([0x0A]);
  for (const stream of [process.stdout, process.stderr]) {
    if (!stream || stream.__hitplayGuarded) continue;
    const originalWrite = stream.write.bind(stream);
    let pending = Buffer.alloc(0);
    let swallowing = false;
    stream.__hitplayGuarded = true;
    stream.write = function (chunk, encoding, callback) {
      if (typeof encoding === 'function') { callback = encoding; encoding = null; }
      let incoming;
      try {
        if (Buffer.isBuffer(chunk)) incoming = chunk;
        else if (ArrayBuffer.isView(chunk)) incoming = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
        else if (chunk == null) incoming = Buffer.alloc(0);
        else incoming = Buffer.from(String(chunk), encoding || 'utf8');
      } catch (_) {
        if (typeof callback === 'function') callback();
        return true;
      }
      const pieces = [];
      const data = Buffer.concat([pending, incoming]);
      pending = Buffer.alloc(0);
      let cursor = 0;
      for (;;) {
        const newline = data.indexOf(0x0A, cursor);
        if (newline < 0) break;
        const line = data.subarray(cursor, newline);
        cursor = newline + 1;
        if (swallowing) {
          swallowing = false;
          pieces.push(Buffer.from(truncatedEndMark));
          continue;
        }
        if (line.length > MAX_LINE_BYTES) {
          // 完整超长行（换行已在本次写入内消费）：截断输出即完结，不进入吞态；
          // 吞态只用于无换行的流式超长行（见下方 tail 分支），否则会误吞下一行。
          pieces.push(Buffer.concat([line.subarray(0, MAX_LINE_BYTES), Buffer.from(truncatedSuffix)]));
        } else {
          pieces.push(line, newlineBuffer);
        }
      }
      if (cursor < data.length) {
        const rest = data.subarray(cursor);
        if (!swallowing) {
          if (rest.length > MAX_LINE_BYTES) {
            pieces.push(Buffer.concat([rest.subarray(0, MAX_LINE_BYTES), Buffer.from(truncatedSuffix)]));
            swallowing = true;
          } else {
            pending = Buffer.from(rest);
          }
        }
      }
      if (pieces.length > 0) originalWrite(Buffer.concat(pieces));
      if (typeof callback === 'function') { try { callback(); } catch (_) {} }
      return true;
    };
  }
})();

const packageDir = process.argv[2];
if (!packageDir || !fs.existsSync(packageDir)) {
  process.stderr.write('[hitplay-cms] 缺少源包目录: ' + packageDir + '\n');
  process.exit(2);
}

// 源包路径围栏（对齐 cat-source-host.js 的 resolveInsidePackageDir）：包内文件
// 读取必须 realpath 解析回包目录内，防御 argv 注入 `..`/符号链接后越界读写。
function resolveInsidePackageDir(relative) {
  const base = fs.realpathSync(packageDir);
  const resolved = fs.realpathSync(path.resolve(packageDir, relative));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) {
    throw new Error('[hitplay-cms] 路径越界，拒绝访问: ' + resolved);
  }
  return resolved;
}

const configPath = resolveInsidePackageDir('config.json');
if (!fs.existsSync(configPath)) {
  process.stderr.write('[hitplay-cms] 包内缺少 config.json: ' + packageDir + '\n');
  process.exit(3);
}

// ---------- 站点分类 ----------
function makeKey(base, usedKeys) {
  let key = 'tv_' + String(base).replace(/[^\w-]/g, '_').slice(0, 48);
  if (!usedKeys.has(key)) { usedKeys.set(key, true); return key; }
  let index = 2;
  while (usedKeys.has(key + '_' + index)) index++;
  usedKeys.set(key + '_' + index, true);
  return key + '_' + index;
}

function classifySites(config) {
  const rawSites = Array.isArray(config) ? config
    : (Array.isArray(config.sites) ? config.sites : []);
  const usedKeys = new Map();
  const cmsSites = [];
  const jsSites = [];
  let unsupported = 0;
  // TVBox 配置级解析器（parses）与需解析线路名单（flags）：
  //   type 1/2 = JSON 解析接口（GET url+播放页地址 → 响应 JSON 含直链）；
  //   type 0   = 网页嗅探（宿主侧 ParseSniffer 已覆盖，此处不重复实现）。
  const parseParsers = (Array.isArray(config.parses) ? config.parses : [])
    .filter(item => item && typeof item.url === 'string' && /^https?:\/\//i.test(item.url)
      && (Number(item.type) === 1 || Number(item.type) === 2))
    .map(item => ({ name: String(item.name || ''), type: Number(item.type) || 2, url: item.url }));
  const parseFlags = (Array.isArray(config.flags) ? config.flags : [])
    .map(item => String(item || '').toLowerCase()).filter(Boolean);
  for (const site of rawSites) {
    if (!site || !site.api || !site.name) continue;
    const key = makeKey(site.key || site.name, usedKeys);
    const api = String(site.api).trim();
    const type = Number(site.type) || 0;
    if (/\.jar(\?|$)/i.test(api) || (type === 3 && /^csp_/i.test(api))) {
      unsupported++;
      continue;
    }
    if (type === 3 && /^https?:\/\//i.test(api) && /\.js(\?|$)/i.test(api)) {
      jsSites.push({ key, name: String(site.name), api, extend: site.ext || '', kind: 'js' });
      continue;
    }
    if ((type === 0 || type === 1) && /^https?:\/\//i.test(api)) {
      cmsSites.push({ key, name: String(site.name), api, kind: 'cms' });
      continue;
    }
    unsupported++;
  }
  return { cmsSites, jsSites, unsupported, parseParsers, parseFlags };
}

let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (error) {
  process.stderr.write('[hitplay-cms] config.json 不是有效 JSON: ' + error.message + '\n');
  process.exit(5);
}
const { cmsSites, jsSites, unsupported, parseParsers, parseFlags } = classifySites(config);
if (cmsSites.length + jsSites.length === 0) {
  process.stderr.write('[hitplay-cms] 配置中没有可支持的站点（type 0/1 CMS 或 type 3 .js）\n');
  process.exit(6);
}

// ---------- 会话池（type 3 JS 源） ----------
// 缓存目录围栏：env 覆盖目录必须 realpath 解析回包目录内，越界即回退包内 cache/
// （Swift 侧默认注入的就是包内 cache/，这里兜底防注入）。
let cacheRoot = process.env.HITPLAY_JS_CACHE_DIR || path.join(packageDir, 'cache');
try { fs.mkdirSync(cacheRoot, { recursive: true }); } catch (_) { /* 兜底 packageDir */ }
try {
  const resolvedCache = fs.realpathSync(cacheRoot);
  const packageReal = fs.realpathSync(packageDir);
  if (resolvedCache !== packageReal && !resolvedCache.startsWith(packageReal + path.sep)) {
    process.stderr.write('[hitplay-cms] 缓存目录越界，回退包内 cache/\n');
    cacheRoot = resolveInsidePackageDir('cache');
    fs.mkdirSync(cacheRoot, { recursive: true });
  }
} catch (_) { /* 包目录不可解析时保持现状（worker 侧还有一道围栏） */ }
let contentPort = 0;
const pool = new SessionPool({
  hostDir: __dirname,
  cacheRoot,
  packageDir,
  proxyPort: () => contentPort,
});

// ---------- CMS 客户端（type 0/1 MacCMS vod json） ----------
function cmsURL(api, params) {
  const url = new URL(api);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && String(value) !== '') url.searchParams.set(key, String(value));
  }
  return url.href;
}

function looksLikeJSON(text) {
  const trimmed = String(text || '').trim();
  return trimmed.startsWith('{') || trimmed.startsWith('[');
}

async function cmsGet(api, params) {
  const result = await request(cmsURL(api, params), { timeout: 15000 });
  if (result.code < 200 || result.code >= 300) throw new Error('CMS HTTP ' + result.code);
  const text = String(result.content || '').trim();
  if (looksLikeJSON(text)) return JSON.parse(text);
  // 正文嗅探分流：存量 MacCMS XML 采集接口（at=xml/.xml 站点）按同 ac 参数
  // 返回 XML——解析为与 vod json 同形的字段（对齐 iOS 原生引擎 MacCMSXML）。
  if (looksLikeXML(text)) return maccmsXMLToObject(text);
  throw new Error('CMS 返回非 JSON（接口不兼容 MacCMS vod json）');
}

function looksLikeXML(text) {
  if (!String(text || '').trim().startsWith('<')) return false;
  return (String(text).match(/<rss|<video|<list/i) !== null);
}

/** 提取 <tag …>…</tag> 内容：indexOf 边界扫描（不用动态构造正则）。 */
function extractTag(xml, tag) {
  const lower = String(xml || '').toLowerCase();
  const open = '<' + tag.toLowerCase();
  const closeToken = '</' + tag.toLowerCase() + '>';
  let from = 0;
  for (;;) {
    const at = lower.indexOf(open, from);
    if (at < 0) return '';
    const next = lower.charAt(at + open.length);
    if (next !== '>' && next !== ' ' && next !== '\t' && next !== '\n' && next !== '\r' && next !== '/') {
      from = at + 1;
      continue;
    }
    const gt = lower.indexOf('>', at);
    if (gt < 0) return '';
    const end = lower.indexOf(closeToken, gt);
    if (end < 0) return '';
    return xml.slice(gt + 1, end);
  }
}

/** 提取 <tag>…</tag> 的可见文本（CDATA 还原 + 嵌套标签剥离）。 */
function xmlText(fragment) {
  return String(fragment || '')
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<[^>]+>/g, '')
    .trim();
}

/** 属性串解析：flag="x" id="1" → {flag, id}。 */
function parseAttributes(fragment) {
  const attrs = {};
  for (const match of String(fragment || '').matchAll(/([-\w]+)\s*=\s*["']?([^"'\s>]*)/g)) {
    attrs[match[1].toLowerCase()] = match[2];
  }
  return attrs;
}

function maccmsXMLToObject(text) {
  const videos = [];
  for (const block of (text.match(/<video>[\s\S]*?<\/video>/gi) || [])) {
    const playFlags = [];
    const playURLs = [];
    for (const dd of block.matchAll(/<dd\b([^>]*)>([\s\S]*?)<\/dd>/gi)) {
      const attrs = parseAttributes(dd[1]);
      playFlags.push(xmlText(attrs.flag || ''));
      playURLs.push(xmlText(dd[2]));
    }
    videos.push({
      vod_id: xmlText(extractTag(block, 'id')),
      vod_name: xmlText(extractTag(block, 'name')),
      type_id: xmlText(extractTag(block, 'tid')),
      type_name: xmlText(extractTag(block, 'type')),
      vod_pic: xmlText(extractTag(block, 'pic')),
      vod_remarks: xmlText(extractTag(block, 'note')),
      vod_year: xmlText(extractTag(block, 'year')),
      vod_actor: xmlText(extractTag(block, 'actor')),
      vod_director: xmlText(extractTag(block, 'director')),
      vod_content: xmlText(extractTag(block, 'des')),
      vod_play_from: playFlags.join('$$$'),
      vod_play_url: playURLs.join('$$$'),
    });
  }
  const classBlock = extractTag(text, 'class');
  const classes = [];
  for (const ty of classBlock.matchAll(/<ty\b([^>]*)>([\s\S]*?)<\/ty>/gi)) {
    const attrs = parseAttributes(ty[1]);
    const name = xmlText(ty[2]);
    if (attrs.id && name) classes.push({ type_id: xmlText(attrs.id), type_name: name });
  }
  const listOpen = (text.match(/<list\b([^>]*)>/i) || [null, ''])[1] || '';
  const listAttrs = parseAttributes(listOpen);
  const positive = (value) => {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : 0;
  };
  return {
    list: videos,
    class: classes,
    page: positive(listAttrs.page) || 1,
    pagecount: positive(listAttrs.pagecount) || 1,
    total: positive(listAttrs.recordcount) || positive(listAttrs.total) || videos.length,
  };
}

function cmsList(data) {
  return Array.isArray(data.list) ? data.list : [];
}

// ---------- 路由派发 ----------
function asObject(value) {
  return value && typeof value === 'object' ? value : {};
}

function parseMaybeJSON(value) {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try { return JSON.parse(trimmed); } catch (_) { /* 非 JSON 原样返回 */ }
    }
  }
  return value;
}

function findSite(key) {
  return jsSites.find(item => item.key === key) || cmsSites.find(item => item.key === key);
}

// ---------- CMS 播放解析判定（与 iOS 原生引擎 NativeEngineServer 同规则） ----------
const MEDIA_EXTENSIONS = ['.m3u8', '.mp4', '.mkv', '.ts', '.flv', '.avi', '.webm', '.mpd', '.m2ts', '.mov', '.rmvb', '.mp3', '.m4a', '.flac', '.wav'];
const PAGE_EXTENSIONS = ['.html', '.htm', '.shtml'];

/**
 * 直链/需解析判定（保守：只有明确的网页播放页才走解析，其余保持直连，
 * 避免 .php?path= 之类的无扩展名直连流被误伤）。
 * flag 命中配置 flags 名单（如 youku/qq/iqiyi）也判需解析（内嵌播放页）。
 */
function decideCMSPlay(playID, flag, flags) {
  const trimmed = String(playID || '').trim();
  const flagLower = String(flag || '').toLowerCase();
  // 空线路名不得命中 flags（JS includes('') 恒真，需显式排除）。
  const flagMatched = !!flagLower && (flags || []).some(item => item && (flagLower.includes(item) || item.includes(flagLower)));
  let parsed;
  try { parsed = new URL(trimmed); } catch (_) { parsed = null; }
  if (!parsed || !/^https?:$/i.test(parsed.protocol)) {
    // 非 http(s)（集号/jx: 前缀等）：维持直连透传，由宿主侧按既有逻辑处理。
    return { needsParse: flagMatched };
  }
  const path = decodeURIComponent(parsed.pathname || '').toLowerCase();
  if (MEDIA_EXTENSIONS.some(ext => path.endsWith(ext))) return { needsParse: false };
  if (PAGE_EXTENSIONS.some(ext => path.endsWith(ext))) return { needsParse: true };
  return { needsParse: flagMatched };
}

/** 逐个尝试配置级 JSON 解析器（type 1/2），首个给出 http(s) 直链的胜出。 */
async function tryJSONParsers(parsers, playID) {
  for (const parser of parsers) {
    const endpoint = parser.url + encodeURIComponent(String(playID || '').trim());
    try {
      const result = await request(endpoint, { timeout: 8000 });
      if (result.code < 200 || result.code >= 300) continue;
      const text = String(result.content || '').trim();
      if (!looksLikeJSON(text)) continue;
      const payload = JSON.parse(text);
      const nested = payload && typeof payload.data === 'object' && !Array.isArray(payload.data) ? payload.data : {};
      const candidates = [payload.url, payload.play_url, payload.playUrl, nested.url, nested.play_url, nested.playUrl];
      const direct = candidates.find(value => typeof value === 'string' && /^https?:\/\//i.test(value));
      if (!direct) continue;
      const header = payload.header || payload.headers || nested.header || nested.headers;
      return {
        parse: 0,
        url: direct,
        header: header && typeof header === 'object' && !Array.isArray(header) ? header : {},
      };
    } catch (_) { /* 单个解析器失败继续下一个 */ }
  }
  return null;
}

async function dispatchRoute(site, route, body) {
  if (site.kind === 'cms') {
    switch (route) {
      case 'home': {
        const data = asObject(await cmsGet(site.api, { ac: 'videolist', pg: 1 }));
        return { class: Array.isArray(data.class) ? data.class : [], list: cmsList(data).slice(0, 24), filters: {} };
      }
      case 'category': {
        const data = asObject(await cmsGet(site.api, { ac: 'videolist', t: body.id, pg: body.page || 1 }));
        return { list: cmsList(data) };
      }
      case 'search': {
        const data = asObject(await cmsGet(site.api, { ac: 'videolist', wd: body.wd, pg: body.page || 1 }));
        return { list: cmsList(data) };
      }
      case 'detail': {
        const id = Array.isArray(body.id) ? body.id[0] : body.id;
        const data = asObject(await cmsGet(site.api, { ac: 'detail', ids: id }));
        return { list: cmsList(data) };
      }
      case 'play': {
        // CMS 站的播放地址在 detail 的 vod_play_url 里。直链（媒体扩展名等）
        // 直接下发；明显的网页播放页（.html 等）或命中配置 flags 名单的线路，
        // 先走配置级 JSON 解析器（parses type 1/2），失败则标记 parse:1 交给
        // 宿主侧 ParseSniffer（网页嗅探）兜底。
        const playID = String(body.id ?? '');
        const flag = String(body.flag ?? '');
        const decision = decideCMSPlay(playID, flag, parseFlags);
        if (decision.needsParse && parseParsers.length) {
          const parsed = await tryJSONParsers(parseParsers, playID);
          if (parsed) return parsed;
        }
        if (decision.needsParse) {
          return { parse: 1, jx: 1, url: playID, header: {} };
        }
        return { parse: 0, url: playID, header: {} };
      }
      case 'init':
        return {};
      default:
        throw new Error('Unknown route: ' + route);
    }
  }
  // type 3 JS 源
  const payload = asObject(body);
  switch (route) {
    case 'init': {
      site.extend = typeof payload.extend === 'string' ? payload.extend : JSON.stringify(payload.extend ?? '');
      return {};
    }
    case 'home': {
      const home = asObject(parseMaybeJSON(await pool.call(site, 'home', [{}])));
      let videos = {};
      try { videos = asObject(parseMaybeJSON(await pool.call(site, 'homeVod', []))); } catch (_) { /* 部分源无 homeVod */ }
      return { class: home.class ?? [], filters: home.filters ?? {}, list: videos.list ?? home.list ?? [] };
    }
    case 'category': {
      const filters = asObject(payload.filters);
      return parseMaybeJSON(await pool.call(site, 'category', [String(payload.id ?? ''), Number(payload.page) || 1, filters, site.extend || '']));
    }
    case 'detail': {
      const id = payload.id ?? '';
      return parseMaybeJSON(await pool.call(site, 'detail', [Array.isArray(id) ? id[0] : String(id)]));
    }
    case 'search': {
      return parseMaybeJSON(await pool.call(site, 'search', [String(payload.wd ?? ''), payload.quick === true, Number(payload.page) || 1]));
    }
    case 'play': {
      return parseMaybeJSON(await pool.call(site, 'play', [String(payload.flag ?? ''), String(payload.id ?? ''), [String(payload.flag ?? '')]]));
    }
    default:
      throw new Error('Unknown route: ' + route);
  }
}

// ---------- /proxy（type 3 JS 源回源代理） ----------
async function handleProxy(req, res, query) {
  const key = query.get('source');
  const site = jsSites.find(item => item.key === key);
  if (!site) throw new Error('JS proxy source was released; reopen the source');
  const params = {};
  for (const [name, value] of query) params[name] = value;
  if (req.method === 'POST') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (body && typeof body === 'object') Object.assign(params, body);
    } catch (_) { /* 非 JSON body 忽略 */ }
  }
  let result = await pool.call(site, 'proxy', [params]);
  if (typeof result === 'string') result = JSON.parse(result);
  if (!Array.isArray(result)) throw new Error('Invalid JS proxy response');
  const [status, mime, body, headers, encoded] = result;
  const data = encoded === 1 ? Buffer.from(String(body), 'base64') : Array.isArray(body) ? Buffer.from(body) : Buffer.from(String(body ?? ''));
  res.writeHead(Number(status) || 200, { 'Content-Type': mime || 'application/octet-stream', ...(typeof headers === 'string' ? JSON.parse(headers) : headers || {}) });
  res.end(data);
}

// ---------- HTTP 服务 ----------
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/proxy') {
      await handleProxy(req, res, url.searchParams);
      return;
    }
    if (url.pathname === '/check') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, cms: cmsSites.length, js: jsSites.length, unsupported }));
      return;
    }
    if (url.pathname === '/config' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        video: {
          sites: [...cmsSites, ...jsSites].map(site => ({
            key: site.key,
            name: site.name,
            type: 3,
            api: '/spider/' + encodeURIComponent(site.key) + '/3',
            searchable: 1,
          })),
        },
      }));
      return;
    }
    const routePattern = /^\/spider\/([\w%-]+)\/3\/(init|home|category|detail|search|play)$/;
    const routeMatch = url.pathname.match(routePattern);
    if (routeMatch && req.method === 'POST') {
      const key = decodeURIComponent(routeMatch[1]);
      const site = findSite(key);
      if (!site) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'no site', key }));
        return;
      }
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      let body = {};
      try { body = JSON.parse(Buffer.concat(chunks).toString() || '{}'); } catch (_) { /* 空/坏 body 按空处理 */ }
      const data = await dispatchRoute(site, routeMatch[2], body);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data ?? {}));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found', path: url.pathname }));
  } catch (error) {
    process.stderr.write('[hitplay-cms] 请求处理异常: ' + (error && error.message) + '\n');
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
    }
    try { res.end(JSON.stringify({ error: 'engine error' })); } catch (_) { /* 已结束 */ }
  }
});

server.listen(0, '127.0.0.1', () => {
  contentPort = server.address().port;
  pool.proxyPort = contentPort;
  process.stdout.write('HITPLAY_PORT=' + contentPort + '\n');
  process.stderr.write('[hitplay-cms] TVBox 配置服务已启动 :' + contentPort
    + '（CMS ' + cmsSites.length + ' / JS ' + jsSites.length + ' / 不支持 ' + unsupported + '）\n');
});

// ---------- 生命周期 ----------
let shuttingDown = false;
function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write('[hitplay-cms] 退出（' + reason + '）\n');
  try { server.close(); } catch (_) {}
  try { pool.disposeAll('JS host stopped'); } catch (_) {}
  try { server.unref(); } catch (_) {}
  process.reallyExit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
setInterval(() => {
  if (process.env.HITPLAY_EMBEDDED_NODE !== '1' && process.ppid === 1) shutdown('parent exited');
}, 3000).unref();
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  const text = String(chunk || '').trim();
  if (text === 'stop' || text === '{"cmd":"stop"}') shutdown('stdin stop');
});
process.stdin.on('end', () => shutdown('stdin EOF'));
process.on('uncaughtException', (error) => {
  process.stderr.write('[hitplay-cms] 未捕获异常: ' + (error && error.stack ? error.stack : error) + '\n');
});
process.on('unhandledRejection', (reason) => {
  process.stderr.write('[hitplay-cms] 未处理的 Promise 拒绝: ' + (reason && reason.message ? reason.message : reason) + '\n');
});
