#!/usr/bin/env node
/**
 * HitPlay tvbox JS 源桥接宿主
 *
 * 职责：
 * 1. 扫描源包目录中的单文件 TVBox JS 源（*.js，每文件一个站点）；
 * 2. worker 会话池见 runtime.js（与 cms-host.js 共用）；
 * 3. 把猫源开放协议映射到 TVBox JS 源方法，供 HitPlayCatSource 的
 *    CatSourceClient 零改动复用：
 *      GET  /config                       → 站点列表（type 3, api=/spider/<key>/3）
 *      GET  /check                        → 健康检查
 *      POST /spider/<key>/3/init          → （worker 装载时已 init，此处接受 extend）
 *      POST /spider/<key>/3/home          → home(filter) + homeVod() 合并
 *      POST /spider/<key>/3/category      → category(id, page, filters, extend)
 *      POST /spider/<key>/3/detail        → detail(id)
 *      POST /spider/<key>/3/search        → search(wd, false, page)
 *      POST /spider/<key>/3/play          → play(flag, id, [flag])
 *      ALL  /proxy?source=<key>&…         → proxy(params)（源内 getProxyUrl 回源代理）
 * 4. stdout 输出 HITPLAY_PORT=<port>；stdin stop/EOF、SIGTERM、PPID 守卫优雅退出。
 *
 * 用法：node --experimental-vm-modules tvbox-js-host/host.js <packageDir>
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { pathToFileURL } = require('url');
const { SessionPool } = require('./runtime');

// ---------- 输出护栏 ----------
// 源码日志库会把 axios 系错误或大响应对象反复序列化成数百 MB 字符串拖垮宿主；
// stdout 同时是 HITPLAY_PORT 控制通道。两层防护：console.* 大对象有界摘要 +
// process.stdout/stderr 单行限幅；必须在装载任何源码之前安装。
// 注意：worker 线程的 console 直写 fd，主线程包装看不到，worker.js 需自装一份。
(function installHitPlayOutputGuard () {
  if (globalThis.__hitplayOutputGuardInstalled) return;
  globalThis.__hitplayOutputGuardInstalled = true;
  const LABEL = 'hitplay-tvbox';
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
  process.stderr.write('[hitplay-tvbox] 缺少源包目录: ' + packageDir + '\n');
  process.exit(2);
}

// ---------- 站点发现：顶层 *.js 每文件一站点 ----------
function sanitizeKey(name) {
  const cleaned = String(name).replace(/[^\w-]/g, '_');
  return cleaned.length > 0 ? cleaned.slice(0, 48) : 'site';
}

function discoverSites() {
  const entries = fs.readdirSync(packageDir, { withFileTypes: true });
  const sites = [];
  const seenKeys = new Map();
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith('.js')) continue;
    if (entry.name.startsWith('_')) continue;
    const file = path.join(packageDir, entry.name);
    let key = 'js_' + sanitizeKey(entry.name.replace(/\.js$/, ''));
    // 同名冲突（不同目录同名源）用短哈希区分，保证 key 稳定且 URL 安全。
    if (seenKeys.has(key)) {
      const digest = crypto.createHash('sha256').update(entry.name).digest('hex').slice(0, 6);
      key = key + '_' + digest;
    }
    seenKeys.set(key, true);
    const name = entry.name.replace(/\.js$/, '');
    // runtime.js 的会话池直接消费 api（file:// 形态）。
    sites.push({ key, name, file, api: pathToFileURL(file).href });
  }
  return sites;
}

const sites = discoverSites();
if (sites.length === 0) {
  process.stderr.write('[hitplay-tvbox] 包内没有可用的 .js 源文件\n');
  process.exit(3);
}

// ---------- 运行时缓存目录（模块缓存 + local 存储落盘） ----------
const cacheRoot = process.env.HITPLAY_JS_CACHE_DIR || path.join(packageDir, 'cache');
try { fs.mkdirSync(cacheRoot, { recursive: true }); } catch (_) { /* 宿主兜底 packageDir */ }

const hostDir = __dirname;
let contentPort = 0;
const pool = new SessionPool({
  hostDir,
  cacheRoot,
  packageDir,
  proxyPort: () => contentPort,
});

// ---------- TVBox 方法映射 ----------
function asObject(value) {
  return value && typeof value === 'object' ? value : {};
}

// 源方法常返回 JSON 字符串（生态语义：由宿主侧解析）——统一在此转对象。
function parseMaybeJSON(value) {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try { return JSON.parse(trimmed); } catch (_) { /* 非 JSON 原样返回 */ }
    }
  }
  return value;
}

async function dispatchRoute(site, route, body) {
  const payload = asObject(body);
  switch (route) {
    case 'init': {
      site.extend = typeof payload.extend === 'string' ? payload.extend : JSON.stringify(payload.extend ?? '');
      // worker 首个业务调用时自动 init；此路由仅登记 extend，保持幂等。
      return {};
    }
    case 'home': {
      const home = asObject(parseMaybeJSON(await pool.call(site, 'home', [{}])));
      let videos = {};
      try { videos = asObject(parseMaybeJSON(await pool.call(site, 'homeVod', []))); } catch (_) { /* 部分源无 homeVod */ }
      return {
        class: home.class ?? [],
        filters: home.filters ?? {},
        list: videos.list ?? home.list ?? [],
      };
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
      const flag = String(payload.flag ?? '');
      const id = String(payload.id ?? '');
      return parseMaybeJSON(await pool.call(site, 'play', [flag, id, [flag]]));
    }
    default:
      throw new Error('Unknown route: ' + route);
  }
}

// ---------- /proxy 回源代理（返回 [status, mime, body, headers, encoded]） ----------
async function handleProxy(req, res, query) {
  const key = query.get('source');
  const site = sites.find(item => item.key === key);
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

// ---------- HTTP 服务（单端口：内容协议 + 代理回源） ----------
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/proxy') {
      await handleProxy(req, res, url.searchParams);
      return;
    }
    if (url.pathname === '/check') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, sites: sites.length }));
      return;
    }
    if (url.pathname === '/config' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        video: {
          sites: sites.map(site => ({
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
      const site = sites.find(item => item.key === key);
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
    process.stderr.write('[hitplay-tvbox] 请求处理异常: ' + (error && error.message) + '\n');
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
  process.stderr.write('[hitplay-tvbox] tvbox JS 源服务已启动 :' + contentPort + '（站点 ' + sites.length + ' 个）\n');
});

// ---------- 生命周期（对齐 cat-source-host.js） ----------
let shuttingDown = false;
function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write('[hitplay-tvbox] 退出（' + reason + '）\n');
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
  process.stderr.write('[hitplay-tvbox] 未捕获异常: ' + (error && error.stack ? error.stack : error) + '\n');
});
process.on('unhandledRejection', (reason) => {
  process.stderr.write('[hitplay-tvbox] 未处理的 Promise 拒绝: ' + (reason && reason.message ? reason.message : reason) + '\n');
});
