# HitPlay Source Kit —— 猫源 / py源 引擎套件

Swift 原生的 TVBox 生态源引擎：一套代码，跑通 **猫源引擎包、TVBox 配置（JSON/XML）、
TVBox 单文件 JS 源、drpy ESM、py 源（FongMi 契约）** 五类生态源型，
内置 **HLS 去广告**、**加密配置解密**、**原生 CMS 引擎（iOS/tvOS 免 Node）**、
**多源聚合搜索** 与完整的沙箱/限额/护栏体系。

> 本套件是 HitPlay 播放器的开源源引擎部分；HitPlay 的自研播放内核与媒体服务
> （Emby 等）为闭源组件，不包含在本仓库中。

运行时能力按平台划分：macOS 可使用 Node.js 和 Python 子进程；iOS/tvOS 的
TVBox CMS JSON/XML 由 Swift 原生引擎处理。iOS/tvOS 上的 JS 源需要集成方提供
兼容的 JavaScript 宿主；本套件不包含 Python 解释器，也不承诺移动端运行 py 源。

## 模块

| 模块 | 内容 |
|---|---|
| `HitPlayCatSource` | 猫源引擎核心：订阅/站点编排、引擎进程管理（Node 宿主族 + iOS 原生引擎）、猫源开放协议客户端、HLS 去广告、TVBox 配置解密、SSRF 准入、iCloud 备份 |
| `HitPlayPySource` | py源宿主契约：python3 启动计划、订阅目录解析、持久化/iCloud 模型 |
| `HitPlayKit` | 无依赖公共件（钥匙串令牌存取、URL 字符集） |
| 宿主脚本（模块资源） | `cat-source-host.js`（猫源引擎包宿主）、`tvbox-js-host/`（TVBox 配置/JS 源宿主 + vm 沙箱 worker）、`py-source-host.py`（py 宿主） |

## 快速上手

```swift
// Package.swift
.package(path: "HitPlaySourceKit")
// target 依赖
.product(name: "HitPlayCatSource", package: "HitPlaySourceKit"),
.product(name: "HitPlayPySource", package: "HitPlaySourceKit")
```

```swift
import HitPlayCatSource

let store = CatSourceStore()
// 1. 订阅源（支持 .js.md5 增量、TVBox 配置 JSON/加密配置、镜像竞速下载）
try await store.addSubscription(url: sourceURL)
// 2. 浏览 / 搜索 / 播放（协议客户端自动路由到对应引擎）
let home = try await store.loadHome()
let result = try await store.resolvePlay(detail: detail, episode: episode)
// result.url —— 已按开关完成 HLS 去广告包装；直接喂给任意播放器即可
```

宿主脚本作为**模块资源**随包分发，引擎按「模块资源优先、主包兜底」定位——
作为库集成时零配置；需要自带脚本时把同名资源放入你的 App bundle 即可覆盖。

环境要求：macOS 上运行 JS/py 源需要 `node`（≥18）与 `python3`（≥3.10）在 PATH；
iOS/tvOS 上纯 CMS 配置无需外部运行时。移动端 JS 源由集成方接入 nodejs-mobile
等宿主后方可运行；移动端 py 源不在本套件的运行范围内。

## 支持的源型

| 源型 | macOS（Node 子进程） | iOS/tvOS |
|---|---|---|
| 猫源引擎包（index.js + index.config.js + md5） | ✅ | ➖ 需集成 JavaScript 宿主 |
| TVBox 配置（type 0/1 CMS JSON + **MacCMS XML**） | ✅ | ✅ **原生引擎**（无 Node 依赖） |
| TVBox 配置内联 type 3 远程 JS 源 | ✅ worker 会话池 | ➖ 需 nodejs-mobile |
| TVBox 单文件 JS 源（`__jsEvalReturn` / drpy ESM / `__JS_SPIDER__`） | ✅ vm 沙箱 | ➖ 需集成 JavaScript 宿主 |
| 配置级 parses JSON 解析器 + flags 名单 | ✅ | ✅ 原生引擎 |
| py 源（`class Spider` 契约，单文件/zip/订阅目录） | ✅ python3 子进程 | ❌ |
| TVBox 加密配置（2423/2324/8位** AES） | ✅ 导入时解密 | ✅ |
| jar / csp_ spider | ❌ 明确报错 | ❌ |

公开包不含 drpy 模板文件 `模板.js`，因为其上游未提供可核实的再分发许可；
依赖该文件的源脚本需要由集成方自行提供获准分发的版本。

## 特色能力

- **HLS 去广告**：三重检测（SCTE/CUE/DATERANGE 标记区间、DISCONTINUITY 块级
  目录指纹、URL 词边界）+ 安全重建（sequence 重编号、AES-128 隐式 IV 合成）；
  capability URL 本地代理，**清理失败自动 302 回原地址**——增强失败等于直连，
  不会造成播放失败。开关：`UserDefaults hitplay.hlsAdClean`。
- **安全边界**：源码 = 用户主动安装的不可信输入。vm 沙箱（无 require/process
  泄漏 + 文件读取围栏）、订阅 SSRF 准入（仅公网 http/https）、下载限额
  （包 64MB / 指针 1MB）、输出护栏（大对象有界摘要 + 单行限幅）、会话超时
  （worker 30s）、进程三段退出 + PPID 守卫。
- **py 宿主生态兼容**：base.spider 契约注入、安卓/Java 桩、`|Header=` 尾注、
  9978/9999 遗留代理改写、`tab:id:` 文件夹、`searchContentPage` 优先、
  localProxy 全参数（请求头/Range/原始 body）、`PYTHON_DEPENDENCY` 错误区分。
- **聚合搜索**：双车道并发（快站 12 / 慢站 4）、90s 总时限、条数上限、
  渐进回调；多引擎结果还原到所属引擎，不会误走路由。
- **缓存体系**：目录 30s / 详情内存 LRU+磁盘 6h / 播放地址 10min（仅直连）/
  请求 single-flight 去重。

## 测试

```bash
swift test
```

覆盖：加密配置解密向量、JS 源三形态识别、真实 Node 宿主全链路冒烟
（config → home → detail → play，含 header 透传）、输出护栏与下载限额、
订阅镜像竞速、py 订阅安装闭环、HLS 去广告三重检测与重建、MacCMS XML、
播放归一化、解析判定矩阵、目录缓存。需要 `node`/`python3` 的用例在环境缺失时自动跳过。

## License

本套件自有代码按 MIT 许可分发（见 LICENSE）。第三方组件（tvbox-js-host/lib 兼容库等）按其原始许可分发，
见 THIRD-PARTY-NOTICES.md。

## 免责声明

本套件只提供源协议的解析与执行框架，不包含、不分发任何源内容或站点数据；
用户自行安装的源脚本的责任由其作者承担。请遵守所在地区的法律法规。

## 交流与反馈

欢迎加入 HitPlay Telegram 群组，交流使用体验、反馈问题与建议：
[加入 Telegram 群组](https://t.me/+JOriPW0sSdpiYTQ9)
