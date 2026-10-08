# HitPlay Source Kit · 猫源 / py源 引擎 —— 开源特色宣传

> 一套 Swift 原生的 TVBox 生态源引擎。把外部源的接入与执行做成有边界、有降级路径、
> 有测试覆盖的工程能力。套件自有代码采用 MIT 许可，第三方兼容组件按各自许可分发。

---

## 一句话定位

**五类生态源型，一套引擎**：猫源引擎包、TVBox 配置（JSON / MacCMS XML）、
TVBox 单文件 JS 源、drpy ESM、py 源（FongMi 契约）——统一收敛为猫源开放协议
（`/config` + `/spider/<key>/<ver>/<method>`），上层 UI 零适配。

平台能力有明确边界：macOS 可使用 Node.js 与 Python 子进程；iOS/tvOS 的 CMS
JSON/XML 由原生 Swift 引擎处理，JS 运行需要集成方提供 JavaScript 宿主，py 源
运行不属于本套件的移动端能力。

## 特色一：三运行时同构，iOS 也有原生引擎

- **macOS**：Node 宿主族（引擎包宿主 / TVBox 配置宿主 / 单文件 JS 源宿主）+
  python3 子进程，每订阅一进程、池化 LRU、热重载、三段优雅退出。
- **iOS / tvOS**：CMS 配置（JSON 与 XML）由内置原生 Swift 引擎处理；JS 源需要
  集成方接入 nodejs-mobile 等宿主。
- 猫源协议客户端统一对接不同宿主，降低上层接入差异。

## 特色二：HLS 去广告（行业内少有的完整开源实现）

针对采集源最常见的「切片里插广告」痛点，内置三重检测 + 安全重建：

1. **官方标记区间**：`#EXT-X-CUE-OUT/IN`、`#EXT-X-SCTE35`、`#EXT-X-DATERANGE`
   （要求 SCTE35-OUT 或广告词 CLASS；端点必须唯一对齐切片边界，多标记冲突全部弃剪）；
2. **结构启发式**：按 DISCONTINUITY 块 + URL 目录指纹——重复块、加密正片里的
   孤岛明文块、头尾插入（需同源强化证据）；
3. **URL 词边界**：`/ads/`、`/adbreak/`、`guanggao` 等路径特征（穿透代理包装检视，
   原地址逐字节保护）。

安全重建：`MEDIA-SEQUENCE` 重编号、AES-128 隐式 IV 按 HLS 规范合成、
DISCONTINUITY 补齐、master/直播/LL-HLS 一律跳过并给出原因。
清理经 capability URL 本地代理下发；无法应用清理的播放列表保留原始播放地址，
具体行为由检测结果和播放列表类型决定。

## 特色三：把安全当产品功能做

源码是「用户主动安装的不可信输入」，引擎按这个前提设计：

- **执行隔离**：JS 源跑在 vm 沙箱（无 require/process 泄漏、网络只经宿主白名单、
  文件读取目录围栏、30s 会话超时后 terminate）；py 源跑在独立进程（依赖白名单、
  安卓/Java 桩防 import 崩溃、PPID 守卫防孤儿进程）；
- **输入边界**：订阅地址 SSRF 准入（仅公网 http/https）、下载限额（包 64MB /
  指纹 1MB，Content-Length 预检 + 流式累计双保险）、响应体按操作限额；
- **输出边界**：护栏防止源码把数百 MB 的错误对象反复序列化拖垮宿主
  （大对象有界摘要 + 单行限幅，控制通道不受污染）；
- **加密配置兼容**：TVBox 生态 `2423 / 2324 / 8位**` 三种加密订阅线格式，
  导入时统一解密（并明确注明这是格式兼容而非安全机制）。

## 特色四：py 源生态兼容天花板

针对常见 Python Spider 契约提供兼容适配：

- `base.spider` 契约完整注入（fetch/pq/regStr/缓存/getProxyUrl/localProxy 全家桶）；
- 安卓/Java 桩：`import android.*` 的源在桌面端不崩（Toast/Handler/ExternalStorage
  全部落到可写目录）；
- 生态约定逐项兼容：`|Header=` 尾注拆分、9978/9999 遗留代理改写、`tab:id:` 文件夹
  折叠、`searchContentPage` 优先、空 header 字符串容错、`PYTHON_DEPENDENCY`
  与源逻辑错误区分报错。

## 特色五：为体验做的工程细节

- **双车道聚合搜索**：快站 12 并发、慢站（py/盘站）独立 4 并发、90s 总时限——
  快结果秒出，慢站后台补齐，渐进回调渲染；
- **缓存体系**：目录 30s、详情 LRU+磁盘 6h、播放地址 10min、请求 single-flight
  去重——二次浏览接近零延迟；
- **播放归一化**：嵌套 JSON 下钻、`[名,url,…]` 内联画质、`|Header=` 请求头注入、
  多线路/多字幕/多弹幕轨/ClearKey DRM 全识别；
- **配置级解析器**：TVBox `parses`（type 1/2 JSON 解析）+ `flags` 线路名单，
  双端同规则判定，嗅探兜底——网页播放页地址不再直连必败；
- **订阅增量**：`.js.md5` 指纹快路径 + 镜像竞速下载 + iCloud 备份恢复。

## 工程质量

- 当前导出包包含 57 项 macOS SwiftPM 测试：Node 子进程端到端冒烟（config → home → detail →
  play，含请求头透传）、加密配置确定性向量、去广告检测矩阵（含「宁可不剪不可
  误剪」反例）、XML 解析、沙箱与限额边界；
- 纯 SwiftPM 包，无第三方 Swift 依赖；宿主脚本随模块资源分发，集成零配置。

---

**仓库结构 / 快速上手 / 协议规范** 见 README 与 `docs/`。
**License**：MIT；第三方兼容库按其原始许可随附（见 THIRD-PARTY-NOTICES.md）。
本套件只提供源协议的解析与执行框架，不含任何源内容；请遵守所在地法律法规。
公开套件不分发未确认许可证的 drpy 模板文件；依赖该文件的脚本需由集成方自行提供获准版本。
