import Foundation
import Network

/// 原生引擎运行时：与 CatSourceEngineRuntime 同面（isRunning/port/baseURL/client/start/stop），
/// 但不派生 Node 子进程——内嵌 NativeEngineServer 提供 loopback HTTP 协议口。
/// 用于 iOS/tvOS（无 Node 运行时）承载 TVBox 配置源（type 0/1 CMS 直连）。
@MainActor
public final class NativeEngineRuntime: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: Int?
    @Published public private(set) var lastError: String?

    private var server: NativeEngineServer?

    public init() {}

    public var baseURL: URL? {
        guard isRunning, let server, server.port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(server.port)")
    }

    /// 原生引擎无配置页。
    public var websiteURL: URL? { nil }

    /// 与 CatSourceEngineRuntime.client() 同义：绑定当前端口的协议客户端。
    public func client() -> CatSourceClient {
        CatSourceClient(baseURL: baseURL ?? URL(string: "http://127.0.0.1:0")!)
    }

    /// 读取包目录内 config.json 并启动内嵌服务。pythonExtend 为对齐 Node 宿主
    /// 签名的占位（原生引擎无 py 依赖概念，忽略）。
    public func start(packageDir: URL, pythonExtend: String? = nil) async throws {
        _ = pythonExtend
        stop()
        let server = NativeEngineServer(packageDir: packageDir)
        do {
            try server.loadConfig()
            try server.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            throw CatSourceError.badResponse(message)
        }
        self.server = server
        isRunning = true
        lastError = nil
        // 端口就绪探活（NWListener 启动是异步的，等 bind 完成）。
        for _ in 0..<50 {
            if server.port > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard server.port > 0, let base = baseURL else {
            lastError = "原生引擎端口未就绪"
            throw CatSourceError.engineNotRunning
        }
        // 健康探活：/config 必须可答。
        _ = try await client().config()
    }

    public func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = nil
    }
}
