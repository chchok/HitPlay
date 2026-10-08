# tvbox-js-host/lib 兼容库

本目录文件为 TVBox/猫源（FongMi cat.js / drpy JS 格式）源脚本的运行时兼容库，
由 `scripts/fetch-tvbox-libs.sh` 以 sha256 锁定拉取入库，不做任何修改。

- 上游：TV-fongmi/quickjs（FongMi/TV，fongmi 分支）`quickjs/src/main/assets/js/lib`
- 许可：GPL-3.0（见 `LICENSE.fongmi`）
- 哈希基准：sha256 锁定，2026-10 校验

| 文件 | 作用 |
| --- | --- |
| cat.js | 猫源生态标准工具集（cheerio/dayjs/Crypto/Uri/jinja2/jp/lodash 聚合导出） |
| cheerio.min.js | HTML 解析（pdfa/pdfh/pd 选择器依赖） |
| crypto-js.js | 加解密工具集（源码内 `import { Crypto } from 'lib/cat.js'` 的底层实现之一） |
| gbk.js | GBK 编码转换（部分站点页面编码） |
| similarity.js | 标题相似度匹配（搜索去重/聚合） |
| net.js | req/http 请求适配层（依赖沙箱注入的 `_http` 全局；本地收录） |
| utils.js | isSub/getSize/removeExt/log/isVideoFormat/jsonParse 兼容层（生态该模块常以 CATOP4 QuickJS 字节码分发，此处为原生同语义实现） |

源脚本通过 `import … from 'lib/xxx.js'` 或 `assets://js/lib/xxx.js` 引用；
worker.js 的内置模块解析仅允许文件名（无路径分隔、必须 .js），无法越界读取。

公开套件不包含 `模板.js`：目前没有找到该上游文件明确的再分发许可。
依赖该文件的脚本需要由使用方自行提供获准分发的版本。
