// lib/net.js —— QuickJS/猫源生态标准请求适配层（FongMi lib 净版语义）。
// 依赖沙箱注入的 http/_http 全局（tvbox-js-host/worker.js 原生提供，语义一致）：
//   _http(url, {async:false})          → 同步请求，直接返回结果对象
//   _http(url, {complete: res => …})   → 异步请求，complete 回调交还结果
let req = (url, options) => http(url, Object.assign({
    async: false
}, options));

function http(url, options = {}) {
    if (options?.async === false) return _http(url, options)
    return new Promise(resolve => _http(url, Object.assign({
        complete: res => resolve(res)
    }, options))).catch(err => {
        console.error(err && err.name, err && err.message, err && err.stack)
        return {
            ok: false,
            status: 500,
            url
        }
    })
};
export { req, http };
