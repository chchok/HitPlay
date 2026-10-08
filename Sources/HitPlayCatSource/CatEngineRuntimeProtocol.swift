import Foundation
import Combine

/// 猫源引擎运行时统一面：Node 宿主（macOS）与原生内嵌服务（iOS/tvOS）同构。
/// 两个实现与协议均为 @MainActor，确保引擎状态、store 与 UI 的访问
/// 使用同一隔离域，避免 Swift 6 下协议调用绕过状态隔离。
@MainActor
public protocol CatEngineRuntimeProtocol: ObservableObject {
    var isRunning: Bool { get }
    var port: Int? { get }
    var baseURL: URL? { get }
    var lastError: String? { get }
    /// 引擎包自带配置页（标准路由 /website）；原生引擎无此页返回 nil。
    var websiteURL: URL? { get }
    func client() -> CatSourceClient
    func stop()
    func start(packageDir: URL, pythonExtend: String?) async throws
}

extension CatSourceEngineRuntime: CatEngineRuntimeProtocol {}

extension NativeEngineRuntime: CatEngineRuntimeProtocol {}
