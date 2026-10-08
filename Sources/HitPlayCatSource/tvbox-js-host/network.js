'use strict';
// HitPlay tvbox JS 源运行时 —— 网络层。
// 特性：跟随重定向（最多 8 跳，303/301/302 POST 降级 GET）、gzip/deflate/brotli
// 解压、charset 解码、buffer 模式（0 文本 / 1 字节数组 / 2 base64 / 3 字节数组）、
// 16MiB 响应上限、默认 10s 超时。返回 {code, headers, content, url}。
const http = require('http');
const https = require('https');
// 默认 UA：CDN/代理（如 git 加速前缀）普遍对无 UA 请求返回 403；生态惯例是
// 每请求自带 UA，这里只兜底缺省场景（源显式给的 UA 永远优先）。
const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
function request(url, options = {}, redirects = 0) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    if (!['http:', 'https:'].includes(target.protocol)) return reject(new Error('Unsupported request protocol'));
    let body = options.body;
    const headers = typeof options.headers === 'string' ? JSON.parse(options.headers) : {...options.headers};
    const hasUA = Object.keys(headers).some(key => key.toLowerCase() === 'user-agent');
    if (!hasUA) headers['User-Agent'] = DEFAULT_USER_AGENT;
    if (options.data != null) {
      if (options.postType === 'form') {
        body = new URLSearchParams(options.data).toString(); headers['Content-Type'] ||= 'application/x-www-form-urlencoded';
      } else if (options.postType === 'form-data') {
        const boundary = 'hitplay-' + require('crypto').randomBytes(12).toString('hex');
        body = Object.entries(options.data).map(([key, value]) => `--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${value}\r\n`).join('') + `--${boundary}--\r\n`;
        headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
      } else { body = JSON.stringify(options.data); headers['Content-Type'] ||= 'application/json'; }
    }
    const method = String(options.method || 'GET').toUpperCase();
    if (body != null && !['GET', 'HEAD'].includes(method)) headers['Content-Length'] = Buffer.byteLength(String(body));
    const req = (target.protocol === 'https:' ? https : http).request(target, {method, headers}, res => {
      if ([301,302,303,307,308].includes(res.statusCode) && res.headers.location && options.redirect !== 0) {
        res.resume();
        if (redirects >= 8) return reject(new Error('Too many redirects'));
        const next = {...options};
        if (res.statusCode === 303 || ([301,302].includes(res.statusCode) && method === 'POST')) {next.method = 'GET'; delete next.data; delete next.body;}
        return request(new URL(res.headers.location, target).href, next, redirects + 1).then(resolve, reject);
      }
      const chunks = []; let length = 0;
      res.on('data', chunk => {length += chunk.length; if (length > 16 * 1024 * 1024) req.destroy(new Error('Response exceeds 16 MiB')); else chunks.push(chunk);});
      res.on('error', reject);
      res.on('end', () => {
        let buffer = Buffer.concat(chunks);
        try {
          const zlib = require('zlib');
          if (res.headers['content-encoding'] === 'gzip') buffer = zlib.gunzipSync(buffer);
          else if (res.headers['content-encoding'] === 'deflate') buffer = zlib.inflateSync(buffer);
          else if (res.headers['content-encoding'] === 'br') buffer = zlib.brotliDecompressSync(buffer);
          // TVBox UA 协商：部分源服务端只放行 tvbox 系
          // UA（403 + 「仅允许 XX 访问」拦截页）。命中时以 tvbox UA 自动重试一次；
          // 拦截本身证明当前 UA 被拒，覆盖显式 UA 是协商语义的一部分。
          if (res.statusCode === 403 && !options.__tvboxUARetry) {
            const probe = buffer.toString('utf8');
            if (probe.includes('仅允许') && probe.includes('访问')) {
              const retryHeaders = { ...headers, 'User-Agent': 'tvbox/hitplay/1.0' };
              return request(target.href, { ...options, headers: retryHeaders, __tvboxUARetry: true }, redirects).then(resolve, reject);
            }
          }
          const charset = /charset=([^;]+)/i.exec(headers['Content-Type'] || headers['content-type'] || res.headers['content-type'] || '')?.[1] || 'utf-8';
          const content = options.buffer === 2 ? buffer.toString('base64') : options.buffer === 1 || options.buffer === 3 ? Array.from(buffer) : new TextDecoder(charset).decode(buffer);
          resolve({code:res.statusCode, status:res.statusCode, headers:res.headers, content, url:target.href});
        } catch (error) {reject(error);}
      });
    });
    req.setTimeout(Number(options.timeout) || 10000, () => req.destroy(new Error('Network timeout')));
    req.on('error', reject);
    if (body != null && !['GET','HEAD'].includes(method)) req.write(String(body));
    req.end();
  });
}
module.exports = {request};
