import Foundation

/// HLS 点播播放列表去广告：三重检测求并集
/// （官方标记区间 / 结构启发式 / URL 词边界）+ 播放列表重建。
///
/// 三重检测求并集：
/// 1. 标记区间（`markedAds`）：`#EXT-X-CUE-OUT/IN`、`#EXT-X-SCTE35`、
///    `#EXT-X-DATERANGE`（要求 SCTE35-OUT 或 CLASS 含广告词）；区间端点必须
///    唯一对齐段边界，重叠冲突的不同标记全部作废（`consistentRanges`）。
/// 2. 结构启发式（`spliceAdvertisements`）：按 DISCONTINUITY 块 + URL 目录指纹，
///    主目录 ≥2/3 时长且 ≥8 切片才启动；广告块 ≤120s 且被主块夹持；命中条件 =
///    重复指纹 ≥2 次、加密流中的孤岛明文块、或头尾插入（需强化证据）。
/// 3. URL 词边界（`explicitAdvertisement`）：路径含 /ads/、/adbreak/、guanggao 等。
///
/// 安全原则（与上游一致）：
/// - 检测用的 URI 副本可解码重定向包装，但媒体条目里的 URL 逐字节原样保留
///   （query 常带签名）；
/// - 只清理 VOD 媒体 playlist（master/直播/LL-HLS 全部跳过并给出原因）；
/// - 重建时修正 `MEDIA-SEQUENCE`/`DISCONTINUITY-SEQUENCE`，AES-128 无显式 IV
///   时按 HLS 规范合成 `IV=0x<sequence+index>`。
enum HLSCleaner {
    struct CleanResult {
        let content: String
        let removedSegments: Int
        /// 空 = 已清理或无需处理；否则为跳过原因（not-hls/master/live/unsupported/ambiguous/disabled/all-segments）。
        let skippedReason: String
    }

    // MARK: - 正则工具

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static func capture(_ line: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// m3u8 属性表解析（对齐 hls-ad-markers `attributes`）：键大写、值去引号。
    static func attributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[:,])\s*([A-Z0-9-]+)=("[^"]*"|[^,]*)"#, options: [.caseInsensitive]) else { return result }
        let ns = line as NSString
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard match.numberOfRanges >= 3 else { continue }
            let key = ns.substring(with: match.range(at: 1)).uppercased()
            var value = ns.substring(with: match.range(at: 2))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// 行内属性名序列（DATERANGE 跨行同名属性合并时的重复键检查用）。
    private static func attributeNames(_ line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[:,])\s*([A-Z0-9-]+)=("[^"]*"|[^,]*)"#, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            .compactMap { match in
                guard match.numberOfRanges >= 2 else { return nil }
                let ns = line as NSString
                return ns.substring(with: match.range(at: 1)).uppercased()
            }
    }

    private static let numberPattern = #"^(?:\d+(?:\.\d*)?|\.\d+)$"#

    private static func number(_ value: String?) -> Double {
        guard let value, matches(value, numberPattern) else { return .nan }
        return Double(value) ?? .nan
    }

    private static let maxAdDuration = 600.0
    private static let tolerance = 0.1
    private static func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) <= tolerance }
    private static func bounded(_ value: Double) -> Bool { value.isFinite && value > 0 && value <= maxAdDuration }

    // MARK: - 检测用 URI 副本（ad-detection `detectionUri`/`explicitAdvertisement`）

    /// 穿透最多 3 层 `?url=`/`?source=` 代理包装，返回可检视的 URL（保持原始条目不变）。
    static func detectionUri(_ raw: String) -> URL? {
        var url: URL?
        var current = raw
        for _ in 0..<3 {
            guard let parsed = URL(string: current), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            url = parsed
            let path = parsed.path
            guard path.hasSuffix("/proxy") || path.hasSuffix("/m3u8-clean")
                    || path.hasSuffix("/proxy/") || path.hasSuffix("/m3u8-clean/") else { break }
            guard let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
                  let target = components.queryItems?.first(where: { $0.name == "url" || $0.name == "source" })?.value,
                  let targetURL = URL(string: target),
                  let targetScheme = targetURL.scheme?.lowercased(),
                  targetScheme == "http" || targetScheme == "https" else { break }
            current = target
        }
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func decodePath(_ path: String) -> String {
        path.removingPercentEncoding ?? path
    }

    /// URL 路径词边界广告特征（ads/adbreak/guanggao 等，对齐 ad-detection `explicitAdvertisement`）。
    static func explicitAdvertisement(_ raw: String) -> Bool {
        guard let url = detectionUri(raw) else { return false }
        let pathname = decodePath(url.path)
        return matches(pathname, #"(?:^|/)(?:ads?|adv|advert|advertisement|adserver|adsegment|adbreak|guanggao)(?:[/_.-]|$)"#)
    }

    /// URL 的目录地址（对齐 JS `new URL('.', url).href`）：保留 path 最后一段之前的完整前缀。
    static func directoryString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString), components.scheme != nil else { return urlString }
        var directory = (components.path as NSString).deletingLastPathComponent
        if directory.count > 1 { directory += "/" }
        components.path = directory.hasPrefix("/") ? directory : "/" + directory
        components.query = nil
        components.fragment = nil
        return components.string ?? urlString
    }

    /// URL 的 origin（对齐 JS `new URL(x).origin`）：scheme://host[:port]。
    private static func origin(of urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let host = url.host else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    // MARK: - 播放列表解析（hls-cleaner `mediaEntries`）

    private static let globalTagPattern = #"^#(?:EXTM3U$|EXT-X-(?:VERSION|TARGETDURATION|MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE|PLAYLIST-TYPE|INDEPENDENT-SEGMENTS|START|ALLOW-CACHE):?)"#
    private static let stateTagPattern = #"^#EXT-X-(?:KEY|MAP|BYTERANGE):"#

    final class Tag {
        let line: String
        let index: Int
        init(line: String, index: Int) {
            self.line = line
            self.index = index
        }
    }

    /// KEY 状态（class 保持引用语义：同一 KEY 行在多个切片间共享同一实例）。
    final class KeyState {
        let line: String
        let method: String
        let uri: String?
        let iv: String?
        let keyFormat: String?
        init(line: String, fields: [String: String]) {
            self.line = line
            self.method = fields["METHOD"] ?? ""
            self.uri = fields["URI"]
            self.iv = fields["IV"]
            self.keyFormat = fields["KEYFORMAT"]
        }
    }

    final class MapState {
        let line: String
        let key: KeyState?
        init(line: String, key: KeyState?) {
            self.line = line
            self.key = key
        }
    }

    struct Entry {
        let uri: String
        let url: String
        let duration: Double
        let tags: [Tag]
        let key: KeyState?
        let map: MapState?
        let byteRange: String?
        let discontinuities: Int
        let index: Int
    }

    struct ParsedPlaylist {
        let headers: [String]
        let entries: [Entry]
        let tail: [Tag]
        let sequence: Int64
        let discontinuitySequence: Int64
        let invalid: Bool
    }

    /// 绝对化 URI：已带 scheme 的逐字节原样返回（签名保护），相对地址才解析拼接。
    static func absoluteUri(_ raw: String, base sourceURL: String) -> String {
        if matches(raw, #"^[a-z][a-z\d+.-]*:"#) { return raw }
        guard let base = URL(string: sourceURL), let resolved = URL(string: raw, relativeTo: base) else { return raw }
        return resolved.absoluteString
    }

    private static func parseMediaEntries(_ lines: [String], sourceURL: String) -> ParsedPlaylist {
        var headers: [String] = []
        var entries: [Entry] = []
        var pending: [Tag] = []
        var key: KeyState?
        var map: MapState?
        var previousRange: (url: String, end: Int64)?
        var discontinuities = 0
        var sequence: Int64 = 0
        var discontinuitySequence: Int64 = 0
        var invalid = false

        // tag 身份 = 行号（markers 集合按行号去重，重建时按行号剔除标记行）。
        for (lineIndex, line) in lines.enumerated() {
            if matches(line, globalTagPattern) {
                headers.append(line)
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    if let value = Int64(line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "") {
                        sequence = value
                    } else { invalid = true }
                }
                if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                    if let value = Int64(line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "") {
                        discontinuitySequence = value
                    } else { invalid = true }
                }
                continue
            }
            if line == "#EXT-X-ENDLIST" { continue }
            if line.hasPrefix("#") {
                pending.append(Tag(line: line, index: lineIndex))
                if line == "#EXT-X-DISCONTINUITY" { discontinuities += 1 }
                if line.hasPrefix("#EXT-X-KEY:") {
                    let fields = attributes(line)
                    let keyFormatOK = fields["KEYFORMAT"] == nil || fields["KEYFORMAT"] == "identity"
                    let ivOK: Bool
                    if fields["METHOD"] == "AES-128" {
                        let hasURI = fields["URI"] != nil && !fields["URI"]!.isEmpty
                        let ivValid = fields["IV"] == nil || matches(fields["IV"] ?? "", #"^0x[\da-f]{1,32}$"#)
                        ivOK = hasURI && ivValid
                    } else { ivOK = true }
                    if !["NONE", "AES-128"].contains(fields["METHOD"] ?? "") || !keyFormatOK || !ivOK { invalid = true }
                    key = KeyState(line: line, fields: fields)
                }
                if line.hasPrefix("#EXT-X-MAP:") {
                    let fields = attributes(line)
                    let hasURI = fields["URI"] != nil && !fields["URI"]!.isEmpty
                    let rangeOK = fields["BYTERANGE"] == nil || matches(fields["BYTERANGE"] ?? "", #"^\d+@\d+$"#)
                    // 加密的 init 段需要显式 IV：前序切片被删后隐式范围无法可靠重建。
                    let mapIVOK = !(key?.method == "AES-128" && key?.iv == nil)
                    if !hasURI || !rangeOK || !mapIVOK { invalid = true }
                    map = MapState(line: line, key: key)
                }
                continue
            }
            let tags = pending
            pending = []
            let durations = tags.filter { $0.line.hasPrefix("#EXTINF:") }
            let durationText = durations.first.flatMap { capture($0.line, #"^#EXTINF:([\d.]+),"#) }
            let duration = durationText.flatMap(Double.init) ?? .nan
            if durations.count != 1 || !duration.isFinite || duration <= 0 { invalid = true }
            let url = absoluteUri(line, base: sourceURL)
            var byteRange: String?
            let ranges = tags.filter { $0.line.hasPrefix("#EXT-X-BYTERANGE:") }
            if !ranges.isEmpty {
                let matchText = ranges[0].line
                let lengthText = capture(matchText, #"^#EXT-X-BYTERANGE:(\d+)(?:@(\d+))?$"#)
                let offsetText = capture(matchText, #"^#EXT-X-BYTERANGE:\d+@(\d+)$"#)
                let length = lengthText.flatMap(Int64.init)
                if ranges.count != 1 || length == nil || length! <= 0 {
                    invalid = true
                } else {
                    let offset: Int64?
                    if let offsetText { offset = Int64(offsetText) }
                    else if previousRange?.url == url { offset = previousRange?.end }
                    else { offset = nil }
                    if let offset {
                        byteRange = "#EXT-X-BYTERANGE:\(length!)@\(offset)"
                        previousRange = (url, offset + length!)
                    } else { invalid = true }
                }
            } else {
                previousRange = nil
            }
            entries.append(Entry(uri: line, url: url, duration: duration.isFinite ? duration : 0,
                                 tags: tags, key: key, map: map, byteRange: byteRange,
                                 discontinuities: discontinuities, index: entries.count))
        }
        if pending.contains(where: { matches($0.line, #"^(?:#EXTINF:|#EXT-X-BYTERANGE:)"#) }) { invalid = true }
        if sequence < 0 || discontinuitySequence < 0 || discontinuities > 1000 { invalid = true }
        return ParsedPlaylist(headers: headers, entries: entries, tail: pending,
                              sequence: sequence, discontinuitySequence: discontinuitySequence, invalid: invalid)
    }

    // MARK: - 标记区间检测（hls-ad-markers `markedAds`）

    private struct CueEvent {
        enum Kind { case out, input, `continue` }
        let type: Kind
        let family: String
        var duration: Double
        var total: Double
        var elapsed: Double
        var invalid: Bool
    }

    private static func cueEvent(_ line: String) -> CueEvent? {
        let fields = attributes(line)
        if matches(line, #"^#EXT-X-CUE-OUT-CONT(?::|$)"#) {
            let compact = line.range(of: #"^#EXT-X-CUE-OUT-CONT:([\d.]+)/([\d.]+)$"#, options: .regularExpression) != nil
            let elapsedText = compact ? (capture(line, #"^#EXT-X-CUE-OUT-CONT:([\d.]+)/"#) ?? fields["ELAPSEDTIME"]) : fields["ELAPSEDTIME"]
            let totalText = compact ? (capture(line, #"^#EXT-X-CUE-OUT-CONT:[\d.]+/([\d.]+)$"#) ?? fields["DURATION"]) : fields["DURATION"]
            let elapsed = number(elapsedText)
            let total = number(totalText)
            let invalid = !bounded(total) || !elapsed.isFinite || elapsed < 0 || elapsed >= total
            return CueEvent(type: .continue, family: "cue", duration: total - elapsed, total: total, elapsed: elapsed, invalid: invalid)
        }
        var type: CueEvent.Kind?
        if matches(line, #"^#EXT-X-(?:CUE|SCTE35)-OUT(?::|$)"#) { type = .out }
        else if matches(line, #"^#EXT-X-(?:CUE|SCTE35)-IN(?::|$)"#) { type = .input }
        else if line.hasPrefix("#EXT-X-SCTE35:"), let rawType = fields["TYPE"]?.uppercased(),
                rawType == "OUT" || rawType == "IN" {
            type = rawType == "OUT" ? .out : .input
        }
        guard let eventType = type else { return nil }
        let value = capture(line, #"^#EXT-X-(?:CUE|SCTE35)-OUT:([\d.]+)$"#) ?? fields["DURATION"]
        let duration = number(value)
        let family = line.hasPrefix("#EXT-X-CUE-") ? "cue" : "scte"
        let invalid: Bool
        if value != nil { invalid = !bounded(duration) } else { invalid = false }
        return CueEvent(type: eventType, family: family, duration: duration, total: .nan, elapsed: .nan, invalid: invalid)
    }

    /// 在偏移序列里找与目标对齐（0.1s 容差）的唯一切片边界；命中多个或没有则失败。
    private static func uniqueBoundary(_ offsets: [Double], _ target: Double, minimum: Int = 0) -> Int? {
        var match: Int?
        if minimum >= offsets.count { return nil }
        for index in minimum..<offsets.count {
            if near(offsets[index], target) {
                if match != nil { return nil }
                match = index
            }
            if offsets[index] > target + tolerance { break }
        }
        return match
    }

    private final class CueRange {
        var start: Int
        var duration: Double
        var total: Double
        var initialElapsed: Double
        var invalid: Bool
        var continuation: Bool
        var families: Set<String>
        var markers: [Int]
        var end: Int?
        var closedFamilies: Set<String>?
        init(start: Int, duration: Double, total: Double, initialElapsed: Double,
             invalid: Bool, continuation: Bool = false, families: Set<String>, markers: [Int]) {
            self.start = start
            self.duration = duration
            self.total = total
            self.initialElapsed = initialElapsed
            self.invalid = invalid
            self.continuation = continuation
            self.families = families
            self.markers = markers
        }
    }

    private static func cueRanges(_ groups: [(Int, [Tag])], _ offsets: [Double]) -> [CueRange] {
        var ranges: [CueRange] = []
        func durationEnd(_ range: CueRange) -> Int? {
            guard !range.invalid, bounded(range.duration) else { return nil }
            guard let end = uniqueBoundary(offsets, offsets[range.start] + range.duration, minimum: range.start + 1) else { return nil }
            return bounded(offsets[end] - offsets[range.start]) ? end : nil
        }
        var active: CueRange?
        for (index, tags) in groups {
            for tag in tags {
                guard let event = cueEvent(tag.line) else { continue }
                switch event.type {
                case .out:
                    // 一次 splice 可能同时有 CUE 与 SCTE 两族标记：仅时长一致才共享区间。
                    if let current = active, current.start == index, !current.continuation, !current.families.contains(event.family) {
                        if event.invalid || (current.duration.isFinite && event.duration.isFinite && current.duration != event.duration) {
                            current.invalid = true
                        }
                        if !current.duration.isFinite {
                            current.total = event.duration
                            current.duration = event.duration
                        }
                        current.families.insert(event.family)
                        current.markers.append(tag.index)
                        continue
                    }
                    if let current = active {
                        if let end = durationEnd(current), end <= index {
                            current.end = end
                            ranges.append(current)
                        } else {
                            current.invalid = true
                        }
                    }
                    active = CueRange(start: index, duration: event.duration, total: event.duration,
                                      initialElapsed: 0, invalid: event.invalid,
                                      families: [event.family], markers: [tag.index])
                case .continue:
                    if active == nil {
                        active = CueRange(start: index, duration: event.duration, total: event.total,
                                          initialElapsed: event.elapsed, invalid: event.invalid,
                                          continuation: true, families: [event.family], markers: [tag.index])
                        continue
                    }
                    guard let current = active else { continue }
                    current.markers.append(tag.index)
                    current.continuation = true
                    let spent = offsets[index] - offsets[current.start]
                    if event.invalid || !near(current.initialElapsed + spent, event.elapsed)
                        || (current.total.isFinite && !near(current.total, event.total)) {
                        current.invalid = true
                    }
                    if !current.total.isFinite {
                        current.total = event.total
                        current.duration = event.total - current.initialElapsed
                    }
                case .input:
                    if let current = active {
                        current.end = index
                        current.closedFamilies = [event.family]
                        current.markers.append(tag.index)
                        ranges.append(current)
                        active = nil
                    } else if let previous = ranges.last {
                        // CUE IN 落在已收区间端点上：另一族标记对同一区间的补关。
                        if previous.end == index, previous.families.contains(event.family),
                           let closed = previous.closedFamilies, !closed.contains(event.family) {
                            previous.closedFamilies?.insert(event.family)
                            previous.markers.append(tag.index)
                        }
                    }
                }
            }
        }
        if let current = active { ranges.append(current) }
        return ranges.filter { range in
            if range.invalid { return false }
            if range.end == nil {
                range.end = durationEnd(range)
            }
            guard let end = range.end, end > range.start else { return false }
            let actual = offsets[end] - offsets[range.start]
            // 显式 CUE IN 是普通配对 cue 的实际终点；continue 断言了已播时长，
            // 其剩余时长也必须吻合。
            return bounded(actual) && (!range.continuation || near(actual, range.duration))
        }
    }

    /// 带时区的 ISO8601 时间戳（秒）；要求显式时区避免本地时区误读。
    private static func timestamp(_ value: String?) -> Double {
        guard let value else { return .nan }
        guard matches(value, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#) else { return .nan }
        let hasFraction = value.contains(".")
        let formatter = hasFraction ? fractionFormatter : plainFormatter
        guard let date = formatter.date(from: value) else { return .nan }
        return date.timeIntervalSince1970
    }

    private static let fractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private struct DateRangeMatch {
        var start: Int
        var end: Int
        var markers: [Int]
    }

    private static func dateRanges(_ groups: [(Int, [Tag])], _ offsets: [Double]) -> [DateRangeMatch] {
        struct Record {
            var fields: [String: String] = [:]
            var markers: [Int] = []
            var invalid = false
        }
        var records: [String: Record] = [:]
        var orderedKeys: [String] = []
        var origins: [Double] = []
        for (index, tags) in groups {
            for tag in tags {
                if tag.line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                    // 尾部 tag 没有后续媒体切片可打时间戳。
                    if index < offsets.count - 1 {
                        let text = String(tag.line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                        let stamp = timestamp(text.trimmingCharacters(in: .whitespaces))
                        if stamp.isFinite { origins.append(stamp - offsets[index]) }
                    }
                }
                guard tag.line.hasPrefix("#EXT-X-DATERANGE:") else { continue }
                let fields = attributes(tag.line)
                guard let id = fields["ID"] else { continue }
                if records[id] == nil {
                    records[id] = Record()
                    orderedKeys.append(id)
                }
                records[id]?.markers.append(tag.index)
                let names = attributeNames(tag.line)
                if Set(names).count != names.count { records[id]?.invalid = true }
                for (name, value) in fields {
                    if let existing = records[id]?.fields[name], existing != value { records[id]?.invalid = true }
                    records[id]?.fields[name] = value
                }
            }
        }
        if origins.isEmpty || origins.contains(where: { !$0.isFinite || !near($0, origins[0]) }) { return [] }
        var ranges: [DateRangeMatch] = []
        for id in orderedKeys {
            guard let record = records[id] else { continue }
            let fields = record.fields
            if record.invalid || fields["X-ASSET-URI"] != nil || fields["X-ASSET-LIST"] != nil
                || matches(fields["CLASS"] ?? "", #"^com\.apple\.hls\.interstitial(?:$|[.\-])"#) { continue }
            // 只认带 SCTE35-OUT 或 CLASS 含广告词边界的区间；外部素材（asset）不在带内。
            let classIsAd = matches(fields["CLASS"] ?? "", #"(?:^|[./_-])(?:ad|ads|advertisement|adbreak)(?:$|[./_-])"#)
            if fields["SCTE35-OUT"] == nil && !classIsAd { continue }
            let startTime = timestamp(fields["START-DATE"])
            let duration = number(fields["DURATION"])
            var endTime = timestamp(fields["END-DATE"])
            if !startTime.isFinite { continue }
            if fields["DURATION"] != nil && !bounded(duration) { continue }
            if fields["END-DATE"] != nil && !endTime.isFinite { continue }
            if endTime.isFinite && duration.isFinite && !near(endTime - startTime, duration) { continue }
            if !endTime.isFinite { endTime = startTime + duration }
            if !bounded(endTime - startTime) { continue }
            guard let start = uniqueBoundary(offsets, startTime - origins[0]),
                  let end = uniqueBoundary(offsets, endTime - origins[0]),
                  end > start, bounded(offsets[end] - offsets[start]) else { continue }
            // 所有独立时钟必须选出相同的切片边界。
            let clocksAgree = origins.allSatisfy { origin in
                uniqueBoundary(offsets, startTime - origin) == start
                    && uniqueBoundary(offsets, endTime - origin) == end
            }
            guard clocksAgree else { continue }
            ranges.append(DateRangeMatch(start: start, end: end, markers: record.markers))
        }
        return ranges
    }

    /// 不同标记格式的重叠区间必须边界一致；冲突不能授权并集（可能越界删正片）。
    private static func consistentRanges(_ cue: [CueRange], _ dated: [DateRangeMatch]) -> [(start: Int, end: Int, markers: [Int])]? {
        // 先合并成同型区间再做两两仲裁；invalid 的直接丢弃。
        var all: [(start: Int, end: Int, markers: [Int], invalid: Bool)] =
            cue.map { ($0.start, $0.end ?? -1, $0.markers, false) }
        all.append(contentsOf: dated.map { ($0.start, $0.end, $0.markers, false) })
        for left in 0..<all.count {
            for right in (left + 1)..<all.count {
                let a = all[left], b = all[right]
                if a.start < b.end && b.start < a.end && (a.start != b.start || a.end != b.end) {
                    all[left].invalid = true
                    all[right].invalid = true
                }
            }
        }
        let valid = all.filter { !$0.invalid }.map { (start: $0.start, end: $0.end, markers: $0.markers) }
        return valid.isEmpty ? nil : valid
    }

    /// 标记检测入口（对齐 `markedAds`）：返回 (待删切片索引, 标记行号)。
    static func markedAds(_ parsed: ParsedPlaylist) -> (removed: Set<Int>, markers: Set<Int>) {
        var removed = Set<Int>()
        var markers = Set<Int>()
        var offsets: [Double] = [0]
        for entry in parsed.entries { offsets.append((offsets.last ?? 0) + entry.duration) }
        var groups: [(Int, [Tag])] = parsed.entries.map { ($0.index, $0.tags) }
        groups.append((parsed.entries.count, parsed.tail))
        let cue = cueRanges(groups, offsets)
        let dated = dateRanges(groups, offsets)
        // consistentRanges 返回 nil 表示无有效区间（包括全部冲突作废）。
        var ranges: [(start: Int, end: Int, markers: [Int])] = []
        let merged = consistentRanges(cue, dated)
        if let merged { ranges = merged }
        for range in ranges {
            if range.end <= range.start { continue }
            for index in range.start..<range.end { removed.insert(index) }
            for marker in range.markers { markers.insert(marker) }
        }
        return (removed, markers)
    }

    // MARK: - 结构启发式（hls-ad-splices `spliceAdvertisements`）

    /// 加密状态的指纹键（对齐 `keyState`）：METHOD/URI/归一化 IV/KEYFORMAT。
    private static func keyState(_ entry: Entry?) -> String {
        guard let key = entry?.key, key.method != "NONE" else { return "NONE" }
        let iv = key.iv.flatMap { value -> String? in
            let hex = value.hasPrefix("0x") || value.hasPrefix("0X") ? String(value.dropFirst(2)) : value
            let trimmed = hex.lowercased().drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        } ?? ""
        return "[\"\(key.method)\",\"\(key.uri ?? "")\",\"\(iv)\",\"\(key.keyFormat ?? "identity")\"]"
    }

    /// DISCONTINUITY 块级广告识别。返回待删切片索引集合。
    static func spliceAdvertisements(_ parsed: ParsedPlaylist) -> Set<Int> {
        struct Block {
            let index: Int
            let discontinuities: Int
            var entries: [Entry] = []
            var duration: Double = 0
            var directory: String = ""
            var main = false
        }
        var removed = Set<Int>()
        let entries = parsed.entries
        guard entries.count >= 12 else { return removed }
        var totals: [String: (count: Int, duration: Double)] = [:]
        var directories: [String] = []
        var blocks: [Block] = []
        var totalDuration = 0.0
        for entry in entries {
            let url = detectionUri(entry.url)
            let directory = url != nil ? directoryString(entry.url) : ""
            directories.append(directory)
            var total = totals[directory] ?? (0, 0)
            total.count += 1
            total.duration += entry.duration
            totals[directory] = total
            totalDuration += entry.duration
            if blocks.isEmpty || blocks.last!.discontinuities != entry.discontinuities {
                blocks.append(Block(index: blocks.count, discontinuities: entry.discontinuities))
            }
            blocks[blocks.count - 1].entries.append(entry)
            blocks[blocks.count - 1].duration += entry.duration
        }
        // 主内容按实际媒体推断（清单本身可能就挂在广告 CDN 上）。
        guard let (main, mainTotal) = totals.sorted(by: { $0.value.duration > $1.value.duration }).first,
              !main.isEmpty, mainTotal.count >= 8, mainTotal.duration >= totalDuration * (2.0 / 3.0) else { return removed }
        let overwhelming = mainTotal.duration >= totalDuration * 0.9
        for index in blocks.indices {
            let first = directories[blocks[index].entries[0].index]
            let uniform = blocks[index].entries.allSatisfy { directories[$0.index] == first }
            blocks[index].directory = uniform ? first : ""
            blocks[index].main = blocks[index].directory == main
        }
        let candidates = blocks.filter { block in
            let before = block.index > 0 ? blocks[block.index - 1] : nil
            let after = block.index + 1 < blocks.count ? blocks[block.index + 1] : nil
            return !block.main && !block.directory.isEmpty && block.duration <= 120
                && (before == nil || before!.main) && (after == nil || after!.main)
                && block.entries.allSatisfy { $0.map == nil && $0.byteRange == nil }
        }
        var fingerprints: [String: [Block]] = [:]
        var provenDirectories = Set<String>()
        func sameMainState(_ block: Block) -> Bool {
            let before = block.index > 0 ? blocks[block.index - 1] : nil
            let after = block.index + 1 < blocks.count ? blocks[block.index + 1] : nil
            guard let before, let after, before.main, after.main else { return false }
            return keyState(before.entries.last) == keyState(after.entries.first)
        }
        func mark(_ block: Block) {
            for entry in block.entries { removed.insert(entry.index) }
            let beforeIsMain = block.index > 0 && blocks[block.index - 1].main
            let afterIsMain = block.index + 1 < blocks.count && blocks[block.index + 1].main
            if beforeIsMain && afterIsMain { provenDirectories.insert(block.directory) }
        }
        for block in candidates {
            let clear = block.entries.allSatisfy { keyState($0) == "NONE" }
            let fingerprint = "[" + block.entries.map { entry -> String in
                "[\"\(entry.url)\",\(entry.duration),\(keyState(entry))]"
            }.joined(separator: ",") + "]"
            fingerprints[fingerprint, default: []].append(block)
            // 加密正片里的孤岛明文块：不必与先前广告逐字节重复。
            if overwhelming, clear, sameMainState(block),
               block.index > 0, blocks[block.index - 1].entries.last?.key?.method == "AES-128" {
                mark(block)
            }
        }
        for (_, matches) in fingerprints where matches.count >= 2 && matches.contains(where: sameMainState) {
            for block in matches { mark(block) }
        }
        for block in candidates {
            let before = block.index > 0 ? blocks[block.index - 1] : nil
            let after = block.index + 1 < blocks.count ? blocks[block.index + 1] : nil
            if !overwhelming || !block.entries.allSatisfy({ keyState($0) == "NONE" })
                || block.entries.count < 2
                || (Double(mainTotal.count) < Double(entries.count) * 0.9 && !provenDirectories.contains(block.directory)) { continue }
            if before != nil && after != nil { continue }
            let first = block.entries[0]
            let neighbor = before?.entries.last ?? after?.entries.first
            let explicitReset = first.key?.method == "NONE" && first.tags.contains { $0.line.hasPrefix("#EXT-X-KEY:") }
            // 无标记的明文头插需要更强的同源证据；不能把普通 CDN 容灾切成广告。
            var unmarkedPrefix = false
            if before == nil, block.duration <= 30, mainTotal.duration >= totalDuration * 0.95,
               Double(mainTotal.count) >= Double(entries.count) * 0.95,
               let blockOrigin = origin(of: block.directory), let mainOrigin = origin(of: main),
               blockOrigin == mainOrigin {
                unmarkedPrefix = true
            }
            if !explicitReset, neighbor?.key?.method != "AES-128", !unmarkedPrefix { continue }
            let occurrences = blocks.filter { item in item.entries.contains { directories[$0.index] == block.directory } }.count
            // 反复出现的片头/片尾素材：除非内部插入已独立证实该目录是广告源，否则保留。
            if occurrences == 1 || provenDirectories.contains(block.directory) { mark(block) }
        }
        return removed
    }

    // MARK: - 重建（hls-cleaner `rebuild`/`rewritePlaylist`）

    private static func rebuild(_ parsed: ParsedPlaylist, _ removed: Set<Int>, _ markers: Set<Int>) -> [String] {
        let kept = parsed.entries.filter { !removed.contains($0.index) }
        guard let first = kept.first else { return parsed.headers }
        var headers = parsed.headers.filter { !matches($0, #"^#EXT-X-(?:MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE):"#) }
        headers.append("#EXT-X-MEDIA-SEQUENCE:\(parsed.sequence + Int64(first.index))")
        let hadDiscSequence = parsed.headers.contains { $0.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") }
        if parsed.discontinuitySequence != 0 || first.discontinuities != 0 || hadDiscSequence {
            headers.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(parsed.discontinuitySequence + Int64(first.discontinuities))")
        }
        var output = headers
        var lastKey: String?
        var lastMap: MapState?
        var previous: Entry?
        func emitKey(_ key: KeyState?, _ index: Int) {
            var line = key?.line
            if let key, key.method == "AES-128", key.iv == nil {
                let sequenceValue = parsed.sequence + Int64(index)
                line = (line ?? "") + ",IV=0x" + String(format: "%032x", sequenceValue)
            }
            if let line, line != lastKey { output.append(line) }
            lastKey = line
        }
        for entry in kept {
            if let previous {
                var count = max(entry.discontinuities - previous.discontinuities, entry.index != previous.index + 1 ? 1 : 0)
                while count > 0 {
                    output.append("#EXT-X-DISCONTINUITY")
                    count -= 1
                }
            }
            if let map = entry.map, map !== lastMap {
                emitKey(map.key, entry.index)
                output.append(map.line)
                lastMap = map
            }
            emitKey(entry.key, entry.index)
            for tag in entry.tags {
                if matches(tag.line, stateTagPattern) || tag.line == "#EXT-X-DISCONTINUITY" || markers.contains(tag.index) { continue }
                output.append(tag.line)
            }
            if let byteRange = entry.byteRange { output.append(byteRange) }
            output.append(entry.uri)
            previous = entry
        }
        for tag in parsed.tail where !matches(tag.line, stateTagPattern) && tag.line != "#EXT-X-DISCONTINUITY" && !markers.contains(tag.index) {
            output.append(tag.line)
        }
        output.append("#EXT-X-ENDLIST")
        return output
    }

    /// URI 重写为回调地址（本地代理 capability URL）；`{$` 变量绑定保持原样。
    private static func rewritePlaylist(_ lines: [String], sourceURL: String, rewriteUri: ((String, Bool) -> String)?) -> String {
        var variant = false
        func resolve(_ raw: String, _ playlist: Bool) -> String {
            if raw.contains("{$") { return raw }
            let absolute = absoluteUri(raw, base: sourceURL)
            guard absolute.lowercased().hasPrefix("http://") || absolute.lowercased().hasPrefix("https://") else { return absolute }
            return rewriteUri?(absolute, playlist) ?? absolute
        }
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines {
            if !line.hasPrefix("#") {
                let result = resolve(line, variant || matches(line, #"\.m3u8(?:[?#]|$)"#))
                variant = false
                output.append(result)
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { variant = true }
            let playlistTag = matches(line, #"^#EXT-X-(?:MEDIA|I-FRAME-STREAM-INF|RENDITION-REPORT):"#)
            if let regex = try? NSRegularExpression(pattern: #"([:,])URI=("[^"]*"|[^,]*)"#) {
                let ns = line as NSString
                var rebuilt = ""
                var cursor = 0
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard match.numberOfRanges >= 3 else { continue }
                    let prefix = ns.substring(with: match.range(at: 1))
                    var value = ns.substring(with: match.range(at: 2))
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    let resolved = resolve(value, playlistTag)
                    rebuilt += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    rebuilt += "\(prefix)URI=\"\(resolved)\""
                    cursor = match.range.location + match.range.length
                }
                rebuilt += ns.substring(from: cursor)
                output.append(rebuilt)
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    // MARK: - 入口（对齐 `cleanHlsPlaylist`）

    static func clean(_ content: String, sourceURL: String, enabled: Bool = true,
                      rewriteUri: ((String, Bool) -> String)? = nil) -> CleanResult {
        let original = content
        guard original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return CleanResult(content: original, removedSegments: 0, skippedReason: "not-hls")
        }
        let withoutBOM = original.hasPrefix("\u{FEFF}") ? String(original.dropFirst()) : original
        var lines = withoutBOM.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        lines = lines.filter { !$0.isEmpty }
        var output = lines
        var removedSegments = 0
        var skippedReason = ""
        if !enabled {
            skippedReason = "disabled"
        } else if lines.contains(where: { matches($0, #"^#EXT-X-(?:STREAM-INF|I-FRAME-STREAM-INF|MEDIA):"#) }) {
            skippedReason = "master"
        } else if !lines.contains("#EXT-X-ENDLIST") {
            skippedReason = "live"
        } else if lines.contains(where: { matches($0, #"^#EXT-X-(?:PART|PART-INF|PRELOAD-HINT|SKIP|DEFINE|RENDITION-REPORT):"#) }) {
            skippedReason = "unsupported"
        } else {
            let parsed = parseMediaEntries(lines, sourceURL: sourceURL)
            if parsed.invalid {
                skippedReason = "ambiguous"
            } else {
                let (marked, markers) = markedAds(parsed)
                var removed = marked
                for index in spliceAdvertisements(parsed) { removed.insert(index) }
                for entry in parsed.entries where explicitAdvertisement(entry.url) { removed.insert(entry.index) }
                if !removed.isEmpty && removed.count < parsed.entries.count {
                    output = rebuild(parsed, removed, markers)
                    removedSegments = removed.count
                } else if !removed.isEmpty {
                    skippedReason = "all-segments"
                }
            }
        }
        return CleanResult(content: rewritePlaylist(output, sourceURL: sourceURL, rewriteUri: rewriteUri),
                           removedSegments: removedSegments, skippedReason: skippedReason)
    }

    /// HLS 形态判定（对齐 hls-proxy `isHls`）：显式 m3u8、扩展名或代理 query 内嵌。
    static func looksLikeHLS(_ url: URL, inferProxy: Bool) -> Bool {
        let urlString = url.absoluteString
        if matches(urlString, #"\.m3u8(?:[?#]|$)"#) { return true }
        guard inferProxy, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let path = components.path
        guard path.hasSuffix("/proxy") || path.hasSuffix("/m3u8-clean")
                || path.hasSuffix("/proxy/") || path.hasSuffix("/m3u8-clean/") else { return false }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        if let type = value("type") ?? value("format"), ["m3u8", "hls"].contains(type.lowercased()) { return true }
        // Python 代理常把签名 playlist 藏在编码后的 query 值里：解析副本检视。
        for name in ["url", "source"] {
            guard let target = value(name), let targetURL = URL(string: target),
                  let scheme = targetURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if matches(targetURL.path, #"\.m3u8$"#) { return true }
        }
        return false
    }
}
