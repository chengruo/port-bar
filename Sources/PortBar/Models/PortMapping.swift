import Foundation

public struct PortRule: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var localPort: Int
    public var remotePort: Int
    public var remoteHost: String

    public init(
        id: UUID = UUID(),
        localPort: Int,
        remotePort: Int,
        remoteHost: String = "127.0.0.1"
    ) {
        self.id = id
        self.localPort = localPort
        self.remotePort = remotePort
        self.remoteHost = remoteHost
    }

    public var summary: String {
        "\(localPort) ➔ \(remoteHost):\(remotePort)"
    }
}

public enum ForwardType: String, Codable, CaseIterable, Identifiable {
    case localPort = "local_port"
    case socks5 = "socks5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localPort:
            return "本地端口转发 (Local Forward)"
        case .socks5:
            return "SOCKS5 动态代理 (Dynamic Proxy)"
        }
    }
}

public struct PortMapping: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var hostId: UUID
    public var forwardType: ForwardType
    public var portRules: [PortRule]
    public var socks5Port: Int
    public var autoReconnect: Bool
    public var autoStart: Bool
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "新端口映射",
        hostId: UUID,
        forwardType: ForwardType = .localPort,
        portRules: [PortRule] = [PortRule(localPort: 8080, remotePort: 8080)],
        socks5Port: Int = 1080,
        autoReconnect: Bool = false,
        autoStart: Bool = false,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hostId = hostId
        self.forwardType = forwardType
        self.portRules = portRules.isEmpty ? [PortRule(localPort: 8080, remotePort: 8080)] : portRules
        self.socks5Port = socks5Port
        self.autoReconnect = autoReconnect
        self.autoStart = autoStart
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Legacy Compatibility Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, hostId, forwardType, portRules, socks5Port, autoReconnect, autoStart, notes, createdAt, updatedAt
        // Legacy keys
        case localPort, remotePort, remoteHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.hostId = try container.decode(UUID.self, forKey: .hostId)
        self.forwardType = try container.decode(ForwardType.self, forKey: .forwardType)
        self.autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        self.autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // 1. Try modern portRules
        if let rules = try container.decodeIfPresent([PortRule].self, forKey: .portRules), !rules.isEmpty {
            self.portRules = rules
            self.socks5Port = try container.decodeIfPresent(Int.self, forKey: .socks5Port) ?? (rules.first?.localPort ?? 1080)
        } else {
            // 2. Fallback to legacy single port
            let legacyLocal = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 8080
            let legacyRemote = try container.decodeIfPresent(Int.self, forKey: .remotePort) ?? legacyLocal
            let legacyHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? "127.0.0.1"
            self.portRules = [PortRule(localPort: legacyLocal, remotePort: legacyRemote, remoteHost: legacyHost)]
            self.socks5Port = legacyLocal
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(forwardType, forKey: .forwardType)
        try container.encode(portRules, forKey: .portRules)
        try container.encode(socks5Port, forKey: .socks5Port)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Computed Properties

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return forwardingSummary
    }

    public var forwardingSummary: String {
        switch forwardType {
        case .localPort:
            if portRules.count == 1, let first = portRules.first {
                return ":\(first.localPort) ➔ :\(first.remotePort)"
            } else if portRules.count > 1 {
                let ports = portRules.map { ":\($0.localPort)" }.joined(separator: ", ")
                return "\(portRules.count) 个端口 (\(ports))"
            }
            return "未配置端口"
        case .socks5:
            return "SOCKS5 :\(socks5Port)"
        }
    }

    public var allLocalPorts: [Int] {
        switch forwardType {
        case .localPort:
            return portRules.map { $0.localPort }
        case .socks5:
            return [socks5Port]
        }
    }

    public var localURLs: [(port: Int, url: URL)] {
        guard forwardType == .localPort else { return [] }
        return portRules.compactMap { rule in
            if let url = URL(string: "http://127.0.0.1:\(rule.localPort)") {
                return (rule.localPort, url)
            }
            return nil
        }
    }

    // MARK: - Batch Parser (Supports 8080, 3306, 6379, 9000-9003, 8080:8081)

    public static func parseBatchPorts(_ text: String, defaultRemoteHost: String = "127.0.0.1") -> [PortRule] {
        var results: [PortRule] = []
        // Split by comma, space, semicolon or newline
        let items = text.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for item in items {
            // Check if format is local:remote or remote
            if item.contains(":") {
                let parts = item.components(separatedBy: ":")
                if parts.count == 2, let l = Int(parts[0]), let r = Int(parts[1]), l > 0 && l <= 65535 && r > 0 && r <= 65535 {
                    results.append(PortRule(localPort: l, remotePort: r, remoteHost: defaultRemoteHost))
                }
            } else if item.contains("-") {
                // Range format, e.g. 9000-9003
                let parts = item.components(separatedBy: "-")
                if parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start > 0 && end <= 65535 && start <= end {
                    let rangeCount = min(end - start, 50) // protect from massive ranges
                    for p in start...(start + rangeCount) {
                        results.append(PortRule(localPort: p, remotePort: p, remoteHost: defaultRemoteHost))
                    }
                }
            } else if let p = Int(item), p > 0 && p <= 65535 {
                // Default: localPort = remotePort!
                results.append(PortRule(localPort: p, remotePort: p, remoteHost: defaultRemoteHost))
            }
        }

        // Deduplicate local ports
        var seen = Set<Int>()
        var deduplicated: [PortRule] = []
        for r in results {
            if !seen.contains(r.localPort) {
                seen.insert(r.localPort)
                deduplicated.append(r)
            }
        }
        return deduplicated
    }
}
