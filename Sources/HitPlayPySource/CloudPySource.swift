import Foundation

/// iCloud 源备份中的 py 源条目（不含 extend——可能含凭据，永不入备份）。
public struct CloudPySource: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool

    public init(id: String, name: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }
}
