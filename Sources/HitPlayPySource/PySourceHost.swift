import Foundation

/// py 源启动计划：宿主脚本、解释器与进程环境。
public struct PySourceLaunchPlan: Sendable {
    public let script: URL
    public let executable: URL
    public let environment: [String: String]
}

/// 启动失败原因（用户可读，直接进引擎状态条）。
public struct PySourceLaunchError: Error {
    public let message: String
}

/// py 源宿主契约（FongMi 约定）：python3 + py-source-host.py 启动源包，
/// 站点配置经 HITPLAY_PY_EXTEND 注入。宿主脚本定位：类所在束 → App 主包 →
/// 源码树回退（源码分发的 SwiftPM 套件形态：脚本与本文件同目录）。
public enum PySourceHost {
    public static func launchPlan(
        pythonExecutable: URL? = nil,
        extend: String?
    ) -> Result<PySourceLaunchPlan, PySourceLaunchError> {
        let script = Bundle(for: BundleToken.self).url(forResource: "py-source-host", withExtension: "py")
            ?? Bundle.main.url(forResource: "py-source-host", withExtension: "py")
            ?? locateScriptInSourceTree()
        guard let script else {
            return .failure(PySourceLaunchError(message: "缺少宿主脚本 py-source-host.py"))
        }
        guard let pythonExecutable = pythonExecutable ?? locateExecutable(named: "python3") else {
            return .failure(PySourceLaunchError(message: "未找到 Python 3 运行时；请安装 Python 3 并确保其位于 PATH 中"))
        }
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path) else {
            return .failure(PySourceLaunchError(message: "Python 运行时不可执行（\(pythonExecutable.path)）"))
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dependencyDirectory = appSupport
            .appendingPathComponent("HitPlay", isDirectory: true)
            .appendingPathComponent("PythonDependencies", isDirectory: true)
        var environment: [String: String] = [
            "HITPLAY_HOST_PORT": "0",
            "HITPLAY_PY_DEPENDENCY_DIR": dependencyDirectory.path
        ]
        if let extend, !extend.isEmpty {
            environment["HITPLAY_PY_EXTEND"] = extend
        }
        return .success(PySourceLaunchPlan(script: script, executable: pythonExecutable, environment: environment))
    }

    /// 源码树回退：从本源文件位置向上逐级查找同目录的宿主脚本。
    private static func locateScriptInSourceTree() -> URL? {
        var directory = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent("py-source-host.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func locateExecutable(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Bundle(for:) 定位锚点：静态链接场景下等价于主包，动态链接时指向本模块。
private final class BundleToken {}
