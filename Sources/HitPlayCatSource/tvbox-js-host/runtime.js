'use strict';
// HitPlay tvbox JS 源运行时 —— worker 会话池。
// 由 tvbox-js-host/host.js（单文件源）与 cms-host.js（TVBox 配置内联 type 3 JS 源）共用。
// 职责：每站点一个 worker（ESM 沙箱，见 worker.js）、会话池上限 15 + LRU 释放、
// play 后钉住、30s 调用超时（超时 → dispose → terminate）。
const { Worker } = require('worker_threads');
const path = require('path');
const crypto = require('crypto');

class SessionPool {
  /**
   * @param {object} options
   *   hostDir    tvbox-js-host 目录（worker.js / network.js / io_worker.js 所在）
   *   cacheRoot  模块缓存 + local 存储根
   *   packageDir 源包目录（file:// 源读取围栏）
   *   proxyPort  /proxy 回源端口（worker 内 getProxyUrl 拼接；服务绑定后更新）
   */
  constructor(options) {
    this.hostDir = options.hostDir;
    this.cacheRoot = options.cacheRoot;
    this.packageDir = options.packageDir;
    // 数值或 () => port（宿主服务绑定后才有端口）。
    this.proxyPort = options.proxyPort || 0;
    this.sessions = new Map();
    this.pending = [];
    this.sequence = 0;
    this.stopped = false;
  }

  proxyPortValue() {
    return typeof this.proxyPort === 'function' ? this.proxyPort() : (this.proxyPort || 0);
  }

  dispose(session, error) {
    if (this.sessions.get(session.key) !== session) return;
    this.sessions.delete(session.key);
    session.worker.terminate();
    if (session.job) { clearTimeout(session.timer); session.job.reject(error); session.job = null; }
  }

  pump() {
    if (this.stopped) return;
    for (let index = 0; index < this.pending.length;) {
      const job = this.pending[index];
      let session = this.sessions.get(job.key);
      if (session && session.job) { index++; continue; }
      if (!session) {
        if (this.sessions.size >= 15) {
          const idle = [...this.sessions.values()].find(item => !item.job && !item.pinned);
          if (!idle) return;
          this.dispose(idle, new Error('JS source released'));
        }
        const worker = new Worker(path.join(this.hostDir, 'worker.js'), {
          workerData: {
            api: job.site.api,
            extend: job.site.extend || '',
            identity: job.site.key,
            siteKey: job.site.key,
            pkgDir: this.packageDir,
            cacheDir: path.join(this.cacheRoot, crypto.createHash('sha256').update(job.site.key).digest('hex')),
            proxyUrl: 'http://127.0.0.1:' + this.proxyPortValue() + '/proxy?source=' + encodeURIComponent(job.site.key),
          },
          execArgv: ['--experimental-vm-modules'],
        });
        session = { key: job.site.key, worker, job: null, site: job.site, pinned: false };
        this.sessions.set(job.site.key, session);
        worker.on('message', response => {
          const active = session.job;
          if (!active || active.id !== response.id) return;
          clearTimeout(session.timer); session.job = null;
          if (!response.error && active.method === 'play') {
            for (const other of this.sessions.values()) other.pinned = false;
            session.pinned = true;
          }
          if (response.error) active.reject(new Error(response.error)); else active.resolve(response.data);
          this.pump();
        });
        worker.on('error', error => { this.dispose(session, error); this.pump(); });
        worker.on('exit', code => { if (this.sessions.get(session.key) === session) { this.dispose(session, new Error('JS worker exited: ' + code)); this.pump(); } });
      }
      this.pending.splice(index, 1);
      session.job = job;
      session.timer = setTimeout(() => { this.dispose(session, new Error('JS call timed out')); this.pump(); }, 30000);
      session.worker.postMessage({ id: job.id, method: job.method, args: job.args });
    }
  }

  /** site: {key, api(file://|http(s)), extend}；method: init/home/…；args: 数组。 */
  call(site, method, args) {
    if (this.stopped) return Promise.reject(new Error('JS host stopped'));
    if (!site || !site.key) return Promise.reject(new Error('Unknown JS site'));
    return new Promise((resolve, reject) => {
      this.pending.push({ key: site.key, site, method, args, id: ++this.sequence, resolve, reject });
      this.pump();
    });
  }

  disposeAll(reason) {
    for (const session of [...this.sessions.values()]) this.dispose(session, new Error(reason));
    for (const job of this.pending.splice(0)) job.reject(new Error(reason));
  }
}

module.exports = { SessionPool };
