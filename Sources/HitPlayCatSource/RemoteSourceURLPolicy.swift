import Darwin
import Foundation

/// 订阅类远程地址准入策略（SSRF 防线）：
/// 仅接受 http/https；拒绝 localhost、环回、私有、链路本地与保留地址主机。
/// 判定基于主机字符串与 IP 字面量（inet_pton），不做 DNS 解析后的二次校验——
/// 订阅地址由用户主动添加，解析级防护（防 DNS 重绑定）属后续增强。
public enum RemoteSourceURLPolicy {
    public struct RejectedHostError: LocalizedError {
        public let host: String
        public var errorDescription: String? {
            "不允许的订阅地址主机「\(host)」：仅接受公网 HTTP(S) 地址"
        }
    }

    /// 校验订阅地址；不合规则抛出用户可读错误。
    /// allowLoopback 仅供测试注入本地 mock 上游，产品路径一律 false。
    public static func validate(_ url: URL, allowLoopback: Bool = false) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw CatSourceError.badResponse("订阅地址仅支持 HTTP/HTTPS")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw CatSourceError.badResponse("订阅地址缺少主机名")
        }
        guard !allowLoopback else { return }
        guard isPublicHost(host) else {
            throw RejectedHostError(host: host)
        }
    }

    /// 便捷判定（保存订阅时的前置反馈用）。
    public static func isPublicHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        do {
            try validate(url)
            return true
        } catch {
            return false
        }
    }

    static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        // 环回/链路本地命名域：localhost 与 *.localhost、mDNS 的 *.local。
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host == "localhost.localdomain" {
            return false
        }
        if isIPLiteral(host) {
            return isPublicIPAddress(host)
        }
        return true
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &v4) == 1 || inet_pton(AF_INET6, pointer, &v6) == 1
        }
    }

    static func isPublicIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) == 1 }) {
            let value = UInt32(bigEndian: v4.s_addr)
            let octets = ((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
            switch octets {
            case (0...0, _, _, _),               // 0.0.0.0/8 本网络
                 (10, _, _, _),                  // 10/8 私有
                 (127, _, _, _),                 // 127/8 环回
                 (169, 254, _, _),               // 169.254/16 链路本地
                 (172, 16...31, _, _),           // 172.16/12 私有
                 (192, 0, 0, _),                 // 192.0.0/24 IETF 协议保留
                 (192, 0, 2, _),                 // 192.0.2/24 TEST-NET-1
                 (192, 168, _, _),               // 192.168/16 私有
                 (198, 18...19, _, _),           // 198.18/15 基准测试
                 (198, 51, 100, _),              // 198.51.100/24 TEST-NET-2
                 (203, 0, 113, _),               // 203.0.113/24 TEST-NET-3
                 (224...255, _, _, _):           // 组播 + 保留 + 广播
                return false
            case (100, 64...127, _, _):          // 100.64/10 CGNAT
                return false
            default:
                return true
            }
        }
        var v6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &v6) == 1 }) else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        // ::/128 未指定、::1/128 环回
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false }
        // ::ffff:0:0/96 IPv4 映射地址：按内嵌 IPv4 判定
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            return isPublicIPAddress(mapped)
        }
        // fc00::/7 ULA（fd00::/8 常用）、fe80::/10 链路本地、ff00::/8 组播
        if (bytes[0] & 0xFE) == 0xFC { return false }
        if (bytes[0] & 0xFF) == 0xFE, (bytes[1] & 0xC0) == 0x80 { return false }
        if (bytes[0] & 0xFF) == 0xFF { return false }
        // 2001:db8::/32 文档保留
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
        return true
    }
}
