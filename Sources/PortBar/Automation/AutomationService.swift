import Foundation
import Combine

enum AutomationAccess: Int, CaseIterable {
    case disabled = 0, readOnly = 1, control = 2, edit = 3
    var title: String {
        switch self {
        case .disabled: return "关闭"
        case .readOnly: return "只读"
        case .control: return "查询与隧道控制"
        case .edit: return "查询、控制与配置编辑"
        }
    }
}

private struct HostInput: Decodable {
    var name: String?; var host: String?; var port: Int?; var username: String?; var notes: String?
}
private struct RuleInput: Decodable {
    var localPort: Int; var remotePort: Int; var remoteHost: String?
}
private struct MappingInput: Decodable {
    var name: String?; var hostId: UUID?; var forwardType: ForwardType?
    var portRules: [RuleInput]?; var socks5Port: Int?
    var autoReconnect: Bool?; var autoStart: Bool?; var notes: String?
}

final class AutomationService: ObservableObject {
    static let shared = AutomationService()
    static let commands = [
        "capabilities", "status", "hosts.list", "hosts.get", "hosts.create", "hosts.update", "hosts.delete",
        "mappings.list", "mappings.get", "mappings.create", "mappings.update", "mappings.delete",
        "tunnels.status", "tunnels.start", "tunnels.stop", "tunnels.diagnose", "logs.list", "activity.list"
    ]
    @Published private(set) var activity: [String] = []
    private let store: ConfigStore
    private let manager: SSHTunnelManager
    private let defaults: UserDefaults

    init(store: ConfigStore = .shared, manager: SSHTunnelManager = .shared, defaults: UserDefaults = .standard) {
        self.store = store; self.manager = manager; self.defaults = defaults
    }

    var access: AutomationAccess { AutomationAccess(rawValue: defaults.integer(forKey: "portbar_cli_access")) ?? .disabled }

    func handle(_ request: AutomationRequest) -> [String: Any] {
        do {
            guard request.version == 1 else { throw AutomationError("UNSUPPORTED_VERSION", "仅支持 CLI 协议版本 1。") }
            guard Self.commands.contains(request.command) else { throw AutomationError("INVALID_ARGUMENT", "未知命令，请运行 portbar --help。") }
            let required: AutomationAccess = request.command.hasSuffix(".create") || request.command.hasSuffix(".update") || request.command.hasSuffix(".delete") ? .edit :
                (["tunnels.start", "tunnels.stop"].contains(request.command) ? .control : .readOnly)
            if request.command != "capabilities" && access.rawValue < required.rawValue {
                throw AutomationError("PERMISSION_DENIED", "请在 PortBar 设置中授予 CLI 所需权限：\(required.title)。")
            }
            try validateOptions(request)
            let result = try execute(request)
            record(request.command, code: "OK")
            return ["ok": true, "requestId": request.id, "revision": store.revision, "data": result]
        } catch {
            record(Self.commands.contains(request.command) ? request.command : "invalid", code: (error as? AutomationError)?.code ?? "INTERNAL_ERROR")
            return AutomationJSON.failure(error, requestId: request.id)
        }
    }

    private func record(_ command: String, code: String) {
        // Never record payloads, credentials, notes or raw SSH stderr.
        activity.append("\(ISO8601DateFormatter().string(from: Date()))  \(command)  \(code)")
        if activity.count > 100 { activity.removeFirst(activity.count - 100) }
    }

    private func validateOptions(_ request: AutomationRequest) throws {
        var allowed = Set<String>()
        if request.command.hasSuffix(".list") { allowed.formUnion(["search", "limit"]) }
        if request.command.hasPrefix("hosts."), !["hosts.list", "hosts.create"].contains(request.command) { allowed.insert("host-id") }
        if request.command.hasPrefix("mappings."), !["mappings.list", "mappings.create"].contains(request.command) { allowed.insert("mapping-id") }
        if request.command.hasPrefix("tunnels.") || request.command == "logs.list" { allowed.insert("mapping-id") }
        let mutation = [".create", ".update", ".delete"].contains { request.command.hasSuffix($0) }
        if mutation { allowed.formUnion(["dry-run", "if-revision"]) }
        if request.command == "hosts.delete" { allowed.insert("cascade") }
        guard Set(request.options.keys).isSubset(of: allowed) else { throw AutomationError("INVALID_ARGUMENT", "命令包含不支持的选项。") }
        for flag in ["dry-run", "cascade"] where request.options[flag] != nil {
            guard request.options[flag] == "true" else { throw AutomationError("INVALID_ARGUMENT", "\(flag) 必须是布尔开关。") }
        }
        if let raw = request.options["limit"] { guard let n = Int(raw), (1...500).contains(n) else { throw AutomationError("INVALID_ARGUMENT", "limit 必须在 1–500 之间。") } }
        let acceptsPayload = request.command.hasSuffix(".create") || request.command.hasSuffix(".update")
        guard acceptsPayload || request.payload == nil else { throw AutomationError("INVALID_ARGUMENT", "该命令不接受 JSON 文件。") }
    }

    private func execute(_ request: AutomationRequest) throws -> Any {
        let options = request.options
        let limit = Int(options["limit"] ?? "100") ?? 100
        let search = options["search"]?.lowercased() ?? ""
        switch request.command {
        case "capabilities":
            return ["protocolVersion": 1, "cliVersion": PortBarVersion.current, "access": access.title,
                    "commands": Self.commands, "credentials": "managed_in_app", "maxMessageBytes": LocalIPC.maxMessageBytes,
                    "runningConfigChanges": "stop_before_edit", "transport": "unix_socket_same_user"] as [String: Any]
        case "status":
            return ["running": true, "hosts": store.hosts.count, "mappings": store.mappings.count, "activeTunnels": manager.activeTunnelCount] as [String: Any]
        case "hosts.list":
            return store.hosts.filter { search.isEmpty || "\($0.name) \($0.host) \($0.username)".lowercased().contains(search) }.prefix(limit).map(hostJSON)
        case "hosts.get": return hostJSON(try host(options))
        case "mappings.list":
            return try store.mappings.filter { search.isEmpty || "\($0.name) \($0.forwardingSummary)".lowercased().contains(search) }.prefix(limit).map { try mappingJSON($0) }
        case "mappings.get": return try mappingJSON(mapping(options))
        case "tunnels.status":
            if options["mapping-id"] != nil { return try tunnelJSON(mapping(options)) }
            return store.mappings.map(tunnelJSON)
        case "tunnels.start":
            let item = try mapping(options)
            try ConfigValidation.mapping(item)
            guard let sshHost = store.host(for: item.hostId) else { throw AutomationError("NOT_FOUND", "关联主机不存在。") }
            try ConfigValidation.host(sshHost)
            guard !manager.isStopping(item.id) else { throw AutomationError("RESOURCE_BUSY", "隧道正在停止，请等待停止完成。") }
            if !manager.status(for: item.id).isConnected && !manager.status(for: item.id).isConnecting {
                for port in item.allLocalPorts where NetworkDetector.shared.isLocalPortListening(port: port) {
                    throw AutomationError("PORT_IN_USE", "本地端口 \(port) 已被占用。")
                }
                manager.startTunnel(for: item)
            }
            return tunnelJSON(item)
        case "tunnels.stop":
            let item = try mapping(options)
            manager.stopTunnel(for: item.id)
            return tunnelJSON(item)
        case "tunnels.diagnose":
            let item = try mapping(options)
            var result = tunnelJSON(item)
            result["ports"] = item.allLocalPorts.map { ["localPort": $0, "listening": NetworkDetector.shared.isLocalPortListening(port: $0)] as [String: Any] }
            result["readinessScope"] = "local_listener_only"
            result["remoteServiceReachability"] = "not_tested"
            result["recentErrors"] = manager.logs(for: item.id).filter(\.isError).suffix(10).map { redact($0.message) }
            return result
        case "logs.list":
            let item = try mapping(options)
            return manager.logs(for: item.id).suffix(limit).map {
                ["timestamp": ISO8601DateFormatter().string(from: $0.timestamp), "message": redact($0.message), "isError": $0.isError] as [String: Any]
            }
        case "activity.list": return Array(activity.suffix(limit))
        default: return try mutate(request)
        }
    }

    private func mutate(_ request: AutomationRequest) throws -> Any {
        let options = request.options
        if let expected = options["if-revision"], expected != store.revision { throw AutomationError("REVISION_CONFLICT", "配置已发生变化，请重新读取并预检查。") }
        var next = PortBarData(hosts: store.hosts, mappings: store.mappings)
        var before: Any = NSNull()
        var after: Any = NSNull()
        var affected: [String] = []
        if request.command.hasPrefix("hosts.") {
            var item = request.command == "hosts.create" ? SSHHost() : try host(options)
            if request.command != "hosts.create" { before = hostJSON(item) }
            let associated = store.mappings.filter { $0.hostId == item.id }
            guard !associated.contains(where: { manager.isManaged($0.id) }) else { throw AutomationError("RESOURCE_BUSY", "请先停止该主机的隧道及自动重连，再修改或删除主机。") }
            if request.command == "hosts.delete" {
                guard associated.isEmpty || options["cascade"] == "true" else { throw AutomationError("HAS_DEPENDENCIES", "主机有关联映射。预检查后使用 --cascade 可一并删除。") }
                affected = associated.map { $0.id.uuidString }
                next.hosts.removeAll { $0.id == item.id }
                next.mappings.removeAll { $0.hostId == item.id }
            } else {
                let input: HostInput = try decode(request, keys: ["name", "host", "port", "username", "notes"])
                item.name = input.name ?? item.name; item.host = input.host ?? item.host
                item.port = input.port ?? item.port; item.username = input.username ?? item.username; item.notes = input.notes ?? item.notes
                if request.command == "hosts.create", input.host == nil { throw AutomationError("INVALID_ARGUMENT", "创建主机必须提供 host。") }
                item.updatedAt = Date()
                try ConfigValidation.host(item)
                if let index = next.hosts.firstIndex(where: { $0.id == item.id }) { next.hosts[index] = item } else { next.hosts.append(item) }
                after = hostJSON(item)
            }
        } else {
            let input: MappingInput? = request.command == "mappings.delete" ? nil : try decode(request, keys: ["name", "hostId", "forwardType", "portRules", "socks5Port", "autoReconnect", "autoStart", "notes"])
            var item: PortMapping
            if request.command == "mappings.create" {
                guard let hostId = input?.hostId else { throw AutomationError("INVALID_ARGUMENT", "创建映射必须提供 hostId。") }
                item = PortMapping(hostId: hostId)
            } else {
                item = try mapping(options)
                before = try mappingJSON(item)
                guard !manager.isManaged(item.id) else { throw AutomationError("RESOURCE_BUSY", "请先停止隧道及自动重连，再修改或删除映射。") }
            }
            if request.command == "mappings.delete" {
                next.mappings.removeAll { $0.id == item.id }
            } else if let input = input {
                item.name = input.name ?? item.name; item.hostId = input.hostId ?? item.hostId
                item.forwardType = input.forwardType ?? item.forwardType
                item.socks5Port = input.socks5Port ?? item.socks5Port
                item.autoReconnect = input.autoReconnect ?? item.autoReconnect; item.autoStart = input.autoStart ?? item.autoStart
                item.notes = input.notes ?? item.notes
                if let rules = input.portRules { item.portRules = rules.map { PortRule(localPort: $0.localPort, remotePort: $0.remotePort, remoteHost: $0.remoteHost ?? "127.0.0.1") } }
                guard next.hosts.contains(where: { $0.id == item.hostId }) else { throw AutomationError("NOT_FOUND", "关联主机不存在。") }
                try ConfigValidation.mapping(item)
                item.updatedAt = Date()
                if let index = next.mappings.firstIndex(where: { $0.id == item.id }) { next.mappings[index] = item } else { next.mappings.append(item) }
                after = try mappingJSON(item)
            }
        }
        let dryRun = options["dry-run"] == "true"
        if !dryRun { try store.commit(next) }
        return ["dryRun": dryRun, "before": before, "after": after, "affectedMappingIds": affected,
                "activation": "saved_only_start_explicitly"] as [String: Any]
    }

    private func decode<T: Decodable>(_ request: AutomationRequest, keys: Set<String>) throws -> T {
        guard let payload = request.payload else { throw AutomationError("INVALID_ARGUMENT", "请使用 --file 提供 JSON 对象。") }
        do {
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], !object.isEmpty,
                  Set(object.keys).isSubset(of: keys), !containsNull(object) else {
                throw AutomationError("INVALID_ARGUMENT", "JSON 必须为非空对象，仅包含支持的字段；不接受密码、null 或未知字段。")
            }
            if let rules = object["portRules"] as? [[String: Any]] {
                for rule in rules where !Set(rule.keys).isSubset(of: ["localPort", "remotePort", "remoteHost"]) {
                    throw AutomationError("INVALID_ARGUMENT", "portRules 包含未知字段。")
                }
            }
            return try JSONDecoder().decode(T.self, from: payload)
        } catch let error as AutomationError { throw error }
        catch { throw AutomationError("INVALID_ARGUMENT", "JSON 字段类型无效，请查看 portbar --help。") }
    }

    private func containsNull(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let object = value as? [String: Any] { return object.values.contains(where: containsNull) }
        if let array = value as? [Any] { return array.contains(where: containsNull) }
        return false
    }

    private func uuid(_ options: [String: String], _ key: String) throws -> UUID {
        guard let raw = options[key], let id = UUID(uuidString: raw) else { throw AutomationError("INVALID_ARGUMENT", "请提供有效的 --\(key) UUID。") }
        return id
    }
    private func host(_ options: [String: String]) throws -> SSHHost {
        guard let item = store.host(for: try uuid(options, "host-id")) else { throw AutomationError("NOT_FOUND", "主机不存在。") }
        return item
    }
    private func mapping(_ options: [String: String]) throws -> PortMapping {
        guard let item = store.mapping(for: try uuid(options, "mapping-id")) else { throw AutomationError("NOT_FOUND", "映射不存在。") }
        return item
    }
    private func hostJSON(_ host: SSHHost) -> [String: Any] {
        ["id": host.id.uuidString, "name": redact(host.name), "host": host.host, "port": host.port,
         "username": host.username, "notes": redact(host.notes), "hasCredential": !host.password.isEmpty,
         "createdAt": ISO8601DateFormatter().string(from: host.createdAt), "updatedAt": ISO8601DateFormatter().string(from: host.updatedAt)]
    }
    private func mappingJSON(_ item: PortMapping) throws -> [String: Any] {
        var result = try AutomationJSON.object(item) as! [String: Any]
        result["name"] = redact(item.name); result["notes"] = redact(item.notes)
        return result
    }
    private func tunnelJSON(_ item: PortMapping) -> [String: Any] {
        let state = manager.status(for: item.id)
        var name: String
        var errorCode: String? = nil
        var message: String? = nil
        switch state {
        case .disconnected: name = "disconnected"
        case .connecting: name = "connecting"
        case .connected: name = "connected"
        case .error(let reason): name = "error"; errorCode = manager.failureCodes[item.id] ?? "SSH_FAILED"; message = redact(reason)
        }
        if manager.isStopping(item.id) { name = "stopping" }
        var result: [String: Any] = ["mappingId": item.id.uuidString, "state": name, "localPorts": item.allLocalPorts,
                                    "readinessScope": "local_listener_only", "operationId": manager.operationIDs[item.id] ?? ""]
        if let code = errorCode { result["error"] = ["code": code, "message": message ?? ""] }
        return result
    }
    private func redact(_ text: String) -> String {
        store.hosts.map(\.password).filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }
}

enum ConfigValidation {
    static func host(_ item: SSHHost) throws {
        try address(item.host)
        guard (1...65535).contains(item.port), !item.username.isEmpty,
              item.username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !item.username.hasPrefix("-"), !item.username.contains("@"), !item.username.contains("\0") else {
            throw AutomationError("INVALID_ARGUMENT", "SSH 端口必须为 1–65535，用户名不得为空、包含空白或 @，或以 - 开头。")
        }
    }
    static func address(_ value: String) throws {
        guard !value.isEmpty, value.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_[]").inverted) == nil,
              !value.hasPrefix("-"), value.utf8.count < 256 else {
            throw AutomationError("INVALID_ARGUMENT", "主机地址必须是 IP 或域名，不能包含空白或 SSH 参数。")
        }
    }
    static func mapping(_ item: PortMapping) throws {
        guard !item.allLocalPorts.isEmpty, item.allLocalPorts.count <= 100,
              item.allLocalPorts.allSatisfy({ (1...65535).contains($0) }),
              Set(item.allLocalPorts).count == item.allLocalPorts.count else {
            throw AutomationError("INVALID_ARGUMENT", "本地端口必须为 1–65535，不能重复，单个映射最多 100 个端口。")
        }
        if item.forwardType == .localPort {
            for rule in item.portRules {
                guard (1...65535).contains(rule.remotePort) else { throw AutomationError("INVALID_ARGUMENT", "目标端口必须为 1–65535。") }
                try address(rule.remoteHost)
            }
        }
    }
}
