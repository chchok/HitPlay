import Foundation

/// MacCMS XML 采集接口解析（`?ac=videolist` / `?ac=detail` 的 `<rss><list><video>` 形态）。
///
/// TVBox 生态大量存量源只提供 XML 接口（`at=xml`/`.xml`），此前 HitPlay 的
/// type 0/1 CMS 直连只认 JSON。解析输出对齐 MacCMS vod json 的字段约定：
/// `vod_id/vod_name/vod_pic/vod_remarks/vod_year/vod_content/vod_play_from/
/// vod_play_url`（线路按 `$$$` 连接、集按 `#`、集名与地址按 `$`），分类输出
/// `type_id/type_name`，分页输出 `page/pagecount/total`。
enum MacCMSXML {
    struct Document {
        var classes: [(id: String, name: String)] = []
        var videos: [[String: Any]] = []
        var page = 1
        var pagecount = 1
        var total = 0
    }

    /// 解析失败返回 nil（调用方回退报「接口不兼容」）；解析成功但没有任何
    /// video/class（如普通 HTML/XML 页面）同样视为不兼容。
    static func parse(_ data: Data) -> Document? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // MacCMS 采集站常带非严格 XML（未转义 &、编码声明漂移）：容错解析。
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var document = delegate.document
        guard !document.videos.isEmpty || !document.classes.isEmpty else { return nil }
        if document.total == 0 { document.total = document.videos.count }
        return document
    }

    /// 转为与 cms json 同形的字典（供 NativeEngineServer 的 cmsListPayload 复用）。
    static func jsonObject(from document: Document, includeClasses: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "list": document.videos,
            "page": document.page,
            "pagecount": document.pagecount,
            "total": document.total,
        ]
        if includeClasses {
            payload["class"] = document.classes.map { ["type_id": $0.id, "type_name": $0.name] }
        }
        return payload
    }

    /// 嗅探：正文是否为 MacCMS XML（`<rss`/`<video`/`<list` 开头的 XML 文档）。
    static func looksLikeXML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        return trimmed.contains("<rss") || trimmed.contains("<video") || trimmed.contains("<list")
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    var document = MacCMSXML.Document()
    private var currentVideo: [String: Any]?
    private var textBuffer = ""
    private var currentDDFlag: String?
    private var ddFlags: [String] = []
    private var ddContents: [String] = []
    private var currentClassNameID = ""

    private static let videoTextElements: Set<String> = [
        "id", "tid", "name", "type", "pic", "note", "year",
        "actor", "director", "writer", "des", "dt", "last",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        switch element {
        case "list":
            document.page = Int(attributeDict["page"] ?? "") ?? 1
            document.pagecount = Int(attributeDict["pagecount"] ?? "") ?? 1
            document.total = Int(attributeDict["recordcount"] ?? attributeDict["total"] ?? "") ?? 0
        case "video":
            currentVideo = [:]
            ddFlags = []
            ddContents = []
        case "dd":
            currentDDFlag = attributeDict["flag"] ?? ""
            textBuffer = ""
        case "ty":
            currentClassNameID = attributeDict["id"] ?? ""
            textBuffer = ""
        default:
            if currentVideo != nil, Self.videoTextElements.contains(element) {
                textBuffer = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        if element == "ty" {
            if !text.isEmpty {
                document.classes.append((id: currentClassNameID, name: text))
            }
            currentClassNameID = ""
            return
        }
        if element == "dd" {
            ddFlags.append(currentDDFlag ?? "")
            ddContents.append(text)
            currentDDFlag = nil
            return
        }
        guard currentVideo != nil else { return }
        if Self.videoTextElements.contains(element) {
            currentVideo?[mapVideoKey(element)] = text
            return
        }
        if element == "video" {
            var video = currentVideo ?? [:]
            video["vod_play_from"] = ddFlags.joined(separator: "$$$")
            video["vod_play_url"] = ddContents.joined(separator: "$$$")
            document.videos.append(video)
            currentVideo = nil
        }
    }

    /// XML 原生标签 → MacCMS vod json 字段（dt 等 5.1 扩展也归并）。
    private func mapVideoKey(_ element: String) -> String {
        switch element {
        case "id": return "vod_id"
        case "tid": return "type_id"
        case "name": return "vod_name"
        case "type": return "type_name"
        case "pic": return "vod_pic"
        case "note": return "vod_remarks"
        case "year": return "vod_year"
        case "actor": return "vod_actor"
        case "director": return "vod_director"
        case "writer": return "vod_writer"
        case "des", "dt": return "vod_content"
        case "last": return "vod_time"
        default: return element
        }
    }
}
