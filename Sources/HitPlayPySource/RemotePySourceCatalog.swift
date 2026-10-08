import Foundation

/// A Python Spider entry advertised by a FongMi/TVBox JSON subscription.
/// The URL can contain an access token; keep it out of user-facing labels and logs.
public struct RemotePySourceReference: Decodable, Hashable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let api: String
    /// 站点扩展参数（FongMi 契约 sites[].ext）：Spider.init(extend) 的入参。
    /// 生态中常见 JSON 字符串或对象形态，统一归一为字符串。
    public let ext: String?

    public var id: String { key + "|" + api }

    public var sourceURL: URL? {
        guard let url = URL(string: api),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.pathExtension.lowercased() == "py" else { return nil }
        return url
    }

    /// 生态常见 py 插件 zip 包（spider.py + 依赖库）。
    public var bundleURL: URL? {
        guard let url = URL(string: api),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.pathExtension.lowercased() == "zip" else { return nil }
        return url
    }

    /// 单 .py 或 zip 包任一可导入。
    public var importableURL: URL? { sourceURL ?? bundleURL }

    public init(key: String, name: String, api: String, ext: String? = nil) {
        self.key = key
        self.name = name
        self.api = api
        self.ext = ext
    }
}

/// Reads only Python Spider entries from a mixed FongMi subscription.
/// Java `csp_*` spiders and JavaScript `.js` sources remain outside this importer.
/// 订阅顶层 `spider` 字段指向 .py/.zip 时作为全局 py 插件兜底（部分订阅没有
/// sites 内联 py 条目，只给全局 spider）。
public enum RemotePySourceCatalog {
    public static func parse(_ data: Data) throws -> [RemotePySourceReference] {
        // JSONSerialization 而非 Decodable：ext 在生态中存在字符串/对象/数组多种
        // 形态（对象需归一为 JSON 字符串传给 init(extend)），宽松解码避免整份
        // 订阅因个别站点字段形态异常而解析失败。
        let root = try decodeRoot(data)
        var seen = Set<String>()
        let references: [RemotePySourceReference] = ((root["sites"] as? [[String: Any]]) ?? []).compactMap { entry -> RemotePySourceReference? in
            guard let key = entry["key"] as? String, !key.isEmpty,
                  let name = entry["name"] as? String, !name.isEmpty,
                  let api = entry["api"] as? String else { return nil }
            let reference = RemotePySourceReference(
                key: key, name: name, api: api,
                ext: Self.normalizedExtend(entry["ext"])
            )
            // 单 .py 文件或 zip 插件包均可导入；其余（csp_/js/T4）不归 py 导入器。
            guard reference.importableURL != nil, seen.insert(api).inserted else { return nil }
            return reference
        }
        // 兜底：顶层全局 spider 指向 .py/.zip 时视为一个可导入的 py 插件包。
        if references.isEmpty, let spider = root["spider"] as? String {
            let reference = RemotePySourceReference(key: "spider", name: "全局 PY 插件", api: spider)
            if reference.importableURL != nil, seen.insert(spider).inserted {
                return [reference]
            }
        }
        if references.isEmpty, let notice = root["notice"] as? String,
           ["封禁", "禁止访问", "访问受限", "违规", "banned", "forbidden", "access denied"].contains(where: { notice.lowercased().contains($0.lowercased()) }) {
            throw RemotePySourceCatalogError.accessRestricted
        }
        return references
    }

    private static func decodeRoot(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RemotePySourceCatalogError.invalidCatalog
        }
        return object
    }

    /// ext 归一：字符串原样；对象/数组转紧凑 JSON；标量转字符串；缺省 nil。
    static func normalizedExtend(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case .some(let object) where object is [String: Any] || object is [Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }
}

public enum RemotePySourceCatalogError: LocalizedError {
    case invalidCatalog
    case accessRestricted

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog:
            return "订阅内容不是有效的 JSON 配置"
        case .accessRestricted:
            return "订阅服务返回访问限制提示，请检查订阅状态后重试"
        }
    }
}
