'use strict';
// HitPlay tvbox JS 源运行时 —— 同步请求桥。
// worker 线程通过 SharedArrayBuffer + Atomics.wait 把异步 HTTP 转成源码里的
// 同步 req()：主请求线程阻塞等待，本 worker 完成写入后 Atomics.notify 唤醒。
const {parentPort} = require('worker_threads');
const {request} = require('./network');
parentPort.on('message', async ({url, options, shared}) => {
  const state = new Int32Array(shared, 0, 2);
  let text;
  try {text = JSON.stringify({result:await request(url, options)});}
  catch (error) {text = JSON.stringify({error:error.message});}
  let data = Buffer.from(text);
  if (data.length > shared.byteLength - 8) data = Buffer.from(JSON.stringify({error:'Synchronous response exceeds 4 MiB'}));
  new Uint8Array(shared, 8).set(data);
  Atomics.store(state, 1, data.length);
  Atomics.store(state, 0, 1);
  Atomics.notify(state, 0);
});
