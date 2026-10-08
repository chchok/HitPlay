import XCTest
@testable import HitPlayCatSource

/// tvbox-js-host 运行时 Node 冒烟：站点发现（/config）、健康检查（/check），
/// 以及（worker.js 就绪时）home/detail/play 全链路派发。
final class TVBoxJsHostSmokeTests: XCTestCase {
    private struct HostProcess {
        let process: Process
        let port: Int
    }

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

    /// worker.js 缺失（打包形态异常）时跳过派发段；/config 与 /check 不依赖 worker。
    private var workerAvailable: Bool {
        guard let dir = try? materializeRuntime() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("worker.js").path)
    }

    /// 复用引擎同款物化逻辑：把平铺包资源整理成 lib/ 目录结构。
    private func materializeRuntime() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-smoke-runtime-\(UUID().uuidString)", isDirectory: true)
        guard CatSourceEngineRuntime.materializeTVBoxRuntime(destination: dir) != nil else {
            throw XCTSkip("tvbox-js-host 资源不完整（host/worker/lib 缺失）")
        }
        return dir.appendingPathComponent("tvbox-js-host", isDirectory: true)
    }

    private static let demoSpiderJS = """
    export default {
      init(cfg) {},
      home(filter) { return JSON.stringify({class:[{type_id:'1',type_name:'电影'}], filters:{'1':[{key:'area',name:'地区',value:[{n:'全部',v:''},{n:'大陆',v:'大陆'}]}]}}); },
      homeVod() { return JSON.stringify({list:[{vod_id:'100',vod_name:'演示片',vod_pic:'',vod_remarks:'HD'}]}); },
      category(tid, pg, filter, ext) { return JSON.stringify({list:[{vod_id:tid + '-' + pg,vod_name:'条目',vod_pic:'',vod_remarks:''}]}); },
      detail(id) { return JSON.stringify({list:[{vod_id:String(id),vod_name:'演示片',vod_content:'简介',vod_play_from:'线路一',vod_play_url:'第1集$https://example.com/a.m3u8'}]}); },
      search(wd, quick) { return JSON.stringify({list:[]}); },
      play(flag, id, flags) { return JSON.stringify({parse:0, url:id, header:{'User-Agent':'demo'}}); },
    };
    """

    @MainActor
    private func startHost(packageDir: URL) async throws -> HostProcess {
        guard let node = locateNode() else { throw XCTSkip("测试环境无 Node 运行时") }
        let runtimeDir: URL
        do {
            runtimeDir = try materializeRuntime()
        } catch {
            throw XCTSkip("tvbox-js-host 资源不可用")
        }

        let cacheDir = packageDir.appendingPathComponent("cache", isDirectory: true)
        let process = Process()
        process.executableURL = node
        process.arguments = [
            "--experimental-vm-modules",
            runtimeDir.appendingPathComponent("host.js").path,
            packageDir.path,
        ]
        process.environment = ["HITPLAY_JS_CACHE_DIR": cacheDir.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()
        try process.run()

        // 读 stdout 直到 HITPLAY_PORT=<n>（最多 15s）。
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let timeoutItem = DispatchWorkItem {
                continuation.resume(throwing: NSError(domain: "tvbox-smoke", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "等待 HITPLAY_PORT 超时"]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutItem)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    timeoutItem.cancel()
                    continuation.resume(throwing: NSError(domain: "tvbox-smoke", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "宿主进程提前退出"]))
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
                    buffer.removeSubrange(..<newline)
                    if line.hasPrefix("HITPLAY_PORT="), let port = Int(line.dropFirst("HITPLAY_PORT=".count)) {
                        handle.readabilityHandler = nil
                        timeoutItem.cancel()
                        continuation.resume(returning: port)
                        return
                    }
                }
            }
        }
        return HostProcess(process: process, port: port)
    }

    private func stopHost(_ host: HostProcess) {
        if let stdin = host.process.standardInput as? Pipe {
            try? stdin.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(3)
        while host.process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if host.process.isRunning { host.process.terminate() }
    }

    @MainActor
    func testConfigAndCheckRoutes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.demoSpiderJS.write(to: dir.appendingPathComponent("demo.js"), atomically: true, encoding: .utf8)

        let host = try await startHost(packageDir: dir)
        defer { stopHost(host) }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(host.port)")!)

        // /config：单文件源应注册为一个 type 3 站点，api 路由与宿主一致。
        let config = try await client.config()
        XCTAssertEqual(config.sites.count, 1)
        XCTAssertEqual(config.sites.first?.name, "demo")
        XCTAssertEqual(config.sites.first?.apiPath, "/spider/js_demo/3")

        // /check 健康检查。
        let (checkData, checkResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(host.port)/check")!)
        XCTAssertEqual((checkResponse as? HTTPURLResponse)?.statusCode, 200)
        let payload = try XCTUnwrap(try? JSONSerialization.jsonObject(with: checkData) as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["sites"] as? Int, 1)

        guard workerAvailable else {
            throw XCTSkip("worker.js 待入库（安全门禁裁决后补全派发段断言）")
        }
        // 站点初始化 + home 合并（home.class + homeVod.list）。
        await client.initSite(apiPath: "/spider/js_demo/3")
        let home = try await client.home(apiPath: "/spider/js_demo/3")
        XCTAssertEqual(home.categories.map(\.name), ["电影"])
        XCTAssertEqual(home.items.first?.name, "演示片")
        XCTAssertEqual(home.filters["1"]?.first?.name, "地区")

        let episodes = try await client.detail(apiPath: "/spider/js_demo/3", itemID: "100")
        XCTAssertEqual(episodes.name, "演示片")
        XCTAssertEqual(episodes.episodes.first?.playKey, "https://example.com/a.m3u8")

        let play = try await client.play(apiPath: "/spider/js_demo/3", flag: "线路一", playKey: "https://example.com/a.m3u8")
        XCTAssertEqual(play.url.absoluteString, "https://example.com/a.m3u8")
        XCTAssertFalse(play.isParseRequired)
        XCTAssertEqual(play.headers["User-Agent"], "demo")
    }
}
