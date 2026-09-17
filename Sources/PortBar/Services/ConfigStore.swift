import Foundation
import Combine

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

    private let configURL: URL

    public init() {
        let fileManager = FileManager.default
        var targetDir: URL

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
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
        if hosts.isEmpty {
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
                localPort: 8080,
                remotePort: 8080,
                remoteHost: "127.0.0.1",
                notes: "访问本地 8080 端口即可转发至远端 8080"
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
        } catch {
            print("[ConfigStore] 加载配置失败: \(error.localizedDescription)")
        }
    }

    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = PortBarData(hosts: hosts, mappings: mappings)
            let data = try encoder.encode(payload)
            try data.write(to: configURL, options: .atomic)
        } catch {
            print("[ConfigStore] 保存配置失败: \(error.localizedDescription)")
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

    public func updateHost(_ host: SSHHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            var updated = host
            updated.updatedAt = Date()
            hosts[idx] = updated
            save()
        }
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

    public func updateMapping(_ mapping: PortMapping) {
        if let idx = mappings.firstIndex(where: { $0.id == mapping.id }) {
            var updated = mapping
            updated.updatedAt = Date()
            mappings[idx] = updated
            save()
        }
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
        copy.localPort = (mappings.map { $0.localPort }.max() ?? original.localPort) + 1
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
        self.hosts = decoded.hosts
        self.mappings = decoded.mappings
        save()
    }
}
