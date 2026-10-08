import Foundation

/// 聚合搜索分组（一站一组）。
public struct AggregateGroup: Identifiable {
    public let siteName: String
    public let items: [CatSourceItem]
    public var id: String { siteName }
    public init(siteName: String, items: [CatSourceItem]) {
        self.siteName = siteName
        self.items = items
    }
}
