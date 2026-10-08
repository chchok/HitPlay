import Combine
import CryptoKit
import Foundation
import HitPlayPySource

/// 订阅源与引擎会话管理：下载 .js.md5 订阅为本地包、启动/停止引擎、
/// 保存站点/分类/条目状态。URL 与请求头不入持久化（仅订阅地址本身入盘）。
@MainActor
public final class CatSourceStore: ObservableObject {
private func debugLog(_ text: String) {
    FileHandle.standardError.write(Data("[hitplay-debug] \(text)\n".utf8))
}

    public struct Subscription: Identifiable, Codable, Equatable {
        public var id: UUID
        public var name: String
        public var url: String
        public var addedAt: Date
        /// 启用状态（nil 视为启用；停用的包不参与自动连接与站点聚合）。
        public var enabled: Bool?

        public init(id: UUID = UUID(), name: String, url: String, addedAt: Date = Date(), enabled: Bool? = true) {
            self.id = id
            self.name = name
            self.url = url
            self.addedAt = addedAt
            self.enabled = enabled
        }

        public var isEnabled: Bool { enabled ?? true }

        /// 本地导入的包（file:// 地址），与在线订阅在订阅源页区分显示。
        public var isLocalPackage: Bool {
            guard let parsed = URL(string: url) else { return false }
            return parsed.isFileURL
        }
    }

    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var selectedSubscriptionID: UUID?
    @Published public private(set) var sites: [CatSourceSite] = []
    @Published public private(set) var selectedSiteID: String?
    @Published public private(set) var categories: [CatSourceCategory] = []
    @Published public private(set) var selectedCategoryID: String?
    @Published public private(set) var items: [CatSourceItem] = []
    /// 站点切换进行中：浏览页据此锁定分类行并提示加载，网格保留旧内容不白屏。
    @Published public private(set) var isSwitchingSite = false
    private var pyPlaybackRequestID = UUID()

    // MARK: 站点健康（源选择弹层的失效标注；跨启动持久化）

    public struct SiteHealthRecord: Codable, Equatable {
        public var lastError: String
        public var date: Date
    }

    @Published public private(set) var siteHealth: [String: SiteHealthRecord] = [:]

    private func markSiteFailed(_ siteID: String?, _ error: String) {
        guard let siteID, !error.isEmpty else { return }
        siteHealth[siteID] = SiteHealthRecord(lastError: error, date: Date())
        persistSiteHealth()
    }

    private func markSiteHealthy(_ siteID: String?) {
        guard let siteID, siteHealth.removeValue(forKey: siteID) != nil else { return }
        persistSiteHealth()
    }

    private func persistSiteHealth() {
        if let data = try? JSONEncoder().encode(siteHealth) {
            defaults.set(data, forKey: persistenceKey + ".siteHealth.v1")
        }
    }
    @Published public private(set) var homeFilters: [String: [CatSourceFilterGroup]] = [:]

    // MARK: py 源（FongMi 契约，每源独立 python 进程）

    public struct PyEngine: Identifiable {
        public let id: String
        public var name: String
        /// 包内全部站点（宿主按目录装载多个 Spider，一源一路由；单文件包为一项）。
        public var sites: [CatSourceSite]
        public let runtime: any CatEngineRuntimeProtocol
        public var enabled: Bool?
        public var extend: String? = ""
        /// Remote .py address when this engine was installed online.
        public var sourceURL: String? = nil
        /// 主 Spider 文件名（zip 插件包解压后与 id 不同；nil = 单文件包的 id + ".py"）。
        public var fileName: String? = nil
        /// 订阅安装物 SHA-256（检查更新快路径，见 PySourceRecord.contentHash）。
        public var contentHash: String? = nil

        public var isEnabled: Bool { enabled ?? true }
        public var site: CatSourceSite? { sites.first }
    }

    /// A saved remote JSON catalog that lists installable Python sources.
    public struct PyCatalogSubscription: Identifiable, Codable, Equatable {
        public var id: UUID
        public var name: String
        public var url: String
        public var addedAt: Date

        public init(id: UUID = UUID(), name: String, url: String, addedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.url = url
            self.addedAt = addedAt
        }
    }

    @Published public private(set) var pyEngines: [PyEngine] = []
    @Published public private(set) var pyCatalogSubscriptions: [PyCatalogSubscription] = []
    @Published public private(set) var aggregateGroups: [AggregateGroup] = []
    @Published public private(set) var isAggregating = false

    /// 猫源多源管理：每个订阅一个常驻引擎进程，互相隔离（独立进程/DB 目录/缓存/随机端口）。
    /// 激活切换只把对应引擎提为「活动引擎」，不停止其他引擎；聚合搜索跨全部在跑引擎。
    public struct CatEngine: Identifiable {
        public let id: UUID
        public var name: String
        /// 未加前缀的原始站点表（发布给 UI 时统一加 cat/<id>/ 前缀）。
        public var rawSites: [CatSourceSite]
        public let runtime: any CatEngineRuntimeProtocol
        public var enabled: Bool?
        public var lastActivatedAt: Date

        public var isEnabled: Bool { enabled ?? true }
    }

    /// 同时存活的引擎上限（LRU 淘汰最旧的非活动引擎，防进程堆积）。
    private static let maxRunningCatEngines = 6

    @Published public private(set) var catEngines: [CatEngine] = []

    private func catEngine(for id: UUID) -> CatEngine? {
        catEngines.first { $0.id == id }
    }

    /// UI 站点 id 前缀：跨引擎去重（不同包的站点 key 可能同名）。
    nonisolated static func catSiteID(_ subID: UUID, _ rawKey: String) -> String {
        "cat/\(subID.uuidString)/\(rawKey)"
    }

    private func prefixedCatSites(_ engine: CatEngine) -> [CatSourceSite] {
        engine.rawSites.map { site in
            CatSourceSite(
                id: Self.catSiteID(engine.id, site.id),
                name: site.name,
                isSearchable: site.isSearchable,
                apiPath: site.apiPath
            )
        }
    }

    /// 全部在跑引擎的站点合并视图（多源浏览：站点选择弹层跨引擎列出，
    /// 选择后 route(for:) 按前缀路由回所属引擎，无需任何重启）。
    public var allRunningCatSites: [CatSourceSite] {
        var merged: [CatSourceSite] = []
        var seen = Set<String>()
        for engine in catEngines where engine.runtime.isRunning && engine.isEnabled {
            for site in prefixedCatSites(engine) where seen.insert(site.id).inserted {
                merged.append(site)
            }
        }
        if merged.isEmpty, runtime.isRunning {
            merged = sites
        }
        return merged
    }

    private var pyPersistenceKey: String { persistenceKey + ".py.v1" }
    private var pyCatalogPersistenceKey: String { persistenceKey + ".pyCatalogSubscriptions.v1" }

    public func savePyCatalogSubscription(name: String, url: String, id: UUID? = nil) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CatSourceError.badResponse("请输入 PY 订阅名称") }
        guard let parsed = URL(string: address), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            throw CatSourceError.badResponse("请输入有效的 HTTP 或 HTTPS PY 订阅地址")
        }
        // 订阅地址准入（SSRF 防线）：拒绝 localhost/环回/私有/保留地址主机。
        try RemoteSourceURLPolicy.validate(parsed)
        if let id, let index = pyCatalogSubscriptions.firstIndex(where: { $0.id == id }) {
            pyCatalogSubscriptions[index].name = title
            pyCatalogSubscriptions[index].url = address
        } else {
            pyCatalogSubscriptions.append(PyCatalogSubscription(id: id ?? UUID(), name: title, url: address))
        }
        persistPyCatalogSubscriptions()
    }

    public func removePyCatalogSubscription(id: UUID) {
        pyCatalogSubscriptions.removeAll { $0.id == id }
        persistPyCatalogSubscriptions()
    }

    private func persistPyCatalogSubscriptions() {
        guard let data = try? JSONEncoder().encode(pyCatalogSubscriptions) else { return }
        defaults.set(data, forKey: pyCatalogPersistenceKey)
    }

    private func loadPyCatalogSubscriptions() {
        guard let data = defaults.data(forKey: pyCatalogPersistenceKey),
              let decoded = try? JSONDecoder().decode([PyCatalogSubscription].self, from: data) else { return }
        pyCatalogSubscriptions = decoded
    }

    private func loadPyRecords() {
        guard let data = defaults.data(forKey: pyPersistenceKey),
              let records = try? JSONDecoder().decode([PySourceRecord].self, from: data) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for record in records {
                let dir = self.packageDirectory(for: UUID(uuidString: record.id) ?? UUID())
                let sourceURL = dir.appendingPathComponent(record.fileName)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    self.statusMessage = "「\(record.name)」文件缺失，请重新导入"
                    continue
                }
                let runtime = CatSourceEngineRuntime()
                bindToastForwarding(runtime)
                guard record.enabled ?? true else {
                    let site = CatSourceSite(id: "py/\(record.id)", name: record.name, isSearchable: true, apiPath: "/spider/py/3")
                    self.pyEngines.append(PyEngine(
                        id: record.id, name: record.name, sites: [site], runtime: runtime,
                        enabled: false, extend: record.extend, sourceURL: record.sourceURL,
                        fileName: record.fileName, contentHash: record.contentHash
                    ))
                    continue
                }
                do {
                    try await runtime.start(packageDir: dir, pythonExtend: record.extend)
                    let configSites = try await runtime.client().config().sites
                    guard !configSites.isEmpty else {
                        runtime.stop()
                        self.statusMessage = "「\(record.name)」没有提供可用站点"
                        continue
                    }
                    let siteIDPrefix = "py/\(record.id)"
                    let sites = self.pySiteEntries(configSites, idPrefix: siteIDPrefix, displayName: record.name)
                    self.pyEngines.append(PyEngine(
                        id: record.id, name: record.name, sites: sites, runtime: runtime,
                        enabled: true, extend: record.extend, sourceURL: record.sourceURL,
                        fileName: record.fileName, contentHash: record.contentHash
                    ))
                } catch {
                    runtime.stop()
                    self.statusMessage = "「\(record.name)」启动失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 引擎站点表 → HitPlay 站点条目：id 加 "py/<包ID>/" 前缀（isPySource 判定依赖）。
    /// 多源包沿用各 Spider 自报名称；单源包显示用户命名。
    private func pySiteEntries(_ configSites: [CatSourceSite], idPrefix: String, displayName: String) -> [CatSourceSite] {
        configSites.map { site in
            let name = configSites.count == 1 ? displayName : site.name
            return CatSourceSite(
                id: "\(idPrefix)/\(site.id)",
                name: name.isEmpty ? displayName : name,
                isSearchable: site.isSearchable,
                apiPath: site.apiPath
            )
        }
    }

    private func savePyRecords() {
        let records = pyEngines.map { engine in
            PySourceRecord(
                id: engine.id, name: engine.name,
                fileName: engine.fileName ?? (engine.id + ".py"),
                enabled: engine.isEnabled, extend: engine.extend,
                sourceURL: engine.sourceURL, contentHash: engine.contentHash
            )
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: pyPersistenceKey)
        }
        scheduleSourceBackup()
    }

    /// 安装 py 源：拷贝进独立包目录并立即启动引擎。
    /// 接受单 .py 文件或 zip 插件包（FongMi py 生态常见形态：spider.py + 依赖库）。
    /// extend 为目录条目 ext 归一后的 init(extend) 入参（本地导入一般无）。
    public func installPySource(name: String, fileURL: URL, extend: String? = nil) async throws {
        let fm = FileManager.default
        let id = UUID()
        let dir = packageDirectory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var primaryFileName = id.uuidString + ".py"
        var contentHash: String
        if fileURL.pathExtension.lowercased() == "zip" {
            #if os(macOS)
            try processZipArchive(at: fileURL, into: dir)
            guard let primary = Self.primaryPyFileName(in: dir) else {
                try? fm.removeItem(at: dir)
                throw CatSourceError.badResponse("py 插件压缩包内没有 .py 文件")
            }
            primaryFileName = primary
            contentHash = Self.sha256Hex(try Data(contentsOf: fileURL))
            #else
            _ = dir
            throw CatSourceError.badResponse("py 插件包解压需要 macOS 端，iOS 版暂不支持")
            #endif
        } else {
            let dest = dir.appendingPathComponent(primaryFileName)
            try fm.copyItem(at: fileURL, to: dest)
            contentHash = Self.sha256Hex(try Data(contentsOf: dest))
        }

        let runtime = CatSourceEngineRuntime()
        bindToastForwarding(runtime)
        let config: CatSourceClient.SiteConfig
        do {
            try await runtime.start(packageDir: dir, pythonExtend: extend)
            config = try await runtime.client().config()
            guard !config.sites.isEmpty else {
                throw CatSourceError.badResponse("py 源未提供 Spider")
            }
        } catch {
            runtime.stop()
            try? fm.removeItem(at: dir)
            throw error
        }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (config.sites.first?.name ?? "订阅") : name
        let sites = pySiteEntries(config.sites, idPrefix: "py/\(id.uuidString)", displayName: displayName)
        let engine = PyEngine(
            id: id.uuidString, name: displayName, sites: sites, runtime: runtime,
            enabled: true, extend: extend ?? "", fileName: primaryFileName, contentHash: contentHash
        )
        pyEngines.append(engine)
        savePyRecords()
        // 目录内文件名与 id 对齐（宿主按目录加载，不依赖文件名）。
        statusMessage = "已安装「\(displayName)」"
    }

    /// zip 解包（ditto）：先解到隔离目录，验证无路径穿越条目后再并入目标目录。
    /// 返回值仅供测试断言；调用方保证目录已存在。
    @discardableResult
    func processZipArchive(at zipURL: URL, into destination: URL) throws {
        #if os(macOS)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("HitPlay-PYZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CatSourceError.badResponse("py 插件压缩包解压失败（\(process.terminationStatus)）")
        }
        // 路径穿越防御：拒绝绝对路径与 ../ 逃逸条目（恶意 zip 的常见形态）。
        let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let relative = item.path.dropFirst(staging.path.count + 1)
            if relative.hasPrefix("/") || relative.contains("../") || relative.contains("/..") {
                throw CatSourceError.badResponse("py 插件压缩包包含不安全的路径条目，已拒绝导入")
            }
        }
        // 逐条目并入目标目录（覆盖同名文件；保留目标目录已有的 db/cookies 等运行数据）。
        // FileManager.copyItem 不支持合并到已存在目录，必须按顶层条目搬运。
        for entry in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
            let source = staging.appendingPathComponent(entry)
            let target = destination.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
        return
        #else
        _ = zipURL
        _ = destination
        throw CatSourceError.badResponse("py 插件包解压需要 macOS 端，iOS 版暂不支持")
        #endif
    }

    /// 包目录主 Spider 文件名：index.py 优先，其余按文件名排序取首个（与宿主装载顺序一致）。
    nonisolated static func primaryPyFileName(in directory: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let pyFiles = entries.filter { $0.hasSuffix(".py") }.sorted()
        if pyFiles.contains("index.py") { return "index.py" }
        return pyFiles.first
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the Python entries from a FongMi/TVBox JSON catalog without retaining
    /// its URL or access token in app storage.
    public func remotePySources(from url: URL, allowLoopback: Bool = false) async throws -> [RemotePySourceReference] {
        try RemoteSourceURLPolicy.validate(url, allowLoopback: allowLoopback)
        let data = try await fetchDataOnce(url)
        let references = try RemotePySourceCatalog.parse(data)
        guard !references.isEmpty else {
            throw CatSourceError.badResponse("订阅中没有可导入的项目")
        }
        return references
    }

    /// Downloads and validates one remote Python source (单 .py 或 zip 插件包)，
    /// then installs it through the same isolated package path used for a local file.
    /// extend 来自目录条目 ext（Spider.init(extend) 入参）；allowLoopback 仅供测试。
    public func installPySource(
        name: String, sourceURL: URL, extend: String? = nil, allowLoopback: Bool = false
    ) async throws {
        try RemoteSourceURLPolicy.validate(sourceURL, allowLoopback: allowLoopback)
        let data = try await fetchDataOnce(sourceURL)
        guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024 else {
            throw CatSourceError.badResponse("远程 PY 文件为空或过大")
        }
        let isZip = data.starts(with: [0x50, 0x4B])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("HitPlay-PY-\(UUID().uuidString)\(isZip ? ".zip" : ".py")")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !isZip {
            guard String(data: data, encoding: .utf8) != nil else {
                throw CatSourceError.badResponse("远程 PY 文件不是 UTF-8 文本")
            }
        }
        try data.write(to: temporary, options: .atomic)
        try await installPySource(name: name, fileURL: temporary, extend: extend)
        if let index = pyEngines.indices.last {
            pyEngines[index].sourceURL = sourceURL.absoluteString
            savePyRecords()
        }
    }

    public func renamePySource(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        pyEngines[index].name = trimmed
        // 多源包保留各 Spider 自报名称；单源包跟随用户命名。
        let isSingle = pyEngines[index].sites.count == 1
        pyEngines[index].sites = pyEngines[index].sites.map { site in
            CatSourceSite(
                id: site.id, name: isSingle ? trimmed : site.name,
                isSearchable: site.isSearchable, apiPath: site.apiPath
            )
        }
        savePyRecords()
        statusMessage = "已重命名为「\(trimmed)」"
    }

    public func setPySourceEnabled(_ enabled: Bool, id: String) async throws {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        let engine = pyEngines[index]
        if !enabled {
            engine.runtime.stop()
            pyEngines[index].enabled = false
            savePyRecords()
            if engine.sites.contains(where: { $0.id == selectedSiteID }) {
                selectedSiteID = nil
                sites = []
                categories = []
                items = []
            }
            statusMessage = "已停用「\(engine.name)」"
            return
        }

        do {
            try await engine.runtime.start(packageDir: packageDirectory(for: UUID(uuidString: id) ?? UUID()), pythonExtend: engine.extend)
            let configSites = try await engine.runtime.client().config().sites
            guard !configSites.isEmpty else {
                engine.runtime.stop()
                throw CatSourceError.badResponse("未提供可用站点")
            }
            pyEngines[index].sites = pySiteEntries(configSites, idPrefix: "py/\(id)", displayName: engine.name)
            pyEngines[index].enabled = true
            savePyRecords()
            statusMessage = "已启用「\(engine.name)」"
        } catch {
            engine.runtime.stop()
            pyEngines[index].enabled = false
            savePyRecords()
            throw error
        }
    }

    public func reloadPySource(id: String) async throws {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        let engine = pyEngines[index]
        guard engine.isEnabled else { throw CatSourceError.badResponse("请先启用此订阅") }
        engine.runtime.stop()
        do {
            try await engine.runtime.start(packageDir: packageDirectory(for: UUID(uuidString: id) ?? UUID()), pythonExtend: engine.extend)
            let configSites = try await engine.runtime.client().config().sites
            guard !configSites.isEmpty else {
                throw CatSourceError.badResponse("未提供可用站点")
            }
            pyEngines[index].sites = pySiteEntries(configSites, idPrefix: "py/\(id)", displayName: engine.name)
            statusMessage = "已重新加载「\(engine.name)」"
        } catch {
            engine.runtime.stop()
            throw error
        }
    }

    /// 用新文件替换本地 PY 源：先在隔离目录启动验证，通过后才替换现有文件。
    public func updatePySource(id: String, fileURL: URL) async throws {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        let engine = pyEngines[index]
        let fm = FileManager.default
        let dir = packageDirectory(for: UUID(uuidString: id) ?? UUID())
        let sourceName = engine.fileName ?? (id + ".py")
        let target = dir.appendingPathComponent(sourceName)
        let staging = dir.appendingPathComponent(".update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: fileURL, to: staging.appendingPathComponent(sourceName))

        let verifier = CatSourceEngineRuntime()
        try await verifier.start(packageDir: staging, pythonExtend: engine.extend)
        defer { verifier.stop() }
        guard try await verifier.client().config().sites.first != nil else {
            throw CatSourceError.badResponse("所选文件未提供可用站点")
        }

        let previous = try Data(contentsOf: target)
        let replacement = try Data(contentsOf: staging.appendingPathComponent(sourceName))
        engine.runtime.stop()
        do {
            try replacement.write(to: target, options: .atomic)
            if engine.isEnabled {
                try await engine.runtime.start(packageDir: dir, pythonExtend: engine.extend)
                let configSites = try await engine.runtime.client().config().sites
                guard !configSites.isEmpty else {
                    throw CatSourceError.badResponse("更新后未提供可用站点")
                }
                pyEngines[index].sites = pySiteEntries(configSites, idPrefix: "py/\(id)", displayName: engine.name)
            }
            scheduleSourceBackup()
            statusMessage = "已更新「\(engine.name)」"
        } catch {
            engine.runtime.stop()
            try? previous.write(to: target, options: .atomic)
            if engine.isEnabled { try? await engine.runtime.start(packageDir: dir, pythonExtend: engine.extend) }
            throw error
        }
    }

    // MARK: py 订阅源更新闭环（对齐 JS 订阅 updateSubscription 的语义）

    /// py 订阅更新检查结果。
    public enum PySourceUpdateCheck: Equatable {
        /// 远端内容与已安装哈希一致（或远端不可比），无需更新。
        case unchanged
        /// 远端内容有新版本。
        case available
    }

    /// 检查单个 py 订阅源是否有更新：下载远端安装物并与 contentHash 比对。
    /// 哈希快路径只在下载后比对（不做 HEAD/ETag 预检，生态服务器普遍不支持）。
    /// - Throws: 源未从订阅安装、地址无效或下载失败。
    public func checkPySourceUpdate(id: String, allowLoopback: Bool = false) async throws -> PySourceUpdateCheck {
        guard let engine = pyEngines.first(where: { $0.id == id }) else {
            throw CatSourceError.badResponse("PY 源不存在")
        }
        guard let sourceURLString = engine.sourceURL, let url = URL(string: sourceURLString) else {
            throw CatSourceError.badResponse("此 PY 源不是从订阅安装的，没有可检查的更新地址")
        }
        try RemoteSourceURLPolicy.validate(url, allowLoopback: allowLoopback)
        let remote = try await fetchDataOnce(url)
        guard !remote.isEmpty else {
            throw CatSourceError.badResponse("远端 PY 内容为空")
        }
        if let hash = engine.contentHash, hash == Self.sha256Hex(remote) {
            return .unchanged
        }
        return .available
    }

    /// 从订阅地址更新 py 源（用户主动触发，逐源执行；无后台/批量自动下载）。
    /// 哈希一致直接跳过；否则按安装物形态分流：
    /// 单 .py 走 updatePySource（隔离验证 + 原子替换 + 回滚）；zip 重解包后
    /// 以隔离目录启动验证，通过再替换包内容（保留 db/cookies 运行数据）。
    /// - Returns: 是否真的发生了更新（false = 哈希一致跳过）。
    @discardableResult
    public func updatePySourceFromSubscription(id: String, allowLoopback: Bool = false) async throws -> Bool {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else {
            throw CatSourceError.badResponse("PY 源不存在")
        }
        let engine = pyEngines[index]
        guard let sourceURLString = engine.sourceURL, let url = URL(string: sourceURLString) else {
            throw CatSourceError.badResponse("此 PY 源不是从订阅安装的，没有可更新的地址")
        }
        try RemoteSourceURLPolicy.validate(url, allowLoopback: allowLoopback)
        statusMessage = "正在检查「\(engine.name)」更新…"
        let remote = try await fetchDataOnce(url)
        guard !remote.isEmpty, remote.count <= 64 * 1_024 * 1_024 else {
            throw CatSourceError.badResponse("远端 PY 内容为空或过大")
        }
        let remoteHash = Self.sha256Hex(remote)
        if let hash = engine.contentHash, hash == remoteHash {
            statusMessage = "「\(engine.name)」已是最新"
            return false
        }
        let isZip = remote.starts(with: [0x50, 0x4B])
        if isZip {
            try await replacePySourceWithZipBundle(id: id, zipData: remote, remoteHash: remoteHash)
        } else {
            guard let text = String(data: remote, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatSourceError.badResponse("远端 PY 文件不是 UTF-8 文本")
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("HitPlay-PYUpdate-\(UUID().uuidString).py")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try remote.write(to: temporary, options: .atomic)
            try await updatePySource(id: id, fileURL: temporary)
        }
        if pyEngines.indices.contains(index) {
            pyEngines[index].contentHash = remoteHash
            savePyRecords()
        }
        statusMessage = "已把「\(engine.name)」更新到最新版本"
        return true
    }

    /// zip 插件包整体替换：新包解到隔离目录并启动验证，通过后停止引擎、
    /// 清除旧 Spider 文件、并入新包内容、重启引擎；失败保持旧包不动。
    private func replacePySourceWithZipBundle(id: String, zipData: Data, remoteHash: String) async throws {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else {
            throw CatSourceError.badResponse("PY 源不存在")
        }
        let engine = pyEngines[index]
        let fm = FileManager.default
        let dir = packageDirectory(for: UUID(uuidString: id) ?? UUID())
        let remoteZip = fm.temporaryDirectory.appendingPathComponent("HitPlay-PYZipUpdate-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: remoteZip) }
        try zipData.write(to: remoteZip, options: .atomic)

        let staging = dir.appendingPathComponent(".update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try processZipArchive(at: remoteZip, into: staging)
        guard let primary = Self.primaryPyFileName(in: staging) else {
            throw CatSourceError.badResponse("远端压缩包内没有 .py 文件")
        }

        let verifier = CatSourceEngineRuntime()
        try await verifier.start(packageDir: staging, pythonExtend: engine.extend)
        defer { verifier.stop() }
        guard try await verifier.client().config().sites.first != nil else {
            throw CatSourceError.badResponse("远端压缩包未提供可用站点")
        }

        engine.runtime.stop()
        do {
            // 清除旧 Spider 文件（.py 与 zip 可能携带的 lib 资源）后并入新包。
            let runtimeSuffixes = Set([".py"])
            for entry in try fm.contentsOfDirectory(atPath: dir.path)
            where runtimeSuffixes.contains((entry as NSString).pathExtension.lowercased()) {
                try? fm.removeItem(at: dir.appendingPathComponent(entry))
            }
            try processZipArchive(at: remoteZip, into: dir)
            guard let newPrimary = Self.primaryPyFileName(in: dir) else {
                throw CatSourceError.badResponse("更新后包内没有 .py 文件")
            }
            pyEngines[index].fileName = newPrimary
            pyEngines[index].contentHash = remoteHash
            if engine.isEnabled {
                try await engine.runtime.start(packageDir: dir, pythonExtend: engine.extend)
                let configSites = try await engine.runtime.client().config().sites
                guard !configSites.isEmpty else {
                    throw CatSourceError.badResponse("更新后未提供可用站点")
                }
                pyEngines[index].sites = pySiteEntries(configSites, idPrefix: "py/\(id)", displayName: engine.name)
            }
            scheduleSourceBackup()
            statusMessage = "已更新「\(engine.name)」"
        } catch {
            engine.runtime.stop()
            throw error
        }
    }

    public func setPySourceExtend(id: String, extend: String) async throws {        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        let engine = pyEngines[index]
        pyEngines[index].extend = extend
        savePyRecords()
        guard engine.isEnabled else {
            statusMessage = "已保存配置；启用后生效"
            return
        }
        engine.runtime.stop()
        do {
            try await engine.runtime.start(packageDir: packageDirectory(for: UUID(uuidString: id) ?? UUID()), pythonExtend: extend)
            let configSites = try await engine.runtime.client().config().sites
            guard !configSites.isEmpty else {
                throw CatSourceError.badResponse("未提供可用站点")
            }
            pyEngines[index].sites = pySiteEntries(configSites, idPrefix: "py/\(id)", displayName: engine.name)
            statusMessage = "已保存并应用配置"
        } catch {
            engine.runtime.stop()
            pyEngines[index].extend = engine.extend
            savePyRecords()
            try? await engine.runtime.start(packageDir: packageDirectory(for: UUID(uuidString: id) ?? UUID()), pythonExtend: engine.extend)
            throw error
        }
    }

    public func removePySource(id: String) {
        guard let index = pyEngines.firstIndex(where: { $0.id == id }) else { return }
        let engine = pyEngines.remove(at: index)
        engine.runtime.stop()
        if engine.sites.contains(where: { $0.id == selectedSiteID }) {
            selectedSiteID = nil
            sites = []
            categories = []
            items = []
        }
        try? FileManager.default.removeItem(at: packageDirectory(for: UUID(uuidString: id) ?? UUID()))
        var records = (defaults.data(forKey: pyPersistenceKey)).flatMap { try? JSONDecoder().decode([PySourceRecord].self, from: $0) } ?? []
        records.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: pyPersistenceKey)
        }
        scheduleSourceBackup()
    }

    /// PY 源站点判断。
    public func siteIDIsPy(_ siteID: String) -> Bool {
        siteID.hasPrefix("py/")
    }

    /// PY 源点击卡片立刻播放：detail → play 解析；返回三元组交视图层播放。
    public func playPyItem(siteID: String, item: CatSourceItem) async -> (detail: CatSourceDetail, episode: CatSourceEpisode, result: CatSourcePlayResult)? {
        let requestID = UUID()
        pyPlaybackRequestID = requestID
        guard let engine = pyEngines.first(where: { $0.sites.contains(where: { $0.id == siteID }) }),
              engine.runtime.isRunning, let base = engine.runtime.baseURL,
              let pySite = engine.sites.first(where: { $0.id == siteID }) else {
            statusMessage = "PY 播放服务未运行，请重新启用该源"
            return nil
        }
        let client = CatSourceClient(baseURL: base)
        statusMessage = "正在读取影片信息：\(item.name)"
        do {
            let detail = try await client.detail(apiPath: pySite.apiPath, itemID: item.id)
            guard pyPlaybackRequestID == requestID else { return nil }
            guard let episode = detail.episodes.first else {
                statusMessage = "「\(item.name)」无可播放分集"
                return nil
            }
            statusMessage = "正在获取播放地址：\(item.name)"
            let result = try await client.play(apiPath: pySite.apiPath, flag: episode.flag, playKey: episode.playKey)
            guard pyPlaybackRequestID == requestID else { return nil }
            statusMessage = nil
            return (detail, episode, result)
        } catch {
            guard pyPlaybackRequestID == requestID else { return nil }
            statusMessage = "播放失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 站点路由解析：js 站点走主引擎，py/ 前缀站点走各自进程。
    private func route(for siteID: String) -> (client: CatSourceClient, apiPath: String)? {
        if siteID.hasPrefix("py/") {
            guard let engine = pyEngines.first(where: { $0.sites.contains(where: { $0.id == siteID }) }),
                  engine.runtime.isRunning, let base = engine.runtime.baseURL,
                  let pySite = engine.sites.first(where: { $0.id == siteID }) else { return nil }
            return (CatSourceClient(baseURL: base), pySite.apiPath)
        }
        if siteID.hasPrefix("cat/") {
            // cat/<subID>/<rawKey>：定位所属猫源引擎（多源并存，各自独立进程与端口）。
            let rest = siteID.dropFirst("cat/".count)
            guard let subIDString = rest.split(separator: "/", maxSplits: 1).first,
                  let subID = UUID(uuidString: String(subIDString)),
                  let engine = catEngine(for: subID),
                  engine.runtime.isRunning, let base = engine.runtime.baseURL else { return nil }
            let rawKey = rest.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/")
            guard let site = engine.rawSites.first(where: { $0.id == rawKey }) else { return nil }
            return (CatSourceClient(baseURL: base), site.apiPath)
        }
        // 兼容旧无前缀 id：仅当它是当前活动引擎的站点。
        guard runtime.isRunning, runtime.baseURL != nil,
              let site = sites.first(where: { $0.id == siteID }) else { return nil }
        return (runtime.client(), site.apiPath)
    }
    @Published public private(set) var isLoading = false
    @Published public var statusMessage: String?
    @Published public private(set) var engineError: String?
    @Published public private(set) var lastActivatedID: UUID?

    /// 防止慢启动的旧订阅/旧站点请求在用户切换后覆盖当前页面。
    private var activationRequestID = UUID()
    private var contentRequestID = UUID()
    /// Multiple tabs can request restoration while the root view is mounting.
    /// Keep one scheduled activation so nodejs-mobile is never started twice.
    private var restoreActivationTask: Task<Void, Never>?

    @Published public var runtime: any CatEngineRuntimeProtocol = CatSourceEngineRuntime()

    private let persistenceKey = "hitplay.catsource.subscriptions.v1"
    private let defaults: UserDefaults
    private let session: URLSession
    /// addSubscription suspends while downloading. Keep an explicit reservation so
    /// repeated taps (or a second presentation of the sheet) cannot create a second UUID.
    private var addingSubscriptionURLKeys = Set<String>()

    /// 引擎 toast → 状态条（C1-5）。多源下每个猫源引擎与每个 py 源引擎都接同一条通道。
    private func bindToastForwarding(_ engineRuntime: CatSourceEngineRuntime) {
        engineRuntime.onToast = { [weak self] text in
            self?.statusMessage = text
        }
        // /msg 全量动作分发：openInternalWebview/danmuPush/push 由组合根接线生效。
        engineRuntime.onEngineMessage = { [weak self] message in
            self?.handleEngineMessage(message)
        }
    }

    /// 引擎消息回调（组合根接线）：
    /// - onEnginePushPlay：包内推送的播放地址 → 走播放器；
    /// - onOpenExternal：openInternalWebview → 系统浏览器打开配置/网页；
    /// - onDanmakuPush：danmuPush → 给当前播放挂弹幕。
    public var onEnginePushPlay: ((URL, String?) -> Void)?
    public var onOpenExternal: ((URL) -> Void)?
    public var onDanmakuPush: ((URL) -> Void)?

    private func handleEngineMessage(_ message: [String: Any]) {
        let action = message["action"] as? String ?? ""
        let opt = message["opt"] as? [String: Any]
        let rawURL = (opt?["url"] as? String) ?? (message["url"] as? String) ?? ""
        switch action {
        case "push":
            guard let url = URL(string: rawURL), url.scheme != nil else { return }
            onEnginePushPlay?(url, opt?["title"] as? String)
        case "openInternalWebview":
            guard let url = URL(string: rawURL), url.scheme != nil else { return }
            onOpenExternal?(url)
        case "danmuPush":
            guard let url = URL(string: rawURL), url.scheme != nil else { return }
            onDanmakuPush?(url)
        default:
            break
        }
    }

    // MARK: 包内推送（「推」推送 type-4 站点代解析）

    /// 在全部运行中的引擎里找推送代解析站点（key=push / 名称含「推送」/ 路由含 /push/）。
    public func pushTarget() -> (client: CatSourceClient, apiPath: String, engineName: String)? {
        func isPushSite(_ site: CatSourceSite) -> Bool {
            site.apiPath.lowercased().contains("/push/")
                || site.id.lowercased() == "push"
                || site.name.contains("推送")
        }
        for engine in catEngines where engine.runtime.isRunning && engine.isEnabled {
            guard let base = engine.runtime.baseURL else { continue }
            if let site = engine.rawSites.first(where: isPushSite) {
                return (engine.runtime.client(), site.apiPath, engine.name)
            }
        }
        if runtime.isRunning, runtime.baseURL != nil,
           let site = sites.first(where: isPushSite) {
            return (runtime.client(), site.apiPath, "当前源")
        }
        return nil
    }

    /// 推送代解析：把用户推来的播放/分享地址交给源内「推」站点解析成直链。
    /// 成功返回解析结果（play 管线同款）；无推送站点或解析失败返回 nil（调用方回退直连）。
    public func resolvePushPlay(_ rawURL: String) async -> CatSourcePlayResult? {
        guard let target = pushTarget() else { return nil }
        guard let data = try? await target.client.play(apiPath: target.apiPath, flag: "", playKey: rawURL) else {
            return nil
        }
        return data
    }

    public init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        if let nodeRuntime = runtime as? CatSourceEngineRuntime {
            bindToastForwarding(nodeRuntime)
        }
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = decoded
        }
        if let data = defaults.data(forKey: persistenceKey + ".siteHealth.v1"),
           let decoded = try? JSONDecoder().decode([String: SiteHealthRecord].self, from: data) {
            siteHealth = decoded
        }
        lastActivatedID = defaults.string(forKey: lastActivatedKey).flatMap(UUID.init(uuidString:))
        selectedSubscriptionID = lastActivatedID
        if let saved = defaults.string(forKey: persistenceKey + ".lastSite"),
           saved.split(separator: "|").first.map(String.init) == lastActivatedID?.uuidString,
           let siteID = saved.split(separator: "|").dropFirst().first.map(String.init) {
            selectedSiteID = siteID
        }
        Task { @MainActor [weak self] in
            await self?.restoreCloudSourcesIfAvailable()
            self?.loadPyCatalogSubscriptions()
            self?.loadPyRecords()
            self?.scheduleSourceBackup()
        }
    }

    private var lastActivatedKey: String { persistenceKey + ".lastActivated" }

    /// CatVodOpen ecosystem behavior: the last-activated subscription connects automatically
    /// when the browse page appears.
    /// 验收辅助：`-hitplayDemoItems` 启动参数注入演示内容（不经引擎）。
    public func debugInjectDemoContentIfNeeded() {
        debugLog("demo inject: args=\(ProcessInfo.processInfo.arguments) items=\(items.count)")
        guard ProcessInfo.processInfo.arguments.contains("-hitplayDemoItems") else { return }
        if sites.isEmpty {
            sites = [CatSourceSite(id: "demo", name: "豆瓣", isSearchable: true),
                     CatSourceSite(id: "demo2", name: "夸克", isSearchable: true)]
            selectedSiteID = "demo"
        }
        if categories.isEmpty {
            categories = [CatSourceCategory(id: "hot", name: "热播"),
                          CatSourceCategory(id: "movie", name: "电影"),
                          CatSourceCategory(id: "tv", name: "电视剧"),
                          CatSourceCategory(id: "show", name: "综艺")]
            selectedCategoryID = "hot"
        }
        if items.isEmpty {
            items = (1...14).map { index -> CatSourceItem in
                let score = 7.8 - Double(index % 7) * 0.4
                let seed = (index % 7) + 1
                let name = index % 3 == 0 ? "英文长标题影片 Example Movie \(index)" : "测试影片\(index)"
                let remark = index % 3 == 0 ? String(format: "评分:%.1f", score) : "HD"
                let poster = URL(string: "https://picsum.photos/seed/hp\(seed)/300/450")
                return CatSourceItem(id: "demo-\(index)", name: name, posterURL: poster, remark: remark, categoryName: "热播")
            }
        }
        debugLog("demo inject done: sites=\(sites.count) cats=\(categories.count) items=\(items.count)")
    }

    public func restoreIfNeeded() {
        debugLog("restoreIfNeeded: subs=\(subscriptions.count) last=\(lastActivatedID?.uuidString.prefix(8) ?? "nil") running=\(runtime.isRunning) err=\(engineError ?? String(describing: engineError))")
        // 搜索页可能只预热了引擎与站点列表；selectedSiteID 已恢复不代表
        // 订阅页的分类/首页数据已加载。按实际内容就绪状态决定是否补载，且旧错误不阻断重试。
        guard !isLoading, restoreActivationTask == nil else { return }
        if !runtime.isRunning {
            if let id = lastActivatedID,
               let subscription = subscriptions.first(where: { $0.id == id }), subscription.isEnabled {
                scheduleRestoreActivation(subscription)
            } else if let first = subscriptions.first(where: \.isEnabled) {
                scheduleRestoreActivation(first)
            }
        } else if sites.isEmpty {
            if let siteID = selectedSiteID, siteID.hasPrefix("py/"), route(for: siteID) != nil {
                Task { await selectSite(siteID) }
            } else if let subscription = selectedSubscription ?? subscriptions.first(where: \.isEnabled) {
                scheduleRestoreActivation(subscription, forceReload: true)
            }
        } else {
            let availableSites = sites + pyEngines.flatMap(\.sites)
            let currentSite = selectedSiteID.flatMap { id in availableSites.first(where: { $0.id == id }) }
            if currentSite != nil,
               engineError == nil,
               selectedCategoryID != nil,
               (!categories.isEmpty || !items.isEmpty) {
                return
            }
            // 保留有效的上次站点；站点失效时回退到默认内容站点。
            let target = currentSite ?? preferredContentSite(in: sites)
            if let target {
                engineError = nil
                Task { await selectSite(target.id) }
            }
        }
    }

    private func scheduleRestoreActivation(_ subscription: Subscription, forceReload: Bool = false) {
        guard restoreActivationTask == nil else { return }
        restoreActivationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activate(subscription, forceReload: forceReload)
            self.restoreActivationTask = nil
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: persistenceKey)
        }
        scheduleSourceBackup()
    }

    private func scheduleSourceBackup() {
        let (snapshot, packageDirectories) = cloudBackupContent()
        ICloudSourceSync.shared.scheduleSync(snapshot: snapshot, packageDirectories: packageDirectories)
    }

    public func syncSourcesToICloudNow() async {
        let (snapshot, packageDirectories) = cloudBackupContent()
        do {
            try await ICloudSourceSync.shared.syncNow(snapshot: snapshot, packageDirectories: packageDirectories)
        } catch {
            statusMessage = "iCloud 源备份失败：\(error.localizedDescription)"
        }
    }

    private func cloudBackupContent() -> (CloudSourceSnapshot, [UUID: URL]) {
        let pyRecords = defaults.data(forKey: pyPersistenceKey)
            .flatMap { try? JSONDecoder().decode([PySourceRecord].self, from: $0) } ?? []
        let cloudSubscriptions = subscriptions.map { subscription -> CloudCatSubscription in
            let safe = ICloudSourceSync.safeAddress(subscription.url)
            return CloudCatSubscription(
                id: subscription.id,
                name: subscription.name,
                address: safe.address,
                addedAt: subscription.addedAt,
                enabled: subscription.isEnabled,
                requiresReconfiguration: safe.requiresReconfiguration
            )
        }
        let cloudPySources = pyRecords.map {
            CloudPySource(id: $0.id, name: $0.name, enabled: $0.enabled ?? true)
        }
        var packageDirectories = Dictionary(uniqueKeysWithValues: subscriptions.map {
            ($0.id, packageDirectory(for: $0.id))
        })
        for record in pyRecords {
            if let id = UUID(uuidString: record.id) {
                packageDirectories[id] = packageDirectory(for: id)
            }
        }
        return (CloudSourceSnapshot(subscriptions: cloudSubscriptions, pySources: cloudPySources), packageDirectories)
    }

    private func restoreCloudSourcesIfAvailable() async {
        let sync = ICloudSourceSync.shared
        guard sync.isEnabled else { return }
        do {
            guard let snapshot = try await sync.restoreLatest(into: packageDirectory(for: UUID()).deletingLastPathComponent()) else { return }
            var knownSubscriptionIDs = Set(subscriptions.map(\.id))
            for record in snapshot.subscriptions where knownSubscriptionIDs.insert(record.id).inserted {
                subscriptions.append(Subscription(
                    id: record.id,
                    name: record.name,
                    url: record.address,
                    addedAt: record.addedAt,
                    enabled: record.enabled
                ))
            }
            if let data = try? JSONEncoder().encode(subscriptions) {
                defaults.set(data, forKey: persistenceKey)
            }

            var pyRecords = defaults.data(forKey: pyPersistenceKey)
                .flatMap { try? JSONDecoder().decode([PySourceRecord].self, from: $0) } ?? []
            let knownPyIDs = Set(pyRecords.map(\.id))
            for record in snapshot.pySources where !knownPyIDs.contains(record.id) {
                pyRecords.append(PySourceRecord(
                    id: record.id,
                    name: record.name,
                    fileName: record.id + ".py",
                    enabled: record.enabled,
                    extend: ""
                ))
            }
            if let data = try? JSONEncoder().encode(pyRecords) {
                defaults.set(data, forKey: pyPersistenceKey)
            }
            if snapshot.subscriptions.contains(where: \.requiresReconfiguration) || !snapshot.pySources.isEmpty {
                statusMessage = "已从 iCloud 恢复源；带认证的源请重新配置登录信息"
            }
        } catch {
            ICloudSourceSync.shared.status = "恢复失败：\(error.localizedDescription)"
        }
    }

    public func packageDirectory(for id: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HitPlay", isDirectory: true)
            .appendingPathComponent("SourcePackages", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public var selectedSubscription: Subscription? {
        subscriptions.first { $0.id == selectedSubscriptionID }
    }

    /// 新增订阅：下载订阅内容为包 index.js 并注册。同名自动命名。
    /// 下载/校验失败（含「不支持的格式」拒收）时清理包目录——不保存不记录不存储。
    public func addSubscription(name: String, url: URL) async throws {
        let urlKey = Self.subscriptionURLKey(url.absoluteString)
        if let existing = subscriptions.first(where: { Self.subscriptionURLKey($0.url) == urlKey }) {
            statusMessage = "该订阅已添加「\(existing.name)」"
            return
        }
        guard addingSubscriptionURLKeys.insert(urlKey).inserted else {
            throw CatSourceError.badResponse("该订阅正在添加，请等待当前保存完成")
        }
        defer { addingSubscriptionURLKeys.remove(urlKey) }

        isLoading = true
        defer { isLoading = false }
        statusMessage = "正在下载猫源…"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = Subscription(
            name: trimmedName.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmedName,
            url: url.absoluteString
        )
        do {
            try await downloadPackage(for: subscription)
            try Task.checkCancellation()
        } catch {
            let dir = packageDirectory(for: subscription.id)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: hashFile(for: subscription.id))
            throw error
        }
        // Recheck after the asynchronous download in case another path imported it meanwhile.
        if let existing = subscriptions.first(where: { Self.subscriptionURLKey($0.url) == urlKey }) {
            try? FileManager.default.removeItem(at: packageDirectory(for: subscription.id))
            statusMessage = "该订阅已添加「\(existing.name)」"
            return
        }
        statusMessage = "正在保存猫源…"
        subscriptions.append(subscription)
        persist()
        if let notice = importNotice {
            statusMessage = "已导入「\(subscription.name)」：\(notice)"
        } else {
            statusMessage = "已导入「\(subscription.name)」"
        }
    }

    private nonisolated static func subscriptionURLKey(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hashFile(for id: UUID) -> URL {
        packageDirectory(for: id).appendingPathComponent("index.js.md5")
    }

    public func editSubscription(_ subscription: Subscription, name: String, url: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme?.lowercased(), ["https", "http", "file"].contains(scheme),
              let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else {
            throw CatSourceError.badResponse("名称或订阅地址无效")
        }
        let sourceChanged = Self.subscriptionURLKey(subscriptions[index].url) != Self.subscriptionURLKey(parsedURL.absoluteString)
        subscriptions[index].name = trimmedName
        subscriptions[index].url = parsedURL.absoluteString
        persist()
        if sourceChanged {
            // 地址已改，旧包不能继续被当成新源使用；下次启用时会按新地址重新下载。
            if let engine = catEngine(for: subscription.id) {
                engine.runtime.stop()
                catEngines.removeAll { $0.id == subscription.id }
            }
            if selectedSubscriptionID == subscription.id {
                activationRequestID = UUID()
                contentRequestID = UUID()
                runtime.stop()
                selectedSubscriptionID = nil
                lastActivatedID = nil
                defaults.removeObject(forKey: lastActivatedKey)
                sites = []
                selectedSiteID = nil
                categories = []
                selectedCategoryID = nil
                items = []
                homeFilters = [:]
            }
            try? FileManager.default.removeItem(at: packageDirectory(for: subscription.id))
        }
        statusMessage = "已修改「\(trimmedName)」"
    }

    /// 安装本地引擎包：接受 index.js 或包含 index.js 的 .zip（生态惯例安装形态）。
    public func addLocalPackage(name: String, fileURL: URL) async throws {
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        let subscription = Subscription(
            name: name.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : name,
            url: fileURL.absoluteString
        )
        let dir = packageDirectory(for: subscription.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexDest = dir.appendingPathComponent("index.js")

        let ext = fileURL.pathExtension.lowercased()
        if ext == "py" {
            // py 源：整文件作为 index.py 放入包目录（运行时选择 Python 宿主）。
            if fm.fileExists(atPath: indexDest.appendingPathExtension("py").path) {
                try? fm.removeItem(at: indexDest.appendingPathExtension("py"))
            }
            try fm.copyItem(at: fileURL, to: indexDest.appendingPathExtension("py"))
            subscriptions.append(subscription)
            persist()
            statusMessage = "已安装 py 源「\(subscription.name)」"
            return
        }
        if ext == "json" {
            let data = try Data(contentsOf: fileURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            let configDest = dir.appendingPathComponent("config.json")
            let sourceDest = dir.appendingPathComponent("source.js")
            let destination: URL
            let payload: Data
            if Self.isTVBoxConfig(text) {
                destination = configDest
                payload = Data(TVBoxConfigCrypto.normalizedConfigText(text).utf8)
            } else if Self.isTVBoxJSSource(text) {
                destination = sourceDest
                payload = data
            } else {
                try Self.validatePackage(data)
                destination = indexDest
                payload = data
            }
            for stale in [indexDest, sourceDest, configDest] where stale != destination {
                try? fm.removeItem(at: stale)
            }
            try payload.write(to: destination, options: .atomic)
            subscriptions.append(subscription)
            persist()
            statusMessage = "已添加本地文件「\(subscription.name)」"
            return
        }
        if ext == "zip" {
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", fileURL.path, dir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CatSourceError.badResponse("解压本地包失败")
            }
            guard let extracted = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == "index.js" && $0 != indexDest }) else {
                throw CatSourceError.badResponse("压缩包内未找到 index.js")
            }
            if extracted.deletingLastPathComponent() != dir {
                try? fm.removeItem(at: indexDest)
                try fm.moveItem(at: extracted, to: indexDest)
            }
            #else
            throw CatSourceError.badResponse("压缩包导入需要 macOS 端，iOS 版暂不支持")
            #endif
        } else {
            // 单文件 JS 源：TVBox 格式（cat.js/drpy）落盘为 source.js，
            // 引擎包格式落盘为 index.js（cat-source-host require 启动）。
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8),
                  text.contains("function") || text.contains("=>") || text.contains("catServerFactory") else {
                throw CatSourceError.badResponse("本地包不是可识别的 JS 源码")
            }
            let destination = Self.isTVBoxJSSource(text) ? dir.appendingPathComponent("source.js") : indexDest
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
        }
        subscriptions.append(subscription)
        persist()
        statusMessage = "已安装本地包「\(subscription.name)」"
    }

    /// 订阅包下载结果（C2-1 增量快路径）。
    private enum PackageDownloadResult {
        case downloaded
        /// 远端 md5 与本地一致，包未变化（跳过下载）。
        case unchanged
    }

    /// 下载订阅包（两步：.md5 哈希文件 → 实际 index.js）。兼容 .js 和 .js.md5 两种地址。
    /// .md5 订阅走增量快路径（生态通用语义）：远端哈希与本地一致时直接跳过下载。
    /// 落盘形态按内容嗅探：TVBox 配置（含生态加密形态，导入侧解为明文）→ config.json；
    /// 单文件 TVBox JS 源 → source.js；引擎包 → index.js。
    /// 导入提示（如 TVBox 配置的部分支持警告）写入 importNotice，由调用方呈现。
    private(set) var importNotice: String?
    private func downloadPackage(for subscription: Subscription) async throws -> PackageDownloadResult {
        importNotice = nil
        let dir = packageDirectory(for: subscription.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexDest = dir.appendingPathComponent("index.js")
        let tvboxDest = dir.appendingPathComponent("source.js")
        let tvboxConfigDest = dir.appendingPathComponent("config.json")
        let hashDest = dir.appendingPathComponent("index.js.md5")

        /// 落盘决策：TVBox 配置 → config.json（解密归一化后写入）；TVBox JS 源 →
        /// source.js；引擎包（需通过 JS 特征校验）→ index.js。均不匹配返回 nil。
        /// TVBox 配置在写入前做支持度检测：0 可支持站点 → 拒收（调用方清理目录，
        /// 不保存不记录不存储）；部分可支持 → 记录提示由导入方呈现。
        func resolveDestination(for data: Data) throws -> (dest: URL, payload: Data)? {
            let text = String(data: data, encoding: .utf8) ?? ""
            if Self.isTVBoxConfig(text) {
                let normalized = TVBoxConfigCrypto.normalizedConfigText(text)
                let support = Self.tvBoxConfigSiteSupport(normalized)
                guard support.supported > 0 else {
                    throw CatSourceError.badResponse(
                        "不支持的格式：此 TVBox 配置的 \(support.total) 个站点全部依赖 jar 运行时（csp_/spider.js 爬虫包），本机无法解析，已取消导入"
                    )
                }
                if support.supported < support.total {
                    importNotice = "此配置共 \(support.total) 个站点，其中 \(support.total - support.supported) 个依赖 jar 运行时暂不支持，已导入可用的 \(support.supported) 个"
                } else {
                    importNotice = nil
                }
                return (tvboxConfigDest, Data(normalized.utf8))
            }
            if Self.isTVBoxJSSource(text) {
                return (tvboxDest, data)
            }
            do {
                try Self.validatePackage(data)
                return (indexDest, data)
            } catch {
                return nil
            }
        }

        func removeStaleCounterparts(of destination: URL) {
            for counterpart in [indexDest, tvboxDest, tvboxConfigDest] where counterpart != destination {
                try? FileManager.default.removeItem(at: counterpart)
            }
        }

        let raw = subscription.url
        guard let sourceURL = URL(string: raw) else { throw CatSourceError.badResponse("订阅地址无效") }
        if sourceURL.path.lowercased().hasSuffix(".md5") {
            // Step 1: download the .md5 hash pointer.
            statusMessage = "正在读取源包指纹…"
            let md5Data = try await fetchData(sourceURL, maxBytes: BoundedDownloader.maxPointerBytes) { data in
                _ = try Self.parsePackageFingerprint(data)
            }
            let remoteHash = try Self.parsePackageFingerprint(md5Data)
            // C2-1：远端哈希与本地一致且包体在 → 快路径，跳过下载。
            let localBody = (try? Data(contentsOf: indexDest))
                ?? (try? Data(contentsOf: tvboxDest))
                ?? (try? Data(contentsOf: tvboxConfigDest))
            if !remoteHash.isEmpty,
               let localData = localBody,
               Self.packageFingerprint(localData) == remoteHash,
               let localHash = try? String(contentsOf: hashDest, encoding: .utf8)
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               localHash == remoteHash {
                return .unchanged
            }
            // Step 2: download the actual JS (strip .md5 from URL).
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            components?.path = String(sourceURL.path.dropLast(4))
            guard let jsURL = components?.url else {
                throw CatSourceError.badResponse("订阅地址无效")
            }
            statusMessage = "正在下载与校验源包…"
            let jsData = try await fetchData(jsURL) { data in
                if Self.packageFingerprint(data) != remoteHash {
                    throw CatSourceError.badResponse("订阅包与 MD5 指纹不一致，请稍后重试")
                }
            }
            guard let resolved = try resolveDestination(for: jsData) else {
                throw CatSourceError.badResponse("订阅内容格式无法识别")
            }
            try resolved.payload.write(to: resolved.dest, options: .atomic)
            removeStaleCounterparts(of: resolved.dest)
            // Save remote hash for future cache invalidation.
            try? remoteHash.write(to: hashDest, atomically: true, encoding: .utf8)
            return .downloaded
        } else {
            guard let sourceURL = URL(string: raw) else { throw CatSourceError.badResponse("订阅地址无效") }
            if sourceURL.isFileURL, sourceURL.pathExtension.lowercased() == "zip" {
                #if os(macOS)
                let staging = dir.appendingPathComponent(".refresh-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", sourceURL.path, staging.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let candidate = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?
                        .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "index.js" }) else {
                    throw CatSourceError.badResponse("本地压缩包内未找到 index.js")
                }
                let data = try Data(contentsOf: candidate)
                try validateJavaScriptPackage(data)
                try data.write(to: indexDest, options: .atomic)
                // 引擎包常自带 index.config.js（启动配置）与 .md5：一并落盘，否则
                // 引擎只能以宿主默认配置启动（部分引擎的站点注册依赖它）。
                let stagingParent = candidate.deletingLastPathComponent()
                for extra in ["index.config.js", "index.js.md5", "index.config.js.md5"] {
                    let source = stagingParent.appendingPathComponent(extra)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(extra))
                        try? FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(extra))
                    }
                }
                #else
                throw CatSourceError.badResponse("压缩包导入需要 macOS 端完成，iOS 版暂不支持")
                #endif
            } else {
                statusMessage = sourceURL.isFileURL ? "正在读取本地猫源…" : "正在下载与校验源包…"
                let jsData = sourceURL.isFileURL ? try Data(contentsOf: sourceURL) : try await fetchData(sourceURL) { data in
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw CatSourceError.badResponse("订阅内容不是 UTF-8 文本")
                    }
                    if !Self.isTVBoxConfig(text), !Self.isTVBoxJSSource(text) {
                        try Self.validatePackage(data)
                    }
                }
                guard let resolved = try resolveDestination(for: jsData) else {
                    throw CatSourceError.badResponse("订阅内容格式无法识别")
                }
                try resolved.payload.write(to: resolved.dest, options: .atomic)
                removeStaleCounterparts(of: resolved.dest)
            }
            return .downloaded
        }
    }

    private func validateJavaScriptPackage(_ data: Data) throws {
        try Self.validatePackage(data)
    }

    nonisolated static func packageFingerprint(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func parsePackageFingerprint(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let hash = text.split(whereSeparator: \.isWhitespace).first,
              hash.count == 32, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CatSourceError.badResponse("订阅指纹不是有效的 MD5，请检查订阅地址")
        }
        return hash.lowercased()
    }

    nonisolated static func validatePackage(_ data: Data, fingerprint: String? = nil) throws {
        if let fingerprint, packageFingerprint(data) != fingerprint {
            throw CatSourceError.badResponse("订阅包与 MD5 指纹不一致，请稍后重试")
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
              text.contains("function") || text.contains("=>") || text.contains("catServerFactory") else {
            throw CatSourceError.badResponse("订阅内容不是可识别的 JavaScript 源包")
        }
    }

    /// 单文件 TVBox JS 源识别（cat.js / drpy ESM 格式），与引擎包格式
    /// 引擎包（CJS exports.start）区分。识别结果决定包内文件放置形态：
    /// TVBox 源存为 source.js（tvbox-js-host 运行时按文件数站点），
    /// 引擎包存为 index.js（cat-source-host.js require 启动）。
    nonisolated static func isTVBoxJSSource(_ text: String) -> Bool {
        // 强标记：FongMi / quickjs 全局形态。
        if text.contains("__jsEvalReturn") || text.contains("__JS_SPIDER__") { return true }
        // 引擎包信号（CJS 打包产物）：一票否决。引擎包的 esbuild 产物
        // 数 MB 大、尾部 export 互操作块常与 init/home 等词同现，宽松正则会误判
        // （曾把用户真实引擎包改写成 source.js 致源失效）；TVBox 沙箱源不可能
        // 包含这些——沙箱内没有 require，也不会调宿主注入的 catServerFactory。
        if text.contains("catServerFactory") || text.contains("module.exports") || text.contains("require(") {
            return false
        }
        // drpy ESM 形态：export default { init, home, category, ... }
        if text.range(of: "export\\s+default", options: .regularExpression) != nil,
           text.range(of: "\\b(home|homeVod|category|detail|search|playerContent|play)\\s*[:(]", options: .regularExpression) != nil {
            return true
        }
        // FongMi 导出形态：export { init, home, ... } / export function init...
        if text.range(of: "export\\s*(function|const|var|let|\\{)[\\s\\S]{0,600}\\b(init|home|homeVod|category|detail|search|play)\\b", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// TVBox 点播配置订阅识别：生态加密标记（2423 / 2324 / 8位**）或含 sites 的 JSON。
    nonisolated static func isTVBoxConfig(_ text: String) -> Bool {
        TVBoxConfigCrypto.isTVBoxConfig(text)
    }

    /// TVBox 配置的站点支持度盘点（与 cms-host 的分类规则一致）：
    /// 可支持 = type 0/1 CMS 直连 + type 3 远程 .js；jar(csp_/spider.jar) 本机不支持。
    nonisolated static func tvBoxConfigSiteSupport(_ configText: String) -> (total: Int, supported: Int, supportedNames: [String]) {
        guard let data = configText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sites = object["sites"] as? [[String: Any]] else {
            return (0, 0, [])
        }
        var total = 0
        var supported = 0
        var names: [String] = []
        for site in sites {
            guard let name = site["name"] as? String, !name.isEmpty,
                  let api = site["api"] as? String, !api.isEmpty else { continue }
            total += 1
            let type = (site["type"] as? NSNumber)?.intValue ?? 0
            if type == 3, api.lowercased().hasPrefix("csp_") { continue }
            if api.lowercased().hasSuffix(".jar") || api.lowercased().hasSuffix(".jar?") { continue }
            if type == 0 || type == 1, api.lowercased().hasPrefix("http") {
                supported += 1; names.append(name); continue
            }
            if type == 3, api.lowercased().hasPrefix("http"), api.lowercased().contains(".js") {
                supported += 1; names.append(name); continue
            }
        }
        return (total, supported, names)
    }

    /// 包体存在性：引擎包 index.js / TVBox 单文件源 source.js / TVBox 配置 config.json 任一在即可。
    private func hasPackageBody(at dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("index.js").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("source.js").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    func fetchData(_ url: URL, maxBytes: Int = BoundedDownloader.maxPackageBytes,
                   validate: @escaping @Sendable (Data) throws -> Void = { _ in }) async throws -> Data {
        let candidates = [url] + Self.mirrorCandidates(for: url)
        let session = self.session
        // 正常直连先启动；慢连接无需等 30 秒超时，备用线路分别在 1/2 秒后加入。
        // 每条线路单独校验，首个有效结果胜出，立即取消其他下载。
        return try await withThrowingTaskGroup(of: Result<Data, Error>.self) { group in
            defer { group.cancelAll() }
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    do {
                        if index > 0 {
                            try await Task.sleep(nanoseconds: UInt64(index) * 1_000_000_000)
                        }
                        try Task.checkCancellation()
                        let data = try await BoundedDownloader.fetch(candidate, session: session, maxBytes: maxBytes)
                        try validate(data)
                        return .success(data)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var lastError: Error = CatSourceError.badResponse("下载失败")
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let data): return data
                case .failure(let error): lastError = error
                }
            }
            throw lastError
        }
    }

    /// GitHub 直链的镜像候选（按优先级）：gh-proxy 前缀任意 GitHub 链接可用；
    /// jsdelivr 仅支持 raw.githubusercontent.com 的 user/repo/branch/path 简单形态。
    nonisolated static func mirrorCandidates(for url: URL) -> [URL] {
        var mirrors: [URL] = []
        let absolute = url.absoluteString
        if url.host == "raw.githubusercontent.com" || url.host == "github.com" {
            if let ghProxy = URL(string: "https://gh-proxy.org/" + absolute) {
                mirrors.append(ghProxy)
            }
        }
        if url.host == "raw.githubusercontent.com" {
            // raw.githubusercontent.com/{user}/{repo}/{branch}/{path} →
            // cdn.jsdelivr.net/gh/{user}/{repo}@{branch}/{path}（branch 含 / 时跳过）
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // GitHub raw 的多段 ref（refs/heads/main）无法映射到 jsdelivr 的 @branch 形态。
            if parts.count >= 4, parts[2] != "refs" {
                let joined = "https://cdn.jsdelivr.net/gh/\(parts[0])/\(parts[1])@\(parts.dropFirst(2).joined(separator: "/"))"
                if let jsdelivr = URL(string: joined) {
                    mirrors.append(jsdelivr)
                }
            }
        }
        return mirrors
    }

    private func fetchDataOnce(_ url: URL, maxBytes: Int = BoundedDownloader.maxPackageBytes) async throws -> Data {
        try await BoundedDownloader.fetch(url, session: session, maxBytes: maxBytes)
    }

    /// 启用/停用：停用激活中的包会停止引擎并清空站点状态。
    public func setEnabled(_ enabled: Bool, for subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].enabled = enabled
        persist()
        if !enabled, selectedSubscriptionID == subscription.id {
            activationRequestID = UUID()
            contentRequestID = UUID()
            runtime.stop()
            selectedSubscriptionID = nil
            lastActivatedID = nil
            defaults.removeObject(forKey: lastActivatedKey)
            sites = []
            selectedSiteID = nil
            categories = []
            selectedCategoryID = nil
            items = []
            statusMessage = "已停用「\(subscription.name)」"
        } else if enabled {
            statusMessage = "已启用「\(subscription.name)」，正在启动引擎"
            let updated = subscriptions[index]
            Task { await activate(updated) }
        }
    }

    /// 更新订阅包：从源地址重新下载最新内容；激活中的包自动重启引擎。
    /// C2-1：.md5 订阅远端哈希未变时跳过下载（快路径）。
    /// C2-5：包有更新且引擎在跑时走热重载（不杀进程），失败回退全量重启。
    public func updateSubscription(_ subscription: Subscription) async throws {
        let current = subscriptions.first(where: { $0.id == subscription.id }) ?? subscription
        let result = try await downloadPackage(for: current)
        scheduleSourceBackup()
        if result == .unchanged {
            statusMessage = "「\(current.name)」已是最新"
            return
        }
        statusMessage = "已更新「\(current.name)」，正在热重载…"
        #if os(macOS)
        if selectedSubscriptionID == current.id, runtime.isRunning, let nodeRuntime = runtime as? CatSourceEngineRuntime {
            do {
                try await nodeRuntime.reload()
                await reloadActiveSourceState()
                statusMessage = "已更新「\(current.name)」并热重载完成"
            } catch {
                statusMessage = "热重载失败（\(error.localizedDescription)），回退全量重启…"
                runtime.stop()
                await activate(current)
            }
        } else if selectedSubscriptionID == current.id {
            runtime.stop()
            await activate(current)
        } else {
            statusMessage = "已更新「\(current.name)」至最新"
        }
        #else
        // iOS/tvOS：无 Node 热重载通道；包已更新，全量重启引擎即可生效。
        if selectedSubscriptionID == current.id {
            runtime.stop()
            await activate(current)
        }
        #endif
    }

    /// 热重载后刷新站点/首页状态（引擎端口可能已变化，config 需重取）。
    private func reloadActiveSourceState() async {
        guard runtime.isRunning else { return }
        do {
            let config = try await runtime.client().config()
            sites = config.sites
            if let preferred = preferredContentSite(in: sites) {
                await selectSite(preferred.id)
            }
        } catch {
            engineError = "热重载后读取站点失败：\(error.localizedDescription)"
        }
    }

    /// 刷新当前订阅所加载的站点与首页数据，不修改源包文件。
    public func refreshSubscriptionCache(_ subscription: Subscription) async {
        if selectedSubscriptionID != subscription.id || !runtime.isRunning {
            await activate(subscription)
            return
        }
        guard let selectedSiteID else {
            await activate(subscription)
            return
        }
        await selectSite(selectedSiteID)
        statusMessage = "已刷新「\(subscription.name)」的站点缓存"
    }

    /// 下拉刷新订阅浏览页当前站点/分类的数据，不重新下载本地订阅包。
    public func refreshCurrentContent() async {
        guard !isLoading else { return }
        engineError = nil
        guard let siteID = selectedSiteID, route(for: siteID) != nil else {
            if let subscription = selectedSubscription ?? subscriptions.first(where: \.isEnabled) {
                await activate(subscription)
            } else {
                restoreIfNeeded()
            }
            return
        }

        if let categoryID = selectedCategoryID {
            await selectCategory(categoryID)
        } else {
            await selectSite(siteID)
        }
        if engineError == nil {
            statusMessage = "已更新当前分类"
        }
    }

    /// 重命名订阅包（不改包目录，仅展示名）。
    public func renameSubscription(_ subscription: Subscription, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].name = trimmed
        persist()
        statusMessage = "已重命名为「\(trimmed)」"
    }

    /// 订阅聚合开关（资源库长按菜单「停用/启用聚合」）。
    public func setSubscriptionEnabled(_ subscription: Subscription, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].enabled = enabled
        persist()
        if !enabled, selectedSubscriptionID == subscription.id {
            activationRequestID = UUID()
            contentRequestID = UUID()
            runtime.stop()
            selectedSubscriptionID = nil
            lastActivatedID = nil
            defaults.removeObject(forKey: lastActivatedKey)
            sites = []
            selectedSiteID = nil
            categories = []
            selectedCategoryID = nil
            items = []
        }
        statusMessage = enabled ? "已启用「\(subscription.name)」聚合" : "已停用「\(subscription.name)」聚合"
    }

    public func removeSubscription(_ subscription: Subscription) {        if selectedSubscriptionID == subscription.id {
            activationRequestID = UUID()
            contentRequestID = UUID()
            runtime.stop()
            selectedSubscriptionID = nil
            lastActivatedID = nil
            defaults.removeObject(forKey: lastActivatedKey)
            sites = []
            selectedSiteID = nil
            categories = []
            selectedCategoryID = nil
            items = []
        }
        // 多源管理：无论是否活动引擎，该订阅自己的引擎都要停掉并移出多源池。
        if let engine = catEngine(for: subscription.id) {
            engine.runtime.stop()
            catEngines.removeAll { $0.id == subscription.id }
        }
        try? FileManager.default.removeItem(at: packageDirectory(for: subscription.id))
        subscriptions.removeAll { $0.id == subscription.id }
        persist()
    }

    /// 历史恢复：确保对应订阅已激活、站点已选。
    public func activateStoredSubscription(loadHome: Bool = true) async {
        if runtime.isRunning, selectedSubscriptionID != nil { return }
        guard let id = lastActivatedID,
              let subscription = subscriptions.first(where: { $0.id == id }) else { return }
        await activate(subscription, loadHome: loadHome)
    }

    public func restoreSite(itemSiteID: String) async -> Bool {
        if selectedSiteID == itemSiteID, !items.isEmpty { return true }
        await selectSite(itemSiteID)
        return selectedSiteID == itemSiteID
    }

    /// 播放历史恢复只需站点初始化，不需要先请求首页与分类列表。
    public func prepareSiteForPlayback(itemSiteID: String) async -> Bool {
        guard let target = route(for: itemSiteID) else {
            statusMessage = "历史记录对应的视频站点未加载，请重新启用原视频源"
            return false
        }
        if selectedSiteID == itemSiteID { return true }
        let requestID = UUID()
        contentRequestID = requestID
        selectedSiteID = itemSiteID
        if let subID = selectedSubscriptionID?.uuidString {
            defaults.set("\(subID)|\(itemSiteID)", forKey: persistenceKey + ".lastSite")
        }
        isLoading = true
        statusMessage = nil
        defer { if contentRequestID == requestID { isLoading = false } }
        do {
            try await target.client.initializeSiteForDiagnostics(apiPath: target.apiPath)
            statusMessage = nil
            return contentRequestID == requestID && selectedSiteID == itemSiteID
        } catch {
            guard contentRequestID == requestID else { return false }
            statusMessage = "恢复播放时初始化站点失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 激活订阅：启动引擎 → 读站点 → 默认加载第一个站点的首页。
    public func activate(_ subscription: Subscription, forceReload: Bool = false, loadHome: Bool = true) async {
        // 同一订阅且引擎已健康：不打断正在填充当前页面的请求。
        if !forceReload, runtime.isRunning, selectedSubscriptionID == subscription.id, !sites.isEmpty {
            if loadHome, selectedSiteID == nil, let preferred = preferredContentSite(in: sites) {
                await selectSite(preferred.id)
            }
            return
        }
        // 首页/分类请求不应阻塞源切换；旧内容响应由 contentRequestID 拦截。
        // 已就绪的池内引擎也可直接切换，同时避免启动阶段重复创建同一引擎。
        let canReuseEngine = !forceReload && catEngine(for: subscription.id)?.runtime.isRunning == true
        let currentEngineReady = runtime.isRunning && !sites.isEmpty
        guard !isLoading || canReuseEngine || currentEngineReady else {
            debugLog("activate skipped while another subscription is loading: \(subscription.name)")
            return
        }
        let previousRuntime = runtime
        let previousSubscriptionID = selectedSubscriptionID
        let previousLastActivatedID = lastActivatedID
        let previousSites = sites
        let previousSiteID = selectedSiteID
        let previousCategories = categories
        let previousCategoryID = selectedCategoryID
        let previousItems = items
        let previousFilters = homeFilters
        var startingRuntime: (any CatEngineRuntimeProtocol)?
        let requestID = UUID()
        activationRequestID = requestID
        contentRequestID = UUID()
        guard subscription.isEnabled else {
            engineError = "「\(subscription.name)」已停用；启用后再切换"
            return
        }

        // 立即切换页面归属并清掉上一包的站点/内容；即使目标源需要重新
        // 下载包体，左上角也不会继续显示旧源，且旧页面数据不会短暂残留。
        selectedSubscriptionID = subscription.id
        lastActivatedID = subscription.id
        defaults.set(subscription.id.uuidString, forKey: lastActivatedKey)
        sites = []
        selectedSiteID = nil
        categories = []
        selectedCategoryID = nil
        items = []
        homeFilters = [:]
        engineError = nil
        isLoading = true

        // 自愈：包体缺失（应用数据迁移/清理）时按订阅地址重新下载。
        let dir = packageDirectory(for: subscription.id)
        defer {
            if activationRequestID == requestID { isLoading = false }
        }
        do {
            // 快路径：该订阅的引擎已在多源池中运行 → 直接提为活动引擎（不重启进程）。
            if !forceReload, let engine = catEngine(for: subscription.id), engine.runtime.isRunning,
               let base = engine.runtime.baseURL {
                runtime = engine.runtime
                sites = prefixedCatSites(engine)
                debugLog("activate: reusing running engine for \(subscription.name) at \(base.path)")
                if loadHome, let preferred = preferredContentSite(in: sites) {
                    await selectSite(preferred.id)
                }
                return
            }
            if !hasPackageBody(at: dir) {
                try await downloadPackage(for: subscription)
                guard activationRequestID == requestID else { return }
            }
            debugLog("activate: starting engine at \(dir.path)")
            // 多源隔离：启动本订阅自己的引擎进程；其他引擎保持运行不受影响。
            // 运行时按 包型+平台 选择：config.json → iOS/tvOS 用原生引擎（无 Node）；
            // macOS 仍走 Node 宿主。index.js / source.js / .py 需 Node/Python（iOS 暂缺）。
            let engineRuntime: any CatEngineRuntimeProtocol
            if let pooled = catEngine(for: subscription.id)?.runtime {
                engineRuntime = pooled
            } else if let native = Self.makeRuntime(packageDir: dir) {
                engineRuntime = native
            } else {
                engineRuntime = CatSourceEngineRuntime()
            }
            if let nodeRuntime = engineRuntime as? CatSourceEngineRuntime {
                bindToastForwarding(nodeRuntime)
            }
            startingRuntime = engineRuntime
            try await engineRuntime.start(packageDir: dir, pythonExtend: nil)
            guard activationRequestID == requestID else {
                engineRuntime.stop()
                return
            }
            runtime = engineRuntime
            debugLog("activate: engine started, port=\(engineRuntime.port.map(String.init) ?? "nil")")
            let config = try await engineRuntime.client().config()
            guard activationRequestID == requestID else { return }
            debugLog("activate: config ok, sites=\(config.sites.count)")
            let engine = CatEngine(
                id: subscription.id,
                name: subscription.name,
                rawSites: config.sites,
                runtime: engineRuntime,
                enabled: subscription.enabled,
                lastActivatedAt: Date()
            )
            if let index = catEngines.firstIndex(where: { $0.id == subscription.id }) {
                catEngines[index] = engine
            } else {
                catEngines.append(engine)
            }
            pruneCatEngines(activeID: subscription.id)
            sites = prefixedCatSites(engine)
            if loadHome, let preferred = preferredContentSite(in: sites) {
                await selectSite(preferred.id)
            }
        } catch {
            guard activationRequestID == requestID else { return }
            if let startingRuntime, startingRuntime !== previousRuntime { startingRuntime.stop() }
            runtime = previousRuntime
            selectedSubscriptionID = previousRuntime.isRunning ? previousSubscriptionID : nil
            sites = previousRuntime.isRunning ? previousSites : []
            selectedSiteID = previousRuntime.isRunning ? previousSiteID : nil
            categories = previousRuntime.isRunning ? previousCategories : []
            selectedCategoryID = previousRuntime.isRunning ? previousCategoryID : nil
            items = previousRuntime.isRunning ? previousItems : []
            homeFilters = previousRuntime.isRunning ? previousFilters : [:]
            lastActivatedID = previousLastActivatedID
            if let previousLastActivatedID {
                defaults.set(previousLastActivatedID.uuidString, forKey: lastActivatedKey)
            } else {
                defaults.removeObject(forKey: lastActivatedKey)
            }
            debugLog("activate FAILED: \(error)")
            engineError = error.localizedDescription
        }
    }

    /// 按包型+平台选择运行时：config.json 在 iOS/tvOS 用原生引擎（无 Node 依赖）；
    /// 其余包型（index.js / source.js / .py）在 iOS/tvOS 无对应运行时，返回 CatSourceEngineRuntime
    ///（start 时会以「未找到 Node 运行时」等明确报错）。
    /// iOS/tvOS：JS 引擎包运行时由宿主注入的 nodejs-mobile 工厂创建
    /// （App 启动时设置；未设置 = 运行时未集成，回落 CatSourceEngineRuntime 报明确错误）。
    public static var nodeRuntimeFactory: (() -> (any CatEngineRuntimeProtocol)?)?

    private static func makeRuntime(packageDir: URL) -> (any CatEngineRuntimeProtocol)? {
        #if os(iOS) || os(tvOS)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: packageDir.path)) ?? []
        let hasNodeEngine = files.contains("index.js") || files.contains("source.js")
        let hasTVBoxConfig = files.contains("config.json")
        if hasTVBoxConfig && !hasNodeEngine {
            return NativeEngineRuntime()
        }
        if hasNodeEngine || (hasTVBoxConfig && hasNodeEngine), let injected = nodeRuntimeFactory?() {
            return injected
        }
        return nil
        #else
        return nil
        #endif
    }

    /// 存活引擎超过上限时，停掉最久未用的非活动引擎（多源管理资源护栏）。
    private func pruneCatEngines(activeID: UUID) {
        let running = catEngines.filter { $0.runtime.isRunning && $0.id != activeID }
        guard running.count >= Self.maxRunningCatEngines else { return }
        let victim = running.min { $0.lastActivatedAt < $1.lastActivatedAt } ?? running[0]
        victim.runtime.stop()
        if let index = catEngines.firstIndex(where: { $0.id == victim.id }) {
            catEngines[index].lastActivatedAt = .distantPast
        }
        debugLog("activate: LRU 停用引擎「\(victim.name)」（并发上限 \(Self.maxRunningCatEngines)）")
    }

    /// 默认站点选择：跳过功能/网盘文件/纯搜索站，优先豆瓣类影视内容站。
    /// 神秘包 config.sites.first 是豆瓣（推荐位），但部分包顺序不同，这里按名称规则兜底。
    private func preferredContentSite(in sites: [CatSourceSite]) -> CatSourceSite? {
        func isFunctional(_ name: String) -> Bool {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.hasPrefix("「设」") || n.hasPrefix("「自」") || n.hasPrefix("「推」")
                || n.hasPrefix("「我」") || n.contains("版本") || n.contains("本地JS")
        }
        func isPureDriveOrSearch(_ name: String) -> Bool {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.hasPrefix("「搜」") { return true }
            if n.contains("我的") || n.contains("网盘") { return true }
            return false
        }
        if let douban = sites.first(where: { $0.name.contains("豆瓣") }) { return douban }
        return sites.first(where: { !isFunctional($0.name) && !isPureDriveOrSearch($0.name) })
            ?? sites.first
    }

    public func selectSite(_ siteID: String) async {
        let requestID = UUID()
        contentRequestID = requestID
        selectedSiteID = siteID
        engineError = nil
        if let subID = selectedSubscriptionID?.uuidString {
            defaults.set("\(subID)|\(siteID)", forKey: persistenceKey + ".lastSite")
        }
        // 不清空旧 categories/items：新站数据到达前保留旧网格（顶栏转圈 + 分类行锁定），
        // 消灭"切站点白屏闪烁"；结果仍由 contentRequestID 竞态保护。
        isSwitchingSite = true
        isLoading = true
        defer {
            // 站点状态属于本次站点切换，不应跟随首页内容 request ID。
            // 首页完成后 selectCategory 会替换 contentRequestID；若在这里也用它
            // 判断，站点切换状态会永远不清除，分类栏随之永久禁用。
            if selectedSiteID == siteID {
                isSwitchingSite = false
            }
            if contentRequestID == requestID {
                isLoading = false
            }
        }
        guard let target = route(for: siteID) else { return }
        do {
            await target.client.initSite(apiPath: target.apiPath)
            guard contentRequestID == requestID, selectedSiteID == siteID else { return }
            let result = try await target.client.home(apiPath: target.apiPath)
            guard contentRequestID == requestID, selectedSiteID == siteID else { return }
            debugLog("selectSite \(siteID): cats=\(result.categories.count) items=\(result.items.count)")
            categories = result.categories
            homeFilters = result.filters
            items = result.items
            markSiteHealthy(siteID)
            // 首分类自动加载：无条件调用（selectCategory 自带 contentRequestID 竞态保护）。
            // 此前的 contentRequestID 门会被首页其它任务（榜单/续播）重置而拦下这次调用，
            // 导致「home 空推荐」型源（如豆瓣）首屏永远空白，用户误判为源不可用。
            if let first = categories.first {
                await selectCategory(first.id)
            }
        } catch {
            guard contentRequestID == requestID else { return }
            debugLog("selectSite FAILED: \(error)")
            engineError = error.localizedDescription
            markSiteFailed(siteID, error.localizedDescription)
        }
    }

    public func selectCategory(_ categoryID: String) async {
        guard let selected = selectedSiteID, let target = route(for: selected) else {
            debugLog("selectCategory \(categoryID): 无路由 selected=\(selectedSiteID ?? "nil")")
            return
        }
        let requestID = UUID()
        contentRequestID = requestID
        selectedCategoryID = categoryID
        engineError = nil
        isLoading = true
        defer {
            if contentRequestID == requestID { isLoading = false }
        }
        do {
            let results = try await target.client.category(
                apiPath: target.apiPath,
                categoryID: categoryID,
                page: 1,
                filters: selectedCategoryFilters(categoryID: categoryID)
            )
            guard contentRequestID == requestID, selectedSiteID == selected else { return }
            items = results
            debugLog("selectCategory \(selected)/\(categoryID): items=\(results.count)")
            markSiteHealthy(selected)
        } catch {
            guard contentRequestID == requestID else { return }
            debugLog("selectCategory \(selected)/\(categoryID) FAILED: \(error)")
            engineError = error.localizedDescription
            markSiteFailed(selected, error.localizedDescription)
        }
    }

    /// 分类筛选值（来自 home 的 filters；当前 UI 未展示筛选面板时取各组的 init 值）。
    private func selectedCategoryFilters(categoryID: String) -> [String: String] {
        var result: [String: String] = [:]
        for group in homeFilters[categoryID] ?? [] where !group.key.isEmpty {
            result[group.key] = group.initValue ?? group.options.first?.value ?? ""
        }
        return result
    }

    public func search(keyword: String) async {
        guard let selected = selectedSiteID, let target = route(for: selected), !keyword.isEmpty else { return }
        let requestID = UUID()
        contentRequestID = requestID
        isLoading = true
        defer {
            if contentRequestID == requestID { isLoading = false }
        }
        do {
            let results = try await target.client.search(apiPath: target.apiPath, keyword: keyword)
            guard contentRequestID == requestID, selectedSiteID == selected else { return }
            items = results
        } catch {
            guard contentRequestID == requestID else { return }
            engineError = error.localizedDescription
        }
    }

    /// 聚合搜索结果打开：切换站点（含 py 源）→ 加载详情 → 返回详情。
    public func selectSiteForDetail(siteName: String, item: CatSourceItem) async -> CatSourceDetail? {
        let siteID = sites.first(where: { $0.name == siteName })?.id
            ?? pyEngines.flatMap(\.sites).first(where: { $0.name == siteName })?.id
        guard let siteID else { return nil }
        await selectSite(siteID)
        return try? await loadDetail(itemID: item.id)
    }

    /// 聚合搜索前置：确保「当前启用订阅」的引擎与站点列表就绪。
    /// 首页推荐卡可直达搜索页，此时订阅页可能从未打开（引擎未启动、站点为空，
    /// searchAllSites 会空转返回零结果）。这里做**轻激活**：只启动引擎拉站点列表，
    /// 不加载站点首页/分类网格（那是订阅页浏览的前置，由 restoreIfNeeded 回来时补），
    /// 让搜索请求尽早发出。引擎已在启动中则等站点到位即可。
    public var hasRunningEngine: Bool {
        runtime.isRunning || pyEngines.contains { $0.runtime.isRunning }
    }

    public func ensureSearchReady() async {
        if runtime.isRunning {
            for _ in 0..<50 where sites.isEmpty && runtime.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        let target = lastActivatedID.flatMap { id in
            subscriptions.first(where: { $0.id == id && $0.isEnabled })
        } ?? subscriptions.first(where: \.isEnabled)
        guard let target else { return }
        let requestID = UUID()
        activationRequestID = requestID
        selectedSubscriptionID = target.id
        lastActivatedID = target.id
        defaults.set(target.id.uuidString, forKey: lastActivatedKey)
        sites = []
        selectedSiteID = nil
        engineError = nil
        isLoading = true
        defer { if activationRequestID == requestID { isLoading = false } }
        do {
            let dir = packageDirectory(for: target.id)
            if !hasPackageBody(at: dir) {
                try await downloadPackage(for: target)
                guard activationRequestID == requestID else { return }
            }
            try await runtime.start(packageDir: dir, pythonExtend: nil)
            guard activationRequestID == requestID else { return }
            let config = try await runtime.client().config()
            guard activationRequestID == requestID else { return }
            sites = config.sites
        } catch {
            guard activationRequestID == requestID else { return }
            engineError = error.localizedDescription
        }
    }

    /// 聚合搜索目标：当前订阅全部可搜索站点（含 py 源）。
    /// 聚合搜索目标：slow = 慢车道（py 源与「盘」聚合站——单站 5-20s，独立限流，
    /// 慢站独立限流：慢车道不挤占快车道并发额度）。
    struct FanOutTarget {
        let name: String
        let apiPath: String
        let client: CatSourceClient
        let slow: Bool
    }

    private func fanOutTargets() -> [FanOutTarget] {
        var targets: [FanOutTarget] = []
        // 多源聚合：全部在跑的猫源引擎（活动引擎已在池内，避免重复）。
        for engine in catEngines where engine.runtime.isRunning && engine.isEnabled {
            guard let base = engine.runtime.baseURL else { continue }
            let client = engine.runtime.client()
            for site in prefixedCatSites(engine) where site.isSearchable {
                targets.append(FanOutTarget(name: site.name, apiPath: site.apiPath, client: client,
                                            slow: site.name.hasPrefix("「盘」")))
            }
        }
        if runtime.isRunning, !catEngines.contains(where: { $0.runtime === runtime }) {
            let client = runtime.client()
            for site in sites where site.isSearchable {
                targets.append(FanOutTarget(name: site.name, apiPath: site.apiPath, client: client,
                                            slow: site.name.hasPrefix("「盘」")))
            }
        }
        for engine in pyEngines where engine.runtime.isRunning {
            guard engine.runtime.baseURL != nil else { continue }
            for pySite in engine.sites where pySite.isSearchable {
                targets.append(FanOutTarget(name: pySite.name, apiPath: pySite.apiPath,
                                            client: engine.runtime.client(), slow: true))
            }
        }
        return targets
    }

    /// 并发聚合搜索公共实现（双车道 + 全局时限/条数上限）：
    /// - 双车道：快车道 12 并发（猫源直连站），慢车道 4 并发（py 源 /「盘」站）；
    /// - 全局 90s 总时限：到期后不再派发新站，在途站点自然收尾；
    /// - 条数上限：全局 5000、单站 500（超限即停派发/截断）。
    /// 每完成一站回调一次供渐进渲染。
    private func runFanOutSearch(
        targets: [FanOutTarget],
        keyword: String,
        onSiteCompleted: @escaping (String, [CatSourceItem]) -> Void
    ) async {
        let ordered = targets.enumerated().sorted { lhs, rhs in
            let lhsPan = lhs.element.name.hasPrefix("「盘」")
            let rhsPan = rhs.element.name.hasPrefix("「盘」")
            if lhsPan != rhsPan { return rhsPan }
            return lhs.offset < rhs.offset
        }
        .map(\.element)

        let keywordCopy = keyword
        let deadline = Date().addingTimeInterval(90)
        let fastLimit = 12
        let slowLimit = 4
        let totalItemLimit = 5000
        let perSiteItemLimit = 500
        var totalItems = 0
        await withTaskGroup(of: (Bool, AggregateGroup?).self) { group in
            var fastInFlight = 0
            var slowInFlight = 0
            var pending = ordered

            func addNext() {
                guard Date() < deadline, totalItems < totalItemLimit else { return }
                // 从队首找第一条有空闲车道的目标（慢车道满时快车道目标不受阻）。
                guard let index = pending.firstIndex(where: { target in
                    target.slow ? slowInFlight < slowLimit : fastInFlight < fastLimit
                }) else { return }
                let target = pending.remove(at: index)
                if target.slow { slowInFlight += 1 } else { fastInFlight += 1 }
                group.addTask {
                    var items = (try? await target.client.search(
                        apiPath: target.apiPath, keyword: keywordCopy, timeout: 12
                    )) ?? []
                    if items.count > perSiteItemLimit {
                        items = Array(items.prefix(perSiteItemLimit))
                    }
                    return (target.slow, items.isEmpty ? nil : AggregateGroup(siteName: target.name, items: items))
                }
            }

            addNext()
            for await (wasSlow, result) in group {
                if wasSlow { slowInFlight -= 1 } else { fastInFlight -= 1 }
                if let result {
                    totalItems += result.items.count
                    onSiteCompleted(result.siteName, result.items)
                }
                addNext()
            }
        }
    }

    /// 聚合搜索：遍历当前订阅包全部可搜索站点（含 py 源）并发搜索，渐进返回。
    public func searchAllSites(
        keyword: String,
        onSiteCompleted: @escaping (String, [CatSourceItem]) -> Void
    ) async {
        guard !keyword.isEmpty else { return }
        await runFanOutSearch(targets: fanOutTargets(), keyword: keyword, onSiteCompleted: onSiteCompleted)
    }

    /// 与搜索结果同一套已运行源范围，保留真实站点身份，供媒体详情页展示聚合资源。
    public func searchMatches(keyword: String) async -> [(site: CatSourceSite, item: CatSourceItem)] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let targets = fanOutSiteTargets()
        let query = keyword
        let deadline = Date().addingTimeInterval(90)
        let fastLimit = 12
        let slowLimit = 4
        let totalItemLimit = 5000
        let perSiteItemLimit = 500
        var totalItems = 0
        return await withTaskGroup(of: (Bool, CatSourceSite, [CatSourceItem]).self, returning: [(site: CatSourceSite, item: CatSourceItem)].self) { group in
            var fastInFlight = 0
            var slowInFlight = 0
            var pending = targets
            var collected: [(CatSourceSite, [CatSourceItem])] = []

            func addNext() {
                guard Date() < deadline, totalItems < totalItemLimit else { return }
                guard let index = pending.firstIndex(where: { target in
                    target.slow ? slowInFlight < slowLimit : fastInFlight < fastLimit
                }) else { return }
                let target = pending.remove(at: index)
                if target.slow { slowInFlight += 1 } else { fastInFlight += 1 }
                group.addTask {
                    var items = (try? await target.client.search(
                        apiPath: target.site.apiPath, keyword: query, timeout: 12
                    )) ?? []
                    if items.count > perSiteItemLimit {
                        items = Array(items.prefix(perSiteItemLimit))
                    }
                    return (target.slow, target.site, items)
                }
            }

            addNext()
            for await (wasSlow, site, items) in group {
                if wasSlow { slowInFlight -= 1 } else { fastInFlight -= 1 }
                if !items.isEmpty {
                    totalItems += items.count
                    collected.append((site, items))
                }
                addNext()
            }
            return collected.flatMap { (site: CatSourceSite, items: [CatSourceItem]) in
                items.map { (site: site, item: $0) }
            }
        }
    }

    /// 将聚合命中还原到所属运行时，避免多订阅下详情和播放误走当前活动源。
    public func client(for site: CatSourceSite) -> CatSourceClient? {
        if let engine = pyEngines.first(where: { $0.sites.contains(where: { $0.id == site.id }) }) {
            return engine.runtime.client()
        }
        let components = site.id.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "cat",
           let engineID = UUID(uuidString: String(components[1])),
           let engine = catEngines.first(where: { $0.id == engineID }) {
            return engine.runtime.client()
        }
        if sites.contains(where: { $0.id == site.id }) { return runtime.client() }
        return nil
    }

    /// 返回站点所属引擎的 /website 地址；多猫源时按站点前缀定位，不能误用当前活动源的端口。
    public func websiteURL(for site: CatSourceSite) -> URL? {
        if let engine = pyEngines.first(where: { $0.sites.contains(where: { $0.id == site.id }) }) {
            return engine.runtime.websiteURL
        }
        let components = site.id.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "cat",
           let engineID = UUID(uuidString: String(components[1])),
           let engine = catEngines.first(where: { $0.id == engineID }) {
            return engine.runtime.websiteURL
        }
        guard sites.contains(where: { $0.id == site.id }) else { return nil }
        return runtime.websiteURL
    }

    private func fanOutSiteTargets() -> [(site: CatSourceSite, client: CatSourceClient, slow: Bool)] {
        var targets: [(site: CatSourceSite, client: CatSourceClient, slow: Bool)] = []
        for engine in catEngines where engine.runtime.isRunning && engine.isEnabled {
            targets.append(contentsOf: prefixedCatSites(engine).filter(\.isSearchable)
                .map { ($0, engine.runtime.client(), $0.name.hasPrefix("「盘」")) })
        }
        if runtime.isRunning, !catEngines.contains(where: { $0.runtime === runtime }) {
            targets.append(contentsOf: sites.filter(\.isSearchable)
                .map { ($0, runtime.client(), $0.name.hasPrefix("「盘」")) })
        }
        for engine in pyEngines where engine.runtime.isRunning && engine.isEnabled {
            targets.append(contentsOf: engine.sites.filter(\.isSearchable)
                .map { ($0, engine.runtime.client(), true) })
        }
        return targets
    }

    /// 豆瓣等浏览型条目的云盘聚合搜索：按片名跨站搜索，结果按站点分组。
    /// 命中站点实时追加（按命中数排序），避免串行超时造成的长时间无响应。
    public func aggregateSearch(keyword: String) async {
        guard !keyword.isEmpty else { return }
        isAggregating = true
        aggregateGroups = []
        defer { isAggregating = false }
        await runFanOutSearch(targets: fanOutTargets(), keyword: keyword) { siteName, items in
            self.aggregateGroups.append(AggregateGroup(siteName: siteName, items: items))
            self.aggregateGroups.sort { $0.items.count > $1.items.count }
        }
    }

    public func loadDetail(itemID: String) async throws -> CatSourceDetail {
        // 详情缓存命中（内存/磁盘且未过期）直接返回：二次点开同一卡片秒开。
        if let cached = cachedDetail(itemID: itemID) { return cached }
        guard let selected = selectedSiteID, let target = route(for: selected) else { throw CatSourceError.engineNotRunning }
        let key = detailCacheKey(itemID)
        let requestKey = key + "|" + target.client.baseURL.absoluteString
        let pending: PendingSourceRequest<CatSourceDetail>
        if let existing = pendingDetails[requestKey] {
            pending = existing
        } else {
            pending = PendingSourceRequest(id: UUID(), task: Task {
                try await target.client.detail(apiPath: target.apiPath, itemID: itemID)
            })
            pendingDetails[requestKey] = pending
        }
        defer { if pendingDetails[requestKey]?.id == pending.id { pendingDetails.removeValue(forKey: requestKey) } }
        let detail = try await pending.task.value
        try Task.checkCancellation()
        guard selectedSiteID == selected else { throw CancellationError() }
        guard !detail.episodes.isEmpty else { return detail }
        storeCachedDetail(detail, key: key)
        return detail
    }

    // MARK: 详情缓存（内存 LRU + 磁盘 JSON/TTL；对齐引擎包"详情随包缓存"惯例）

    private var detailMemoryCache: [String: CachedDetailWrapper] = [:]
    private struct PendingSourceRequest<Value: Sendable> {
        let id: UUID
        let task: Task<Value, Error>
    }
    private var pendingDetails: [String: PendingSourceRequest<CatSourceDetail>] = [:]
    private var pendingPlayResults: [String: PendingSourceRequest<CatSourcePlayResult>] = [:]
    private var detailMemoryOrder: [String] = []
    private let detailMemoryCacheLimit = 80
    private let detailCacheTTL: TimeInterval = 6 * 3600

    private func detailCacheKey(_ itemID: String) -> String {
        Self.scopedCacheKey([selectedSiteID ?? "-", itemID])
    }

    nonisolated static func scopedCacheKey(_ components: [String]) -> String {
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func detailCacheFile(_ key: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HitPlay", isDirectory: true)
            .appendingPathComponent("DetailCache", isDirectory: true)
            .appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    public func cachedDetail(itemID: String) -> CatSourceDetail? {
        let key = detailCacheKey(itemID)
        if let hit = detailMemoryCache[key] {
            if Date().timeIntervalSince(hit.fetchedAt) < detailCacheTTL {
                rememberDetailInMemory(hit, key: key)
                return hit.detail
            }
            detailMemoryCache.removeValue(forKey: key)
            detailMemoryOrder.removeAll { $0 == key }
        }
        let file = detailCacheFile(key)
        guard let data = try? Data(contentsOf: file),
              let wrapper = try? JSONDecoder().decode(CachedDetailWrapper.self, from: data),
              Date().timeIntervalSince(wrapper.fetchedAt) < detailCacheTTL else { return nil }
        rememberDetailInMemory(wrapper, key: key)
        return wrapper.detail
    }

    private func storeCachedDetail(_ detail: CatSourceDetail, key: String) {
        let wrapper = CachedDetailWrapper(fetchedAt: Date(), detail: detail)
        rememberDetailInMemory(wrapper, key: key)
        // 磁盘写入放后台线程；写临时文件再改名，避免半截 JSON。
        let file = detailCacheFile(key)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(wrapper) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func rememberDetailInMemory(_ wrapper: CachedDetailWrapper, key: String) {
        detailMemoryCache[key] = wrapper
        detailMemoryOrder.removeAll { $0 == key }
        detailMemoryOrder.append(key)
        while detailMemoryOrder.count > detailMemoryCacheLimit {
            let evicted = detailMemoryOrder.removeFirst()
            detailMemoryCache.removeValue(forKey: evicted)
        }
    }

    /// 悬停/可见性预取：命中缓存直接返回；未命中静默拉一次详情。
    public func prefetchDetail(itemID: String) async {
        if cachedDetail(itemID: itemID) != nil { return }
        _ = try? await loadDetail(itemID: itemID)
    }

    private struct CachedDetailWrapper: Codable {
        let fetchedAt: Date
        let detail: CatSourceDetail
    }

    // MARK: 播放地址预取缓存（首集秒播；短 TTL 防地址失效）

    private var playResultCache: [String: (result: CatSourcePlayResult, at: Date)] = [:]
    private let playResultCacheTTL: TimeInterval = 10 * 60

    private func playResultCacheKey(_ detail: CatSourceDetail, _ episode: CatSourceEpisode) -> String {
        Self.scopedCacheKey([selectedSiteID ?? "-", detail.detailID, episode.flag, episode.playKey])
    }

    public func prefetchFirstPlay(detail: CatSourceDetail) async {
        guard let first = detail.episodes.first else { return }
        let key = playResultCacheKey(detail, first)
        if let hit = playResultCache[key], Date().timeIntervalSince(hit.at) < playResultCacheTTL { return }
        // resolvePlay 成功后会把直连地址写入 playResultCache，这里只负责触发。
        _ = try? await resolvePlay(detail: detail, episode: first, bypassCache: false)
    }

    private func rememberPlayResult(_ result: CatSourcePlayResult, key: String) {
        playResultCache[key] = (result, Date())
        if playResultCache.count > 24 {
            if let oldest = playResultCache.min(by: { $0.value.at < $1.value.at })?.key {
                playResultCache.removeValue(forKey: oldest)
            }
        }
    }

    public func resolvePlay(detail: CatSourceDetail, episode: CatSourceEpisode, bypassCache: Bool = false) async throws -> CatSourcePlayResult {
        guard let selected = selectedSiteID, let target = route(for: selected) else { throw CatSourceError.engineNotRunning }
        let key = playResultCacheKey(detail, episode)
        if !bypassCache, let hit = playResultCache[key], Date().timeIntervalSince(hit.at) < playResultCacheTTL {
            return Self.hlsAdCleaned(hit.result)
        }
        let requestKey = key + "|" + target.client.baseURL.absoluteString
        let pending: PendingSourceRequest<CatSourcePlayResult>
        if !bypassCache, let existing = pendingPlayResults[requestKey] {
            pending = existing
        } else {
            pending = PendingSourceRequest(id: UUID(), task: Task {
                try await target.client.play(apiPath: target.apiPath, flag: episode.flag, playKey: episode.playKey)
            })
            pendingPlayResults[requestKey] = pending
        }
        defer { if pendingPlayResults[requestKey]?.id == pending.id { pendingPlayResults.removeValue(forKey: requestKey) } }
        let result = try await pending.task.value
        try Task.checkCancellation()
        guard selectedSiteID == selected else { throw CancellationError() }
        // 只缓存直连地址；需要外部解析的结果缓存了也没意义。
        if !result.isParseRequired, pendingPlayResults[requestKey]?.id == pending.id {
            rememberPlayResult(result, key: key)
        }
        return Self.hlsAdCleaned(result)
    }

    /// 猫源直链 HLS 去广告（三重检测）：VOD m3u8 包装为
    /// 本地清理代理 capability URL；代理清理失败时 302 回原地址自动降级。
    /// 缓存里始终保存原始地址——代理上下文闲置 2 小时回收，长期缓存的代理
    /// 地址不可靠；包装只发生在返回值上。开关：hitplay.hlsAdClean（默认开）。
    private static func hlsAdCleaned(_ result: CatSourcePlayResult) -> CatSourcePlayResult {
        let enabled = UserDefaults.standard.object(forKey: "hitplay.hlsAdClean") as? Bool ?? true
        guard enabled, !result.isParseRequired else { return result }
        guard let prepared = HLSCleanProxy.shared.prepare(url: result.url, headers: result.headers) else { return result }
        var cleaned = result.withURL(prepared.url)
        cleaned.qualityURLs = cleaned.qualityURLs.map { quality in
            guard let wrapped = HLSCleanProxy.shared.prepare(url: quality.url, headers: result.headers) else { return quality }
            return CatSourceQualityURL(label: quality.label, url: wrapped.url)
        }
        return cleaned
    }
}
