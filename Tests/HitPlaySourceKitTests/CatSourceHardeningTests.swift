import Network
import XCTest
@testable import HitPlayCatSource

/// 猫源链路加固测试：
/// 1. 输出护栏：源码巨型日志被单行限幅 + 大对象摘要，控制行（HITPLAY_PORT）不受污染；
/// 2. 订阅下载大小上限：Content-Length 预检 / 无长度流式中止 / 正常下载。
final class CatSourceHardeningTests: XCTestCase {
    // MARK: - 输出护栏（cat-source-host.js 真实 Node 运行时）

    private func locateNode() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["HITPLAY_TEST_NODE"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func locateHostScript() -> URL? {
        for base in [Bundle(for: CatSourceEngineRuntime.self).resourceURL, Bundle.main.resourceURL].compactMap({ $0 }) {
            let candidate = base.appendingPathComponent("cat-source-host.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // 源码树回退（SwiftPM 套件形态）：从本测试文件位置向上逐级查找。
        var directory = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent("Sources/HitPlayCatSource/cat-source-host.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    @MainActor
    func testOutputGuardTruncatesOversizedLogsAndKeepsControlLines() async throws {
        guard let node = locateNode() else { throw XCTSkip("测试环境无 Node 运行时") }
        guard let hostScript = locateHostScript() else { throw XCTSkip("cat-source-host.js 资源不可用") }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hitplay-guard-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 夹具源包：10MB 超长 stdout 行 + 2MB 的 axios 系错误对象 + 正常日志 + 主内容服务。
        let fixture = """
        const huge = 'A'.repeat(10 * 1024 * 1024);
        process.stdout.write(huge + '\\n');
        const giant = 'B'.repeat(2 * 1024 * 1024);
        const err = new Error('request failed');
        err.config = { url: 'https://example.com/api' };
        err.response = { status: 502, data: giant };
        console.error('probe-axios', err);
        console.log('probe-normal-line');
        global.catServerFactory(function (req, res) { res.end('ok'); }).listen(3000);
        """
        try fixture.write(to: dir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = node
        process.arguments = [hostScript.path, dir.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()

        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                // 防御性上限：若护栏失效，测试收集器自身不应把内存吃爆。
                if data.count < 4 * 1024 * 1024 { data.append(chunk) }
            }
            var text: String {
                lock.lock(); defer { lock.unlock() }
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
        let outSink = Sink()
        let errSink = Sink()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            outSink.append(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            errSink.append(chunk)
        }

        try process.run()
        // 等 HITPLAY_PORT 控制行（宿主启动完成的唯一可信信号），随后 stdin EOF
        // 让宿主走干净退出路径；轮询而非固定睡眠，宿主异常时也能快速失败。
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !outSink.text.contains("HITPLAY_PORT=") {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let outText = outSink.text
        let errText = errSink.text

        // 1) 控制通道完好：HITPLAY_PORT 行可解析。
        XCTAssertTrue(outText.contains("HITPLAY_PORT="), "控制行丢失，stdout 已被污染：\(outText.prefix(300))")
        // 2) 10MB 超长行被截断为 128KB 上限 + 截断标记（未护栏时 stdout 至少 10MB）。
        XCTAssertLessThan(outSink.data.count, 1024 * 1024, "超长行未被限幅")
        XCTAssertTrue(outText.contains("超长输出行已截断"), "缺少截断标记")
        // 3) axios 系错误被摘要为短串，2MB 请求体未进入输出。
        XCTAssertTrue(errText.contains("probe-axios"), "console.error 内容丢失")
        XCTAssertTrue(errText.contains("status=502"), "axios 错误摘要缺失：\(errText.prefix(300))")
        XCTAssertLessThan(errSink.data.count, 1024 * 1024, "错误对象未被摘要")
        // 4) 正常日志不受影响。
        XCTAssertTrue(outText.contains("probe-normal-line"), "正常日志被误伤")
    }

    // MARK: - 订阅下载大小上限（BoundedDownloader + 本地回环 HTTP）

    /// 最小 HTTP 服务器：GET → 200，可声明 Content-Length，可分块延迟发送。
    private final class MiniHTTPServer: @unchecked Sendable {
        let body: Data
        let declareContentLength: Bool
        let chunkSize: Int
        let chunkDelayMs: Int
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "hitplay.test.http")
        private(set) var port: UInt16 = 0
        private var connections: [NWConnection] = []

        init(body: Data, declareContentLength: Bool, chunkSize: Int = 0, chunkDelayMs: Int = 0) {
            self.body = body
            self.declareContentLength = declareContentLength
            self.chunkSize = chunkSize
            self.chunkDelayMs = chunkDelayMs
        }

        func start() async throws -> UInt16 {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.queue.async { self.handle(connection) }
            }
            let lock = NSLock()
            var resumed = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    lock.lock(); defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    switch state {
                    case .ready: continuation.resume()
                    case .failed(let error): continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    lock.lock(); defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: NSError(domain: "minihttp", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "listener ready timeout"]))
                }
            }
            guard let tcpPort = listener.port?.rawValue else {
                throw NSError(domain: "minihttp", code: -2)
            }
            port = tcpPort
            return port
        }

        private func handle(_ connection: NWConnection) {
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                // 消费请求头（GET，无需内容），连接就绪后立即响应。
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in }
                self?.respond(connection)
            }
            connection.start(queue: queue)
        }

        private func respond(_ connection: NWConnection) {
            var head = "HTTP/1.1 200 OK\r\nServer: mini\r\n"
            if declareContentLength {
                head += "Content-Length: \(body.count)\r\n"
            }
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if self.chunkSize <= 0 {
                    connection.send(content: self.body, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                // 分块延迟发送：模拟无 Content-Length 的慢流，触发下载中途中止路径。
                var offset = 0
                func sendNext() {
                    guard offset < self.body.count else {
                        connection.cancel()
                        return
                    }
                    let end = min(offset + self.chunkSize, self.body.count)
                    let chunk = self.body.subdata(in: offset..<end)
                    offset = end
                    connection.send(content: chunk, completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(self.chunkDelayMs)) { sendNext() }
                    })
                }
                sendNext()
            })
        }

        func stop() {
            listener?.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func testContentLengthOverLimitIsRejectedBeforeDownload() async throws {
        let server = MiniHTTPServer(body: Data(repeating: 0x41, count: 5 * 1024 * 1024), declareContentLength: true)
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/pkg.js")!
        do {
            _ = try await BoundedDownloader.fetch(url, session: .shared, maxBytes: 1024 * 1024)
            XCTFail("超限下载应失败")
        } catch let error as CatSourceError {
            XCTAssertTrue(error.localizedDescription.contains("大小上限"), "错误文案应说明大小上限：\(error.localizedDescription)")
        }
    }

    func testMidStreamAbortWithoutContentLength() async throws {
        let server = MiniHTTPServer(
            body: Data(repeating: 0x42, count: 2 * 1024 * 1024),
            declareContentLength: false,
            chunkSize: 256 * 1024,
            chunkDelayMs: 20
        )
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/pkg.js")!
        let started = Date()
        do {
            _ = try await BoundedDownloader.fetch(url, session: .shared, maxBytes: 1024 * 1024)
            XCTFail("无长度声明且超限时应中止")
        } catch let error as CatSourceError {
            XCTAssertTrue(error.localizedDescription.contains("超过大小上限"), "应为流式中止路径：\(error.localizedDescription)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 15, "应在超限瞬间中止而非等完整下载")
        }
    }

    func testWithinLimitSucceeds() async throws {
        let body = Data(repeating: 0x43, count: 64 * 1024)
        let server = MiniHTTPServer(body: body, declareContentLength: true)
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/pkg.js")!
        let data = try await BoundedDownloader.fetch(url, session: .shared, maxBytes: 1024 * 1024)
        XCTAssertEqual(data, body)
    }

    func testMultiMegabytePackageDownload() async throws {
        let body = Data(repeating: 0x43, count: 7 * 1024 * 1024)
        let server = MiniHTTPServer(body: body, declareContentLength: true)
        let port = try await server.start()
        defer { server.stop() }
        let started = Date()
        let data = try await BoundedDownloader.fetch(
            URL(string: "http://127.0.0.1:\(port)/pkg.js")!, session: .shared,
            maxBytes: BoundedDownloader.maxPackageBytes)
        XCTAssertEqual(data, body)
        print("CAT_PACKAGE_7MB_SECONDS=\(Date().timeIntervalSince(started))")
    }

    func testCancellingDownloadStopsBeforeFullBodyArrives() async throws {
        let server = MiniHTTPServer(body: Data(repeating: 0x43, count: 2 * 1024 * 1024),
                                    declareContentLength: true, chunkSize: 32 * 1024, chunkDelayMs: 150)
        let port = try await server.start()
        defer { server.stop() }
        let download = Task {
            try await BoundedDownloader.fetch(URL(string: "http://127.0.0.1:\(port)/pkg.js")!,
                                              session: .shared, maxBytes: BoundedDownloader.maxPackageBytes)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let cancelledAt = Date()
        download.cancel()
        do {
            _ = try await download.value
            XCTFail("已取消的下载不能成功保存")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
    }
}


extension CatSourceHardeningTests {
    func testProtocolFallbackOnlyForUnsupportedRoutes() async throws {
        for status in [401, 403, 429, 500, 503, 404, 405, 501] {
            ReviewCatHTTPStub.reset(status: status)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReviewCatHTTPStub.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = CatSourceClient(baseURL: URL(string: "https://source.test")!, session: session)
            do {
                let result = try await client.play(apiPath: "/spider/demo/3", flag: "line", playKey: "key")
                XCTAssertTrue([404, 405, 501].contains(status))
                XCTAssertEqual(result.url.path, "/actual.mp4")
            } catch {
                XCTAssertFalse([404, 405, 501].contains(status))
            }
            XCTAssertEqual(ReviewCatHTTPStub.paths().count, [404, 405, 501].contains(status) ? 2 : 1)
        }
    }

    func testTimeoutAndCancellationDoNotStartProtocolFallback() async throws {
        for code in [URLError.Code.timedOut, .cancelled] {
            ReviewCatHTTPStub.reset(status: 200, error: URLError(code))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReviewCatHTTPStub.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = CatSourceClient(baseURL: URL(string: "https://source.test")!, session: session)
            do {
                _ = try await client.play(apiPath: "/spider/demo/3", flag: "line", playKey: "key")
                XCTFail("Expected the original network error")
            } catch let error as URLError { XCTAssertEqual(error.code, code) }
            XCTAssertEqual(ReviewCatHTTPStub.paths().count, 1)
        }
    }

    func testPlayPreservesProviderHeadersAndStringParseFlag() async throws {
        ReviewCatHTTPStub.reset(status: 200, body: #"{"url":"https://cdn.test/page","parse":"1","headers":{"user-agent":"fixture","authorization":"Bearer token","X-Provider-Key":"key","Cookie":"session=1","X-Bad":"value\r\nInjected: no"}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewCatHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await CatSourceClient(baseURL: URL(string: "https://source.test")!, session: session)
            .play(apiPath: "/spider/demo/3", flag: "line", playKey: "key")
        XCTAssertTrue(result.isParseRequired)
        XCTAssertEqual(result.headers["Authorization"], "Bearer token")
        XCTAssertEqual(result.headers["X-Provider-Key"], "key")
        XCTAssertEqual(result.headers["Cookie"], "session=1")
        XCTAssertEqual(result.headers["User-Agent"], "fixture")
        XCTAssertNil(result.headers["X-Bad"])
    }

    func testDetailCacheDoesNotCollideForEscapedPathsOrDelimiterIDs() {
        // These pairs collide under slash replacement or delimiter joining.
        XCTAssertNotEqual(CatSourceStore.scopedCacheKey(["site/a", "id"]), CatSourceStore.scopedCacheKey(["site_a", "id"]))
        XCTAssertNotEqual(CatSourceStore.scopedCacheKey(["site|a", "id"]), CatSourceStore.scopedCacheKey(["site", "a|id"]))
        XCTAssertEqual(CatSourceStore.scopedCacheKey(["site", String(repeating: "a", count: 1000)]).count, 64)
    }
}

private final class ReviewCatHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var failure: Error?
    private static var payload = ""
    private static var recorded: [String] = []
    static func reset(status: Int, error: Error? = nil, body: String = #"{"url":"https://cdn.test/actual.mp4"}"#) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; failure = error; payload = body; recorded = []
    }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let error = Self.failure
        let status = request.url!.path.hasPrefix("/api/") ? 200 : Self.status
        let body = Self.payload
        Self.recorded.append(request.url!.path)
        Self.lock.unlock()
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


extension CatSourceHardeningTests {
    @MainActor
    private func withReviewSourceStore(_ body: (CatSourceStore, String, String) async throws -> Void) async throws {
        guard locateNode() != nil, locateHostScript() != nil else { throw XCTSkip("Node host unavailable") }
        let suite = "CatCacheReview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = CatSourceStore(defaults: defaults)
        let subscription = CatSourceStore.Subscription(name: "Review fixture", url: "https://fixture.test/index.js")
        let directory = store.packageDirectory(for: subscription.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            store.runtime.stop()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let script = #"""
        let details = 0, plays = 0;
        global.catServerFactory((req, res) => {
          res.setHeader('Content-Type', 'application/json');
          const respond = value => res.end(JSON.stringify(value));
          if (req.url === '/config') return respond({video:{sites:[
            {key:'a',name:'A',type:3,api:'/spider/a/3'},
            {key:'b',name:'B',type:3,api:'/spider/b/3'}
          ]}});
          if (req.url === '/stats') return respond({details,plays});
          if (req.url.endsWith('/detail')) {
            const count = ++details;
            const site = req.url.includes('/a/') ? 'A' : 'B';
            return setTimeout(() => respond({list:[{vod_id:'same-id',vod_name:site,
              vod_content:'request-'+count,vod_play_from:'line',vod_play_url:'Episode$key'}]}), 200);
          }
          if (req.url.endsWith('/play')) {
            const count = ++plays;
            return setTimeout(() => respond({url:'https://cdn.test/video.mp4?request='+count,parse:0}), 200);
          }
          return respond({class:[],list:[]});
        }).listen(3000);
        """#
        try script.write(to: directory.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        await store.activate(subscription, loadHome: false)
        XCTAssertNil(store.engineError)
        XCTAssertTrue(store.runtime.isRunning)
        let siteA = CatSourceStore.catSiteID(subscription.id, "a")
        let siteB = CatSourceStore.catSiteID(subscription.id, "b")
        await store.selectSite(siteA)
        try await body(store, siteA, siteB)
    }

    @MainActor
    func testConcurrentDetailAndPlayPrefetchShareSourceRequests() async throws {
        try await withReviewSourceStore { store, _, _ in
            async let first = store.loadDetail(itemID: "same-id")
            async let second = store.loadDetail(itemID: "same-id")
            let (a, b) = try await (first, second)
            XCTAssertEqual(a.overview, "request-1")
            XCTAssertEqual(b.overview, "request-1", "Hover and foreground detail should share one source call")
            let episode = try XCTUnwrap(a.episodes.first)
            async let prefetch: Void = store.prefetchFirstPlay(detail: a)
            async let play = store.resolvePlay(detail: a, episode: episode)
            let (_, result) = try await (prefetch, play)
            XCTAssertEqual(result.url.query, "request=1")
            let cached = try await store.resolvePlay(detail: a, episode: episode)
            XCTAssertEqual(cached.url.query, "request=1")
            let fresh = try await store.resolvePlay(detail: a, episode: episode, bypassCache: true)
            XCTAssertEqual(fresh.url.query, "request=2")
        }
    }

    @MainActor
    func testSwitchingSiteRejectsOldDetailWithoutPollutingNewSiteCache() async throws {
        try await withReviewSourceStore { store, _, siteB in
            let old = Task { try await store.loadDetail(itemID: "same-id") }
            let statsURL = try XCTUnwrap(store.runtime.baseURL).appendingPathComponent("stats")
            let deadline = Date().addingTimeInterval(3)
            var started = false
            while Date() < deadline {
                let (data, _) = try await URLSession.shared.data(from: statsURL)
                let stats = try JSONSerialization.jsonObject(with: data) as? [String: Int]
                if stats?["details"] == 1 { started = true; break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(started, "Old site request must be in flight")
            await store.selectSite(siteB)
            do { _ = try await old.value; XCTFail("Old site result escaped after site switch") }
            catch is CancellationError {}
            XCTAssertNil(store.cachedDetail(itemID: "same-id"))
            let detail = try await store.loadDetail(itemID: "same-id")
            XCTAssertEqual(detail.name, "B")
            XCTAssertEqual(store.cachedDetail(itemID: "same-id")?.name, "B")
        }
    }
}
