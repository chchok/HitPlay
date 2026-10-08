import Darwin
import Foundation
import HitPlayKit
import HitPlayPySource

private final class CatSourceLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrPrefix = ""
    private var stderrTail = ""
    private var didComplete = false

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let text = String(data: data, encoding: .utf8) ?? ""
        let prefixLimit = 1_200
        let tailLimit = 5_000
        if stderrPrefix.count < prefixLimit {
            stderrPrefix += String(text.prefix(prefixLimit - stderrPrefix.count))
        }
        stderrTail = String((stderrTail + text).suffix(tailLimit))
    }

    func stderrSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard stderrTail.count > stderrPrefix.count else { return stderrTail }
        return stderrPrefix + "\n…已省略中间诊断…\n" + stderrTail
    }

    func appendStdout(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        stdoutBuffer.append(data)
        var lines: [String] = []
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            lines.append(String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return lines
    }

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

// MARK: - DTO（CatVod 开放接口约定）

public struct CatSourceSite: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isSearchable: Bool
    /// 站点路由基址（如 /spider/douban/3），来自 /config 的 api 字段。
    public let apiPath: String

    /// Ecosystem convention for cloud-drive/search sites (for example 「盘」夸克).
    /// This is a source-provided label, not proof that the remote service is currently reachable.
    public var isCloudDriveSite: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("「盘」")
    }

    /// 纯网盘站点（用户自己的夸克/百度/UC/115 网盘内容页，如"我的夸克网盘"）。
    /// 与「盘」开头的影视聚合站（玩偶/木偶等搜索站）不同——那些不是用户的网盘。
    public var isPureCloudDriveSite: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("我的") { return true }
        if trimmed.contains("网盘") { return true }
        let lower = trimmed.lowercased()
        let pureDriveWords = ["夸克网盘", "百度网盘", "uc网盘", "115网盘", "天翼网盘", "阿里云盘", "移动云盘", "云盘页"]
        return pureDriveWords.contains { lower.contains($0) }
    }

    public init(id: String, name: String, isSearchable: Bool = true, apiPath: String = "") {
        self.id = id
        self.name = name
        self.isSearchable = isSearchable
        self.apiPath = apiPath
    }
}

public struct CatSourceFilterOption: Sendable, Equatable {
    public let name: String
    public let value: String
}

public struct CatSourceFilterGroup: Sendable, Equatable {
    public let key: String
    public let name: String
    public let initValue: String?
    public let options: [CatSourceFilterOption]
}

public struct CatSourceItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let posterURL: URL?
    public let remark: String
    public let categoryName: String?

    public init(id: String, name: String, posterURL: URL?, remark: String, categoryName: String?) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.remark = remark
        self.categoryName = categoryName
    }
}

public struct CatSourceCategory: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CatSourceEpisode: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    /// 线路名（vod_play_from 的分段）。
    public let flag: String
    /// 播放标识（vod_play_url 分段的 key）。
    public let playKey: String

    public init(id: String, name: String, flag: String, playKey: String) {
        self.id = id
        self.name = name
        self.flag = flag
        self.playKey = playKey
    }
}

public struct CatSourceDetail: Sendable, Equatable, Identifiable, Codable {
    public let detailID: String
    public var id: String { detailID }
    public let name: String
    public let overview: String
    public let posterURL: URL?
    public let flags: [String]
    public let episodes: [CatSourceEpisode]

    public init(detailID: String, name: String, overview: String, posterURL: URL?, flags: [String], episodes: [CatSourceEpisode]) {
        self.detailID = detailID
        self.name = name
        self.overview = overview
        self.posterURL = posterURL
        self.flags = flags
        self.episodes = episodes
    }
}

/// 多画质地址（play 返回的 url 成对数组 `[["标清", url], ["高清", url]]`）。
public struct CatSourceQualityURL: Sendable, Equatable, Identifiable {
    public let label: String
    public let url: URL
    public var id: String { label + "|" + url.absoluteString }
}

/// 源站直出的附件轨：外挂字幕 / 多路弹幕。
public struct CatSourceAttachment: Sendable, Equatable, Identifiable, Codable {
    public let name: String
    public let url: URL
    public var id: String { name + "|" + url.absoluteString }
}

public struct CatSourcePlayResult: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let isParseRequired: Bool
    public var danmakuURL: URL?
    /// 多画质候选（含主地址）；空数组 = 源站只给了单地址。
    public var qualityURLs: [CatSourceQualityURL]
    /// 源站直出的外挂字幕轨。
    public var subtitles: [CatSourceAttachment]
    /// 源站提供的多路弹幕轨（单轨时与 danmakuURL 相同）。
    public var danmakuChoices: [CatSourceAttachment]
    /// ClearKey DRM（tvbox 约定 drmType=clearkey + drmKey/drmKid，mpv 侧走 cenc 解密）。
    public var drmClearKey: String?
    public var drmKid: String?

    public init(
        url: URL,
        headers: [String: String],
        isParseRequired: Bool,
        danmakuURL: URL? = nil,
        qualityURLs: [CatSourceQualityURL] = [],
        subtitles: [CatSourceAttachment] = [],
        danmakuChoices: [CatSourceAttachment] = [],
        drmClearKey: String? = nil,
        drmKid: String? = nil
    ) {
        self.url = url
        self.headers = headers
        self.isParseRequired = isParseRequired
        self.danmakuURL = danmakuURL
        self.qualityURLs = qualityURLs
        self.subtitles = subtitles
        self.danmakuChoices = danmakuChoices
        self.drmClearKey = drmClearKey
        self.drmKid = drmKid
    }

    /// 返回替换主地址的副本（HLS 去广告代理包装用；其余字段原样保留）。
    public func withURL(_ newURL: URL) -> CatSourcePlayResult {
        CatSourcePlayResult(
            url: newURL,
            headers: headers,
            isParseRequired: isParseRequired,
            danmakuURL: danmakuURL,
            qualityURLs: qualityURLs,
            subtitles: subtitles,
            danmakuChoices: danmakuChoices,
            drmClearKey: drmClearKey,
            drmKid: drmKid
        )
    }
}

public enum CatSourceError: LocalizedError, Sendable {
    case engineNotRunning
    case badResponse(String)
    case http(Int)
    case noPlayableURL

    public var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "引擎未运行"
        case .badResponse(let detail): return "订阅返回异常：\(detail)"
        case .http(let status): return "订阅返回异常：HTTP \(status)"
        case .noPlayableURL: return "该集未返回可播放地址"
        }
    }
}

// MARK: - Runtime（Node 子进程宿主）

/// Spawns the cat-source host (Node) for one package, waits for the content
/// port to appear on stdout, and proxies requests to it.
@MainActor
public final class CatSourceEngineRuntime: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: Int?
    @Published public private(set) var lastError: String?
    /// 猫源引擎 toast（/msg action=toast，经 stderr 的 [cat-msg] 行解析；C1-5）。
    @Published public private(set) var lastToastMessage: String?
    /// 引擎消息回调（toast 等）；在创建引擎后由宿主（CatSourceStore）接线。
    public var onToast: ((String) -> Void)?
    /// 引擎 /msg 全量消息（`{action, opt}` 结构）：
    /// toast 之外的 action（openInternalWebview / danmuPush / push / saveProfile…）
    /// 由宿主按需接线；runtime 只做解析与转发。
    public var onEngineMessage: (([String: Any]) -> Void)?

    private var pendingCatMsgBuffer = Data()

    #if os(macOS)
    private var process: Process?
    #endif
    private var packageDir: URL?
    private let nodeExecutable: URL
    private let pythonExecutable: URL

    public init(nodeExecutable: URL? = nil, pythonExecutable: URL? = nil) {
        self.nodeExecutable = nodeExecutable ?? Self.locateExecutable(named: "node") ?? URL(fileURLWithPath: "/opt/homebrew/bin/node")
        self.pythonExecutable = pythonExecutable ?? Self.locateExecutable(named: "python3") ?? URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    }

    private static func locateExecutable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 每份应用安装一个稳定实例键（重启复用同一 db，多 App/多实例互不干扰）。
    /// iOS nodejs-mobile 运行时复用同一实例键（包内 JsonDB 隔离口径一致）。
    public static func stableInstanceKeyForNodeMobile() -> String { stableInstanceKey() }

    private static func stableInstanceKey() -> String {
        let key = "hitplay.engine.instance"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// 宿主脚本定位：类所在束 → App 主包 → 源码树回退（源码分发的 SwiftPM
    /// 套件形态：脚本就在本模块源目录内，App 形态则走前两级 Bundle）。
    private static func locateHostScript(named name: String, extension ext: String) -> URL? {
        Bundle(for: Self.self).url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
            ?? locateInSourceTree("\(name).\(ext)")
    }

    /// 从当前源文件位置向上查找相对路径（源码分发形态专用；App 构建时前两级
    /// Bundle 命中，不会走到这里）。
    nonisolated static func locateInSourceTree(_ relativePath: String) -> URL? {
        var directory = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// tvbox-js-host 运行时文件名（平铺资源；lib 兼容库见 tvboxLibFileNames）。
    nonisolated private static let tvboxRuntimeFileNames = ["host.js", "worker.js", "network.js", "io_worker.js", "runtime.js", "cms-host.js"]
    nonisolated private static let tvboxLibFileNames = ["cat.js", "cheerio.min.js", "crypto-js.js", "gbk.js", "similarity.js"]

    nonisolated private static func locateTVBoxRuntimeFile(_ name: String, in libSubdirectory: Bool) -> URL? {
        let bundle = Bundle(for: Self.self)
        var bases = [bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
        // 源码树回退：套件源码分发的模块源目录（与 cat-source-host.js 同级，
        // tvbox-js-host/ 为其子目录——与下方候选路径约定一致）。
        if let sourceBase = locateInSourceTree("cat-source-host.js")?.deletingLastPathComponent() {
            bases.append(sourceBase)
        }
        for base in bases {
            var candidates: [URL] = []
            if libSubdirectory {
                candidates = [
                    base.appendingPathComponent("tvbox-js-host/lib/\(name)"),
                    base.appendingPathComponent("lib/\(name)"),
                    base.appendingPathComponent(name),
                ]
            } else {
                candidates = [
                    base.appendingPathComponent("tvbox-js-host/\(name)"),
                    base.appendingPathComponent(name),
                ]
            }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 把平铺的 tvbox 运行时资源物化成 worker.js 需要的目录结构
    /// （<destination>/tvbox-js-host/{host,worker,network,io_worker}.js + lib/*.js）。
    /// 幂等：目标文件已存在且大小一致时跳过拷贝。返回 host.js 所在目录。
    /// （nonisolated：引擎启动与测试物化共用，不依赖 MainActor 状态。）
    nonisolated public static func materializeTVBoxRuntime(destination: URL) -> URL? {
        let fm = FileManager.default
        let runtimeDir = destination.appendingPathComponent("tvbox-js-host", isDirectory: true)
        let libDir = runtimeDir.appendingPathComponent("lib", isDirectory: true)
        do {
            try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
            for name in tvboxRuntimeFileNames {
                guard let source = locateTVBoxRuntimeFile(name, in: false) else { return nil }
                let target = runtimeDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path)
                    || (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int) != (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) {
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: source, to: target)
                }
            }
            for name in tvboxLibFileNames {
                guard let source = locateTVBoxRuntimeFile(name, in: true) else { return nil }
                let target = libDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path)
                    || (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int) != (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) {
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: source, to: target)
                }
            }
            return runtimeDir
        } catch {
            return nil
        }
    }

    public var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// 包自带配置页面（标准路由 /website）。
    public var websiteURL: URL? {
        baseURL?.appendingPathComponent("website")
    }

    /// Starts (or restarts) the host for a package directory.
    /// js 引擎包（index.js）用 node + cat-source-host.js；TVBox 配置（config.json）
    /// 用 node + tvbox-js-host/cms-host.js（CMS 直连 + 内联 type 3 JS 源）；py 包
    /// （*.py）用 python3 + py-source-host.py；单文件 TVBox JS 源（*.js 无 index.js）
    /// 用 node + tvbox-js-host/host.js（ESM 沙箱运行时）。
    public func start(packageDir: URL, pythonExtend: String? = nil) async throws {
        #if os(macOS)
        try await startNodeProcess(packageDir: packageDir, pythonExtend: pythonExtend)
        #else
        lastError = "JS/py 引擎需要 Node/Python 运行时，iOS/tvOS 版暂不支持；请使用 TVBox 配置源（type 0/1 CMS 直连站）"
        throw CatSourceError.badResponse(lastError!)
        #endif
    }

    #if os(macOS)
    /// Node 子进程启动（仅 macOS）：拉起 cat-source-host.js / py-source-host.py。
    private func startNodeProcess(packageDir: URL, pythonExtend: String?) async throws {
        stop()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: packageDir.path)) ?? []
        let hasJS = files.contains("index.js")
        let hasPY = files.contains { $0.hasSuffix(".py") }
        let hasSingleFileJS = files.contains { $0.hasSuffix(".js") && $0 != "index.js" && !$0.hasSuffix(".js.md5") }
        let hasTVBoxConfig = files.contains("config.json")
        let hostScript: URL
        let executable: URL
        // TVBox JS 源运行时需要 --experimental-vm-modules（vm.SourceTextModule）；
        // cms 宿主自身不需要（沙箱只在 worker 进程里，execArgv 由 runtime.js 注入）。
        var nodeArgumentsPrefix: [String] = []
        var environment: [String: String] = ["HITPLAY_HOST_PORT": "0"]
        if hasJS {
            guard let script = Self.locateHostScript(named: "cat-source-host", extension: "js") else {
                lastError = "缺少宿主脚本 cat-source-host.js"
                throw CatSourceError.engineNotRunning
            }
            guard FileManager.default.fileExists(atPath: nodeExecutable.path) else {
                lastError = "未找到 Node 运行时（\(nodeExecutable.path)）"
                throw CatSourceError.engineNotRunning
            }
            hostScript = script
            executable = nodeExecutable
        } else if hasTVBoxConfig || hasSingleFileJS {
            guard FileManager.default.fileExists(atPath: nodeExecutable.path) else {
                lastError = "未找到 Node 运行时（\(nodeExecutable.path)）"
                throw CatSourceError.engineNotRunning
            }
            // 平铺资源物化出 lib/ 结构到包内 cache/（同时充当运行时 local 存储根）。
            let cacheDir = packageDir.appendingPathComponent("cache", isDirectory: true)
            guard let runtimeDir = Self.materializeTVBoxRuntime(destination: cacheDir) else {
                lastError = "运行时资源不完整（缺少必要组件）"
                throw CatSourceError.engineNotRunning
            }
            hostScript = runtimeDir.appendingPathComponent(hasTVBoxConfig ? "cms-host.js" : "host.js")
            executable = nodeExecutable
            nodeArgumentsPrefix = ["--experimental-vm-modules"]
            environment["HITPLAY_JS_CACHE_DIR"] = cacheDir.path
        } else if hasPY {
            switch PySourceHost.launchPlan(pythonExecutable: pythonExecutable, extend: pythonExtend) {
            case let .success(plan):
                hostScript = plan.script
                executable = plan.executable
                for (key, value) in plan.environment {
                    environment[key] = value
                }
            case let .failure(error):
                lastError = error.message
                throw CatSourceError.engineNotRunning
            }
        } else {
            lastError = "包内缺少 index.js 或 .py 源文件"
            throw CatSourceError.badResponse(lastError ?? "包无效")
        }
        self.packageDir = packageDir

        let process = Process()
        process.executableURL = executable
        process.arguments = nodeArgumentsPrefix + [hostScript.path, packageDir.path]
        // 包内 JsonDB（ABC.db.json）按「包目录 + 本应用实例」隔离，
        // 避免同包多进程（并行 App/多订阅切换）争抢文件锁；NODE_PATH 同时是包内 db 路径变量。
        let instanceKey = Self.stableInstanceKey()
        let dbDir = packageDir.appendingPathComponent("db-\(instanceKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        environment["NODE_PATH"] = dbDir.path
        process.environment = environment
        process.currentDirectoryURL = dbDir
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                self.isRunning = false
                self.port = nil
                if let pending = self.reloadContinuation {
                    self.reloadContinuation = nil
                    pending.resume(throwing: CatSourceError.engineNotRunning)
                }
            }
        }
        self.process = process
        try process.run()
        isRunning = true

        // Read stdout via readabilityHandler looking for HITPLAY_PORT=<n>.
        let launchedPort: Int
        do {
            launchedPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let handle = stdout.fileHandleForReading
            let launchState = CatSourceLaunchState()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { errHandle in
                let chunk = errHandle.availableData
                if chunk.isEmpty { errHandle.readabilityHandler = nil; return }
                launchState.appendStderr(chunk)
            }
            let timeoutItem = DispatchWorkItem {
                guard launchState.claimCompletion() else { return }
                handle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(throwing: CatSourceError.badResponse("引擎启动超时：\(launchState.stderrSummary())"))
            }
            // 重包（如神秘猫源 48 站点 + 弹幕服务）冷启动可达 30s 以上
            // First PY-source launch may provision the supported FongMi Python
            // dependency set into the app-private support directory.
            DispatchQueue.global().asyncAfter(deadline: .now() + (hasPY ? 240 : 40), execute: timeoutItem)
            handle.readabilityHandler = { readHandle in
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    readHandle.readabilityHandler = nil
                    if launchState.claimCompletion() {
                        timeoutItem.cancel()
                        // 引擎提前退出：带上 stderr 摘要（如「配置中没有可支持的站点」），
                        // 让用户看到真实原因而非笼统的「引擎未运行」。
                        let summary = launchState.stderrSummary().trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: summary.isEmpty
                            ? CatSourceError.engineNotRunning
                            : CatSourceError.badResponse("引擎提前退出：\(summary)"))
                    }
                    return
                }
                for line in launchState.appendStdout(chunk) {
                    if line.hasPrefix("HITPLAY_PORT="),
                       let value = Int(line.dropFirst("HITPLAY_PORT=".count)) {
                        guard launchState.claimCompletion() else { return }
                        timeoutItem.cancel()
                        // 启动完成后 stdout 转为常驻监听：热重载时源包会重新监听端口
                        // （HITPLAY_PORT=n 更新）并回报完成标记（HITPLAY_RELOADED=0/1）。
                        readHandle.readabilityHandler = { [weak self] outHandle in
                            let chunk = outHandle.availableData
                            guard !chunk.isEmpty else {
                                outHandle.readabilityHandler = nil
                                return
                            }
                            Task { @MainActor [weak self] in self?.consumeEngineStdout(chunk) }
                        }
                        // 启动完成后 stderr 转为常驻监听：解析 [cat-msg] JSON 行
                        // （messageToDart 通道，toast 等 action）供 UI 呈现。
                        stderrHandle.readabilityHandler = { [weak self] msgHandle in
                            let chunk = msgHandle.availableData
                            guard !chunk.isEmpty else {
                                msgHandle.readabilityHandler = nil
                                return
                            }
                            Task { @MainActor [weak self] in self?.consumeCatMessageChunk(chunk) }
                        }
                        continuation.resume(returning: value)
                        return
                    }
                    if line.contains("源包加载失败") || line.contains("缺少源包") {
                        Task { @MainActor in self.lastError = String(line.prefix(200)) }
                    }
                }
            }
            }
        } catch {
            // A timed-out source may still be running a long startup task. Stop it
            // before returning so it cannot occupy a port during the next attempt.
            let diagnostic = error.localizedDescription
            if self.process === process {
                stop()
                lastError = diagnostic
            } else if process.isRunning {
                process.terminate()
            }
            throw error
        }
        guard self.process === process else {
            throw CancellationError()
        }
        port = launchedPort
        lastError = nil
        guard port != nil else {
            throw lastError.map { CatSourceError.badResponse($0) } ?? CatSourceError.engineNotRunning
        }
        // Health probe: /config must answer.
        _ = try await client().config()
        guard self.process === process else {
            throw CancellationError()
        }
    }

    #endif

    /// 聚合搜索/详情专用会话：对本地引擎放开单主机并发连接（.shared 默认 6 条/主机），
    /// 12 路并发搜索一波全发，首屏结果不被连接池排队拖慢。
    private lazy var engineSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Fresh client bound to the current engine port.
    public func client() -> CatSourceClient {
        CatSourceClient(baseURL: baseURL ?? URL(string: "http://127.0.0.1:0")!, session: engineSession)
    }

    public func stop() {
        #if os(macOS)
        pendingStdoutBuffer.removeAll()
        if let pending = reloadContinuation {
            reloadContinuation = nil
            pending.resume(throwing: CatSourceError.engineNotRunning)
        }
        guard let process, process.isRunning else {
            process = nil
            isRunning = false
            return
        }
        // Graceful: host exits on stdin EOF.
        if let stdin = process.standardInput as? Pipe {
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit(withTimeout: 3)
        if process.isRunning {
            // 三段升级：stdin EOF → SIGTERM → SIGKILL。
            // 宿主拦截了源包的 process.exit，但源码仍可能覆盖 SIGTERM 处理器拒绝退出，
            // 最终手段必须保证端口释放（否则残留进程会占住引擎端口）。
            process.terminate()
            process.waitUntilExit(withTimeout: 2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
        isRunning = false
        port = nil
        #endif
    }

    // MARK: 引擎消息（[cat-msg] 行解析）

    /// 行缓冲解析引擎 stderr：`[cat-msg] {"action":"toast",...}` → onToast/lastToastMessage。
    /// 其余 action（getPlayInfo/saveProfile 等）由宿主脚本应答，这里只透传 toast。
    private func consumeCatMessageChunk(_ chunk: Data) {
        pendingCatMsgBuffer.append(chunk)
        while let newline = pendingCatMsgBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingCatMsgBuffer[..<newline]
            pendingCatMsgBuffer.removeSubrange(pendingCatMsgBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  line.hasPrefix("[cat-msg] ") else { continue }
            let payload = line.dropFirst("[cat-msg] ".count)
            guard let data = payload.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 全量分发（push/openInternalWebview/danmuPush 等由宿主接线处理）。
            onEngineMessage?(message)
            guard (message["action"] as? String) == "toast" else { continue }
            // 消息结构 {action:"toast", opt:{message,duration}}；兼容平铺形态。
            let opt = message["opt"] as? [String: Any]
            let text = (opt?["message"] as? String)
                ?? (message["message"] as? String)
                ?? (message["text"] as? String)
                ?? (message["data"] as? String)
                ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lastToastMessage = trimmed
            onToast?(trimmed)
        }
    }

    /// 热重载等待句柄（C2-5）：收到 HITPLAY_RELOADED 行即完成/失败。
    private var reloadContinuation: CheckedContinuation<Void, Error>?
    private var pendingStdoutBuffer = Data()

    /// 常驻解析引擎 stdout：HITPLAY_PORT 更新（热重载后端口可能变化）与
    /// HITPLAY_RELOADED 完成标记。
    private func consumeEngineStdout(_ chunk: Data) {
        pendingStdoutBuffer.append(chunk)
        while let newline = pendingStdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingStdoutBuffer[..<newline]
            pendingStdoutBuffer.removeSubrange(pendingStdoutBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if line.hasPrefix("HITPLAY_PORT="), let value = Int(line.dropFirst("HITPLAY_PORT=".count)) {
                if port != value {
                    port = value
                }
            }
            if line.hasPrefix("HITPLAY_RELOADED=1") {
                reloadContinuation?.resume()
                reloadContinuation = nil
            } else if line.hasPrefix("HITPLAY_RELOADED=0") {
                reloadContinuation?.resume(throwing: CatSourceError.badResponse("源包热重载失败，需全量重启"))
                reloadContinuation = nil
            }
        }
    }

    /// 热重载当前源包（C2-5）：stdin 发送 reload，宿主 stop 旧实例 → 清缓存 →
    /// 重新 require → start，随后回报端口与完成标记。进程不重启，Node 冷启动为零。
    /// （仅 macOS Node 宿主；iOS/tvOS 原生引擎无此通道。）
    #if os(macOS)
    public func reload() async throws {
        guard let process, process.isRunning else { throw CatSourceError.engineNotRunning }
        pendingStdoutBuffer.removeAll()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reloadContinuation?.resume(throwing: CatSourceError.badResponse("已有热重载进行中"))
            reloadContinuation = continuation
            if let stdin = process.standardInput as? Pipe {
                try? stdin.fileHandleForWriting.write(contentsOf: Data("reload\n".utf8))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let pending = self.reloadContinuation else { return }
                    self.reloadContinuation = nil
                    pending.resume(throwing: CatSourceError.badResponse("热重载超时（90s），请改用停止后重启"))
                }
            }
        }
    }
    #endif
}

// MARK: - API 客户端（真实猫源协议：GET /config + POST {api}/init|home|category|detail|search|play）

/// /config 返回的分类容器：video（影视站源）/ read / comic / music / pan。
public struct CatSourceClient {
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public struct SiteConfig: Sendable {
        public let sites: [CatSourceSite]
    }

    /// 站点列表：跳过纯功能站点（「设」配置、版本号）。
    public func config() async throws -> SiteConfig {
        struct Payload: Decodable {
            struct Group: Decodable {
                struct Site: Decodable {
                    let key: String?
                    let name: String?
                    let type: Int?
                    let api: String?
                    let searchable: Int?
                }
                let sites: [Site]?
            }
            let video: Group?
        }
        let payload: Payload = try await get("config")
        let sites = (payload.video?.sites ?? []).compactMap { site -> CatSourceSite? in
            guard let key = site.key, let name = site.name, !name.isEmpty, !key.hasSuffix("_version") else { return nil }
            if name.hasPrefix("「设」") { return nil }
            let type = site.type ?? 0
            let apiPath = site.api?.isEmpty == false ? site.api! : "/spider/\(key)/\(type)"
            return CatSourceSite(id: key, name: name, isSearchable: (site.searchable ?? 1) == 1, apiPath: apiPath)
        }
        return SiteConfig(sites: sites)
    }

    // MARK: UZ 协议回退

    /// 从 /spider/<key>/<type> 形态的 apiPath 提取 UZ 模块名（裸 key）。
    nonisolated static func uzModule(from apiPath: String) -> String? {
        let parts = apiPath.split(separator: "/").map(String.init)
        // /spider/<key>/<type>
        guard parts.count >= 3, parts[0] == "spider" else { return nil }
        return parts[1]
    }

    /// UZ 查询协议请求：GET /api/<module>?<query>。
    /// 新代引擎（如豆包 2026-10 版）把 spider 服务拆分后，主服务以 UZ 查询协议
    /// 暴露能力，响应与猫源开放协议同形（class/list/vod_* 字段）。
    private func uzGet(apiPath: String, query: [String: String], timeout: TimeInterval = 30) async throws -> Data {
        guard let module = Self.uzModule(from: apiPath) else {
            throw CatSourceError.badResponse("无法推导 UZ 模块名：\(apiPath)")
        }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api").appendingPathComponent(module), resolvingAgainstBaseURL: false) else {
            throw CatSourceError.engineNotRunning
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw CatSourceError.engineNotRunning }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatSourceError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    /// 主通道（猫源开放协议）失败且状态码可回退时，尝试 UZ 协议；两边都失败抛原始错误。
    private func withUZFallback(apiPath: String, query: [String: String], timeout: TimeInterval = 30, primary: () async throws -> Data) async throws -> Data {
        do {
            return try await primary()
        } catch {
            // Only a missing/unsupported route indicates a different protocol.
            // Retrying timeouts, cancellation, authentication or rate limits adds
            // another full wait without fixing the cause.
            let primaryError = error
            guard case CatSourceError.http(let status) = error,
                  [404, 405, 501].contains(status),
                  Self.uzModule(from: apiPath) != nil else { throw error }
            try Task.checkCancellation()
            do {
                let data = try await uzGet(apiPath: apiPath, query: query, timeout: timeout)
                return data
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                throw primaryError
            }
        }
    }

    /// Probes the source-provided engine configuration page without returning its body.
    /// The caller can distinguish a missing /website route from an unavailable engine.
    public func probeWebsite() async throws -> Int {
        let url = baseURL.appendingPathComponent("website")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatSourceError.badResponse("配置页没有返回 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CatSourceError.badResponse("配置页 HTTP \(http.statusCode)")
        }
        return http.statusCode
    }

    /// 初始化站点（幂等；失败不阻塞浏览）。
    public func initSite(apiPath: String) async {
        _ = try? await post(apiPath + "/init", body: [:])
    }

    /// 诊断专用初始化：保留错误，让调用方能够区分站点初始化失败与后续接口失败。
    public func initializeSiteForDiagnostics(apiPath: String) async throws {
        _ = try await post(apiPath + "/init", body: [:])
    }

    public struct HomeResult: Sendable {
        public let categories: [CatSourceCategory]
        public let items: [CatSourceItem]
        /// 分类筛选组（按 type_id 索引），供筛选 UI 使用。
        public let filters: [String: [CatSourceFilterGroup]]
    }

    public func home(apiPath: String) async throws -> HomeResult {
        // 目录只读缓存（目录缓存 语义对齐：TTL 30s / LRU 100 条）：
        // 站点切换与返回浏览时避免重复回源；搜索/详情/播放不受影响。
        let cacheKey = Self.catalogCacheKey(baseURL: baseURL, apiPath: apiPath, kind: "home", extra: nil)
        if let cached = Self.cachedCatalogData(forKey: cacheKey) {
            return try decodeHome(cached)
        }
        let data = try await withUZFallback(apiPath: apiPath, query: ["filter": "1"]) {
            try await post(apiPath + "/home", body: [:])
        }
        Self.storeCatalogData(data, forKey: cacheKey)
        return try decodeHome(data)
    }

    public func category(apiPath: String, categoryID: String, page: Int, filters: [String: String] = [:]) async throws -> [CatSourceItem] {
        let filtersJSON = filters.isEmpty ? "" : (try? String(data: JSONSerialization.data(withJSONObject: filters), encoding: .utf8)) ?? ""
        var query = ["t": categoryID, "page": String(page)]
        if !filtersJSON.isEmpty { query["ext"] = filtersJSON }
        let cacheKey = Self.catalogCacheKey(baseURL: baseURL, apiPath: apiPath, kind: "category", extra: query)
        if let cached = Self.cachedCatalogData(forKey: cacheKey) {
            return try decodeList(cached)
        }
        let data = try await withUZFallback(apiPath: apiPath, query: query) {
            try await post(apiPath + "/category", body: ["id": categoryID, "page": page, "filters": filters.isEmpty ? [String: String]() : filters])
        }
        Self.storeCatalogData(data, forKey: cacheKey)
        return try decodeList(data)
    }

    public func search(apiPath: String, keyword: String, page: Int = 1, timeout: TimeInterval = 30) async throws -> [CatSourceItem] {
        let data = try await withUZFallback(apiPath: apiPath, query: ["wd": keyword, "pg": String(page), "quick": "0"], timeout: timeout) {
            try await post(apiPath + "/search", body: ["wd": keyword, "page": page], timeout: timeout)
        }
        return try decodeList(data)
    }

    public func detail(apiPath: String, itemID: String) async throws -> CatSourceDetail {
        struct Payload: Decodable {
            struct Item: Decodable {
                let vod_id: String?
                let vod_name: String?
                let vod_content: String?
                let vod_pic: String?
                let vod_play_from: String?
                let vod_play_url: String?
            }
            let list: [Item]?
        }
        // 详情是点击卡片的阻塞路径：12s 上限，超时快速降级到聚合搜索。
        let data = try await withUZFallback(apiPath: apiPath, query: ["ac": "detail", "ids": itemID], timeout: 12) {
            try await post(apiPath + "/detail", body: ["id": itemID], timeout: 12)
        }
        let payload = try decode(Payload.self, from: data)
        guard let entry = payload.list?.first else {
            throw CatSourceError.badResponse("详情为空")
        }
        let flags = (entry.vod_play_from ?? "")
            .split(separator: "$", omittingEmptySubsequences: true)
            .map(String.init)
        // vod_play_url: "线路1$集名1#集名2$$$线路2$集名1#..." — 按线路分组。
        var episodes: [CatSourceEpisode] = []
        let blocks = (entry.vod_play_url ?? "").components(separatedBy: "$$$")
        for (index, block) in blocks.enumerated() {
            let flag = index < flags.count ? flags[index] : "线路\(index + 1)"
            for piece in block.components(separatedBy: "#") {
                let parts = piece.components(separatedBy: "$")
                guard parts.count >= 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let key = parts[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !key.isEmpty else { continue }
                // 盘站把整个文件夹作为单集：名字直接是 ID/GUID，展示为「播放」。
                let isRawKey = name == key
                    || name.range(of: "^[0-9a-fA-F]{12,}$", options: .regularExpression) != nil
                episodes.append(CatSourceEpisode(id: "\(flag)|\(key)", name: isRawKey ? "播放" : name, flag: flag, playKey: key))
            }
        }
        // 盘站的文件夹条目没有海报：vod_pic 是小文件夹图标，拉伸会糊满详情页。
        let isFolderEntry = (entry.vod_id ?? itemID).hasPrefix("folder@@@")
        return CatSourceDetail(
            detailID: entry.vod_id ?? itemID,
            name: entry.vod_name ?? "",
            overview: (entry.vod_content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
            posterURL: isFolderEntry ? nil : entry.vod_pic.flatMap(URL.init(string:)),
            flags: flags,
            episodes: episodes
        )
    }

    public func play(apiPath: String, flag: String, playKey: String) async throws -> CatSourcePlayResult {
        let data = try await withUZFallback(apiPath: apiPath, query: ["play": playKey, "flag": flag]) {
            try await post(apiPath + "/play", body: ["id": playKey, "flag": flag])
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CatSourceError.badResponse("播放响应不是有效 JSON")
        }
        var payload = Self.drillPlayPayload(root) as? [String: Any]
        if payload == nil {
            // 数组根（数组分支）：全字符串/数组 → 包成 url 字段；
            // 全带地址字段的对象数组 → 包成 list。
            let drilled = Self.drillPlayPayload(root)
            if let array = drilled as? [Any], !array.isEmpty {
                if array.allSatisfy({ $0 is String }) || array.allSatisfy({ $0 is [Any] }) {
                    payload = ["url": array]
                } else if let dicts = drilled as? [[String: Any]], dicts.allSatisfy(Self.hasPlayURLField) {
                    payload = ["list": dicts]
                } else if let first = array.first as? [String: Any] {
                    payload = first
                }
            }
        }
        guard let payload else {
            throw CatSourceError.badResponse("播放响应格式无效")
        }
        // Source implementations vary: some return `url` directly, others
        // return a `list` of entries; `url` may be a string, [url],
        // a [label, url, label, url] inline-pair array, or [[label, url]]
        // quality pairs (tvbox playResult convention).
        // Read only the fields needed for playback so unrelated extension
        // fields cannot make a valid stream fail strict Codable decoding.
        let entry = (payload["list"] as? [[String: Any]])?.first ?? payload
        var qualityURLs: [CatSourceQualityURL] = []
        var urlCandidates: [String] = []
        switch entry["url"] {
        case let value as String:
            urlCandidates = [value]
        case let values as [String]:
            if Self.looksLikeInlinePairs(values) {
                // [名, url, 名2, url2] 形态（兼容多形态返回）。
                for index in stride(from: 0, to: values.count - 1, by: 2) {
                    if let url = sanitizedURL(values[index + 1]) {
                        qualityURLs.append(CatSourceQualityURL(label: values[index], url: url))
                    }
                }
                urlCandidates = stride(from: 1, to: values.count, by: 2).map { values[$0] }
            } else {
                urlCandidates = values
            }
        case let pairs as [[String]]:
            // 成对数组：[label, url]——tvbox 多画质约定。
            for pair in pairs where pair.count >= 2 {
                if let url = sanitizedURL(pair[1]) {
                    qualityURLs.append(CatSourceQualityURL(label: pair[0], url: url))
                }
            }
            urlCandidates = pairs.compactMap { $0.count >= 2 ? $0[1] : nil }
        case let pairs as [[Any]]:
            for pair in pairs where pair.count >= 2 {
                guard let label = pair[0] as? String, let raw = pair[1] as? String,
                      let url = sanitizedURL(raw) else { continue }
                qualityURLs.append(CatSourceQualityURL(label: label, url: url))
            }
            urlCandidates = pairs.compactMap { $0.count >= 2 ? $0[1] as? String : nil }
        default:
            break
        }
        // 主地址沿用既有选择规则：数组时取最后一个带 scheme 的（多为最高画质直链）。
        guard let raw = urlCandidates.reversed().first(where: { sanitizedURL($0) != nil }) else {
            throw CatSourceError.noPlayableURL
        }
        // TVBox/py 生态 `url|Header=k=v&k2=v2` 尾注（TVBox 生态尾注约定）：
        // 必须在百分号编码之前拆（sanitizedURL 会把 | 编码掉）；仅当尾段能解析出
        // 非空键值对时才拆，避免误伤含 | 的正常地址。
        var urlString = raw
        let inlineHeaders = Self.splitInlineHeaders(&urlString)
        guard let url = sanitizedURL(urlString) else { throw CatSourceError.noPlayableURL }
        // 成对数组里若没有主地址本身，补一条避免画质切换丢当前源。
        if !qualityURLs.isEmpty, !qualityURLs.contains(where: { $0.url.absoluteString == urlString }) {
            qualityURLs.append(CatSourceQualityURL(label: "默认", url: url))
        }
        var headers: [String: String] = [:]
        var headerSource = entry["headers"] as? [String: Any]
        if headerSource == nil, let headerString = entry["header"] as? String,
           let headerData = headerString.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] {
            headerSource = decoded
        }
        // TVBox 约定 header 也常以字典形态返回（header: {"User-Agent": …}）。
        if headerSource == nil {
            headerSource = entry["header"] as? [String: Any]
        }
        // Preserve all source-required headers, including Authorization and
        // provider-specific tokens. Canonicalize common case variants;
        // hop-by-hop and framing headers never travel with the media request
        // (白名单化，防 CRLF 注入)。
        let hopByHop: Set<String> = ["host", "connection", "content-length", "transfer-encoding"]
        var mergedHeaders = inlineHeaders
        for (name, rawValue) in headerSource ?? [:] {
            guard let value = rawValue as? String, !value.isEmpty,
                  !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            let canonical: String
            switch name.lowercased() {
            case "user-agent", "useragent": canonical = "User-Agent"
            case "referer": canonical = "Referer"
            case "cookie": canonical = "Cookie"
            case "authorization": canonical = "Authorization"
            default: canonical = name
            }
            if !hopByHop.contains(canonical.lowercased()) {
                mergedHeaders[canonical] = value
            }
        }
        headers = mergedHeaders
        let isParseRequired = [entry["jx"], entry["parse"]].contains { value in
            (value as? NSNumber)?.intValue == 1 || (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        // 弹幕：danmaku / danmakuUrl（驼峰），单串或多路 [{name,url}]/[url]。
        let danmakuChoices = parseAttachments(entry, keys: ["danmaku", "danmakuUrl", "danmu"])
        let danmakuURL = danmakuChoices.first?.url
        // 外挂字幕：subtitles / subtitle / subs。
        let subtitles = parseAttachments(entry, keys: ["subtitles", "subtitle", "subs"])
        // ClearKey DRM（tvbox 约定：drmType=clearkey + drmKey/drmKid）。
        var clearKey: String?
        var clearKid: String?
        let drmType = (entry["drmType"] as? String) ?? (entry["drm"] as? String) ?? ""
        if let key = entry["drmKey"] as? String, !key.isEmpty,
           drmType.isEmpty || drmType.lowercased().contains("clear") {
            clearKey = key
            clearKid = entry["drmKid"] as? String
        }
        return CatSourcePlayResult(
            url: url,
            headers: headers,
            isParseRequired: isParseRequired,
            danmakuURL: danmakuURL,
            qualityURLs: qualityURLs,
            subtitles: subtitles,
            danmakuChoices: danmakuChoices,
            drmClearKey: clearKey,
            drmKid: clearKid
        )
    }

    // MARK: 私有

    // MARK: 目录只读缓存（进程级；目录缓存 目录缓存语义：TTL 30s / ≤100 条）
    // client() 每次新建实例，缓存必须放静态层；key 含 baseURL（引擎重启换端口后
    // 旧键自然失效，无需显式失效逻辑）。

    private static let catalogCacheLock = NSLock()
    private static var catalogCache: [String: (data: Data, at: Date)] = [:]
    private static let catalogCacheTTL: TimeInterval = 30
    private static let catalogCacheLimit = 100

    private static func catalogCacheKey(baseURL: URL, apiPath: String, kind: String, extra: [String: String]?) -> String {
        let extraPart = extra?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") ?? ""
        return "\(kind)|\(baseURL.absoluteString)|\(apiPath)|\(extraPart)"
    }

    private static func cachedCatalogData(forKey key: String) -> Data? {
        catalogCacheLock.lock()
        defer { catalogCacheLock.unlock() }
        guard let entry = catalogCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < catalogCacheTTL else {
            catalogCache.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    private static func storeCatalogData(_ data: Data, forKey key: String) {
        catalogCacheLock.lock()
        defer { catalogCacheLock.unlock() }
        catalogCache[key] = (data, Date())
        if catalogCache.count > catalogCacheLimit {
            if let oldest = catalogCache.min(by: { $0.value.at < $1.value.at })?.key {
                catalogCache.removeValue(forKey: oldest)
            }
        }
    }

    /// 播放结果下钻（兼容多形态返回）：
    /// 1. 嵌套 JSON 字符串连续解析（最多 3 次）；
    /// 2. 包裹在 data/result/play 字段下时逐层下钻（最多 3 层，字符串继续解析）。
    /// 仅当外层自身没有可用的播放地址字段时才下钻，避免破坏同级的 header/parse 等字段。
    private static func drillPlayPayload(_ root: Any) -> Any {
        var current = root
        for _ in 0..<3 {
            guard let text = current as? String,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { break }
            current = parsed
        }
        for _ in 0..<3 {
            guard let dict = current as? [String: Any], !hasPlayURLField(dict) else { break }
            guard let key = ["data", "result", "play"].first(where: { dict[$0] != nil }),
                  let nested = dict[key] else { break }
            if let text = nested as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                current = parsed
            } else {
                current = nested
            }
        }
        return current
    }

    private static func hasPlayURLField(_ dict: [String: Any]) -> Bool {
        for key in ["url", "urls", "play_url", "playUrl", "link", "src", "m3u8"] {
            if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            if dict[key] is [[String: Any]] || dict[key] is [String] { return true }
        }
        return false
    }

    /// [名, url, 名2, url2] 内联配对形态判定：偶数位都不是带 scheme 的地址、
    /// 奇数位都是（普通画质数组 [url1, url2] 不受影响）。
    private static func looksLikeInlinePairs(_ values: [String]) -> Bool {
        guard values.count >= 2, values.count % 2 == 0 else { return false }
        var sawURL = false
        for index in stride(from: 0, to: values.count, by: 2) {
            let label = values[index]
            let candidate = values[index + 1]
            let labelIsURL = URL(string: label)?.scheme != nil
            let candidateIsURL = URL(string: candidate)?.scheme != nil
            if labelIsURL || !candidateIsURL { return false }
            sawURL = true
        }
        return sawURL
    }

    /// `url|Header=k=v&k2=v2` 尾注拆分（TVBox 生态尾注约定）：
    /// 就地截掉尾注并返回键值对；尾段解析不出键值对时保持原串。
    /// `Header=` 引导段（部分源写成 `url|Header=User-Agent=x&…`）先剥掉再解析。
    private static func splitInlineHeaders(_ urlString: inout String) -> [String: String] {
        guard let pipe = urlString.lastIndex(of: "|") else { return [:] }
        var suffix = String(urlString[urlString.index(after: pipe)...])
        guard suffix.contains("=") else { return [:] }
        if suffix.lowercased().hasPrefix("header=") {
            suffix = String(suffix.dropFirst("header=".count))
        }
        var result: [String: String] = [:]
        for pair in suffix.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = kv.first, !name.isEmpty else { continue }
            let key = String(name).removingPercentEncoding ?? String(name)
            let value = kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            result[key] = value
        }
        guard !result.isEmpty else { return [:] }
        urlString = String(urlString[..<pipe])
        return result
    }

    /// 列表数据 vod_pic 容错：字典形态 `{url, headers}` 取 url；`pic|Header=…`
    /// 尾注剥掉（凭据只对单张图片有效，整串保留反而污染）。防止 Decodable
    /// 因类型不匹配整包解码失败。internal 供对齐测试直接验证。
    static func sanitizedListData(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        func sanitize(_ raw: Any) -> Any? {
            if let dict = raw as? [String: Any] {
                return dict["url"] as? String ?? nil
            }
            guard let text = raw as? String else { return raw }
            // `pic|Header=…` 尾注：能解析出键值对才剥（与播放地址同规则）。
            var mutable = text
            let inlineHeaders = splitInlineHeaders(&mutable)
            return inlineHeaders.isEmpty ? text : mutable
        }
        if var list = object["list"] as? [[String: Any]] {
            for index in list.indices {
                if let pic = list[index]["vod_pic"], let fixed = sanitize(pic) {
                    list[index]["vod_pic"] = fixed
                }
            }
            object["list"] = list
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private func sanitizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        // 源站返回的地址常带未转义的中文/空格，先按百分号编码补齐再解析。
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlAllowed),
              let url = URL(string: encoded), url.scheme != nil else { return nil }
        return url
    }

    /// 解析 tvbox/CatVod 的附件轨字段：值可能是 URL 串、{name,url} 对象或对象/串数组。
    private func parseAttachments(_ entry: [String: Any], keys: [String]) -> [CatSourceAttachment] {
        for key in keys {
            guard let value = entry[key] else { continue }
            var attachments: [CatSourceAttachment] = []
            func append(_ name: String, _ raw: String) {
                guard let url = sanitizedURL(raw) else { return }
                attachments.append(CatSourceAttachment(name: name, url: url))
            }
            switch value {
            case let raw as String:
                append(key, raw)
            case let dict as [String: Any]:
                let name = (dict["name"] as? String) ?? (dict["label"] as? String) ?? key
                if let raw = (dict["url"] as? String) ?? (dict["api"] as? String) { append(name, raw) }
            case let list as [String]:
                for (index, raw) in list.enumerated() { append("\(key)\(index + 1)", raw) }
            case let list as [[String: Any]]:
                for item in list {
                    let name = (item["name"] as? String) ?? (item["label"] as? String) ?? key
                    if let raw = (item["url"] as? String) ?? (item["api"] as? String) { append(name, raw) }
                }
            case let list as [Any]:
                for item in list {
                    if let raw = item as? String { append(key, raw) }
                    if let dict = item as? [String: Any] {
                        let name = (dict["name"] as? String) ?? (dict["label"] as? String) ?? key
                        if let raw = (dict["url"] as? String) ?? (dict["api"] as? String) { append(name, raw) }
                    }
                }
            default:
                continue
            }
            if !attachments.isEmpty { return attachments }
        }
        return []
    }

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval = 30) async throws -> Data {
        guard let url = URL(string: path.hasPrefix("/") ? path : "/" + path, relativeTo: baseURL) else {
            throw CatSourceError.engineNotRunning
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatSourceError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CatSourceError.engineNotRunning
        }
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw CatSourceError.engineNotRunning }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatSourceError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Source responses may contain expiring playback URLs or tokens;
            // never echo raw response bodies into visible UI diagnostics.
            throw CatSourceError.badResponse("JSON 解码失败：\(error.localizedDescription)")
        }
    }

    private func decodeHome(_ data: Data) throws -> HomeResult {
        struct VodItem: Decodable {
            let vod_id: String?
            let vod_name: String?
            let vod_pic: String?
            let vod_remarks: String?
            let vod_year: String?
            let type_name: String?
        }
        struct Payload: Decodable {
            struct Category: Decodable { let type_id: String?; let type_name: String? }
            struct FilterValue: Decodable { let n: String?; let v: String? }
            struct FilterGroup: Decodable {
                let key: String?
                let name: String?
                let initValue: String?
                let value: [FilterValue]?
                enum CodingKeys: String, CodingKey {
                    case key, name, value
                    case initValue = "init"
                }
            }
            let `class`: [Category]?
            let list: [VodItem]?
            let filters: [String: [FilterGroup]]?
        }
        let payload = try decode(Payload.self, from: Self.sanitizedListData(data))
        let categories = (payload.class ?? []).compactMap { category -> CatSourceCategory? in
            guard let id = category.type_id else { return nil }
            return CatSourceCategory(id: id, name: category.type_name ?? id)
        }
        let items = (payload.list ?? []).compactMap { item -> CatSourceItem? in
            guard let id = item.vod_id, let name = item.vod_name else { return nil }
            return CatSourceItem(
                id: id, name: name,
                posterURL: item.vod_pic.flatMap(URL.init(string:)),
                remark: item.vod_remarks ?? "",
                categoryName: item.type_name
            )
        }
        var filters: [String: [CatSourceFilterGroup]] = [:]
        for (typeID, groups) in payload.filters ?? [:] {
            filters[typeID] = groups.map { group in
                CatSourceFilterGroup(
                    key: group.key ?? "",
                    name: group.name ?? "",
                    initValue: group.initValue,
                    options: (group.value ?? []).compactMap { option in
                        guard let n = option.n, let v = option.v else { return nil }
                        return CatSourceFilterOption(name: n, value: v)
                    }
                )
            }
        }
        return HomeResult(categories: categories, items: items, filters: filters)
    }

    private func decodeList(_ data: Data) throws -> [CatSourceItem] {
        struct Payload: Decodable {
            struct Item: Decodable {
                let vod_id: String?
                let vod_name: String?
                let vod_pic: String?
                let vod_remarks: String?
                let vod_year: String?
            }
            let list: [Item]?
        }
        let payload = try decode(Payload.self, from: Self.sanitizedListData(data))
        return (payload.list ?? []).compactMap { item -> CatSourceItem? in
            guard let id = item.vod_id, let name = item.vod_name else { return nil }
            return CatSourceItem(
                id: id, name: name,
                posterURL: item.vod_pic.flatMap(URL.init(string:)),
                remark: item.vod_remarks ?? "",
                categoryName: nil
            )
        }
    }
}

private extension Array where Element == CatSourceItem {
    func filtered(byKeyword keyword: String, using nameOf: (CatSourceItem) -> String) -> [CatSourceItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return self }
        return filter { nameOf($0).localizedCaseInsensitiveContains(trimmed) }
    }
}

// MARK: - helpers

#if os(macOS)
extension Process {
    fileprivate func waitUntilExit(withTimeout timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
#endif
