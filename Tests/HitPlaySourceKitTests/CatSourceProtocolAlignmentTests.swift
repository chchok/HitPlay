import XCTest
import Network
@testable import HitPlayCatSource

/// 猫源引擎协议对齐测试：
/// 1. HLS 去广告三重检测 + playlist 重建；
/// 2. MacCMS XML 采集接口解析（NativeEngineServer + cms-host 双端）；
/// 3. 播放结果归一化（嵌套下钻 / 内联画质对 / `|Header=` 尾注 / 逐跳头过滤）。
final class CatSourceProtocolAlignmentTests: XCTestCase {
    // MARK: - HLS 去广告：基础与门禁

    private func vodPlaylist(segments: [(name: String, duration: Double)], mediaSequence: Int = 0) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10",
                     "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for segment in segments {
            lines.append("#EXTINF:\(segment.duration),")
            lines.append(segment.name)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    func testNonHLSContentSkips() {
        let result = HLSCleaner.clean("<html>not a playlist</html>", sourceURL: "https://cdn.example.com/video")
        XCTAssertEqual(result.skippedReason, "not-hls")
        XCTAssertEqual(result.removedSegments, 0)
    }

    func testMasterPlaylistSkips() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        480p.m3u8
        #EXT-X-ENDLIST
        """
        let result = HLSCleaner.clean(master, sourceURL: "https://cdn.example.com/master.m3u8")
        XCTAssertEqual(result.skippedReason, "master")
    }

    func testLivePlaylistSkips() {
        let live = vodPlaylist(segments: [("seg1.ts", 4), ("seg2.ts", 4)])
            .replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
        let result = HLSCleaner.clean(live, sourceURL: "https://cdn.example.com/live.m3u8")
        XCTAssertEqual(result.skippedReason, "live")
    }

    func testDisabledKeepsSegments() {
        let playlist = vodPlaylist(segments: [("seg/ads/1.ts", 4), ("seg/main/1.ts", 4)])
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8", enabled: false)
        XCTAssertEqual(result.skippedReason, "disabled")
        XCTAssertTrue(result.content.contains("ads/1.ts"))
    }

    // MARK: - 检测器 C：URL 词边界

    func testExplicitAdURLRemoved() {
        let playlist = vodPlaylist(segments: [
            ("main/seg0.ts", 6), ("main/seg1.ts", 6),
            ("/ads/banner0.ts", 6), ("/ads/banner1.ts", 6),
            ("main/seg2.ts", 6), ("main/seg3.ts", 6),
        ])
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 2, "路径 /ads/ 词边界命中应删除两个切片")
        XCTAssertFalse(result.content.contains("/ads/banner0.ts"))
        XCTAssertTrue(result.content.contains("main/seg0.ts"))
        XCTAssertEqual(result.skippedReason, "")
    }

    func testGuanggaoURLRemovedAndQuerySignaturePreserved() {
        let playlist = vodPlaylist(segments: [
            ("https://cdn.example.com/main/a.ts?token=xyz", 6),
            ("https://cdn.example.com/guanggao/x.ts?sign=ABCdef123&expires=99", 6),
            ("https://cdn.example.com/main/b.ts?token=xyz", 6),
        ])
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 1)
        XCTAssertFalse(result.content.contains("guanggao"))
        // 正片 URL（含签名 query）逐字节保留。
        XCTAssertTrue(result.content.contains("main/a.ts?token=xyz"))
    }

    func testSimilarButNonAdPathsKept() {
        // "adjust" 含 "ad" 但词边界不匹配；"additional" 同理。
        let playlist = vodPlaylist(segments: [
            ("adjust/seg0.ts", 6), ("additional/seg1.ts", 6),
            ("normal/seg2.ts", 6), ("normal/seg3.ts", 6),
        ])
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 0, "非词边界命中不得误删")
    }

    // MARK: - 检测器 A：SCTE/CUE 标记区间

    func testCueOutInMarkerRangeRemoved() {
        // CUE-OUT 挂在 seg3 的 tag 组，CUE-IN 挂在 seg6 的 tag 组：
        // 覆盖 seg3/4/5（12s 与声明时长一致）→ 整段移除 3 片。
        var segments: [String] = []
        for index in 0..<12 {
            if index == 3 { segments.append("#EXT-X-CUE-OUT:12.0") }
            if index == 6 { segments.append("#EXT-X-CUE-IN") }
            segments.append("#EXTINF:4.0,")
            segments.append("https://cdn.example.com/media/seg\(index).ts")
        }
        let lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"] + segments + ["#EXT-X-ENDLIST"]
        let result = HLSCleaner.clean(lines.joined(separator: "\n"), sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 3, "CUE-OUT..CUE-IN 区间（3 段广告）应整段移除")
        for index in 3...5 {
            XCTAssertFalse(result.content.contains("seg\(index).ts"))
        }
        for index in [0, 1, 2, 6, 11] {
            XCTAssertTrue(result.content.contains("seg\(index).ts"))
        }
        // 首个保留切片是 seg0（index 未前移）：MEDIA-SEQUENCE 不变，标记行随删除消失。
        XCTAssertTrue(result.content.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertFalse(result.content.contains("CUE-OUT"))
        XCTAssertTrue(result.content.contains("#EXT-X-ENDLIST"))
    }

    func testUnclosedCueWithMisalignedDurationNotRemoved() {
        // 无 CUE-IN：以声明时长推导终点（seg3 起点 15s + 12s = 27s），5s 段边界
        // 上 27s 无唯一切片边界 → 弃剪（安全优先，绝不越界删正片）。
        var segments: [String] = []
        for index in 0..<12 {
            if index == 3 { segments.append("#EXT-X-CUE-OUT:12.0") }
            segments.append("#EXTINF:5.0,")
            segments.append("https://cdn.example.com/media/seg\(index).ts")
        }
        let lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"] + segments + ["#EXT-X-ENDLIST"]
        let result = HLSCleaner.clean(lines.joined(separator: "\n"), sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 0, "边界不对齐的 cue 必须弃剪")
        XCTAssertTrue(result.content.contains("seg3.ts"))
    }

    func testDATERANGEWithSCTE35Removed() {
        // PDT 时钟从 epoch 基准起：seg2 前打 stamp(8)（前两段共 8s）。
        // DATERANGE 覆盖 [8s, 16s) = seg2/seg3，双 PDT 时钟选出相同边界 → 移除。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ seconds: Double) -> String {
            formatter.string(from: Date(timeIntervalSince1970: 1_780_000_000 + seconds))
        }
        var segments: [String] = []
        var clock = 0.0
        for index in 0..<12 {
            if index == 2 {
                segments.append("#EXT-X-PROGRAM-DATE-TIME:\(stamp(clock))")
                segments.append("#EXT-X-DATERANGE:ID=\"break1\",START-DATE=\"\(stamp(8.0))\",DURATION=8.0,SCTE35-OUT=0xFC3033")
            }
            if index == 4 {
                segments.append("#EXT-X-PROGRAM-DATE-TIME:\(stamp(clock))")
            }
            segments.append("#EXTINF:4.0,")
            segments.append("https://cdn.example.com/media/seg\(index).ts")
            clock += 4.0
        }
        let lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"] + segments + ["#EXT-X-ENDLIST"]
        let result = HLSCleaner.clean(lines.joined(separator: "\n"), sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 2, "DATERANGE(SCTE35-OUT) 覆盖 seg2/seg3 应移除")
        XCTAssertFalse(result.content.contains("seg2.ts"))
        XCTAssertFalse(result.content.contains("seg3.ts"))
        XCTAssertTrue(result.content.contains("seg4.ts"))
    }

    func testDATERANGEWithAppleInterstitialNotRemoved() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ seconds: Double) -> String {
            formatter.string(from: Date(timeIntervalSince1970: 1_780_000_000 + seconds))
        }
        var segments: [String] = []
        var clock = 0.0
        for index in 0..<12 {
            if index == 2 {
                segments.append("#EXT-X-PROGRAM-DATE-TIME:\(stamp(clock))")
                segments.append("#EXT-X-DATERANGE:ID=\"plug\",START-DATE=\"\(stamp(8.0))\",DURATION=8.0,CLASS=\"com.apple.hls.interstitial\",X-ASSET-URI=\"https://ads.example.com/x.m3u8\"")
            }
            segments.append("#EXTINF:4.0,")
            segments.append("https://cdn.example.com/media/seg\(index).ts")
            clock += 4.0
        }
        let lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"] + segments + ["#EXT-X-ENDLIST"]
        let result = HLSCleaner.clean(lines.joined(separator: "\n"), sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 0, "外部素材 interstitial 不在带内，不授权删除")
    }

    // MARK: - 检测器 B：结构启发式（目录指纹）

    func testRepeatedDirectoryBlockRemovedByFingerprint() {
        // 主目录 media/ 占绝对多数；同指纹广告块（ads-block/，各 2 段）在 seg5 后
        // 与 seg8 后重复出现两次、均被主块夹持 → 指纹规则全部移除。
        var segments: [String] = []
        func appendAds() {
            segments.append("#EXT-X-DISCONTINUITY")
            for ad in 0..<2 {
                segments.append("#EXTINF:4.0,")
                segments.append("https://ads.example.com/ads-block/a\(ad).ts")
            }
            segments.append("#EXT-X-DISCONTINUITY")
        }
        for index in 0..<12 {
            segments.append("#EXTINF:4.0,")
            segments.append("https://cdn.example.com/media/seg\(index).ts")
            if index == 5 { appendAds() }
            if index == 8 { appendAds() }
        }
        let lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"] + segments + ["#EXT-X-ENDLIST"]
        let result = HLSCleaner.clean(lines.joined(separator: "\n"), sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 4, "两处同指纹广告块（各 2 段）应全部移除")
        XCTAssertEqual(result.content.components(separatedBy: "ads-block").count - 1, 0)
        XCTAssertTrue(result.content.contains("seg5.ts"))
        XCTAssertTrue(result.content.contains("seg8.ts"))
    }

    // MARK: - 重建语义

    func testRebuildRenumbersSequenceAndSynthesizesAESIV() {
        // AES-128（KEY 无 IV）+ 片头两段为 /adv/ 广告：删除后首个保留切片原
        // index=2 → MEDIA-SEQUENCE 平移 +2，KEY 合成 IV=0x(sequence+2)。
        var segments: [String] = [
            "#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example.com/key.bin\"",
        ]
        for index in 0..<8 {
            let name = index < 2 ? "https://cdn.example.com/adv/seg\(index).ts" : "https://cdn.example.com/media/seg\(index).ts"
            segments.append("#EXTINF:4.0,")
            segments.append(name)
        }
        let playlist = (["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:10"] + segments + ["#EXT-X-ENDLIST"])
            .joined(separator: "\n")
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8")
        XCTAssertEqual(result.removedSegments, 2)
        XCTAssertTrue(result.content.contains("#EXT-X-MEDIA-SEQUENCE:12"), "片头 2 段被删，sequence 应 10+2")
        let ivLine = result.content.split(separator: "\n").first { $0.contains("IV=0x") }.map(String.init) ?? ""
        XCTAssertTrue(ivLine.contains(String(format: "%032x", 12)), "首个保留切片 IV 应为 0x%032x（sequence+index）")
        XCTAssertTrue(ivLine.contains("key.bin"), "KEY URI 原样保留")
        XCTAssertTrue(result.content.contains("#EXT-X-ENDLIST"))
    }

    func testRewriteUriRewritesSegmentURIs() {
        let playlist = vodPlaylist(segments: [("media/seg0.ts", 4), ("media/seg1.ts", 4)])
        var rewritten: [String] = []
        let result = HLSCleaner.clean(playlist, sourceURL: "https://cdn.example.com/index.m3u8") { target, _ in
            rewritten.append(target)
            return "http://127.0.0.1:1/hls/proxy/\(rewritten.count)"
        }
        XCTAssertTrue(result.content.contains("http://127.0.0.1:1/hls/proxy/"))
        XCTAssertFalse(result.content.contains("media/seg0.ts"))
        XCTAssertTrue(rewritten.contains("https://cdn.example.com/media/seg0.ts"))
    }

    // MARK: - MacCMS XML

    func testMacCMSXMLParsing() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="5.1"><list page="2" pagecount="9" recordcount="177">
        <class><ty id="1"><![CDATA[电影]]></ty><ty id="2">剧集</ty></class>
        <video><last>2026-01-01</last><id>101</id><tid>1</tid><name><![CDATA[测试片&名]]></name>
        <type>电影</type><pic>http://a/1.jpg</pic><note>HD</note><year>2024</year><des><![CDATA[简介<b>粗</b>]]></des>
        <dl><dd flag="qiyi"><![CDATA[第01集$http://s/1.m3u8#第02集$http://s/2.m3u8]]></dd>
        <dd flag="m3u8"><![CDATA[全集$http://s/all.m3u8]]></dd></dl></video>
        <video><id>102</id><tid>2</tid><name>第二部</name><type>剧集</type><pic></pic><note>更新至08集</note>
        <dl><dd flag="m3u8"><![CDATA[第01集$http://s/b/1.m3u8]]></dd></dl></video>
        </list></rss>
        """
        guard let document = MacCMSXML.parse(Data(xml.utf8)) else {
            return XCTFail("MacCMS XML 应可解析")
        }
        XCTAssertEqual(document.page, 2)
        XCTAssertEqual(document.pagecount, 9)
        XCTAssertEqual(document.total, 177)
        XCTAssertEqual(document.classes.count, 2)
        XCTAssertEqual(document.classes[0].id, "1")
        XCTAssertEqual(document.classes[0].name, "电影")
        XCTAssertEqual(document.videos.count, 2)
        let first = try XCTUnwrap(document.videos.first)
        XCTAssertEqual(first["vod_id"] as? String, "101")
        XCTAssertEqual(first["vod_name"] as? String, "测试片&名")
        XCTAssertEqual(first["vod_play_from"] as? String, "qiyi$$$m3u8")
        let playURL = try XCTUnwrap(first["vod_play_url"] as? String)
        XCTAssertTrue(playURL.hasPrefix("第01集$http://s/1.m3u8#第02集$http://s/2.m3u8$$$全集"))
        let second = try XCTUnwrap(document.videos.last)
        XCTAssertEqual(second["vod_remarks"] as? String, "更新至08集")
        let jsonObject = MacCMSXML.jsonObject(from: document, includeClasses: true)
        XCTAssertEqual((jsonObject["class"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(jsonObject["page"] as? Int, 2)
    }

    func testMacCMSXMLRejectsNonXML() {
        XCTAssertNil(MacCMSXML.parse(Data("<html><body>x</body></html>".utf8)))
        XCTAssertNil(MacCMSXML.parse(Data("{}".utf8)))
    }

    // MARK: - 播放结果归一化（CatSourceClient.play）

    /// 本地 HTTP 桩：任何请求返回预设 JSON。
    private func makePlayStub(_ payload: String) throws -> (port: Int, server: NWListener) {
        final class PortBox: @unchecked Sendable { var value = 0 }
        let box = PortBox()
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "test.play.stub")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                box.value = Int(listener.port?.rawValue ?? 0)
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + Data(payload.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success, "桩服务应就绪")
        return (box.value, listener)
    }

    func testPlayNormalizationNestedDataAndInlineHeaders() async throws {
        // 嵌套 data 包裹 + `url|Header=UA&Referer=…` 尾注（Header= 引导段剥离）。
        let payload = #"{"data":{"url":"http://stream.example.com/live.m3u8|Header=User-Agent=ProbeUA&Referer=http://page.example.com/","parse":0}}"#
        let stub = try makePlayStub(payload)
        defer { stub.server.cancel() }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        let result = try await client.play(apiPath: "/spider/test/3", flag: "线路1", playKey: "ep1")
        XCTAssertEqual(result.url.absoluteString, "http://stream.example.com/live.m3u8")
        XCTAssertEqual(result.headers["User-Agent"], "ProbeUA")
        XCTAssertEqual(result.headers["Referer"], "http://page.example.com/")
        XCTAssertFalse(result.isParseRequired)
    }

    func testPlayNormalizationArrayRootWithInlinePairs() async throws {
        // 数组根 + [名, url, 名2, url2] 内联画质数组 + 顶层 headers 字典。
        let payload = #"[{"url":["超清","http://s.example.com/hd.m3u8","高清","http://s.example.com/sd.m3u8"],"headers":{"User-Agent":"PairUA"}}]"#
        let stub = try makePlayStub(payload)
        defer { stub.server.cancel() }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        let result = try await client.play(apiPath: "/spider/test/3", flag: "线路1", playKey: "ep1")
        XCTAssertEqual(result.url.absoluteString, "http://s.example.com/sd.m3u8", "主地址沿用取最后带 scheme 的规则")
        XCTAssertEqual(result.qualityURLs.count, 2, "两条内联画质；主地址已在候选中，不再补默认")
        XCTAssertEqual(result.qualityURLs.first?.label, "超清")
        XCTAssertEqual(result.headers["User-Agent"], "PairUA")
    }

    func testPlayNormalizationPlainQualityArrayUnaffected() async throws {
        // 普通画质数组 [url1, url2] 不能被误判成内联对。
        let payload = #"{"url":["http://s.example.com/720.m3u8","http://s.example.com/1080.m3u8"]}"#
        let stub = try makePlayStub(payload)
        defer { stub.server.cancel() }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        let result = try await client.play(apiPath: "/spider/test/3", flag: "", playKey: "ep1")
        XCTAssertEqual(result.url.absoluteString, "http://s.example.com/1080.m3u8")
        XCTAssertTrue(result.qualityURLs.isEmpty, "普通画质数组不产生 label 对")
    }

    func testHopByHopHeadersStripped() async throws {
        let payload = #"{"url":"http://s.example.com/v.mp4","header":{"Connection":"keep-alive","Content-Length":"9","Cookie":"sid=1"}}"#
        let stub = try makePlayStub(payload)
        defer { stub.server.cancel() }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        let result = try await client.play(apiPath: "/spider/test/3", flag: "", playKey: "ep1")
        XCTAssertNil(result.headers["Connection"])
        XCTAssertNil(result.headers["Content-Length"])
        XCTAssertEqual(result.headers["Cookie"], "sid=1")
    }

    func testVodPicSanitization() throws {
        // 字典形态海报 / |Header= 尾注：折成纯 URL，不得让 Decodable 整包失败。
        let data = #"{"list":[{"vod_id":"1","vod_name":"A","vod_pic":{"url":"http://a/1.jpg","headers":{"Referer":"http://a/"}}},{"vod_id":"2","vod_name":"B","vod_pic":"http://a/2.jpg|Header=Referer=http%3A%2F%2Fa%2F"},{"vod_id":"3","vod_name":"C","vod_pic":"http://a/3.jpg"}]}"#.data(using: .utf8)!
        let sanitizer = CatSourceClient.sanitizedListData(data)
        let object = try JSONSerialization.jsonObject(with: sanitizer) as? [String: Any]
        let list = try XCTUnwrap(object?["list"] as? [[String: Any]])
        XCTAssertTrue(list[0]["vod_pic"] is String, "字典海报应折成 URL 串")
        let second = try XCTUnwrap(list[1]["vod_pic"] as? String)
        XCTAssertFalse(second.contains("|Header="), "尾注应剥离")
        XCTAssertEqual(second, "http://a/2.jpg")
        XCTAssertEqual(list[2]["vod_pic"] as? String, "http://a/3.jpg")
    }

    // MARK: - HLS 形态判定与目录推导

    func testLooksLikeHLS() throws {
        XCTAssertTrue(HLSCleaner.looksLikeHLS(try XCTUnwrap(URL(string: "https://a.example.com/x.m3u8?token=1")), inferProxy: false))
        XCTAssertTrue(HLSCleaner.looksLikeHLS(try XCTUnwrap(URL(string: "https://a.example.com/proxy?url=https%3A%2F%2Fb.example.com%2Fy.m3u8")), inferProxy: true))
        XCTAssertFalse(HLSCleaner.looksLikeHLS(try XCTUnwrap(URL(string: "https://a.example.com/video.mp4")), inferProxy: false))
        XCTAssertFalse(HLSCleaner.looksLikeHLS(try XCTUnwrap(URL(string: "https://a.example.com/proxy?url=https%3A%2F%2Fb.example.com%2Fy.mp4")), inferProxy: true))
    }

    func testDirectoryStringMatchesJSURLDot() {
        XCTAssertEqual(HLSCleaner.directoryString("https://a.example.com/b/c.ts"), "https://a.example.com/b/")
        XCTAssertEqual(HLSCleaner.directoryString("https://a.example.com/c.ts"), "https://a.example.com/")
        XCTAssertEqual(HLSCleaner.directoryString("https://a.example.com"), "https://a.example.com/")
    }

    // MARK: - TVBox 配置级 parses：CMS 播放解析判定（cms-host.js 与 NativeEngineServer 同规则）

    func testCMSPlayDecisionMatrix() {
        let flags = ["youku", "qq", "iqiyi"]
        // 媒体扩展名 → 直连（无论线路名）。
        XCTAssertFalse(NativeEngineServer.decideCMSPlay(
            playID: "https://cdn.example.com/v/1.m3u8?token=x", flag: "优酷", flags: flags).needsParse)
        // 网页播放页 → 需解析。
        XCTAssertTrue(NativeEngineServer.decideCMSPlay(
            playID: "https://v.example.com/detail/8130.html", flag: "", flags: flags).needsParse)
        // 无扩展名直连流（.php?path= 等）→ 直连（保守，防误伤）。
        XCTAssertFalse(NativeEngineServer.decideCMSPlay(
            playID: "https://live.example.com/stream.php?path=1&key=x", flag: "", flags: flags).needsParse)
        // 线路名命中 flags（youku/qq/iqiyi 族）→ 需解析（内嵌播放页）。
        XCTAssertTrue(NativeEngineServer.decideCMSPlay(
            playID: "https://player.example.com/embed?id=1", flag: "优酷youku", flags: flags).needsParse)
        XCTAssertTrue(NativeEngineServer.decideCMSPlay(
            playID: "https://player.example.com/embed?id=1", flag: "QQ专辑", flags: flags).needsParse)
        // 非 http(s)（集号/jx: 前缀）→ 维持直连透传。
        XCTAssertFalse(NativeEngineServer.decideCMSPlay(
            playID: "12345", flag: "", flags: flags).needsParse)
        XCTAssertFalse(NativeEngineServer.decideCMSPlay(
            playID: "jx:https://v.example.com/1.html", flag: "", flags: flags).needsParse)
        // 线路名与 flags 互不包含 → 直连。
        XCTAssertFalse(NativeEngineServer.decideCMSPlay(
            playID: "https://cdn.example.com/v/1.mp4", flag: "普通线路", flags: flags).needsParse)
    }

    func testNativeEngineServerCapturesParseParsers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hitplay-parse-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = """
        {"sites":[{"key":"cms1","name":"XML站","type":1,"api":"https://api.example.com/api.php/provide/vod/at/xml"}],
         "parses":[{"name":"Json并发","type":2,"url":"https://jx.example.com/api?url="},
                   {"name":"网页","type":0,"url":"https://web.example.com/?url="},
                   {"name":"坏地址","type":2,"url":"ftp://nope"}],
         "flags":["youku","QQ","iqiyi"]}
        """
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let server = NativeEngineServer(packageDir: dir)
        try server.loadConfig()
        XCTAssertEqual(server.sites.count, 1)
        XCTAssertEqual(server.parseParsers.count, 1, "只收 type 1/2 且 http(s) 的解析器")
        XCTAssertEqual(server.parseParsers.first?.url, "https://jx.example.com/api?url=")
        XCTAssertEqual(server.parseFlags, ["youku", "qq", "iqiyi"], "flags 归一小写")
    }

    // MARK: - 目录 TTL 缓存（home/category 30s）

    /// 计数 HTTP 桩：统计请求数，home 响应固定 JSON。
    private func makeCountingStub(payload: String) throws -> (port: Int, hits: () -> Int, server: NWListener) {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
            var current: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        final class PortBox: @unchecked Sendable { var value = 0 }
        let box = PortBox()
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "test.catalog.stub")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                box.value = Int(listener.port?.rawValue ?? 0)
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                counter.increment()
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + Data(payload.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success, "桩服务应就绪")
        return (box.value, { counter.current }, listener)
    }

    func testCatalogCacheReusesHomeAndCategoryResponses() async throws {
        let homePayload = #"{"class":[{"type_id":"1","type_name":"电影"}],"list":[]}"#
        let stub = try makeCountingStub(payload: homePayload)
        defer { stub.server.cancel() }
        let client = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        // 进程级缓存跨实例：两次 home（不同实例）只回源一次。
        _ = try await client.home(apiPath: "/spider/a/3")
        let second = CatSourceClient(baseURL: URL(string: "http://127.0.0.1:\(stub.port)")!)
        let home = try await second.home(apiPath: "/spider/a/3")
        XCTAssertEqual(stub.hits(), 1, "第二次 home 应命中 30s 目录缓存")
        XCTAssertEqual(home.categories.first?.name, "电影")
        // 分类缓存：不同页码/筛选是不同键。
        _ = try await client.category(apiPath: "/spider/a/3", categoryID: "1", page: 1)
        _ = try await client.category(apiPath: "/spider/a/3", categoryID: "1", page: 1)
        XCTAssertEqual(stub.hits(), 2, "同页分类第二次应命中缓存")
        _ = try await client.category(apiPath: "/spider/a/3", categoryID: "1", page: 2)
        XCTAssertEqual(stub.hits(), 3, "不同页码是不同缓存键")
    }
}
