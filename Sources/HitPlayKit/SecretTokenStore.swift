import Foundation
import Security

/// 跨模块共用的用户偏好键。键值一旦发布不可更改（落盘数据兼容）。
public enum HitPlayPreferenceKey {
    /// `.strm` 指针直连开关：网盘源与 Emby/Jellyfin 侧共用同一个开关。
    public static let strmDirect = "hitplay.clouddrive.strmDirect.v1"
}

/// Keychain 存取令牌的最小封装（服务名固定，键为服务器维度）。
public struct SecretTokenStore {
    let service: String
    private static let testLock = NSLock()
    private static var testValues: [String: [String: String]] = [:]

    public init(service: String = "com.hitplay.player.tokens") {
        self.service = service
    }

    /// 单元测试宿主中跳过真实钥匙串：重建的二进制读取旧 ACL 条目会触发
    /// 无人可应答的系统授权弹窗，挂死整个测试宿主（2026-10-01 采样定位）。
    /// 钥匙串行为本身的验收属手动/设备场景。
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// CLI 验收/基准运行（--verify-* / --benchmark*）的显式逃逸：这类运行不消费
    /// 真实凭据，设 HITPLAY_IN_MEMORY_SECRETS=1 走内存字典，避免每次重建二进制
    /// 后 Keychain ACL 弹窗把无头验收挂死（与单测逃逸同一根因）。
    private static var useInMemorySecrets: Bool {
        isRunningUnitTests
            || ProcessInfo.processInfo.environment["HITPLAY_IN_MEMORY_SECRETS"] == "1"
    }

    @discardableResult
    public func set(_ value: String, for key: String) -> Bool {
        if Self.useInMemorySecrets {
            Self.testLock.lock(); defer { Self.testLock.unlock() }
            Self.testValues[service, default: [:]][key] = value
            return true
        }
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public func value(for key: String) -> String? {
        if Self.useInMemorySecrets {
            Self.testLock.lock(); defer { Self.testLock.unlock() }
            return Self.testValues[service]?[key]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(_ key: String) {
        if Self.useInMemorySecrets {
            Self.testLock.lock(); defer { Self.testLock.unlock() }
            Self.testValues[service]?.removeValue(forKey: key)
            return
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ] as CFDictionary)
    }
}
