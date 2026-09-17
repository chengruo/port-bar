import Foundation

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
    public var localPort: Int
    public var remotePort: Int
    public var remoteHost: String
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
        localPort: Int = 8080,
        remotePort: Int = 8080,
        remoteHost: String = "127.0.0.1",
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
        self.localPort = localPort
        self.remotePort = remotePort
        self.remoteHost = remoteHost
        self.autoReconnect = autoReconnect
        self.autoStart = autoStart
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch forwardType {
        case .localPort:
            return ":\(localPort) ➔ :\(remotePort)"
        case .socks5:
            return "SOCKS5 :\(localPort)"
        }
    }

    public var forwardingSummary: String {
        switch forwardType {
        case .localPort:
            return "127.0.0.1:\(localPort) ➔ \(remoteHost):\(remotePort)"
        case .socks5:
            return "SOCKS5 127.0.0.1:\(localPort)"
        }
    }

    public var localURL: URL? {
        URL(string: "http://127.0.0.1:\(localPort)")
    }
}
