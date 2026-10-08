import Foundation
import Network

/// iOS/TVOS 原生猫源引擎：内嵌 loopback HTTP 服务，口供与 cms-host（Node）完全一致
/// （GET /config、GET /check、POST /spider/<key>/3/*）。CatSourceClient 零改动复用。
///
/// 支持范围（与 macOS 端 cms-host 相同的边界）：
/// - type 0/1：MacCMS vod json 直连站（ac=videolist / ac=detail）；
/// - type 3 且 api 为 http(s) *.js：iOS 无 Node 运行时，暂不支持；
/// - type 3 jar / csp_：需要 JVM + dex2jar，明确不支持。
///
/// 配置来源：订阅包内的 config.json（TVBoxConfigCrypto 已在导入时解为明文）。
final class NativeEngineServer {
    enum ServerError: Error, LocalizedError {
        case badConfig(String)

        var errorDescription: String? {
            switch self {
            case .badConfig(let reason): return reason
            }
        }
    }

    struct NativeSite {
        let key: String
        let name: String
        let api: String
        let kind: Kind
        /// api 指向 MacCMS XML 采集接口（`at=xml`/`.xml`）：请求与 JSON 相同的
        /// ac 参数，响应按正文嗅探分流解析。
        let isXML: Bool

        enum Kind { case cms, js }

        init(key: String, name: String, api: String, kind: Kind, isXML: Bool = false) {
            self.key = key
            self.name = name
            self.api = api
            self.kind = kind
            self.isXML = isXML
        }
    }

    private(set) var sites: [NativeSite] = []
    private(set) var unsupportedCount = 0
    /// TVBox 配置级 JSON 解析器（parses type 1/2；type 0 嗅探由宿主侧 ParseSniffer 承担）。
    private(set) var parseParsers: [(name: String, type: Int, url: String)] = []
    /// 需解析线路名单（flags，如 youku/qq/iqiyi）：线路名命中即判需解析。
    private(set) var parseFlags: [String] = []
    let packageDir: URL

    /// NWListener 监听句柄（start 后非 nil）。
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hitplay.native-engine")
    /// 连接 → 已读缓冲（HTTP/1.1 请求解析）。NWConnection 不 Hashable，按对象身份索引。
    private var pending: [ObjectIdentifier: (connection: NWConnection, buffer: Data)] = [:]

    init(packageDir: URL) {
        self.packageDir = packageDir
    }

    // MARK: 配置装载

    /// 从包目录读 config.json 并分类站点。不支持的站点计数，0 可支持 → 抛错。
    func loadConfig() throws {
        let configURL = packageDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ServerError.badConfig("包内缺少 config.json")
        }
        let text: String
        do { text = try String(contentsOf: configURL, encoding: .utf8) } catch {
            throw ServerError.badConfig("config.json 读取失败：\(error.localizedDescription)")
        }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServerError.badConfig("config.json 不是有效 JSON")
        }
        let rawSites = (object["sites"] as? [[String: Any]]) ?? []
        // TVBox 配置级解析器与需解析线路名单（与 macOS 端 cms-host.js 同规则）。
        parseParsers = ((object["parses"] as? [[String: Any]]) ?? []).compactMap { parser in
            guard let url = parser["url"] as? String,
                  url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://"),
                  let type = (parser["type"] as? NSNumber)?.intValue, type == 1 || type == 2 else { return nil }
            return (name: parser["name"] as? String ?? "", type: type, url: url)
        }
        parseFlags = ((object["flags"] as? [Any]) ?? []).compactMap { flag in
            guard let text = flag as? String, !text.isEmpty else { return nil }
            return text.lowercased()
        }
        var loaded: [NativeSite] = []
        var usedKeys = Set<String>()
        unsupportedCount = 0
        for site in rawSites {
            guard let name = site["name"] as? String, !name.isEmpty,
                  let api = site["api"] as? String, !api.isEmpty else { continue }
            let type = (site["type"] as? NSNumber)?.intValue ?? 0
            let lower = api.lowercased()
            let key: String
            if type == 0 || type == 1, lower.hasPrefix("http") {
                // MacCMS XML 接口（at=xml / .xml）：与 JSON 同 ac 参数，按正文嗅探解析。
                let isXML = lower.contains(".xml") || lower.contains("at=xml")
                key = uniqueKey("cms", name, &usedKeys)
                loaded.append(NativeSite(key: key, name: name, api: api, kind: .cms, isXML: isXML))
                continue
            }
            if type == 3, lower.hasPrefix("http"), lower.contains(".js") {
                // iOS 无 Node 运行时：远程 JS 引擎源暂不支持，计入不支持数。
                unsupportedCount += 1
                continue
            }
            unsupportedCount += 1
        }
        guard !loaded.isEmpty else {
            throw ServerError.badConfig("配置中没有可支持的站点（需要 type 0/1 CMS 直连站；type 3 JS 站点需 Node 运行时，iOS 版暂不支持）")
        }
        sites = loaded
    }

    private func uniqueKey(_ prefix: String, _ name: String, _ used: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }
        var base = prefix + "_" + String(String.UnicodeScalarView(scalars))
        if base.count > 48 { base = String(base.prefix(48)) }
        var candidate = base
        var index = 2
        while used.contains(candidate) {
            candidate = base + "_\(index)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: 站点访问

    func site(withKey key: String) -> NativeSite? {
        sites.first { $0.key == key }
    }

    // MARK: HTTP 服务（Network.framework，仅监听 127.0.0.1）

    var port: UInt16 { listener?.port?.rawValue ?? 0 }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port.any
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            for (_, entry) in self?.pending ?? [:] { entry.connection.cancel() }
            self?.pending.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        pending[ObjectIdentifier(connection)] = (connection, Data())
        receiveLoop(ObjectIdentifier(connection))
    }

    private func receiveLoop(_ id: ObjectIdentifier) {
        guard let entry = pending[id] else { return }
        let connection = entry.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let entry = self.pending[id] else { return }
            let bufferIn = entry.buffer
            var buffer = bufferIn
            if let data, !data.isEmpty { buffer.append(data) }
            if let requestEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // 头部已完整；POST body 按 Content-Length 读取（本协议 body 均为小 JSON）。
                let headerText = String(data: buffer[..<requestEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = Self.headerValue(headerText, name: "Content-Length").flatMap(Int.init) ?? 0
                let bodyStart = requestEnd.upperBound
                if buffer.count - bodyStart >= contentLength {
                    let body = buffer[bodyStart..<(bodyStart + contentLength)]
                    let rest = buffer[(bodyStart + contentLength)...]
                    self.pending[id] = (connection, Data(rest))
                    let method = headerText.split(separator: " ").first.map(String.init) ?? "GET"
                    let target = headerText.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    self.respond(connection, method: method, target: target, body: Data(body))
                    if rest.isEmpty { self.pending.removeValue(forKey: id) }
                    self.receiveLoop(id)
                    return
                }
                self.pending[id] = (connection, buffer)
            }
            if isComplete || error != nil {
                self.pending.removeValue(forKey: id)
                connection.cancel()
                return
            }
            self.receiveLoop(id)
        }
    }

    private static func headerValue(_ headers: String, name: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ connection: NWConnection, method: String, target: String, body: Data) {
        Task { [weak self] in
            let response: Data
            do {
                guard let self else { return }
                let (status, payload) = try await self.handle(method: method, target: target, body: body)
                response = Self.httpResponse(status: status, json: payload)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                response = Self.httpResponse(status: 500, json: Data("{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "'"))\"}".utf8))
            }
            connection.send(content: response, completion: .contentProcessed { _ in })
        }
    }

    private static func httpResponse(status: Int, json: Data) -> Data {
        let reason = status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(json.count)\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        data.append(json)
        _ = head.count
        return data
    }

    // MARK: 路由

    private func handle(method: String, target: String, body: Data) async throws -> (Int, Data) {
        guard let url = URL(string: "http://127.0.0.1" + target) else {
            return (404, Data("{\"error\":\"bad request\"}".utf8))
        }
        let path = url.path
        if path == "/check" {
            return (200, Data("{\"ok\":true,\"native\":true,\"cms\":\(sites.count),\"unsupported\":\(unsupportedCount)}".utf8))
        }
        if path == "/config" {
            let siteJSON = sites.map { site -> String in
                let escapedName = Self.jsonEscaped(site.name)
                let escapedKey = Self.jsonEscaped(site.key)
                return #"{"key":"\#(escapedKey)","name":"\#(escapedName)","type":3,"api":"/spider/\#(escapedKey)/3","searchable":1}"#
            }
            let payload = "{\"video\":{\"sites\":[\(siteJSON.joined(separator: ","))]}}"
            return (200, Data(payload.utf8))
        }
        let pattern = "^/spider/([^/]+)/3/(init|home|category|detail|search|play)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              method == "POST" else {
            return (404, Data("{\"error\":\"not found\"}".utf8))
        }
        let nsPath = path as NSString
        let key = nsPath.substring(with: match.range(at: 1))
        let route = nsPath.substring(with: match.range(at: 2))
        guard let site = site(withKey: key) else {
            return (404, Data("{\"error\":\"no site\"}".utf8))
        }
        let params = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch route {
        case "init":
            return (200, Data("{}".utf8))
        default:
            let payload = try await dispatchCMS(site, route: route, params: params)
            return (200, payload)
        }
    }

    // MARK: MacCMS (type 0/1) 派发

    private func dispatchCMS(_ site: NativeSite, route: String, params: [String: Any]) async throws -> Data {
        switch route {
        case "home":
            let data = try await cmsGet(site.api, ["ac": "videolist", "pg": "1"])
            return cmsListPayload(data, includeClasses: true, limit: 24)
        case "category":
            let data = try await cmsGet(site.api, ["ac": "videolist", "t": "\(params["id"] ?? "")", "pg": "\(params["page"] ?? 1)"])
            return cmsListPayload(data, includeClasses: false, limit: .max)
        case "search":
            let data = try await cmsGet(site.api, ["ac": "videolist", "wd": "\(params["wd"] ?? "")", "pg": "\(params["page"] ?? 1)"])
            return cmsListPayload(data, includeClasses: false, limit: .max)
        case "detail":
            let rawDetailID = params["id"]
            let id: String
            if let text = rawDetailID as? String {
                id = text
            } else if let list = rawDetailID as? [Any], let first = list.first {
                id = String(describing: first)
            } else {
                id = ""
            }
            let data = try await cmsGet(site.api, ["ac": "detail", "ids": id])
            return cmsListPayload(data, includeClasses: false, limit: .max)
        case "play":
            let playID = String(describing: params["id"] ?? "")
            let flag = String(describing: params["flag"] ?? "")
            let decision = Self.decideCMSPlay(playID: playID, flag: flag, flags: parseFlags)
            if decision.needsParse, !parseParsers.isEmpty {
                if let parsed = await tryJSONParsers(playID: playID) {
                    return parsed
                }
            }
            if decision.needsParse {
                let escapedID = Self.jsonEscaped(playID)
                return Data(#"{"parse":1,"jx":1,"url":"\#(escapedID)","header":{}}"#.utf8)
            }
            let escapedID = Self.jsonEscaped(playID)
            let playJSON = "{\"parse\":0,\"url\":\"" + escapedID + "\",\"header\":{}}"
            return Data(playJSON.utf8)
        default:
            return Data("{}".utf8)
        }
    }

    // MARK: CMS 播放解析判定（与 macOS 端 cms-host.js 同规则）

    static let cmsMediaExtensions = [".m3u8", ".mp4", ".mkv", ".ts", ".flv", ".avi", ".webm", ".mpd", ".m2ts", ".mov", ".rmvb", ".mp3", ".m4a", ".flac", ".wav"]
    static let cmsPageExtensions = [".html", ".htm", ".shtml"]

    /// 直链/需解析判定（保守：只有明确的网页播放页或线路名命中 flags 才走解析，
    /// 其余保持直连——避免 .php?path= 之类无扩展名直连流被误伤）。
    static func decideCMSPlay(playID: String, flag: String, flags: [String]) -> (needsParse: Bool, reason: String) {
        let trimmed = playID.trimmingCharacters(in: .whitespacesAndNewlines)
        let flagLower = flag.lowercased()
        // 空线路名不得命中 flags。
        let flagMatched = !flagLower.isEmpty && flags.contains { entry in
            !entry.isEmpty && (flagLower.contains(entry) || entry.contains(flagLower))
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // 非 http(s)（集号/jx: 前缀等）：维持直连透传，由宿主侧按既有逻辑处理。
            return (flagMatched, "non-http" )
        }
        let path = (url.path.removingPercentEncoding ?? url.path).lowercased()
        if cmsMediaExtensions.contains(where: { path.hasSuffix($0) }) {
            return (false, "media")
        }
        if cmsPageExtensions.contains(where: { path.hasSuffix($0) }) {
            return (true, "page")
        }
        return (flagMatched, "flag")
    }

    /// 逐个尝试配置级 JSON 解析器（type 1/2），首个给出 http(s) 直链的胜出。
    private func tryJSONParsers(playID: String) async -> Data? {
        let trimmed = playID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        for parser in parseParsers {
            // 解析器契约：GET {parser.url}{urlencode(播放页地址)}。
            guard let endpoint = URL(string: parser.url + encoded) else { continue }
            var request = URLRequest(url: endpoint, timeoutInterval: 8)
            request.setValue(UserAgent.defaultUA, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count < 2 * 1024 * 1024,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let nested = object["data"] as? [String: Any]
            let candidates: [Any?] = [object["url"], object["play_url"], object["playUrl"],
                                      nested?["url"], nested?["play_url"], nested?["playUrl"]]
            guard let direct = candidates.lazy.compactMap({ $0 as? String })
                .first(where: { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }) else { continue }
            var headerDict: [String: Any] = [:]
            for candidate in [object["header"], object["headers"], nested?["header"], nested?["headers"]] {
                if let dict = candidate as? [String: Any] { headerDict = dict; break }
            }
            let escapedURL = Self.jsonEscaped(direct)
            let headerJSON = (try? JSONSerialization.data(withJSONObject: headerDict))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return Data(#"{"parse":0,"url":"\#(escapedURL)","header":\#(headerJSON)}"#.utf8)
        }
        return nil
    }

    private func cmsListPayload(_ data: [String: Any], includeClasses: Bool, limit: Int) -> Data {
        var payload: [String: Any] = [:]
        if includeClasses, let classes = data["class"] { payload["class"] = classes }
        if includeClasses { payload["filters"] = [:] }
        if let list = data["list"] as? [[String: Any]] {
            payload["list"] = limit == .max ? list : Array(list.prefix(limit))
            payload["page"] = data["page"] ?? 1
            payload["pagecount"] = data["pagecount"] ?? 1
            payload["total"] = data["total"] ?? list.count
        } else {
            payload["list"] = [] as [Any]
        }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    private func cmsGet(_ api: String, _ params: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(string: api) else {
            throw ServerError.badConfig("CMS 地址无效")
        }
        // 与 macOS 端 cms-host 行为对齐：仅要求 http/https（内网 NAS 上的
        // CMS 是合理场景，不做主机名单过滤；iOS 上 loopback 亦可达宿主 mock）。
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else {
            throw ServerError.badConfig("CMS 地址不被允许（仅限 http/https）")
        }
        var items = components.queryItems ?? []
        for (key, value) in params {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { throw ServerError.badConfig("CMS 地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(UserAgent.defaultUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerError.badConfig("CMS HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 正文嗅探分流：JSON 之外，存量 MacCMS XML 采集接口（at=xml/.xml 站点）
        // 也按同 ac 参数返回——解析为与 vod json 同形的字段。
        if !text.hasPrefix("{") && !text.hasPrefix("["), MacCMSXML.looksLikeXML(text) {
            guard let document = MacCMSXML.parse(Data(text.utf8)) else {
                throw ServerError.badConfig("CMS XML 解析失败（接口不兼容 MacCMS）")
            }
            return MacCMSXML.jsonObject(from: document, includeClasses: true)
        }
        guard text.hasPrefix("{") || text.hasPrefix("["),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw ServerError.badConfig("CMS 返回非 JSON（接口不兼容 MacCMS vod json）")
        }
        return object
    }

    static func isLocalOrReservedHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") { return true }
        if lowered == "::1" || lowered.hasPrefix("fe80:") || lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true }
        // IPv4 字面量：环回/私有/链路本地/保留段。
        let parts = lowered.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 0 || a == 10 || a == 127 { return true }
            if a == 169 && b == 254 { return true }
            if a == 172 && (100...199).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64...127).contains(b) { return true }
            if a >= 224 { return true }
        }
        return false
    }

    static func jsonEscaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

enum UserAgent {
    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}
