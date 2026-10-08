import Foundation
import CryptoKit
import Network

/// 本地 HLS 去广告代理。
///
/// 地址是不可猜测的 capability URL（`/hls/<token48>/<id32>.<ext>`）：上游真实
/// 地址与凭据只存在进程内存里，端点不接受客户端指定任意目标。播放列表经
/// `HLSCleaner` 清理后，回源地址逐条注册为本代理资源；分片/密钥请求透传
/// Range 并流式转发。任一环节失败都 302 回原始地址自动降级——清理失败
/// 不会造成播放失败，最坏情况等于直连。
final class HLSCleanProxy {
    static let shared = HLSCleanProxy()

    struct Prepared {
        let url: URL
        let originalURL: URL
    }

    final class Context {
        let token: String
        var headers: [String: String]
        var enabled: Bool
        /// 分离音/视频/字幕 rendition：只剪一支会移出对方时间轴，禁用清理。
        var separateRenditions = false
        /// 资源 id → 上游地址（playlist: / resource: 前缀参与 id 派生）。
        var resources: [String: (url: String, playlist: Bool)] = [:]
        var lastSeen = Date()
        fileprivate init(token: String, headers: [String: String], enabled: Bool) {
            self.token = token
            self.headers = headers
            self.enabled = enabled
        }
    }

    /// 会话上限（16）与闲置回收。
    private static let maxContexts = 16
    private static let maxResourcesPerContext = 100_000
    private static let maxPlaylistBytes = 8 * 1024 * 1024
    private static let contextIdleLifetime: TimeInterval = 2 * 60 * 60

    private let queue = DispatchQueue(label: "hitplay.hls-clean-proxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var contexts: [String: Context] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private init() {}

    var baseURL: URL? {
        queue.sync { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)") }
    }

    // MARK: - 准备（播放地址包装入口）

    /// 把点播 HLS 直链包装为本代理 capability URL；不适用时返回 nil（原样直连）。
    /// 播放线程调用（不得在代理内部队列上调用）。
    @discardableResult
    func prepare(url: URL, headers: [String: String], enabled: Bool = true) -> Prepared? {
        guard enabled, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        // 已是环回地址：不包装（防环；本代理自身地址必为环回）。
        if let host = url.host, host.isLoopbackHost { return nil }
        guard HLSCleaner.looksLikeHLS(url, inferProxy: true) else { return nil }
        ensureListening()
        return queue.sync { () -> Prepared? in
            guard port != 0 else { return nil }
            var sanitized: [String: String] = [:]
            for (name, value) in headers {
                let key = name.trimmingCharacters(in: .whitespaces)
                let lower = key.lowercased()
                guard !key.isEmpty, key.rangeOfCharacter(from: .newlines) == nil,
                      value.rangeOfCharacter(from: .newlines) == nil,
                      !["host", "connection", "content-length", "transfer-encoding", "accept-encoding"].contains(lower)
                else { continue }
                sanitized[key] = value
            }
            let token = Self.randomHex(byteCount: 24)
            let context = Context(token: token, headers: sanitized, enabled: enabled)
            contexts[token] = context
            trimContextsLocked()
            guard let registered = registerLocked(context, url.absoluteString, playlist: true) else {
                contexts.removeValue(forKey: token)
                return nil
            }
            return Prepared(url: registered, originalURL: url)
        }
    }

    /// 释放指定 capability URL 所属的上下文（换源/停播时调用；不调用也有闲置回收）。
    func release(url: URL) {
        guard url.path.hasPrefix("/hls/") else { return }
        let token = url.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        queue.sync { contexts.removeValue(forKey: token) }
    }

    func releaseAll() {
        queue.sync { contexts.removeAll() }
    }

    // MARK: - 资源注册（须持锁）

    private func registerLocked(_ context: Context, _ urlString: String, playlist: Bool) -> URL? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let prefix = playlist ? "playlist" : "resource"
        let digest = SHA256.hash(data: Data("\(prefix):\(urlString)".utf8))
        let id = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        if context.resources[String(id)] == nil {
            guard context.resources.count < Self.maxResourcesPerContext else { return nil }
            context.resources[String(id)] = (urlString, playlist)
        }
        let path = url.path
        let extensionText = path.split(separator: ".").last.map { String($0.prefix(8)) } ?? "bin"
        let safeExtension = extensionText.range(of: #"^[a-z\d]{1,8}$"#, options: [.regularExpression, .caseInsensitive]) != nil ? extensionText : "bin"
        return URL(string: "http://127.0.0.1:\(port)/hls/\(context.token)/\(id).\(playlist ? "m3u8" : safeExtension)")
    }

    private func trimContextsLocked() {
        let now = Date()
        for (token, context) in contexts where now.timeIntervalSince(context.lastSeen) > Self.contextIdleLifetime {
            contexts.removeValue(forKey: token)
        }
        while contexts.count > Self.maxContexts,
              let oldest = contexts.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            contexts.removeValue(forKey: oldest)
        }
    }

    private static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    // MARK: - 服务生命周期

    /// 启动监听并短暂等待就绪（在调用方线程等待；回调跑在代理队列上，无死锁）。
    private func ensureListening() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard port == 0, listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else { return }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                self?.queue.async {
                    self?.port = listener.port?.rawValue ?? 0
                }
            }
            listener.start(queue: queue)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if baseURL != nil { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                Task { await self.handle(requestHead: head, connection: connection) }
                return
            }
            if buffer.count > 32 * 1024 || isComplete {
                connection.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                return
            }
            self.receiveHead(connection, buffer: buffer)
        }
    }

    // MARK: - 请求处理

    private func handle(requestHead: String, connection: NWConnection) async {
        let lines = requestHead.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init)?.uppercased() ?? "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        defer { connection.cancel() }

        guard method == "GET" || method == "HEAD",
              let url = URL(string: "http://127.0.0.1" + target),
              url.path.hasPrefix("/hls/") else {
            await respond(connection, status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found\n".utf8))
            return
        }
        let pathParts = url.path.split(separator: "/").dropFirst().map(String.init)
        let found: (Context, (url: String, playlist: Bool))? = queue.sync { () -> (Context, (url: String, playlist: Bool))? in
            guard pathParts.count == 3, let context = contexts[pathParts[0]],
                  let resource = context.resources[pathParts[1]] else { return nil }
            context.lastSeen = Date()
            return (context, resource)
        }
        guard let context = found?.0, let resource = found?.1 else {
            await respond(connection, status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found\n".utf8))
            return
        }

        var upstreamRequest = URLRequest(url: URL(string: resource.url) ?? url, timeoutInterval: 60)
        upstreamRequest.httpMethod = method
        for (name, value) in context.headers {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }
        // 代理必须拿到未压缩的确定性字节流；播放列表不做 Range（整表重写）。
        upstreamRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !resource.playlist {
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let name = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                if name.caseInsensitiveCompare("Range") == .orderedSame {
                    upstreamRequest.setValue(value, forHTTPHeaderField: "Range")
                }
            }
        }

        do {
            if resource.playlist {
                let (data, response) = try await session.data(for: upstreamRequest)
                guard let http = response as? HTTPURLResponse else {
                    await redirect(connection, to: resource.url)
                    return
                }
                let finalURL = response.url?.absoluteString ?? resource.url
                guard (200..<300).contains(http.statusCode) else {
                    // 上游失败：302 回原始地址自动降级（最坏情况等于直连）。
                    await redirect(connection, to: resource.url)
                    return
                }
                let sniff = String(data: data.prefix(128), encoding: .utf8) ?? ""
                guard sniff.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                    await passthrough(connection, status: http.statusCode, upstreamHeaders: http.allHeaderFields, body: data)
                    return
                }
                if data.count > Self.maxPlaylistBytes {
                    await redirect(connection, to: finalURL)
                    return
                }
                let original = String(decoding: data, as: UTF8.self)
                // DEFINE/IMPORT 变量绑定到原始 URI 与父级作用域：整支 302 回源保作用域。
                if original.contains("#EXT-X-DEFINE:") || original.contains("{$") {
                    await redirect(connection, to: finalURL)
                    return
                }
                // 分离 rendition 只剪一支会移出其余 rendition 时间轴：标记后保持整支直通。
                if original.components(separatedBy: .newlines).contains(where: { line in
                    line.hasPrefix("#EXT-X-MEDIA:")
                        && line.range(of: #"[:,]TYPE=(?:AUDIO|VIDEO|SUBTITLES)(?:,|$)"#, options: String.CompareOptions.regularExpression) != nil
                        && line.range(of: #"[:,]URI="#, options: String.CompareOptions.regularExpression) != nil
                }) {
                    queue.sync { context.separateRenditions = true }
                }
                let enabled = queue.sync { context.enabled && !context.separateRenditions }
                let cleaned = HLSCleaner.clean(original, sourceURL: finalURL, enabled: enabled) { target, playlist in
                    self.queue.sync {
                        self.registerLocked(context, target, playlist: playlist)?.absoluteString
                    } ?? target
                }
                var headers = ["Content-Type": "application/vnd.apple.mpegurl; charset=utf-8", "Cache-Control": "no-store"]
                if method == "HEAD" { headers["Content-Length"] = String(cleaned.content.utf8.count) }
                await respond(connection, status: 200, headers: headers,
                              body: method == "HEAD" ? Data() : Data(cleaned.content.utf8))
            } else {
                // 分片/密钥：流式转发（伪 HLS 的单分片可能是整部电影，不能整段缓冲）。
                let (bytes, response) = try await session.bytes(for: upstreamRequest)
                guard let http = response as? HTTPURLResponse else {
                    await redirect(connection, to: resource.url)
                    return
                }
                var headers: [String: String] = ["Cache-Control": "no-store"]
                for (name, value) in http.allHeaderFields {
                    guard let name = name as? String, let value = value as? String,
                          ["content-type", "content-range", "accept-ranges", "etag", "last-modified"].contains(name.lowercased()) else { continue }
                    headers[name] = value
                }
                if let length = http.value(forHTTPHeaderField: "Content-Length") {
                    headers["Content-Length"] = length
                }
                var head = "HTTP/1.1 \(http.statusCode) \(Self.reasonPhrase(http.statusCode))\r\n"
                for (name, value) in headers {
                    head += "\(name): \(value)\r\n"
                }
                head += "Connection: close\r\n\r\n"
                try await send(connection, Data(head.utf8))
                var buffer = Data()
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 64 * 1024 {
                        try await send(connection, buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    try await send(connection, buffer)
                }
            }
        } catch {
            await redirect(connection, to: resource.url)
        }
    }

    // MARK: - 响应写出

    private func redirect(_ connection: NWConnection, to urlString: String) async {
        await respond(connection, status: 302, headers: ["Location": urlString, "Cache-Control": "no-store"], body: Data())
    }

    private func passthrough(_ connection: NWConnection, status: Int, upstreamHeaders: [AnyHashable: Any], body: Data) async {
        var headers: [String: String] = ["Cache-Control": "no-store"]
        for (name, value) in upstreamHeaders {
            guard let name = name as? String, let value = value as? String,
                  ["content-type", "content-range", "accept-ranges", "etag", "last-modified"].contains(name.lowercased()) else { continue }
            headers[name] = value
        }
        await respond(connection, status: status, headers: headers, body: body)
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data) async {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" {
            head += "\(name): \(value)\r\n"
        }
        if !body.isEmpty {
            head += "Content-Length: \(body.count)\r\n"
        } else if let length = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            head += "Content-Length: \(length)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        try? await send(connection, payload)
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Status \(status)"
        }
    }
}

private extension String {
    var isLoopbackHost: Bool {
        let lowered = lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" || lowered == "[::1]"
    }
}
