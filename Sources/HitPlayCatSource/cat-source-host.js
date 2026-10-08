#!/usr/bin/env node
/**
 * HitPlay 猫源引擎宿主（HitPlay cat-source host）
 *
 * 职责（兼容猫源引擎包公开调用约定，独立实现）：
 * 1. 加载源包目录中的 index.js 与 index.config.js；
 * 2. 注入宿主全局：catServerFactory（源包用它注册 HTTP 路由）、
 *    catDartServerPort（端口占位）、DB_NAME；
 * 3. 通过监听 net.Server.prototype.listen 捕获源包创建的服务端口，
 *    只认 catServerFactory 创建的主内容服务，避免 /msg 等辅助服务抢占；
 * 4. 在独立端口启动主内容服务并把地址写到 stdout（HITPLAY_PORT=<port>）；
 * 5. /msg 接收源包的结构化日志并转发到 stderr（不占内容端口）；
 * 6. stdin 收到 stop、SIGTERM/SIGINT 或 stdin EOF 时优雅退出。
 *
 * 用法：node cat-source-host.js <packageDir>
 */

'use strict';

const fs = require('fs');
const path = require('path');
const net = require('net');

// ---------- 多源端口隔离 ----------
// 多个猫源引擎并存时（HitPlay 多源管理），每个引擎是独立 Node 进程，但
// 有些引擎会把服务绑在固定端口（2333/9988…），多个实例可能互相
// EADDRINUSE。宿主接管 listen：一律改为随机端口（port 0），真实端口经
// HITPLAY_PORT 上报给应用，引擎内部互访使用 catDartServerPort()/相对路径，
// 不依赖固定端口。（注意：文件后段端口探针的 originalListen 是另一层包装。）
const isolatedListen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (typeof arg === 'number' && arg > 0) {
      args[i] = 0;
      break;
    }
    if (arg && typeof arg === 'object' && !Array.isArray(arg) && Number(arg.port) > 0) {
      args[i] = { ...arg, port: 0 };
      break;
    }
  }
  return isolatedListen.apply(this, args);
};

const packageDir = process.argv[2];
if (!packageDir || !fs.existsSync(path.join(packageDir, 'index.js'))) {
  process.stderr.write('[hitplay-host] 缺少源包 index.js: ' + packageDir + '\n');
  process.exit(2);
}

// ---------- 输出护栏 ----------
// 源码日志库会把 axios 系错误（config/response 挂整个请求体）或大响应对象反复
// 序列化成数百 MB 字符串，把宿主内存与输出链路一起拖垮；stdout 同时是
// HITPLAY_PORT/HITPLAY_RELOADED 控制通道，超长行还会拖慢应用侧行解析。两层防护：
// 1. console.* 大对象摘要：Error/Buffer/长字符串/任意对象一律产出有界摘要，
//    绝不先构造巨型字符串（axios 系按 shape 摘要，未知对象 util.inspect 限深）；
// 2. process.stdout/stderr.write 单行限幅：超限行截断并打标记（宿主自身控制行
//    恒短，不受影响）。必须在加载源包之前安装。
// 注意：worker 线程的 console 直写 fd，主线程包装看不到，worker 需自装一份。
(function installHitPlayOutputGuard () {
  if (globalThis.__hitplayOutputGuardInstalled) return;
  globalThis.__hitplayOutputGuardInstalled = true;
  const LABEL = 'hitplay-host';
  const MAX_LINE_BYTES = 128 * 1024;
  const MAX_STRING_CHARS = 4 * 1024;
  const truncatedSuffix = `\n[${LABEL}] 超长输出行已截断（单行上限 ${MAX_LINE_BYTES} 字节）\n`;
  const truncatedEndMark = `[${LABEL}] 超长行残余已丢弃\n`;

  // 大对象有界摘要：任何输入都产出短字符串或原值，绝不构造巨型字符串。
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
      return value.stack || value.message || String(value); // stack 有界
    }
    if (Array.isArray(value) && value.length > 64) return `[Array(${value.length})]`;
    if (typeof value === 'object') {
      try {
        // util.inspect 限深限长：有界输出，不展开巨数组/长字符串。
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

// 源包路径围栏：动态 require 的目标必须解析回源包目录内，防御 argv 注入
// `..`/符号链接后越界加载任意本地脚本。require 的天然注入面（命令注入类），
// 以目录围栏收敛；源包内容本身的信任边界 = 用户主动安装的源（产品设计）。
function resolveInsidePackageDir (relative) {
  const base = fs.realpathSync(packageDir);
  const resolved = fs.realpathSync(path.resolve(packageDir, relative));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) {
    throw new Error('[hitplay-host] 源包路径越界，拒绝加载: ' + resolved);
  }
  return resolved;
}

// ---------- 源包兼容垫层（社区宿主通用惯例） ----------
// 部分源包把源站代码当常驻服务写，会误调 process.exit 结束宿主进程；
// 屏蔽后宿主自身退出统一走 shutdown() 里的 process.reallyExit。
const originalProcessExit = process.exit.bind(process);
process.exit = (code) => {
  process.stderr.write('[hitplay-host] 已拦截源包 process.exit(' + code + ')\n');
};

if (typeof WebAssembly === 'undefined') {
  // 低版本/裁剪 Node 无 WebAssembly：给 llhttp 类纯 WASM 依赖一个空实现，
  // 让源包的 require 阶段不崩溃（请求仍走 Node 自带 http 栈）。
  const llhttpStub = {
    memory: { buffer: new ArrayBuffer(1024) },
    llhttp_alloc() { return 0; },
    llhttp_free() {},
    llhttp_init() {},
    llhttp_execute() { return 0; },
    llhttp_get_error_pos() { return 0; },
    llhttp_get_error_reason() { return 0; },
    llhttp_resume() {}
  };
  globalThis.WebAssembly = {
    compile: async () => ({}),
    instantiate: async () => ({ exports: llhttpStub })
  };
}

// globalThis.fetch 垫层：老 Node（<18）没有内置 fetch 时，源包代码里直接调
// fetch() 会 ReferenceError；有 node-fetch 就挂上，没有就静默跳过。
try {
  const fetchImpl = require('node-fetch');
  if (typeof fetchImpl === 'function') {
    globalThis.fetch = fetchImpl;
    globalThis.Headers = fetchImpl.Headers;
    globalThis.Request = fetchImpl.Request;
    globalThis.Response = fetchImpl.Response;
    process.stderr.write('[hitplay-host] 已注入 node-fetch 全局垫层\n');
  }
} catch (_) { /* 新 Node 自带 fetch，无需垫层 */ }

try {
  if (!globalThis.crypto) {
    globalThis.crypto = require('crypto');
  }
} catch (_) { /* 无 crypto 模块时跳过 */ }

// fastify 兼容：部分源包默认导出依赖 fastify 实例形态（.listen 返回 Promise 且
// 实例可 .register 链式）。宿主环境没有 fastify 的监听语义时给个桩，避免启动即崩。
const Module = require('module');
const originalModuleLoad = Module._load;
Module._load = function (request) {
  if (request === 'fastify') {
    try {
      const fastify = originalModuleLoad.apply(this, arguments);
      return function () {
        const inst = fastify.apply(this, arguments);
        return inst && typeof inst.listen === 'function' ? inst : createFastifyStub();
      };
    } catch (_) {
      return function () { return createFastifyStub(); };
    }
  }
  return originalModuleLoad.apply(this, arguments);
};

function createFastifyStub () {
  return {
    register() { return this; },
    listen(opts, cb) {
      const port = typeof opts === 'number' ? opts : (opts && opts.port) || 0;
      const addr = `http://0.0.0.0:${port}`;
      if (typeof cb === 'function') cb(null, addr);
      return Promise.resolve(addr);
    },
    close() {},
    stop: false
  };
}

let contentPort = null;
let capturedServer = null;
let fallbackServer = null;
let fallbackPort = null;
let fallbackReported = false;
let shuttingDown = false;
setTimeout(() => {
  if (!fallbackReported && !contentPort && fallbackServer) {
    fallbackReported = true;
    capturedServer = fallbackServer;
    contentPort = fallbackPort;
    process.stderr.write('[hitplay-host] 无主内容服务，使用候补端口 ' + fallbackPort + '\n');
    process.stdout.write('HITPLAY_PORT=' + fallbackPort + '\n');
  }
}, 12000).unref();

// ---------- 端口捕获：监听 listen 探测主内容服务 ----------
const originalListen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  const server = this;
  originalListen.apply(server, args);
  server.on('listening', function onListening() {
    const address = server.address();
    const port = address && typeof address === 'object' ? address.port : null;
    if (!port) return;
    if (server.__hitplayAuxServer) return;
    if (capturedServer === server && contentPort === port) return;
    if (server.__hitplayMainServer) {
      // 主内容服务（catServerFactory 创建）：立即上报，覆盖此前误捕获的端口。
      const previous = capturedServer;
      capturedServer = server;
      contentPort = port;
      if (previous && previous !== server) {
        process.stderr.write('[hitplay-host] 内容服务端口更正为 ' + port + '\n');
      }
      process.stdout.write('HITPLAY_PORT=' + port + '\n');
      return;
    }
    if (capturedServer) {
      process.stderr.write('[hitplay-host] 忽略辅助服务端口 ' + port + '\n');
      return;
    }
    // 非主服务先记为候补；主服务随后出现时会覆盖。
    if (!fallbackServer) {
      fallbackServer = server;
      fallbackPort = port;
      process.stderr.write('[hitplay-host] 暂记候补端口 ' + port + '（等待主内容服务）\n');
    }
  });
  return server;
};

// ---------- 宿主全局契约 ----------
const HOST_PORT = Number(process.env.HITPLAY_HOST_PORT) || 0;

// 源包通常自带 node_modules/express；优先用包内 Express 保证中间件兼容，
// 找不到时回退到内置的极简路由 shim。
let expressFactory = null;
try {
  expressFactory = require(path.join(packageDir, 'node_modules', 'express'));
  process.stderr.write('[hitplay-host] 使用源包内置 express\n');
} catch (_) {
  process.stderr.write('[hitplay-host] 源包无 express，使用内置路由 shim\n');
}

// 无 index.config.js 的包使用的最小启动配置
function buildDefaultStartConfig () {
  return {
    ali: { token: '', token280: 'token280' },
    quark: { cookie: '' },
    uc: { cookie: '', token: 'token', ut: 'ut' },
    y115: { cookie: '' },
    baidu: { cookie: '' },
    bili: { cookie: '' },
    muou: { url: '' },
    wogg: { url: '' },
    woniu: { url: '' },
    leijing: { url: '' },
    tgsou: { tgPic: false, count: 0, url: '', channelUsername: '' },
    tgchannel: {},
    sites: { list: [] },
    pans: { list: [] },
    danmu: { urls: [], autoPush: false, excludeSites: ['live'] },
    t4: { list: [] },
    cms: { list: [] },
    alist: [],
    color: {}
  };
}

global.catServerFactory = function (factory, options) {
  // CatVodOpen 原生合同：catServerFactory(requestHandler, options) → 返回可 listen 的 server。
  // requestHandler 形参个数 >= 2（req, res）即视为原生合同；express 风格工厂为单参。
  if (typeof factory === 'function' && factory.length >= 2) {
    const httpModule = require('http');
    const rawServer = httpModule.createServer((req, res) => {
      try {
        const result = factory(req, res);
        if (result && typeof result.catch === 'function') {
          result.catch((error) => {
            process.stderr.write('[hitplay-host] 请求处理异常: ' + (error && error.message) + '\n');
            if (!res.writableEnded) { res.statusCode = 500; res.end('engine error'); }
          });
        }
      } catch (error) {
        process.stderr.write('[hitplay-host] 请求处理异常: ' + (error && error.message) + '\n');
        if (!res.writableEnded) { res.statusCode = 500; res.end('engine error'); }
      }
    });
    rawServer.__hitplayMainServer = true;
    return rawServer;
  }
  if (expressFactory) {
    try {
      const app = expressFactory();
      factory(app);
      app.listen(0, () => {});
      return app;
    } catch (error) {
      process.stderr.write('[hitplay-host] 包内 express 路由异常，回退 shim: ' + (error && error.message) + '\n');
    }
  }
  const expressLike = {
    _handlers: [],
    use (...args) { this._handlers.push({ type: 'use', args }); return this; },
    get (route, ...handlers) { this._handlers.push({ type: 'get', route, handlers }); return this; },
    post (route, ...handlers) { this._handlers.push({ type: 'post', route, handlers }); return this; },
    all (route, ...handlers) { this._handlers.push({ type: 'all', route, handlers }); return this; },
    set () { return this; },
    enable () { return this; },
    disable () { return this; },
    engine () { return this; },
    param () { return this; },
    listen (port, callback) {
      if (typeof port === 'function') { callback = port; port = 0; }
      startContentServer(this, Number(port) || 0, callback);
      return this;
    }
  };
  try {
    factory(expressLike);
  } catch (error) {
    process.stderr.write('[hitplay-host] catServerFactory 回调异常: ' + (error && error.message) + '\n');
  }
  return expressLike;
};

// 消息端口通过 catDartServerPort() 提供（HTTP /msg），
// 返回 0 表示消息通道不可用（引擎会自行降级）。
global.catDartServerPort = () => (typeof msgPort === 'number' ? msgPort : 0);
global.DB_NAME = 'hitplay';

// catServerFactory 的服务实现：把 express-like 路由映射到 Node http。
function startContentServer (app, port, callback) {
  // 必须用 http.Server：net.Server 不发出 request 事件，监听了也不会被调用。
  const server = require('http').createServer((req, res) => {
    socketGuard(req.socket);
    dispatch(req, res);
  });
  server.__hitplayMainServer = true;
  const dispatch = createDispatch(app);
  server.listen(port, () => {
    const address = server.address();
    const bound = address && typeof address === 'object' ? address.port : port;
    process.stderr.write('[hitplay-host] 内容服务已启动 :' + bound + '\n');
    if (callback) callback();
  });
  return server;
}

function socketGuard (socket) {
  socket.on('error', () => {});
}

function createDispatch (app) {
  return function dispatch (req, res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    const parsed = new URL(req.url, 'http://localhost');
    let matched = null;
    for (const handler of app._handlers) {
      if (handler.type === 'get' && routeMatches(handler.route, parsed.pathname)) {
        matched = handler;
        break;
      }
      if (handler.type === 'all' && routeMatches(handler.route, parsed.pathname)) {
        matched = handler;
        break;
      }
    }
    if (!matched) {
      res.statusCode = 404;
      res.end('not found');
      return;
    }
    enrichRequest(req, parsed);
    const chain = matched.handlers.slice();
    runChain(chain, req, res, 0);
  };
}

function routeMatches (route, pathname) {
  if (!route) return true;
  if (route === pathname) return true;
  const pattern = String(route)
    .replace(/:[^/]+/g, '[^/]+')
    .replace(/\//g, '\\/');
  return new RegExp('^' + pattern + '/?$').test(pathname);
}

function enrichRequest (req, parsed) {
  req.query = {};
  parsed.searchParams.forEach((value, key) => { req.query[key] = value; });
  req.path = parsed.pathname;
}

function runChain (handlers, req, res, index) {
  if (index >= handlers.length) { res.end(); return; }
  const handler = handlers[index];
  try {
    handler(req, res, () => runChain(handlers, req, res, index + 1));
  } catch (error) {
    process.stderr.write('[hitplay-host] 路由处理异常: ' + (error && error.message) + '\n');
    if (!res.writableEnded) { res.statusCode = 500; res.end('engine error'); }
  }
}

// ---------- /msg 消息服务（引擎通过 HTTP /msg 上报消息） ----------
// 引擎通过 catDartServerPort() 拿到宿主端口后，用 messageToDart
// POST JSON 上报 toast/getPlayInfo/saveProfile/queryProfile/openInternalWebview/
// danmuPush 等 action。此前的 raw TCP 日志口接不住 HTTP 请求（请求会落空）。
let msgPort = 0;try {
  const msgServer = require('http').createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      let reply = {};
      try {
        const msg = JSON.parse(raw);
        process.stderr.write('[cat-msg] ' + JSON.stringify(msg) + '\n');
        // queryProfile/saveProfile 语义：返回空对象让引擎走默认档案（凭证仍由源包
        // 自己的 JsonDB 管理）；getPlayInfo 返回空串代表无原生播放信息。
        if (msg && msg.action === 'getPlayInfo') reply = { playInfo: '' };
      } catch (_) {
        if (raw) process.stderr.write('[cat-msg] ' + raw + '\n');
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(reply));
    });
    req.on('error', () => {});
  });
  msgServer.__hitplayAuxServer = true;
  msgServer.listen(0, '127.0.0.1', () => {
    msgPort = msgServer.address().port;
    process.stderr.write('[hitplay-host] /msg 消息端口 ' + msgPort + '\n');
  });
} catch (error) {
  process.stderr.write('[hitplay-host] /msg 服务启动失败（不阻塞主流程）\n');
}

// ---------- 加载源包 ----------
let loadedSourceModule = null;
let loadedStartConfig = null;

function clearRequireCacheShallow (modulePath) {
  try {
    const resolved = require.resolve(modulePath);
    const mod = require.cache[resolved];
    if (mod && Array.isArray(mod.children)) {
      mod.children.forEach((child) => {
        if (child && child.id) delete require.cache[child.id];
      });
    }
    delete require.cache[resolved];
  } catch (error) {
    // ignore missing modules
  }
}

/// 装载源包（首启与热重载共用；C2-5）：stop 旧实例 → 清 require 缓存 →
/// 重新 require → start(config)。返回是否成功。
async function loadSourcePackage () {
  let startConfig = null;
  const configPath = path.join(packageDir, 'index.config.js');
  if (fs.existsSync(configPath)) {
    try {
      const configModule = require(configPath);
      startConfig = configModule && configModule.default ? configModule.default : configModule;
      process.stderr.write('[hitplay-host] 已加载 index.config.js\n');
    } catch (configError) {
      process.stderr.write('[hitplay-host] index.config.js 加载失败（继续）: ' + (configError && configError.message) + '\n');
    }
  }
  // 引擎包惯例：无配置文件的包使用内置默认配置（缺 config 时包内启动流程
  // 流程会读 e.config.pans/e.config.sites，传 null 会 TypeError 导致引擎无法启动）。
  if (!startConfig || typeof startConfig !== 'object') {
    startConfig = buildDefaultStartConfig();
    process.stderr.write('[hitplay-host] 包无 index.config.js，使用内置默认配置\n');
  }
  // 热重载：先停旧实例，再清缓存重载。
  if (loadedSourceModule && typeof loadedSourceModule.stop === 'function') {
    try {
      await loadedSourceModule.stop();
    } catch (error) {
      process.stderr.write('[hitplay-host] 旧实例 stop 异常（继续）: ' + (error && error.message) + '\n');
    }
  }
  clearRequireCacheShallow(path.join(packageDir, 'index.js'));
  clearRequireCacheShallow(configPath);
  loadedSourceModule = require(path.join(packageDir, 'index.js'));
  loadedStartConfig = startConfig;
  process.stderr.write('[hitplay-host] 已加载 index.js\n');
  if (typeof loadedSourceModule.start !== 'function') {
    process.stderr.write('[hitplay-host] 源包未导出 start()，跳过自动启动\n');
    return false;
  }
  await loadedSourceModule.start(startConfig);
  process.stderr.write('[hitplay-host] start() 完成\n');
  if (!contentPort) process.stderr.write('[hitplay-host] 警告：start() 完成但内容服务未监听\n');
  return true;
}

/// 热重载入口（stdin 收到 reload / {"cmd":"reload"}）。
async function reloadSourcePackage () {
  try {
    await loadSourcePackage();
    process.stdout.write('HITPLAY_RELOADED=1\n');
    process.stderr.write('[hitplay-host] 热重载完成\n');
  } catch (error) {
    process.stderr.write('[hitplay-host] 热重载失败: ' + (error && error.stack ? error.stack : error) + '\n');
    process.stdout.write('HITPLAY_RELOADED=0\n');
  }
}

(async () => {
  try {
    await loadSourcePackage();
  } catch (error) {
    process.stderr.write('[hitplay-host] 源包加载失败: ' + (error && error.stack ? error.stack : error) + '\n');
    process.exit(3);
  }
})();

// ---------- 生命周期 ----------
function shutdown (reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write('[hitplay-host] 退出（' + reason + '）\n');
  try { if (capturedServer) capturedServer.close(); } catch (_) {}
  // process.exit 已被垫层拦截（防源包误杀宿主），此处用底层 reallyExit 真正退出。
  try { if (capturedServer) capturedServer.unref(); } catch (_) {}
  process.reallyExit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
// 兜底守护：父应用被强杀/崩溃时 stdin EOF 可能延迟或不触发，PPID 变 1 即父进程已亡。
setInterval(() => {
  if (process.env.HITPLAY_EMBEDDED_NODE !== '1' && process.ppid === 1) shutdown('parent exited');
}, 3000).unref();
process.stdin.setEncoding('utf8');
let stdinLineBuffer = '';
process.stdin.on('data', (chunk) => {
  // C2-5 热重载协议：整行 "reload" 或 {"cmd":"reload"}；"stop" 依旧优雅退出。
  stdinLineBuffer += String(chunk);
  let newlineIndex;
  while ((newlineIndex = stdinLineBuffer.indexOf('\n')) >= 0) {
    const line = stdinLineBuffer.slice(0, newlineIndex).trim();
    stdinLineBuffer = stdinLineBuffer.slice(newlineIndex + 1);
    if (!line) continue;
    if (line === 'stop') { shutdown('stdin stop'); continue; }
    let command = line;
    if (line.startsWith('{')) {
      try { command = String(JSON.parse(line).cmd || ''); } catch (_) { /* 非 JSON 按原文处理 */ }
    }
    if (command === 'reload') {
      reloadSourcePackage();
    }
  }
});
process.stdin.on('end', () => shutdown('stdin EOF'));
process.on('uncaughtException', (error) => {
  process.stderr.write('[hitplay-host] 未捕获异常: ' + (error && error.stack ? error.stack : error) + '\n');
});
process.on('unhandledRejection', (reason) => {
  let detail = reason && reason.stack ? reason.stack : String(reason);
  try {
    const props = {};
    for (const k of Object.keys(reason || {})) {
      const v = reason[k];
      props[k] = v && v.message ? v.message + (v.code ? '[' + v.code + ']' : '') : v;
    }
    detail += ' | props: ' + JSON.stringify(props);
    if (reason && reason.inner) detail += ' | inner: ' + String(reason.inner).slice(0, 200);
  } catch (_) {}
  process.stderr.write('[hitplay-host] 未处理的 Promise 拒绝: ' + detail + '\n');
});

// 保底：若源包 N 秒内未启动内容服务，提示但不退出（部分包按需启动）。
setTimeout(() => {
  if (!contentPort) {
    process.stderr.write('[hitplay-host] 警告：内容服务尚未注册端口\n');
  }
}, 15000).unref();
