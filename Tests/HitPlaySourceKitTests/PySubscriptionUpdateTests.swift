import Network
import XCTest
@testable import HitPlayCatSource
@testable import HitPlayPySource

/// py 订阅源加固与更新闭环测试：
/// 1. 订阅地址准入（SSRF 防线：拒绝 localhost/环回/私有/保留主机）；
/// 2. FongMi 目录 ext 字段归一（字符串/对象/缺失）；
/// 3. 端到端订阅更新（本地回环 mock 上游 + 真实 py 引擎，allowLoopback 注入）。
final class PySubscriptionUpdateTests: XCTestCase {
    // MARK: - URL 准入策略

    func testRemoteSourceURLPolicyAcceptsPublicHosts() {
        let accepted = [
            "https://example.com/source.py",
            "http://example.com:8080/catalog.json",
            "https://sub.example.co.uk/a/b.py",
            "https://8.8.8.8/x.py",
            "https://[2606:4700::1111]/x.py",
            "https://example.test/b.json", // CurrentSourceTests 在用的假想公网主机
        ]
        for candidate in accepted {
            XCTAssertTrue(RemoteSourceURLPolicy.isPublicHTTPURL(candidate), "应接受：\(candidate)")
        }
    }

    func testRemoteSourceURLPolicyRejectsLoopbackPrivateAndReservedHosts() {
        let rejected = [
            "http://localhost/source.py",
            "http://localhost.localdomain/source.py",
            "http://box.localhost/source.py",
            "http://printer.local/source.py",
            "http://127.0.0.1/source.py",
            "http://127.254.1.1/source.py",
            "http://10.1.2.3/source.py",
            "http://172.16.0.1/source.py",
            "http://172.31.255.255/source.py",
            "http://192.168.1.1/source.py",
            "http://169.254.3.4/source.py",
            "http://100.64.0.1/source.py",
            "http://0.0.0.0/source.py",
            "http://224.0.0.1/source.py",
            "http://240.0.0.1/source.py",
            "http://255.255.255.255/source.py",
            "http://[::1]/source.py",
            "http://[::]/source.py",
            "http://[fd00::1]/source.py",
            "http://[fe80::1]/source.py",
            "http://[ff02::1]/source.py",
            "http://[2001:db8::1]/source.py",
            "http://[::ffff:127.0.0.1]/source.py",
            "http://[::ffff:192.168.1.1]/source.py",
            "ftp://example.com/source.py",
            "file:///etc/passwd",
            "",
        ]
        for candidate in rejected {
            XCTAssertFalse(RemoteSourceURLPolicy.isPublicHTTPURL(candidate), "应拒绝：\(candidate)")
        }
    }

    func testPolicyAllowLoopbackInjectionForTests() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8907/source.py"))
        XCTAssertThrowsError(try RemoteSourceURLPolicy.validate(url))
        XCTAssertNoThrow(try RemoteSourceURLPolicy.validate(url, allowLoopback: true))
    }

    // MARK: - 目录 ext 归一

    func testPyCatalogParsesExtStringObjectAndMissing() throws {
        let json = #"""
        {"code":1,"sites":[
            {"key":"a","name":"字符串ext","type":3,"api":"https://example.com/a.py","ext":"{\"token\":\"x\"}"},
            {"key":"b","name":"对象ext","type":3,"api":"https://example.com/b.py","ext":{"token":"y","n":2}},
            {"key":"c","name":"无ext","type":3,"api":"https://example.com/c.py"},
            {"key":"d","name":"js不收","type":3,"api":"https://example.com/d.js","ext":"zzz"}
        ]}
        """#
        let references = try RemotePySourceCatalog.parse(Data(json.utf8))
        XCTAssertEqual(references.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(references[0].ext, #"{"token":"x"}"#)
        let objectExt = try XCTUnwrap(references[1].ext)
        XCTAssertTrue(objectExt.contains(#""token":"y""#), "对象 ext 应归一为 JSON 字符串：\(objectExt)")
        XCTAssertTrue(objectExt.contains(#""n":2"#))
        XCTAssertNil(references[2].ext)
    }

    func testPyCatalogRejectsInvalidJSON() {
        XCTAssertThrowsError(try RemotePySourceCatalog.parse(Data("not json".utf8)))
    }

    // MARK: - 端到端订阅更新（本地回环 mock + 真实 py 引擎）

    /// 最小 FongMi Spider：只依赖宿主注入的 base 模块，不触网。
    private static func spiderSource(displayName: String, marker: String) -> String {
        """
        try:
            from base.spider import Spider as BaseSpider
        except ImportError:
            class BaseSpider: pass

        class Spider(BaseSpider):
            MARKER = "\(marker)"

            def getName(self):
                return "\(displayName)"

            def init(self, extend=""):
                self.extend = extend

            def homeContent(self, flag):
                return {"class": [{"type_id": "1", "type_name": "电影"}], "list": []}
        """
    }

    private func locateExecutable(_ candidates: [String]) -> URL? {
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    @MainActor
    private func makeStore() -> CatSourceStore {
        let suite = "test.pysubscription.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return CatSourceStore(defaults: defaults)
    }

    /// 可换内容的本地回环 HTTP 服务器（GET → 200 + body；allowLoopback 测试专用）。
    private final class LoopbackServer: @unchecked Sendable {
        private let lock = NSLock()
        private var bodyValue = Data()
        var body: Data {
            get { lock.lock(); defer { lock.unlock() }; return bodyValue }
            set { lock.lock(); defer { lock.unlock() }; bodyValue = newValue }
        }
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "hitplay.test.pyloopback")
        private(set) var port: UInt16 = 0
        private var connections: [NWConnection] = []

        init(body: Data) {
            bodyValue = body
        }

        func start() async throws {
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
                    continuation.resume(throwing: NSError(domain: "pyloopback", code: -1))
                }
            }
            port = listener.port?.rawValue ?? 0
            guard port > 0 else { throw NSError(domain: "pyloopback", code: -2) }
        }

        private func handle(_ connection: NWConnection) {
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in }
                guard let self else { return }
                let body = self.body
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            connection.start(queue: queue)
        }

        func stop() {
            listener?.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func makeZip(sourceDirectory: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", sourceDirectory.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "pyzip", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ditto 打包失败（\(process.terminationStatus)）"])
        }
    }

    /// 单 .py 订阅：安装 → 检查无更新 → 远端换版 → 检查命中 → 更新 → 哈希快路径跳过。
    @MainActor
    func testSingleFileSubscriptionUpdateLoop() async throws {
        guard locateExecutable(["/usr/bin/python3", "/opt/homebrew/bin/python3"]) != nil else {
            throw XCTSkip("测试环境无 Python 运行时")
        }
        let v1 = Data(Self.spiderSource(displayName: "演示PY", marker: "v1").utf8)
        let server = LoopbackServer(body: v1)
        try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/source.py"))

        let store = makeStore()
        try await store.installPySource(name: "演示PY", sourceURL: url, allowLoopback: true)
        guard let engine = store.pyEngines.first else {
            return XCTFail("安装后应有引擎")
        }
        XCTAssertEqual(engine.sourceURL, url.absoluteString)
        XCTAssertEqual(engine.contentHash, CatSourceStore.sha256Hex(v1))

        // 远端未变：检查 = 无更新；更新 = 跳过。
        try await Task.sleep(nanoseconds: 100_000_000)
        let unchangedCheck = try await store.checkPySourceUpdate(id: engine.id, allowLoopback: true)
        XCTAssertEqual(unchangedCheck, .unchanged)
        let skipped = try await store.updatePySourceFromSubscription(id: engine.id, allowLoopback: true)
        XCTAssertFalse(skipped)

        // 远端换版：检查命中，更新真实替换文件。
        let v2 = Data(Self.spiderSource(displayName: "演示PY", marker: "v2").utf8)
        server.body = v2
        let availableCheck = try await store.checkPySourceUpdate(id: engine.id, allowLoopback: true)
        XCTAssertEqual(availableCheck, .available)
        let updated = try await store.updatePySourceFromSubscription(id: engine.id, allowLoopback: true)
        XCTAssertTrue(updated)
        let dir = store.packageDirectory(for: UUID(uuidString: engine.id)!)
        let installed = try Data(contentsOf: dir.appendingPathComponent(engine.fileName ?? (engine.id + ".py")))
        XCTAssertEqual(String(data: installed, encoding: .utf8), String(data: v2, encoding: .utf8))
        XCTAssertEqual(store.pyEngines.first?.contentHash, CatSourceStore.sha256Hex(v2))

        // 持久化记录含哈希（重启恢复后仍可走快路径）。
        let records = store.pyEngines.map { engine in
            PySourceRecord(
                id: engine.id, name: engine.name, fileName: engine.fileName ?? (engine.id + ".py"),
                enabled: engine.isEnabled, extend: engine.extend,
                sourceURL: engine.sourceURL, contentHash: engine.contentHash
            )
        }
        XCTAssertEqual(records.first?.contentHash, CatSourceStore.sha256Hex(v2))
        store.removePySource(id: engine.id)
    }

    /// zip 插件包：安装记录主 Spider 文件名（修复 zip 包重启后「文件缺失」），
    /// 远端换版走 zip 整体替换路径。
    @MainActor
    func testZipBundleSubscriptionInstallAndUpdate() async throws {
        guard locateExecutable(["/usr/bin/python3", "/opt/homebrew/bin/python3"]) != nil else {
            throw XCTSkip("测试环境无 Python 运行时")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pysub-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let bundleDir = work.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try Self.spiderSource(displayName: "演示ZIP", marker: "v1")
            .write(to: bundleDir.appendingPathComponent("spider.py"), atomically: true, encoding: .utf8)
        try "lib placeholder".write(to: bundleDir.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        let zipV1 = work.appendingPathComponent("v1.zip")
        try makeZip(sourceDirectory: bundleDir, destination: zipV1)

        let server = LoopbackServer(body: try Data(contentsOf: zipV1))
        try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/plugin.zip"))

        let store = makeStore()
        try await store.installPySource(name: "演示ZIP", sourceURL: url, allowLoopback: true)
        guard let engine = store.pyEngines.first else {
            return XCTFail("安装后应有引擎")
        }
        XCTAssertEqual(engine.fileName, "spider.py", "zip 包主 Spider 文件名应被记录")
        XCTAssertEqual(engine.contentHash, CatSourceStore.sha256Hex(try Data(contentsOf: zipV1)))

        // 换版 zip：同名 spider.py 内容变更。
        try Self.spiderSource(displayName: "演示ZIP", marker: "v2")
            .write(to: bundleDir.appendingPathComponent("spider.py"), atomically: true, encoding: .utf8)
        let zipV2 = work.appendingPathComponent("v2.zip")
        try makeZip(sourceDirectory: bundleDir, destination: zipV2)
        server.body = try Data(contentsOf: zipV2)
        let updated = try await store.updatePySourceFromSubscription(id: engine.id, allowLoopback: true)
        XCTAssertTrue(updated)
        XCTAssertEqual(store.pyEngines.first?.fileName, "spider.py")
        XCTAssertEqual(store.pyEngines.first?.contentHash, CatSourceStore.sha256Hex(try Data(contentsOf: zipV2)))

        // 重启恢复路径：持久化记录的 fileName 指向真实存在的文件。
        let dir = store.packageDirectory(for: UUID(uuidString: engine.id)!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("spider.py").path))
        store.removePySource(id: engine.id)
    }
}
