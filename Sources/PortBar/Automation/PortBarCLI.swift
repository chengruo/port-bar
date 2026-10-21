import Foundation
import Darwin

enum PortBarCLI {
    static let help = """
    PortBar CLI \(PortBarVersion.current) — local SSH tunnel automation
    Usage: portbar <command> [options]

      capabilities                         Protocol, access level and supported commands
      status                               Application summary
      hosts list [--search TEXT] [--limit N]
      hosts get --host-id UUID
      hosts create --file PATH             Create a host (credentials managed in the app)
      hosts update --host-id UUID --file PATH
      hosts delete --host-id UUID [--cascade]
      mappings list [--search TEXT] [--limit N]
      mappings get --mapping-id UUID
      mappings create --file PATH
      mappings update --mapping-id UUID --file PATH
      mappings delete --mapping-id UUID
      tunnels status [--mapping-id UUID]
      tunnels start|stop --mapping-id UUID [--wait --timeout SECONDS]
      tunnels diagnose --mapping-id UUID
      logs list --mapping-id UUID [--limit N]
      activity list [--limit N]             Recent CLI calls (in memory, max 100)
      skill install --directory PATH       Copy bundled skill to PATH/portbar
      schema                               JSON input fields and response contract

    Options:
      --json                Structured envelope on stdout, including errors
      --dry-run             Preview create/update/delete without saving
      --if-revision VALUE   Reject mutation if the configuration has changed
      --cascade             Explicitly delete a host's associated mappings
      --file -              Read JSON from stdin (max 256 KiB)
      --wait                Wait for start/stop completion (default timeout: 15s)
      --timeout SECONDS     1–120 seconds; requires --wait
      --help, --version

    Host JSON (create requires host; update patches supplied fields):
      {"name":"dev","host":"dev.example.com","port":22,"username":"ubuntu","notes":""}
    Mapping JSON (create requires hostId; defaults: local_port, 8080→8080):
      {"name":"db","hostId":"UUID","forwardType":"local_port",
       "portRules":[{"localPort":13306,"remoteHost":"127.0.0.1","remotePort":3306}],
       "autoStart":false,"autoReconnect":false}
    SOCKS5: use forwardType=socks5 and socks5Port (default 1080).
    Unknown fields, nulls, credentials and invalid ports are rejected.
    Edits/deletes require stopped tunnels. Saving never starts a tunnel immediately.
    Readiness checks local listeners, not remote application health.
    No automatic application launch. Open PortBar and enable CLI in Settings first.
    Access is shared by local processes running as the same macOS user.
    Exit codes: 0 success; 2 arguments; 3 unavailable; 4 denied; 5 operation failed; 6 timeout.
    """

    static func run(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        do {
            if arguments.isEmpty || arguments.contains("--help") || arguments == ["-h"] { print(help); return 0 }
            if arguments == ["--version"] { print("portbar \(PortBarVersion.current) (protocol 1)"); return 0 }
            let parsed = try parse(arguments)
            if parsed.request.command == "skill.install" {
                guard let path = parsed.request.options["directory"] else { throw AutomationError("INVALID_ARGUMENT", "请提供 --directory。") }
                let destination = try installSkill(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                return emit(["ok": true, "data": ["installed": destination.path]], json: json)
            }
            if parsed.request.command == "schema" {
                return emit(["ok": true, "data": schema], json: json)
            }
            var response = try LocalIPC.call(parsed.request)
            if parsed.wait, response["ok"] as? Bool == true {
                let target = parsed.request.command == "tunnels.start" ? "connected" : "disconnected"
                let deadline = Date().addingTimeInterval(parsed.timeout)
                let operationID = (response["data"] as? [String: Any])?["operationId"] as? String
                while true {
                    guard let data = response["data"] as? [String: Any], let state = data["state"] as? String else { break }
                    if let current = data["operationId"] as? String, let expected = operationID, current != expected {
                        response["ok"] = false
                        response["error"] = ["code": "OPERATION_SUPERSEDED", "message": "隧道操作已被其他操作替代。"]
                        break
                    }
                    if state == target { break }
                    if state == "error" {
                        response["ok"] = false
                        response["error"] = data["error"] ?? ["code": "SSH_FAILED", "message": "SSH 隧道连接失败。"]
                        break
                    }
                    if Date() >= deadline {
                        response["ok"] = false
                        response["error"] = ["code": "TIMEOUT", "message": "等待超时，操作可能仍在进行，请查询 tunnels status。"]
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                    response = try LocalIPC.call(AutomationRequest(command: "tunnels.status", options: parsed.request.options.filter { $0.key == "mapping-id" }))
                    if response["ok"] as? Bool != true { break }
                }
            }
            return emit(response, json: json)
        } catch {
            return emit(AutomationJSON.failure(error), json: json)
        }
    }

    struct Parsed {
        var request: AutomationRequest
        var wait: Bool
        var timeout: Double
    }

    static func parse(_ arguments: [String]) throws -> Parsed {
        var words: [String] = []
        var options: [String: String] = [:]
        let flags: Set<String> = ["json", "dry-run", "cascade", "wait"]
        let valued: Set<String> = ["host-id", "mapping-id", "search", "limit", "file", "if-revision", "timeout", "directory"]
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                guard options[key] == nil, flags.contains(key) || valued.contains(key) else { throw AutomationError("INVALID_ARGUMENT", "未知或重复选项：\(arg)") }
                if flags.contains(key) { options[key] = "true" }
                else {
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw AutomationError("INVALID_ARGUMENT", "\(arg) 缺少值。") }
                    options[key] = arguments[index]
                }
            } else { words.append(arg) }
            index += 1
        }
        let command = words.joined(separator: ".")
        guard AutomationService.commands.contains(command) || ["skill.install", "schema"].contains(command) else {
            throw AutomationError("INVALID_ARGUMENT", "未知命令，请运行 portbar --help。")
        }
        options.removeValue(forKey: "json")
        let wait = options.removeValue(forKey: "wait") != nil
        let timeoutRaw = options.removeValue(forKey: "timeout")
        let timeout = Double(timeoutRaw ?? "15") ?? -1
        guard timeout.isFinite, (1...120).contains(timeout), (timeoutRaw == nil || wait), (!wait || ["tunnels.start", "tunnels.stop"].contains(command)) else {
            throw AutomationError("INVALID_ARGUMENT", "--wait 仅用于隧道启停，--timeout 必须配合 --wait 且为 1–120 秒。")
        }
        var payload: Data?
        if let file = options.removeValue(forKey: "file") {
            guard command.hasSuffix(".create") || command.hasSuffix(".update") else { throw AutomationError("INVALID_ARGUMENT", "该命令不接受 --file。") }
            do {
                let handle = file == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
                defer { if file != "-" { try? handle.close() } }
                payload = try handle.read(upToCount: 262_145) ?? Data()
                guard payload!.count <= 262_144 else { throw AutomationError("PAYLOAD_TOO_LARGE", "JSON 文件超过 256 KiB。") }
            } catch let error as AutomationError { throw error }
            catch { throw AutomationError("INVALID_ARGUMENT", "无法读取 JSON 文件。") }
        }
        if command == "skill.install" {
            guard Set(options.keys) == ["directory"] else { throw AutomationError("INVALID_ARGUMENT", "skill install 仅接受 --directory 和 --json。") }
        } else if command == "schema" {
            guard options.isEmpty else { throw AutomationError("INVALID_ARGUMENT", "schema 不接受额外选项。") }
        }
        return Parsed(request: AutomationRequest(command: command, options: options, payload: payload), wait: wait, timeout: timeout)
    }

    static func installSkill(directory: URL) throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let candidates = [
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/portbar"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("skills/portbar")
        ]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else {
            throw AutomationError("SKILL_NOT_FOUND", "未找到配套 Skill，请重新安装完整的 PortBar.app。")
        }
        let destination = directory.appendingPathComponent("portbar", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AutomationError("ALREADY_EXISTS", "目标 portbar 目录已存在，请先备份或移走后重试。")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch { throw AutomationError("INSTALL_FAILED", "无法安装 Skill，请检查目标目录的写入权限。") }
        return destination
    }

    static let schema: [String: Any] = [
        "protocolVersion": 1,
        "hostFields": ["name": "string", "host": "string (required on create)", "port": "integer 1..65535 (default 22)", "username": "string (default root)", "notes": "string"],
        "mappingFields": ["name": "string", "hostId": "UUID (required on create)", "forwardType": "local_port | socks5", "portRules": "array of {localPort: integer, remotePort: integer, remoteHost?: string}; 1..100 rules", "socks5Port": "integer 1..65535 (default 1080)", "autoReconnect": "boolean (default false)", "autoStart": "boolean (default false)", "notes": "string"],
        "response": ["ok": "boolean", "requestId": "string (IPC commands)", "revision": "opaque string (success; changes on config save)", "data": "command result on success", "error": "{code: string, message: string} on failure"],
        "commands": AutomationService.commands,
        "notes": ["Updates patch supplied fields; null and unknown fields are rejected.", "Credentials are managed only in the GUI.", "Lists default to 100, --limit 1..500; filter with --search.", "dry-run returns before/after and affectedMappingIds; it never saves.", "--wait tests local listener readiness, not remote application health."]
    ]

    @discardableResult private static func emit(_ response: [String: Any], json: Bool) -> Int32 {
        let success = response["ok"] as? Bool == true
        let error = response["error"] as? [String: Any]
        if json {
            if let bytes = try? AutomationJSON.data(response) { FileHandle.standardOutput.write(bytes + Data([10])) }
        } else if success {
            if let bytes = try? AutomationJSON.data(response["data"] ?? [:]) { FileHandle.standardOutput.write(bytes + Data([10])) }
        } else {
            let message = "\(error?["code"] as? String ?? "ERROR"): \(error?["message"] as? String ?? "操作失败。")\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        guard !success else { return 0 }
        switch error?["code"] as? String {
        case "INVALID_ARGUMENT", "PAYLOAD_TOO_LARGE", "UNSUPPORTED_VERSION": return 2
        case "APP_NOT_RUNNING", "IPC_ERROR": return 3
        case "PERMISSION_DENIED": return 4
        case "TIMEOUT": return 6
        default: return 5
        }
    }
}
