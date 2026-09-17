import Foundation

public enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .disconnected:
            return "已断开"
        case .connecting:
            return "连接中..."
        case .connected:
            return "已连接"
        case .error(let msg):
            return "错误: \(msg)"
        }
    }
}

public struct LogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String
    public let isError: Bool

    public init(timestamp: Date = Date(), message: String, isError: Bool = false) {
        self.timestamp = timestamp
        self.message = message
        self.isError = isError
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
