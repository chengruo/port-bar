import Foundation
import Combine
import Darwin

public struct PortBarData: Codable {
    public var hosts: [SSHHost]
    public var mappings: [PortMapping]

    public init(hosts: [SSHHost] = [], mappings: [PortMapping] = []) {
        self.hosts = hosts
        self.mappings = mappings
    }
}

public final class ConfigStore: ObservableObject {
    public static let shared = ConfigStore()

    @Published public var hosts: [SSHHost] = []
    @Published public var mappings: [PortMapping] = []

    @Published public var lastError: String?
    public private(set) var revision = UUID().uuidString
    private var persisted = PortBarData()
    private let configURL: URL

    public init(directory: URL? = nil, seedDemo: Bool = true) {
        let fileManager = FileManager.default
        var targetDir: URL

        if let directory = directory {
            targetDir = directory
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } else if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let candidateDir = appSupport.appendingPathComponent("PortBar", isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidateDir, withIntermediateDirectories: true)
                let probe = candidateDir.appendingPathComponent(".probe")
                try "ok".write(to: probe, atomically: true, encoding: .utf8)
                try? fileManager.removeItem(at: probe)
                targetDir = candidateDir
            } catch {
                let homeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".portbar", isDirectory: true)
                if (try? fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)) != nil {
                    targetDir = homeDir
                } else {
                    let localDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".portbar", isDirectory: true)
                    try? fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
                    targetDir = localDir
                }
            }
        } else {
            let localDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".portbar", isDirectory: true)
            try? fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
            targetDir = localDir
        }

        self.configURL = targetDir.appendingPathComponent("config_v2.json")
        load()

        // If completely empty, insert a demo host and mapping
        if seedDemo && hosts.isEmpty && !fileManager.fileExists(atPath: configURL.path) {
            let demoHost = SSHHost(
                name: "生产开发机 (Demo)",
                host: "192.168.1.100",
                port: 22,
                username: "ubuntu",
                password: "",
                notes: "示例主机，修改为你的真实服务器。"
            )
            hosts = [demoHost]

            let demoMapping = PortMapping(
                name: "Web 管理后台",
                hostId: demoHost.id,
                forwardType: .localPort,
                portRules: [
                    PortRule(localPort: 8080, remotePort: 8080),
                    PortRule(localPort: 3306, remotePort: 3306)
                ],
                notes: "示例端口转发，已配置 8080 和 3306 端口"
            )
            mappings = [demoMapping]

            save()
        }
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PortBarData.self, from: data)
            self.hosts = decoded.hosts
            self.mappings = decoded.mappings
            persisted = decoded
            revision = UUID().uuidString
        } catch {
            print("[ConfigStore] 加载配置失败: \(error.localizedDescription)")
        }
    }

    /// Write before publishing, so failed writes cannot report a successful mutation.
    public func commit(_ payload: PortBarData) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            let temporary = configURL.deletingLastPathComponent().appendingPathComponent(".config-\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd); unlink(temporary.path) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            guard fsync(fd) == 0, rename(temporary.path, configURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            hosts = payload.hosts
            mappings = payload.mappings
            persisted = payload
            revision = UUID().uuidString
            lastError = nil
        } catch {
            throw AutomationError("SAVE_FAILED", "配置保存失败，请检查磁盘空间和目录权限。")
        }
    }

    @discardableResult public func save() -> Bool {
        do {
            try commit(PortBarData(hosts: hosts, mappings: mappings))
            return true
        } catch {
            hosts = persisted.hosts
            mappings = persisted.mappings
            lastError = (error as? AutomationError)?.message ?? "配置保存失败。"
            return false
        }
    }

    // MARK: - Host Operations

    public func host(for id: UUID) -> SSHHost? {
        hosts.first(where: { $0.id == id })
    }

    public func addHost(_ host: SSHHost) {
        hosts.append(host)
        save()
    }

    @discardableResult public func updateHost(_ host: SSHHost) -> Bool {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            guard hosts[idx].updatedAt == host.updatedAt else {
                lastError = "主机配置已被其他操作修改，请重新选择主机后编辑。"
                return false
            }
            var updated = host
            updated.updatedAt = Date()
            hosts[idx] = updated
            return save()
        }
        lastError = "主机已被删除。"
        return false
    }

    public func deleteHost(id: UUID) {
        hosts.removeAll(where: { $0.id == id })
        // Also remove associated mappings or leave them unassociated
        mappings.removeAll(where: { $0.hostId == id })
        save()
    }

    // MARK: - Mapping Operations

    public func mapping(for id: UUID) -> PortMapping? {
        mappings.first(where: { $0.id == id })
    }

    public func addMapping(_ mapping: PortMapping) {
        mappings.append(mapping)
        save()
    }

    @discardableResult public func updateMapping(_ mapping: PortMapping) -> Bool {
        if let idx = mappings.firstIndex(where: { $0.id == mapping.id }) {
            guard mappings[idx].updatedAt == mapping.updatedAt else {
                lastError = "映射配置已被其他操作修改，请重新选择映射后编辑。"
                return false
            }
            var updated = mapping
            updated.updatedAt = Date()
            mappings[idx] = updated
            return save()
        }
        lastError = "映射已被删除。"
        return false
    }

    public func deleteMapping(id: UUID) {
        mappings.removeAll(where: { $0.id == id })
        save()
    }

    public func duplicateMapping(id: UUID) -> PortMapping? {
        guard let original = mappings.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) (副本)"
        let maxExisting = mappings.flatMap { $0.portRules.map { max($0.localPort, $0.remotePort) } }.max() ?? 8080
        let offset = max(1, maxExisting + 1 - (original.portRules.first?.localPort ?? 8080))
        copy.portRules = original.portRules.map {
            PortRule(localPort: $0.localPort + offset, remotePort: $0.remotePort, remoteHost: $0.remoteHost)
        }
        copy.createdAt = Date()
        copy.updatedAt = Date()
        mappings.append(copy)
        save()
        return copy
    }

    // MARK: - Import / Export

    public func exportConfig(to targetURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = PortBarData(hosts: hosts, mappings: mappings)
        let data = try encoder.encode(payload)
        try data.write(to: targetURL, options: .atomic)
    }

    public func importConfig(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PortBarData.self, from: data)
        try commit(decoded)
    }
}
