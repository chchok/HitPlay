// lib/utils.js —— 猫源生态 utils 兼容层（纯 JS 原生实现）。
// 生态里该模块常以 CATOP4 保护格式（QuickJS 字节码，仅 QuickJS 宿主可执行）分发；
// 本文件按其明文导出面（isSub/getSize/removeExt/log/isVideoFormat/jsonParse）与
// 内嵌正则常量做同语义原生实现，供 Node ESM 沙箱使用。行为对齐生态惯例：
// 全部无 throws，异常路径返回安全默认值。
const VIDEO_FORMAT_REGEXP = new RegExp(
    'http(?!http).{12,}?\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)\\?.*' +
    '|http(?!http).{12,}?\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)' +
    '|http(?!http).*?video/tos*'
);
const SUBRESOURCE_REGEXP = /\.(js|css|html)(\?.*)?$/i;

function isVideoFormat(url) {
    try { return VIDEO_FORMAT_REGEXP.test(String(url || '')); } catch (e) { return false; }
}

// 子资源判定：.js/.css/.html 结尾（含查询串）视为非媒体，常用于嗅探/代理过滤。
function isSub(str) {
    try { return SUBRESOURCE_REGEXP.test(String(str || '')); } catch (e) { return false; }
}

function size(num) {
    const value = Number(num);
    if (!isFinite(value) || value < 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let index = 0;
    let scaled = value;
    while (scaled >= 1024 && index < units.length - 1) { scaled /= 1024; index++; }
    return (index === 0 ? String(scaled) : scaled.toFixed(2)) + units[index];
}

function getSize(num) {
    return size(num);
}

function toFixed(num, digits) {
    const value = Number(num);
    if (!isFinite(value)) return String(num ?? '');
    return value.toFixed(Number(digits) || 0);
}

// 去除地址/标题尾部的扩展名（保留查询串语义由调用方处理，生态用法多为展示标题净化）。
function removeExt(str) {
    const text = String(str ?? '');
    try {
        const stripped = text.replace(/\.(html?|css|js|php|aspx|jsp)(\?.*)?$/i, (match, ext, query) => query || '');
        return stripped;
    } catch (e) { return text; }
}

function log(msg) {
    try {
        if (typeof msg === 'object') console.log(JSON.stringify(msg));
        else console.log(String(msg));
    } catch (e) { /* console 不可用则静默 */ }
}

function debug(msg) { log(msg); }

function headerOf(input) {
    const header = {};
    try {
        const headers = input && (input.headers || input.header) || {};
        const keys = ['ua', 'user-agent', 'User-Agent', 'referer', 'Referer'];
        const lower = {};
        for (const key of Object.keys(headers)) lower[String(key).toLowerCase()] = headers[key];
        if (lower['ua'] != null && !lower['user-agent']) lower['user-agent'] = lower['ua'];
        for (const key of keys) {
            const value = lower[key.toLowerCase()];
            if (value != null && String(value).length > 0 && String(value) !== 'null') {
                header[/^ref/i.test(key) ? 'Referer' : 'User-Agent'] = String(value);
            }
        }
    } catch (e) { /* 忽略非法 header */ }
    return header;
}

// 从播放数据中解析直链：接受字符串（JSON 或纯 URL）或对象
// （{url|data|playUrl|jx, headers|header:{ua,referer}}），返回
// { parse, url, header } 形态；解析失败回退 parse:1 + 原始页面地址。
function jsonParse(input) {
    const fallbackUrl = (input && (input.url || input.pageUrl)) || '';
    try {
        let obj = input;
        if (typeof obj === 'string') {
            const text = obj.trim();
            obj = text.startsWith('{') || text.startsWith('[') ? JSON.parse(text) : { url: text };
        }
        if (Array.isArray(obj)) obj = obj[0] || {};
        let playUrl = obj.url || obj.data || obj.playUrl || obj.play_url || '';
        if (typeof playUrl === 'object') playUrl = playUrl.url || '';
        playUrl = String(playUrl || '').trim();
        const header = headerOf(obj);
        if (!playUrl || !/^https?:/i.test(playUrl)) {
            return { parse: 1, url: fallbackUrl, header };
        }
        return { parse: 0, url: playUrl, header };
    } catch (e) {
        return { parse: 1, url: fallbackUrl, header: {} };
    }
}

export { isSub, getSize, removeExt, log, isVideoFormat, jsonParse, debug, size, toFixed };
