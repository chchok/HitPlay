# 第三方组件声明（THIRD-PARTY NOTICES）

本套件包含以下第三方组件，按其原始许可分发：

## tvbox-js-host/lib/（TVBox/FongMi quickjs 兼容库）

| 文件 | 来源 | 说明 |
|---|---|---|
| `lib/cat.js` | FongMi/TV（quickjs 版 Spider 兼容库） | 源脚本 `require('lib/cat.js')` 的兼容面 |
| `lib/cheerio.min.js` | cheerio（browserified） | HTML 解析（pdfa/pdfh/pd 的实现基础） |
| `lib/crypto-js.js` | crypto-js | md5X/aesX/desX 等站点兼容原语 |
| `lib/gbk.js` | gbk 编码表 | GBK/GB2312 页面解码 |
| `lib/similarity.js` | 社区标题相似度库 | 搜索/匹配辅助 |

以下五个文件按 SHA-256 校验后原样分发（拉取脚本见上游仓库
`scripts/fetch-tvbox-libs.sh`）；原始许可文本随包附于
`Sources/HitPlayCatSource/tvbox-js-host/lib/LICENSE.fongmi`。

| 文件 | SHA-256 |
|---|---|
| `cat.js` | `49bcc6c6ade5fcbfce98875f51bafc010ebb015f7e8db2a9fc2e22a4575ac046` |
| `cheerio.min.js` | `10cf39856c496ed2c681c00b6a245b2306a119041591c35d1e31b6bf0a9e6901` |
| `crypto-js.js` | `e888d4276fa167121c6fca26dbc9821a8a79b66ae9b192e5a33c6a5bb2056e53` |
| `gbk.js` | `a002c29e9722e123f9ccea98e30d7207531e404f6b3351759a6b0bb4090f8f41` |
| `similarity.js` | `921218b6b6c6794714c284975ba9f87220c57b40fc4f4c78e21741dc96b747be` |

`模板.js` 未随公开包分发，因为当前上游仓库没有提供可核实的再分发许可。
本套件自有文件的 MIT 许可不覆盖 GPL-3.0 组件；各文件仍受其原始许可证约束。

## 运行时依赖（不随包分发，由使用环境提供）

- **Node.js（≥18）**：macOS 上以子进程方式运行 `cat-source-host.js` /
  `tvbox-js-host/*.js` 宿主。Node.js 及其依赖各自遵循其原始许可（MIT 系）。
- **Python 3（≥3.10）与 py 源标准依赖面**：requests / beautifulsoup4 / lxml /
  pyquery / pycryptodome / ujson / cachetools —— 运行 py 源的宿主
  `py-source-host.py` 会在缺少这些依赖时安装到应用私有目录；各包遵循其原始许可
  （BSD/MIT/Apache 系，pycryptodome 为 BSD-3）。

## 协议与生态致谢

本套件实现并兼容 TVBox / CatVodOpen / 猫源引擎包契约 / MacCMS 等社区开放协议与
包格式；这些协议与格式由其各自的社区项目定义，感谢其维护者。
