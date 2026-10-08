import Foundation

/// py 源持久化记录（UserDefaults JSON；键由猫源存储的订阅持久化键 + ".py.v1" 组成）。
public struct PySourceRecord: Codable {
    public var id: String
    public var name: String
    public var fileName: String
    public var enabled: Bool?
    public var extend: String?
    public var sourceURL: String?
    /// 订阅安装物的 SHA-256（单 .py = 文件字节；zip = 压缩包字节）。
    /// 订阅检查更新时与远端下载内容比对，一致即跳过（哈希快路径）。
    public var contentHash: String?

    public init(
        id: String, name: String, fileName: String, enabled: Bool?, extend: String?,
        sourceURL: String? = nil, contentHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.enabled = enabled
        self.extend = extend
        self.sourceURL = sourceURL
        self.contentHash = contentHash
    }
}
