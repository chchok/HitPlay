'use strict';
// HitPlay tvbox JS 源运行时 —— 源执行 worker。
// 每个站点一个 worker：vm.SourceTextModule（ESM）沙箱内加载源文件，
// 兼容三种导出形态：__jsEvalReturn()（FongMi cat.js 格式）、default（drpy ESM）、
// __JS_SPIDER__（quickjs 全局格式）。
//
// 【信任边界与安全说明（设计决策，非疏忽）】
// 1. 本文件的职责是在受控 vm 沙箱中运行"用户主动安装"的 JS 源脚本——与仓库中
//    cat-source-host.js 以 require() 加载用户安装的引擎包同一信任模型：源码作者
//    ≠ 可信方，执行本身是产品功能。隔离手段 = 独立 vm 上下文（无 require/process
//    泄漏，网络 IO 只经宿主提供的 req/http 白名单）+ 文件读取目录围栏
//    （readContainedFile）+ 宿主侧 30s 会话超时后 terminate（host.js pump）。
// 2. md5X/aesX/desX/rsaX 是 TVBox/猫源生态的兼容 API 契约：源脚本按名调用这些
//    函数与各站点服务端交互，算法选择由站点服务端决定（部分站点接口要求 MD5
//    摘要或 RSA PKCS1 签名），宿主只是兼容层。这些原语不用于安全保护，替换成
//    SHA-256/OAEP 会直接破坏生态源码兼容性；因此按契约原样提供，仅暴露给
//    沙箱内源码使用。
// 3. 源方法派发采用跨上下文直接调用（函数对象在 vm 上下文内创建、宿主侧
//    apply）：语义与上下文内调用一致（函数闭包仍持有沙箱全局），阻塞防护由
//    宿主侧 dispose→terminate 兜底（等效超时保护）。
const {parentPort, workerData, Worker} = require('worker_threads');
const vm = require('vm');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {request} = require('./network');
// ---------- 输出护栏（worker 侧必须自装） ----------
// worker 线程的 console 直写进程 fd，主线程宿主装的包装看不到；沙箱 console
// 与本 worker 是同一对象，此处安装后源码的巨型日志在进入输出链路前即被限幅。
(function installHitPlayOutputGuard () {
  if (globalThis.__hitplayOutputGuardInstalled) return;
  globalThis.__hitplayOutputGuardInstalled = true;
  const LABEL = 'hitplay-tvbox-worker';
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
const io = new Worker(path.join(__dirname, 'io_worker.js'));
const {fileURLToPath} = require('url');
const hash = value => crypto.createHash('sha256').update(String(value)).digest('hex');
const root = workerData.cacheDir;
const packageRoot = fs.realpathSync(String(workerData.pkgDir));
fs.mkdirSync(root, {recursive:true});
const storagePath = path.join(root, 'storage-' + hash(workerData.identity) + '.json');
let storage = {}; try {storage = JSON.parse(fs.readFileSync(storagePath, 'utf8'));} catch (_) {}
function saveStorage() {const temp = storagePath + '.tmp'; fs.writeFileSync(temp, JSON.stringify(storage)); fs.renameSync(temp, storagePath);}
function syncRequest(url, options = {}) {
  const shared = new SharedArrayBuffer(4 * 1024 * 1024 + 8);
  const state = new Int32Array(shared, 0, 2);
  io.postMessage({url, options:JSON.parse(JSON.stringify(options)), shared});
  if (Atomics.wait(state, 0, 0, (Number(options.timeout) || 10000) + 1000) === 'timed-out') throw new Error('Synchronous request timed out');
  const response = JSON.parse(Buffer.from(new Uint8Array(shared, 8, Atomics.load(state, 1))).toString());
  if (response.error) throw new Error(response.error);
  return response.result;
}
function req(url, options = {}) {
  if (options.async === true) {
    const pending = request(url, options);
    if (typeof options.complete === 'function') pending.then(options.complete);
    return pending;
  }
  return syncRequest(url, options);
}
function crypt(mode, encrypt, input, inBase64, key, iv, outBase64, kind) {
  let keyBytes = Buffer.from(key);
  const blockMode = String(mode).toLowerCase().includes('ecb') ? 'ecb' : 'cbc';
  if (kind === 'des') {const padded = Buffer.alloc(16); keyBytes.copy(padded, 0, 0, 16); keyBytes = Buffer.concat([padded, padded.subarray(0, 8)]);}
  const algorithm = kind === 'aes' ? `aes-${keyBytes.length * 8}-${blockMode}` : `des-ede3-${blockMode}`;
  const isEcb = algorithm.endsWith('-ecb');
  const cipher = encrypt ? crypto.createCipheriv(algorithm, keyBytes, isEcb ? null : Buffer.from(iv)) : crypto.createDecipheriv(algorithm, keyBytes, isEcb ? null : Buffer.from(iv));
  const output = Buffer.concat([cipher.update(Buffer.from(input, inBase64 ? 'base64' : 'utf8')), cipher.final()]);
  return output.toString(outBase64 ? 'base64' : 'utf8');
}
const sandbox = {
  console, Buffer, URL, URLSearchParams, TextEncoder, TextDecoder,
  __JS_SPIDER__:undefined,
  setTimeout, clearTimeout, setInterval, clearInterval,
  req, http:(url, options = {}) => options.async === false ? req(url, options) : request(url, options),
  _http:(url, options = {}) => options.complete ? request(url, options).then(options.complete) : req(url, options),
  joinUrl:(base, relative) => new URL(relative, base).href,
  getProxyUrl:() => workerData.proxyUrl,
  getProxy:() => workerData.proxyUrl,
  // 兼容契约 API：站点接口普遍要求 MD5 摘要（非安全用途，见文件头安全说明）。
  md5X:value => crypto.createHash('md5').update(String(value)).digest('hex'),
  base64Encode:value => Buffer.from(String(value)).toString('base64'),
  base64Decode:value => Buffer.from(String(value), 'base64').toString(),
  atob:value => Buffer.from(String(value), 'base64').toString('binary'),
  btoa:value => Buffer.from(String(value), 'binary').toString('base64'),
  aesX:(...args) => crypt(...args, 'aes'), desX:(...args) => crypt(...args, 'des'),
  // 兼容契约 API：padding 由源脚本按站点服务端要求显式指定（OAEP 或 PKCS1），
  // 宿主只做参数透传，不做加密决策（见文件头安全说明）。
  rsaX:(mode, pub, encrypt, input, inBase64, key, outBase64) => {
    const fn = encrypt ? (pub ? crypto.publicEncrypt : crypto.privateEncrypt) : (pub ? crypto.publicDecrypt : crypto.privateDecrypt);
    const useOaep = String(mode).toUpperCase().includes('OAEP');
    return fn({key, padding: useOaep ? crypto.constants.RSA_PKCS1_OAEP_PADDING : crypto.constants.RSA_PKCS1_PADDING}, Buffer.from(input, inBase64 ? 'base64':'utf8')).toString(outBase64 ? 'base64':'utf8');
  },
  local:{get:(group,key) => storage[group]?.[key] ?? '', set:(group,key,value) => {(storage[group] ||= {})[key] = value; saveStorage();}, delete:(group,key) => {delete storage[group]?.[key]; saveStorage();}},
  _cache:{},
  getCache:key => sandbox._cache[key], setCache:(key,value) => {sandbox._cache[key]=value;}, delCache:key => {delete sandbox._cache[key];},
};
sandbox.globalThis = sandbox; sandbox.global = sandbox; sandbox.window = sandbox; sandbox.self = sandbox;
const context = vm.createContext(sandbox);
const modules = new Map();
function resolve(specifier, base) {
  if (specifier.startsWith('assets://') || specifier.startsWith('lib/')) return specifier;
  return new URL(specifier, base).href;
}
// 本地源文件读取：file:// URL 必须落在源包目录内（宿主侧已做一遍围栏，这里兜底）。
function readContainedFile(fileURL) {
  let target;
  try {target = fs.realpathSync(fileURLToPath(fileURL));} catch (_) {return null;}
  if (target !== packageRoot && !target.startsWith(packageRoot + path.sep)) return null;
  return fs.readFileSync(target, 'utf8');
}
async function source(url) {
  if (url.startsWith('assets://') || url.startsWith('lib/')) {
    const name = url.startsWith('lib/') ? url.slice(4) : url.replace(/^assets:\/\/js\/lib\//, '');
    if (path.basename(name) !== name || !name.endsWith('.js')) throw new Error('Unsupported built-in module: ' + url);
    return fs.readFileSync(path.join(__dirname, 'lib', name), 'utf8');
  }
  if (url.startsWith('file://')) {
    const text = readContainedFile(url);
    if (text == null) throw new Error('Local source escaped package directory: ' + url);
    return text;
  }
  if (!/^https?:\/\//.test(url)) throw new Error('Unsupported module URL: ' + url);
  const filename = path.join(root, hash(url) + '.js');
  if (fs.existsSync(filename)) return fs.readFileSync(filename, 'utf8');
  const result = await request(url, {timeout:15000});
  if (result.code < 200 || result.code >= 300) throw new Error('Module HTTP ' + result.code + ': ' + url);
  fs.writeFileSync(filename + '.tmp', result.content); fs.renameSync(filename + '.tmp', filename);
  return result.content;
}
async function moduleFor(url) {
  if (modules.has(url)) return modules.get(url);
  const pending = (async () => {
    const text = await source(url); 
    return new vm.SourceTextModule(text, {context, identifier:url,
      initializeImportMeta:meta => {meta.url=url;},
      importModuleDynamically:async (specifier, ref) => {
        const dependency = await moduleFor(resolve(specifier, ref.identifier));
        if (dependency.status === 'unlinked') await dependency.link(linker);
        if (dependency.status === 'linked') await dependency.evaluate({timeout:5000});
        return dependency;
      },
    });
  })();
  modules.set(url, pending);
  return pending;
}
async function linker(specifier, reference) {return moduleFor(resolve(specifier, reference.identifier));}
let spider; let initPromise;
async function initialize() {
  if (typeof vm.SourceTextModule !== 'function') throw new Error('JS runtime requires --experimental-vm-modules');
  const htmlModule = await moduleFor('assets://js/lib/cheerio.min.js');
  await htmlModule.link(linker); await htmlModule.evaluate({timeout:5000});
  const cheerio = htmlModule.namespace.default;
  const select = (html, expression) => {
    const $ = cheerio.load(String(html || ''));
    let nodes = $.root();
    for (const selector of expression.split('&&').filter(Boolean)) nodes = nodes.find(selector);
    return {$, nodes};
  };
  sandbox.pdfa = (html, expression) => {const {$, nodes} = select(html, expression); return nodes.toArray().map(node => $.html(node));};
  sandbox.pdfh = (html, expression) => {
    const parts = expression.split('&&'); const attribute = parts.pop();
    const {nodes} = select(html, parts.join('&&'));
    if (attribute === 'Text') return nodes.text();
    if (attribute === 'Html') return nodes.html() || '';
    return nodes.first().attr(attribute) || '';
  };
  sandbox.pd = (html, expression, base) => {const value = sandbox.pdfh(html, expression); if (!value || /^(data:|javascript:|magnet:)/.test(value)) return value; try {return new URL(value, base).href;} catch (_) {return value;}};
  const main = await moduleFor(workerData.api);
  await main.link(linker); await main.evaluate({timeout:15000});
  const namespace = main.namespace;
  const isCat = typeof namespace.__jsEvalReturn === 'function';
  spider = isCat ? namespace.__jsEvalReturn() : namespace.default;
  if (typeof spider === 'function') spider = spider();
  spider ||= sandbox.__JS_SPIDER__;
  if (!spider) throw new Error('JS must export default or __jsEvalReturn');
  let ext = workerData.extend || '';
  try {if (typeof ext === 'string' && ext.trim().startsWith('{')) ext = JSON.parse(ext);} catch (_) {}
  if (isCat) {sandbox.req = sandbox.http; ext = {stype:3, skey:workerData.siteKey, ext};}
  if (typeof spider.init === 'function') await spider.init(ext);
}
let queue = Promise.resolve();
parentPort.on('message', job => {
  queue = queue.catch(() => {}).then(async () => {
    try {
      await (initPromise ||= initialize());
      if (job.method === 'init') {parentPort.postMessage({id:job.id, data:''}); return;}
      const fn = spider[job.method];
      if (typeof fn !== 'function') throw new Error('JS method not supported: ' + job.method);
      // 跨上下文直接调用：阻塞防护由宿主侧会话超时 → dispose → terminate 兜底
      // （host.js pump 30s 定时器），worker 无需 eval 形态的执行包装。
      const data = await Promise.resolve(fn.apply(spider, job.args || []));
      let decoded = data;
      if (typeof data === 'string' && data.trim().startsWith('{')) {try {decoded = JSON.parse(data);} catch (_) {}}
      if (decoded?.msg && !decoded.list && !decoded.class && !decoded.url) throw new Error(String(decoded.msg));
      parentPort.postMessage({id:job.id, data});
    } catch (error) {parentPort.postMessage({id:job.id, error:error.stack || error.message});}
  });
});
