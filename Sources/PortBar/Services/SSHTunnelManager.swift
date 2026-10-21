import Foundation
import Combine

public final class SSHTunnelManager: ObservableObject {
    public static let shared = SSHTunnelManager()

    @Published public var statuses: [UUID: TunnelState] = [:] // Keyed by mapping.id
    @Published public var logs: [UUID: [LogEntry]] = [:]       // Keyed by mapping.id

    public private(set) var operationIDs: [UUID: String] = [:]
    public private(set) var failureCodes: [UUID: String] = [:]

    public func isManaged(_ id: UUID) -> Bool {
        // Keep ownership until the termination callback has finalized state and timers.
        processes[id] != nil || reconnectTimers[id] != nil
    }

    public func isStopping(_ id: UUID) -> Bool {
        isIntentionallyStopping.contains(id) && processes[id] != nil
    }

    private var processes: [UUID: Process] = [:]
    private var isIntentionallyStopping: Set<UUID> = []
    private var reconnectTimers: [UUID: Timer] = [:]

    private let suppliedStore: ConfigStore?
    private let sshExecutable: URL
    private var configStore: ConfigStore { suppliedStore ?? .shared }

    init(store: ConfigStore? = nil, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.suppliedStore = store
        self.sshExecutable = sshExecutable
    }

    public var activeTunnelCount: Int {
        statuses.values.filter { $0.isConnected }.count
    }

    public func status(for mappingId: UUID) -> TunnelState {
        statuses[mappingId] ?? .disconnected
    }

    public func logs(for mappingId: UUID) -> [LogEntry] {
        logs[mappingId] ?? []
    }

    public func appendLog(for mappingId: UUID, message: String, isError: Bool = false, operationID: String? = nil) {
        DispatchQueue.main.async {
            var mappingLogs = self.logs[mappingId] ?? []
            let safeMessage = self.configStore.hosts.map(\.password).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                .reduce(message) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
            mappingLogs.append(LogEntry(message: safeMessage, isError: isError))
            if isError && (operationID == nil || self.operationIDs[mappingId] == operationID) {
                let lower = message.lowercased()
                if lower.contains("permission denied") || lower.contains("authentication failed") { self.failureCodes[mappingId] = "AUTH_FAILED" }
                else if lower.contains("address already in use") { self.failureCodes[mappingId] = "PORT_IN_USE" }
                else if lower.contains("host key verification failed") || lower.contains("host identification has changed") { self.failureCodes[mappingId] = "HOST_KEY_CHANGED" }
                else if lower.contains("could not resolve hostname") { self.failureCodes[mappingId] = "DNS_FAILED" }
                else if lower.contains("connection refused") { self.failureCodes[mappingId] = "CONNECTION_REFUSED" }
                else if lower.contains("timed out") { self.failureCodes[mappingId] = "CONNECT_TIMEOUT" }
            }
            if mappingLogs.count > 500 {
                mappingLogs.removeFirst(mappingLogs.count - 500)
            }
            self.logs[mappingId] = mappingLogs
        }
    }

    public func clearLogs(for mappingId: UUID) {
        DispatchQueue.main.async {
            self.logs[mappingId] = []
        }
    }

    // MARK: - Tunnel Control

    public func toggleTunnel(for mapping: PortMapping) {
        let current = status(for: mapping.id)
        if current.isConnected || current.isConnecting {
            stopTunnel(for: mapping.id)
        } else {
            startTunnel(for: mapping)
        }
    }

    public func startTunnel(for mapping: PortMapping) {
        if isStopping(mapping.id) { return }
        if status(for: mapping.id).isConnected || status(for: mapping.id).isConnecting { return }
        operationIDs[mapping.id] = UUID().uuidString
        failureCodes.removeValue(forKey: mapping.id)
        guard let host = configStore.host(for: mapping.hostId) else {
            statuses[mapping.id] = .error("未找到关联的主机配置")
            appendLog(for: mapping.id, message: "❌ 启动失败: 未找到关联的主机配置", isError: true)
            return
        }

        do {
            try ConfigValidation.host(host)
            try ConfigValidation.mapping(mapping)
        } catch {
            statuses[mapping.id] = .error((error as? AutomationError)?.message ?? "配置无效")
            failureCodes[mapping.id] = "INVALID_ARGUMENT"
            return
        }
        if let occupied = mapping.allLocalPorts.first(where: { NetworkDetector.shared.isLocalPortListening(port: $0) }) {
            statuses[mapping.id] = .error("本地端口 \(occupied) 已被占用")
            failureCodes[mapping.id] = "PORT_IN_USE"
            return
        }

        if mapping.forwardType == .localPort && mapping.portRules.isEmpty {
            statuses[mapping.id] = .error("尚未配置任何端口转发规则")
            appendLog(for: mapping.id, message: "❌ 启动失败: 尚未配置任何端口转发规则", isError: true)
            return
        }

        // Cancel existing reconnect timer if any
        reconnectTimers[mapping.id]?.invalidate()
        reconnectTimers.removeValue(forKey: mapping.id)

        // Stop existing process if any
        if let existing = processes[mapping.id], existing.isRunning {
            existing.terminate()
        }

        isIntentionallyStopping.remove(mapping.id)
        statuses[mapping.id] = .connecting

        appendLog(for: mapping.id, message: "🚀 正在建立 SSH 端口转发...")
        appendLog(for: mapping.id, message: "服务: \(mapping.name)")
        appendLog(for: mapping.id, message: "跳板主机: [\(host.displayName)] \(host.username)@\(host.host):\(host.port)")

        let process = Process()
        process.executableURL = self.sshExecutable

        var arguments = [
            "-N", // Do not execute a remote command
            "-o", "ConnectTimeout=10",
            "-p", String(host.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "TCPKeepAlive=yes"
        ]

        switch mapping.forwardType {
        case .localPort:
            for rule in mapping.portRules {
                arguments.append("-L")
                let target = rule.remoteHost.contains(":") && !rule.remoteHost.hasPrefix("[") ? "[\(rule.remoteHost)]" : rule.remoteHost
                arguments.append("127.0.0.1:\(rule.localPort):\(target):\(rule.remotePort)")
                appendLog(for: mapping.id, message: "  ➔ 转发项: 127.0.0.1:\(rule.localPort) ➔ \(rule.remoteHost):\(rule.remotePort)")
            }
        case .socks5:
            arguments.append("-D")
            arguments.append("127.0.0.1:\(mapping.socks5Port)")
            appendLog(for: mapping.id, message: "  ➔ SOCKS5 代理监听: 127.0.0.1:\(mapping.socks5Port)")
        }

        var env = ProcessInfo.processInfo.environment

        // Handle Password via askpass bridge if provided
        let trimmedPassword = host.password
        if !trimmedPassword.isEmpty {
            if let askpassPath = AskpassHelper.shared.getAskpassBinaryPath() {
                env["SSH_ASKPASS"] = askpassPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = "portbar:0"
                env["PORTBAR_SSH_PASSWORD"] = trimmedPassword
                arguments.append("-o")
                arguments.append("BatchMode=no")
            } else {
                appendLog(for: mapping.id, message: "⚠️ 未能加载 askpass 认证桥接器，将尝试默认凭据", isError: true)
            }
        }

        if trimmedPassword.isEmpty { arguments += ["-o", "BatchMode=yes"] }
        arguments.append("\(host.username)@\(host.host)")

        process.arguments = arguments
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let operationID = operationIDs[mapping.id]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in lines {
                self?.appendLog(for: mapping.id, message: line)
            }
        }

        // Read stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in lines {
                self?.appendLog(for: mapping.id, message: line, isError: true, operationID: operationID)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                guard self.processes[mapping.id] === proc else { return }
                self.processes.removeValue(forKey: mapping.id)
                let intentional = self.isIntentionallyStopping.contains(mapping.id)

                if intentional {
                    self.statuses[mapping.id] = .disconnected
                    self.appendLog(for: mapping.id, message: "🛑 隧道已停止。")
                } else {
                    let code = proc.terminationStatus
                    let errMsg = "SSH 进程意外退出 (代码: \(code))"
                    if self.failureCodes[mapping.id] != "READINESS_TIMEOUT" {
                        self.statuses[mapping.id] = .error(errMsg)
                    }
                    if self.failureCodes[mapping.id] == nil { self.failureCodes[mapping.id] = "SSH_FAILED" }
                    self.appendLog(for: mapping.id, message: "❌ \(errMsg)", isError: true)

                    // Auto reconnect if enabled
                    if mapping.autoReconnect {
                        self.appendLog(for: mapping.id, message: "🔄 已开启自动重连，将在 5 秒后重试...")
                        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                            self?.startTunnel(for: mapping)
                        }
                        self.reconnectTimers[mapping.id] = timer
                    }
                }
            }
        }

        do {
            try process.run()
            processes[mapping.id] = process

            // Verify listening status by polling local ports
            self.monitorPortConnection(for: mapping, process: process)
        } catch {
            statuses[mapping.id] = .error(error.localizedDescription)
            appendLog(for: mapping.id, message: "❌ 启动失败: \(error.localizedDescription)", isError: true)
        }
    }

    public func stopTunnel(for mappingId: UUID) {
        if isStopping(mappingId) { return }
        if isManaged(mappingId) || status(for: mappingId) != .disconnected {
            operationIDs[mappingId] = UUID().uuidString
        }
        reconnectTimers[mappingId]?.invalidate()
        reconnectTimers.removeValue(forKey: mappingId)

        isIntentionallyStopping.insert(mappingId)

        if let proc = processes[mappingId], proc.isRunning {
            proc.terminate()
        } else {
            statuses[mappingId] = .disconnected
        }
    }

    public func stopAll() {
        for mappingId in Set(processes.keys).union(reconnectTimers.keys) {
            stopTunnel(for: mappingId)
        }
    }

    // MARK: - Port Monitoring

    private func monitorPortConnection(for mapping: PortMapping, process: Process) {
        var attempts = 0
        let maxAttempts = 60 // 12s: allow SSH ConnectTimeout to report a useful error
        let portsToCheck = mapping.allLocalPorts

        guard !portsToCheck.isEmpty else { return }

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard self.processes[mapping.id] === process, process.isRunning,
                  !self.isIntentionallyStopping.contains(mapping.id) else {
                timer.invalidate()
                return
            }

            attempts += 1
            if portsToCheck.allSatisfy({ NetworkDetector.shared.isLocalPortListening(port: $0) }) {
                timer.invalidate()
                DispatchQueue.main.async {
                    guard self.processes[mapping.id] === process, process.isRunning,
                          !self.isIntentionallyStopping.contains(mapping.id) else { return }
                    self.statuses[mapping.id] = .connected
                    let portList = portsToCheck.map { String($0) }.joined(separator: ", ")
                    self.appendLog(for: mapping.id, message: "✅ 隧道已成功建立！正在监听本地端口: \(portList)")
                }
                return
            }

            if attempts >= maxAttempts {
                timer.invalidate()
                DispatchQueue.main.async {
                    if self.processes[mapping.id] === process, case .connecting = self.statuses[mapping.id] {
                        self.failureCodes[mapping.id] = "READINESS_TIMEOUT"
                        self.statuses[mapping.id] = .error("等待本地端口监听超时")
                        self.appendLog(for: mapping.id, message: "等待本地端口监听超时", isError: true)
                        process.terminate()
                    }
                }
            }
        }
    }

    // MARK: - Diagnostic Test Connection (For SSHHost)

    public func testConnection(host: SSHHost, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = self.sshExecutable

            var arguments = [
                "-p", String(host.port),
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new"
            ]

            var env = ProcessInfo.processInfo.environment
            let trimmedPassword = host.password
            if !trimmedPassword.isEmpty, let askpassPath = AskpassHelper.shared.getAskpassBinaryPath() {
                env["SSH_ASKPASS"] = askpassPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = "portbar:0"
                env["PORTBAR_SSH_PASSWORD"] = trimmedPassword
                arguments.append("-o")
                arguments.append("BatchMode=no")
            } else {
                arguments.append("-o")
                arguments.append("BatchMode=yes")
            }

            arguments.append("\(host.username)@\(host.host)")
            arguments.append("echo PORTBAR_TEST_OK")

            process.arguments = arguments
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 && output.contains("PORTBAR_TEST_OK") {
                        completion(true, "连接成功！SSH 登录凭据有效。")
                    } else {
                        completion(false, "连接失败 (退出码 \(process.terminationStatus)): \(output)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "执行测试失败: \(error.localizedDescription)")
                }
            }
        }
    }
}
