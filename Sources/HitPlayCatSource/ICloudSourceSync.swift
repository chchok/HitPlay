import Combine
import Foundation
import HitPlayPySource

public struct CloudCatSubscription: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var address: String
    public var addedAt: Date
    public var enabled: Bool
    public var requiresReconfiguration: Bool

    public init(
        id: UUID,
        name: String,
        address: String,
        addedAt: Date,
        enabled: Bool,
        requiresReconfiguration: Bool
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.addedAt = addedAt
        self.enabled = enabled
        self.requiresReconfiguration = requiresReconfiguration
    }
}

public struct CloudSourceSnapshot: Codable {
    public var schemaVersion = 1
    public var createdAt = Date()
    public var subscriptions: [CloudCatSubscription]
    public var pySources: [CloudPySource]

    public init(subscriptions: [CloudCatSubscription], pySources: [CloudPySource]) {
        self.subscriptions = subscriptions
        self.pySources = pySources
    }
}

@MainActor
public final class ICloudSourceSync: ObservableObject {
    public static let shared = ICloudSourceSync()

    @Published public var status = "等待同步"
    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var isSyncing = false
    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published public var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Self.retentionKey) }
    }

    private static let enabledKey = "hitplay.icloudSourceSync.enabled.v1"
    private static let retentionKey = "hitplay.icloudSourceSync.retentionDays.v1"
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let containerIdentifier: String
    private var pendingSync: Task<Void, Never>?

    public init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        containerIdentifier: String = "iCloud.com.hitplay.player"
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.containerIdentifier = containerIdentifier
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let savedRetention = defaults.integer(forKey: Self.retentionKey)
        self.retentionDays = savedRetention == 15 ? 15 : 7
        self.lastSyncDate = defaults.object(forKey: "hitplay.icloudSourceSync.lastSync.v1") as? Date
    }

    public func scheduleSync(snapshot: CloudSourceSnapshot, packageDirectories: [UUID: URL]) {
        guard isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.syncNow(snapshot: snapshot, packageDirectories: packageDirectories)
        }
    }

    public func syncNow(snapshot: CloudSourceSnapshot, packageDirectories: [UUID: URL]) async throws {
        guard isEnabled else { status = "iCloud 同步已关闭"; return }
        guard let root = syncRoot(create: true) else {
            status = "iCloud Drive 不可用，请检查登录状态和云盘空间"
            throw SyncError.containerUnavailable
        }
        isSyncing = true
        status = "正在备份源文件与配置…"
        defer { isSyncing = false }

        let snapshotDirectory = root.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        let packagesDirectory = snapshotDirectory.appendingPathComponent("Packages", isDirectory: true)
        do {
            try fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
            let manifestURL = snapshotDirectory.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: manifestURL, options: .atomic)

            for (id, localDirectory) in packageDirectories where fileManager.fileExists(atPath: localDirectory.path) {
                let destination = packagesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                try fileManager.copyItem(at: localDirectory, to: destination)
            }
            try pruneSnapshots(in: root, keepingDays: retentionDays)
            lastSyncDate = snapshot.createdAt
            defaults.set(snapshot.createdAt, forKey: "hitplay.icloudSourceSync.lastSync.v1")
            status = "已同步 · \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))"
        } catch {
            try? fileManager.removeItem(at: snapshotDirectory)
            status = "同步失败：\(error.localizedDescription)"
            throw error
        }
    }

    /// 首次恢复时只补齐本机缺失的包目录；已有同 ID 包永远不被云端副本覆盖。
    public func restoreLatest(into localPackageRoot: URL) async throws -> CloudSourceSnapshot? {
        guard isEnabled else { return nil }
        guard let root = syncRoot(create: false) else { return nil }
        let candidates = try snapshotDirectories(in: root)
        for directory in candidates {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let snapshot = try? Self.decodeSnapshot(data) else { continue }

            for subscription in snapshot.subscriptions {
                try restorePackage(id: subscription.id, from: directory, into: localPackageRoot)
            }
            for source in snapshot.pySources {
                guard let id = UUID(uuidString: source.id) else { continue }
                try restorePackage(id: id, from: directory, into: localPackageRoot)
            }
            lastSyncDate = snapshot.createdAt
            status = "已找到 iCloud 备份 · \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))"
            return snapshot
        }
        status = "iCloud 中暂无源备份"
        return nil
    }

    public nonisolated static func safeAddress(_ rawAddress: String) -> (address: String, requiresReconfiguration: Bool) {
        guard var components = URLComponents(string: rawAddress),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return ("本地源文件（随源包备份）", true)
        }
        let requiresReconfiguration = components.user != nil || components.password != nil
            || components.query != nil || components.fragment != nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return (components.string ?? "", requiresReconfiguration)
    }

    private func syncRoot(create: Bool) -> URL? {
        guard let container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        let root = documents.appendingPathComponent("HitPlay/SourceSync", isDirectory: true)
        if create {
            do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
            catch { status = "无法创建 iCloud 备份目录：\(error.localizedDescription)"; return nil }
        }
        return root
    }

    private func snapshotDirectories(in root: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.hasDirectoryPath }
            .sorted { lhs, rhs in
                let lhsDate = (try? Self.decodeSnapshot(Data(contentsOf: lhs.appendingPathComponent("manifest.json"))).createdAt) ?? .distantPast
                let rhsDate = (try? Self.decodeSnapshot(Data(contentsOf: rhs.appendingPathComponent("manifest.json"))).createdAt) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func pruneSnapshots(in root: URL, keepingDays days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        for directory in try snapshotDirectories(in: root) {
            let date = (try? Self.decodeSnapshot(Data(contentsOf: directory.appendingPathComponent("manifest.json"))).createdAt) ?? .distantPast
            if date < cutoff { try? fileManager.removeItem(at: directory) }
        }
    }

    private func restorePackage(id: UUID, from snapshotDirectory: URL, into localPackageRoot: URL) throws {
        let source = snapshotDirectory.appendingPathComponent("Packages/\(id.uuidString)", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = localPackageRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(at: localPackageRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func decodeSnapshot(_ data: Data) throws -> CloudSourceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudSourceSnapshot.self, from: data)
    }

    private enum SyncError: LocalizedError {
        case containerUnavailable
        var errorDescription: String? {
            switch self {
            case .containerUnavailable: return "iCloud 容器不可用"
            }
        }
    }
}
