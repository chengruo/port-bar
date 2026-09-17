import Foundation
import Combine

public final class SSHTunnelManager: ObservableObject {
    public static let shared = SSHTunnelManager()

    @Published public var statuses: [UUID: TunnelState] = [:] // Keyed by mapping.id
    @Published public var logs: [UUID: [LogEntry]] = [:]       // Keyed by mapping.id

    private var processes: [UUID: Process] = [:]
    private var isIntentionallyStopping: Set<UUID> = []
    private var reconnectTimers: [UUID: Timer] = [:]

    private init() {}

    public var activeTunnelCount: Int {
        statuses.values.filter { $0.isConnected }.count
    }

    public func status(for mappingId: UUID) -> TunnelState {
        statuses[mappingId] ?? .disconnected
    }

    public func logs(for mappingId: UUID) -> [LogEntry] {
        logs[mappingId] ?? []
    }

    public func appendLog(for mappingId: UUID, message: String, isError: Bool = false) {
        DispatchQueue.main.async {
            var mappingLogs = self.logs[mappingId] ?? []
            mappingLogs.append(LogEntry(message: message, isError: isError))
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
        guard let host = ConfigStore.shared.host(for: mapping.hostId) else {
            statuses[mapping.id] = .error("未找到关联的主机配置")
            appendLog(for: mapping.id, message: "❌ 启动失败: 未找到关联的主机配置", isError: true)
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var arguments = [
            "-N", // Do not execute a remote command
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
                arguments.append("\(rule.localPort):\(rule.remoteHost):\(rule.remotePort)")
                appendLog(for: mapping.id, message: "  ➔ 转发项: 127.0.0.1:\(rule.localPort) ➔ \(rule.remoteHost):\(rule.remotePort)")
            }
        case .socks5:
            arguments.append("-D")
            arguments.append("\(mapping.socks5Port)")
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

        arguments.append("\(host.username)@\(host.host)")

        process.arguments = arguments
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
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
                self?.appendLog(for: mapping.id, message: line, isError: true)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                self.processes.removeValue(forKey: mapping.id)
                let intentional = self.isIntentionallyStopping.contains(mapping.id)

                if intentional {
                    self.statuses[mapping.id] = .disconnected
                    self.appendLog(for: mapping.id, message: "🛑 隧道已停止。")
                } else {
                    let code = proc.terminationStatus
                    let errMsg = "SSH 进程意外退出 (代码: \(code))"
                    self.statuses[mapping.id] = .error(errMsg)
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
        for mappingId in processes.keys {
            stopTunnel(for: mappingId)
        }
    }

    // MARK: - Port Monitoring

    private func monitorPortConnection(for mapping: PortMapping, process: Process) {
        var attempts = 0
        let maxAttempts = 25 // 25 * 200ms = 5s
        let portsToCheck = mapping.allLocalPorts

        guard let firstPort = portsToCheck.first else {
            statuses[mapping.id] = .connected
            return
        }

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard process.isRunning else {
                timer.invalidate()
                return
            }

            attempts += 1
            if NetworkDetector.shared.isLocalPortListening(port: firstPort) {
                timer.invalidate()
                DispatchQueue.main.async {
                    self.statuses[mapping.id] = .connected
                    let portList = portsToCheck.map { String($0) }.joined(separator: ", ")
                    self.appendLog(for: mapping.id, message: "✅ 隧道已成功建立！正在监听本地端口: \(portList)")
                }
                return
            }

            if attempts >= maxAttempts {
                timer.invalidate()
                DispatchQueue.main.async {
                    if case .connecting = self.statuses[mapping.id] {
                        self.statuses[mapping.id] = .connected
                        self.appendLog(for: mapping.id, message: "⚡️ SSH 进程已就绪 (标记为运行状态)")
                    }
                }
            }
        }
    }

    // MARK: - Diagnostic Test Connection (For SSHHost)

    public func testConnection(host: SSHHost, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

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
