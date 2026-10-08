import XCTest
@testable import HitPlayCatSource

/// TVBox 配置订阅（TVBox 生态加密配置）：加密配置解密 + 标记识别 + CMS 宿主冒烟。
final class TVBoxConfigTests: XCTestCase {
    // 由 `openssl enc -aes-128-cbc`（key=iv="abcd1234" 右补 0 到 16 字节，PKCS7）
    // 生成的确定性测试向量，明文为含一个 CMS 站点的最小配置。
    private static let encryptedVector =
        "2324abcd1234**SPGypk7H4niKUTBJ0xVBjwHKAcgUp1L0LeHgZ+9tP+yw1bk0+uCrOSx+TfvRl7SfwCDVgbw40FOSy1j2ENysDZthDpRmhIF5eh6rz0HLLUPxg1IS3jdOJBKC0/s1GfY+"

    func testDecrypts2324Config() throws {
        let payload = try XCTUnwrap(TVBoxConfigCrypto.decryptIfEncrypted(Self.encryptedVector))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let sites = try XCTUnwrap(object["sites"] as? [[String: Any]])
        XCTAssertEqual(sites.first?["key"] as? String, "cms1")
    }

    func testWrongKeyReturnsNil() {
        // 错误口令必须返回 nil 而非明文（口令来自配置自身标记，校验以 JSON 判定收口）。
        XCTAssertNil(TVBoxConfigCrypto.decryptIfEncrypted("2324zzzzzzzz**AAAA"), "错误口令必须返回 nil 而非明文")
    }

    func testDetectsTVBoxConfigMarkers() {
        XCTAssertTrue(TVBoxConfigCrypto.isTVBoxConfig(Self.encryptedVector))
        XCTAssertTrue(TVBoxConfigCrypto.isTVBoxConfig("2423YWJj"))
        XCTAssertTrue(TVBoxConfigCrypto.isTVBoxConfig("abcd1234**c2l0ZXM="))
        XCTAssertTrue(TVBoxConfigCrypto.isTVBoxConfig(#"{"sites":[{"key":"a","name":"A","type":0,"api":"http://x/vod"}]}"#))
        XCTAssertFalse(TVBoxConfigCrypto.isTVBoxConfig(#"{"wallpaper":"http://x/1.jpg"}"#))
        XCTAssertFalse(TVBoxConfigCrypto.isTVBoxConfig("module.exports = { start() {} };"))
    }

    // MARK: - CMS 宿主冒烟（真实 node + python mock 上游）

    private func locateExecutable(_ candidates: [String]) -> URL? {
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// 源码树回退（SwiftPM 套件形态）：从本测试文件位置向上逐级查找。
    private static func locateInSourceTree(_ relativePath: String) -> URL? {
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

    @MainActor
    func testCMSHostServesCMSAndJSSites() async throws {
        guard let node = locateExecutable(["/opt/homebrew/bin/node", "/usr/local/bin/node"]) else {
            throw XCTSkip("测试环境无 Node 运行时")
        }
        guard let python = locateExecutable(["/usr/bin/python3", "/opt/homebrew/bin/python3"]) else {
            throw XCTSkip("测试环境无 Python（mock 上游）")
        }
        // 资源定位：App 形态走 Bundle（平铺或 tvbox-js-host/ 子目录）；
        // SwiftPM 源码套件形态走源码树回退（Tests 向上找仓库/套件根）。
        let cmsHostCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("cms-host.js"),
            Bundle.main.resourceURL?.appendingPathComponent("tvbox-js-host/cms-host.js"),
            Bundle(for: Self.self).resourceURL?.appendingPathComponent("tvbox-js-host/cms-host.js"),
            Self.locateInSourceTree("Sources/HitPlayCatSource/tvbox-js-host/cms-host.js"),
        ]
        guard let cmsHostURL = cmsHostCandidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw XCTSkip("缺少 cms-host.js 资源")
        }

        // 1. mock 上游（MacCMS vod json + 远程 JS 源）。
        let upstreamDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-cms-upstream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: upstreamDir, withIntermediateDirectories: true)
        let vodJSON = #"{"class":[{"type_id":"6","type_name":"喜剧片"}],"list":[{"vod_id":"1","vod_name":"CMS影片","vod_pic":"","vod_remarks":"HD","vod_play_from":"cms线路","vod_play_url":"第1集$https://example.com/cms1.m3u8"}]}"#
        let jsSource = """
        export default {
          init(cfg) {},
          home(filter) { return JSON.stringify({class:[{type_id:'9',type_name:'JS分类'}]}); },
          homeVod() { return JSON.stringify({list:[]}); },
          category(tid, pg, filter, ext) { return JSON.stringify({list:[]}); },
          detail(id) { return JSON.stringify({list:[]}); },
          search(wd, quick) { return JSON.stringify({list:[]}); },
          play(flag, id, flags) { return JSON.stringify({parse:0, url:id, header:{}}); },
        };
        """
        try vodJSON.write(to: upstreamDir.appendingPathComponent("vod.json"), atomically: true, encoding: .utf8)
        try jsSource.write(to: upstreamDir.appendingPathComponent("demo.js"), atomically: true, encoding: .utf8)
        let mock = Process()
        mock.executableURL = python
        mock.arguments = [upstreamDir.appendingPathComponent("mock_server.py").path]
        // mock_server.py 由测试写入（动态端口，首行上报；/vod.json /demo.js 原样返回）
        let mockScript = """
        import json
        from http.server import BaseHTTPRequestHandler, HTTPServer
        VOD = json.load(open(r"\(upstreamDir.appendingPathComponent("vod.json").path)"))
        JS = open(r"\(upstreamDir.appendingPathComponent("demo.js").path)").read()
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                path = self.path.split("?")[0]
                if path.endswith("/vod.json"):
                    body = json.dumps(VOD).encode(); ctype = "application/json"
                elif path.endswith("/demo.js"):
                    body = JS.encode(); ctype = "application/javascript"
                else:
                    self.send_response(404); self.end_headers(); return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        # 动态端口（port 0）：防遗留 mock 进程占用固定端口污染测试数据。
        srv = HTTPServer(("127.0.0.1", 0), H)
        print(srv.server_port, flush=True)
        srv.serve_forever()
        """
        try mockScript.write(to: upstreamDir.appendingPathComponent("mock_server.py"), atomically: true, encoding: .utf8)
        let mockStdout = Pipe()
        mock.standardOutput = mockStdout
        try? mock.run()
        defer { mock.terminate() }
        // 读 mock 首行拿实际端口（5s 超时兜底）。
        let upstreamPort: Int = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let timeoutItem = DispatchWorkItem {
                continuation.resume(throwing: NSError(domain: "tvbox-cms", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "mock 上游端口上报超时"]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutItem)
            mockStdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let line = String(data: chunk, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), let port = Int(line) else { return }
                handle.readabilityHandler = nil
                timeoutItem.cancel()
                continuation.resume(returning: port)
            }
        }
        let upstreamBase = "http://127.0.0.1:\(upstreamPort)"
        // 等 mock 就绪
        for _ in 0..<30 {
            if (try? await URLSession.shared.data(from: URL(string: "\(upstreamBase)/vod.json")!)) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 2. 包目录：明文 config.json（订阅导入时已解密归一）。
        let packageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-cms-pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageDir) }
        let configJSON = """
        {"sites":[
          {"key":"cms1","name":"CMS站","type":0,"api":"\(upstreamBase)/vod.json"},
          {"key":"js1","name":"JS站","type":3,"api":"\(upstreamBase)/demo.js"},
          {"key":"jar1","name":"Jar站","type":3,"api":"csp_XXX"}
        ]}
        """
        try configJSON.write(to: packageDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        // 3. 物化运行时 + 启动 cms 宿主。
        let cacheDir = packageDir.appendingPathComponent("cache", isDirectory: true)
        guard let runtimeDir = CatSourceEngineRuntime.materializeTVBoxRuntime(destination: cacheDir),
              FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("cms-host.js").path) else {
            throw XCTSkip("tvbox-js-host 运行时资源不完整")
        }
        let host = Process()
        host.executableURL = node
        host.arguments = [runtimeDir.appendingPathComponent("cms-host.js").path, packageDir.path]
        host.environment = ["HITPLAY_JS_CACHE_DIR": cacheDir.path]
        let stdout = Pipe()
        let stderr = Pipe()
        host.standardOutput = stdout
        host.standardError = stderr
        host.standardInput = Pipe()
        try host.run()
        defer {
            if let stdin = host.standardInput as? Pipe {
                try? stdin.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
                try? stdin.fileHandleForWriting.close()
            }
            if host.isRunning { host.terminate() }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            var buffer = Data()
            let timeoutItem = DispatchWorkItem {
                continuation.resume(throwing: NSError(domain: "tvbox-cms", code: -1, userInfo: [NSLocalizedDescriptionKey: "等待 HITPLAY_PORT 超时"]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutItem)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    timeoutItem.cancel()
                    continuation.resume(throwing: NSError(domain: "tvbox-cms", code: -2, userInfo: [NSLocalizedDescriptionKey: "宿主提前退出"]))
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
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        // 4. 断言：配置站点注册（jar 站被过滤）、CMS 全链路、内联 JS 源。
        let config = try await client.config()
        XCTAssertEqual(config.sites.map(\.name), ["CMS站", "JS站"])

        let home = try await client.home(apiPath: "/spider/tv_cms1/3")
        XCTAssertEqual(home.categories.map(\.name), ["喜剧片"])
        XCTAssertEqual(home.items.first?.name, "CMS影片")

        let detail = try await client.detail(apiPath: "/spider/tv_cms1/3", itemID: "1")
        XCTAssertEqual(detail.episodes.first?.playKey, "https://example.com/cms1.m3u8")
        XCTAssertEqual(detail.episodes.count, 1)

        let play = try await client.play(apiPath: "/spider/tv_cms1/3", flag: "cms线路", playKey: "https://example.com/cms1.m3u8")
        XCTAssertEqual(play.url.absoluteString, "https://example.com/cms1.m3u8")
        XCTAssertFalse(play.isParseRequired)

        let jsHome = try await client.home(apiPath: "/spider/tv_js1/3")
        XCTAssertEqual(jsHome.categories.map(\.name), ["JS分类"])
    }
}
