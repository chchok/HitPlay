import Foundation
import CommonCrypto

/// TVBox 生态加密订阅配置解密。
///
/// 线格式（TVBox 生态"加密配置"）：
/// 1. `2423` 前缀：去掉前缀后是 base64（容错去空白），解出的是下述第 2 种形态；
/// 2. `2324` + 8 位口令 + `**` + base64 密文；
/// 3. 任意 `8位字母数字**` 开头（正则 `[A-Za-z0-9]{8}\*\*`）+ base64 密文。
///
/// 口令处理：右补 '0' 到 16 字节作 AES-128 密钥，iv 取同一口令块（部分站点用零 IV，
/// 作为回退尝试）。解出结果必须是 JSON 才算成功。
/// 说明：这是对生态既有线格式的"读取"兼容，密钥来自配置自身标记，非安全机制。
enum TVBoxConfigCrypto {
    static func decryptIfEncrypted(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("2423") {
            guard let decoded = base64Decode(String(text.dropFirst(4))) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("2324") {
            let start = text.index(text.startIndex, offsetBy: 4)
            let keyEnd = text.index(start, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
            guard keyEnd < text.endIndex else { return nil }
            let key8 = String(text[start..<keyEnd])
            var body = String(text[keyEnd...])
            if body.hasPrefix("**") { body = String(body.dropFirst(2)) }
            return decryptBody(body, key8: key8)
        }
        // `[A-Za-z0-9]{8}\*\*` 开头标记
        if let match = text.range(of: "^[A-Za-z0-9]{8}\\*\\*", options: .regularExpression) {
            let key8 = String(text[match.lowerBound..<text.index(match.upperBound, offsetBy: -2)])
            let body = String(text[match.upperBound...])
            return decryptBody(body, key8: key8)
        }
        return nil
    }

    /// 明文 JSON 判定：无加密标记且本身是 sites 配置。
    static func isTVBoxConfig(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("2423") { return true }
        if trimmed.range(of: "^[A-Za-z0-9]{8}\\*\\*", options: .regularExpression) != nil { return true }
        if trimmed.hasPrefix("2324") { return true }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return object["sites"] is [Any]
    }

    /// 解密入口（供 store 在导入/刷新时调用）：能解则返回明文 JSON 文本，否则原样返回。
    static func normalizedConfigText(_ raw: String) -> String {
        decryptIfEncrypted(raw) ?? raw
    }

    private static func base64Decode(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        var base64 = cleaned
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decryptBody(_ body: String, key8: String) -> String? {
        guard !body.isEmpty else { return nil }
        guard let rawCipher = rawBase64Data(body) else { return nil }
        let keyString = rightPad0(key8)
        let keyData = Data(keyString.utf8)
        let zeroIV = Data(repeating: 0, count: 16)
        for iv in [keyData, zeroIV] {
            if let plain = aesCBCDecrypt(rawCipher, key: keyData, iv: iv),
               let text = String(data: plain, encoding: .utf8),
               isJSONText(text) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func rawBase64Data(_ text: String) -> Data? {
        let cleaned = text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        var base64 = cleaned
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: base64)
    }

    private static func rightPad0(_ key: String) -> String {
        var padded = key
        while padded.count < 16 { padded += "0" }
        return String(padded.prefix(16))
    }

    private static func isJSONText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// AES-128-CBC + PKCS7（CommonCrypto）。
    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            data.withUnsafeBytes { (dataPointer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyPointer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    iv.withUnsafeBytes { (ivPointer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress, key.count,
                            ivPointer.baseAddress,
                            dataPointer.baseAddress, data.count,
                            outputPointer.baseAddress, outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength > 0 else { return nil }
        let decrypted = output.prefix(outputLength)
        return decrypted
    }
}
