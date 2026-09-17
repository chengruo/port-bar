import SwiftUI
import AppKit

public struct PortMappingDetailView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var tunnelManager = SSHTunnelManager.shared

    @State private var mapping: PortMapping
    @State private var showingLogs: Bool = false
    @State private var showingBatchInput: Bool = false
    @State private var batchText: String = ""
    @State private var saveConfirmation: Bool = false

    public init(mapping: PortMapping) {
        _mapping = State(initialValue: mapping)
    }

    public var body: some View {
        let status = tunnelManager.status(for: mapping.id)
        let selectedHost = configStore.host(for: mapping.hostId)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Bar
                headerView(status: status, host: selectedHost)

                Divider()

                // Form Sections
                Group {
                    basicSection
                    hostSelectionSection
                    forwardingSection
                    advancedOptionsSection
                }

                Divider()

                // Bottom Bar
                bottomBar
            }
            .padding(24)
        }
        .sheet(isPresented: $showingLogs) {
            LogView(hostId: mapping.id, hostName: mapping.displayName)
        }
        .sheet(isPresented: $showingBatchInput) {
            batchInputSheet
        }
    }

    // MARK: - Subviews

    private func headerView(status: TunnelState, host: SSHHost?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusColor(status).opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: statusIcon(status))
                    .font(.system(size: 24))
                    .foregroundColor(statusColor(status))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(mapping.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(status))
                        .frame(width: 8, height: 8)
                    Text(status.displayText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    if let h = host {
                        Text("跳板: \(h.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("⚠️ 未指定有效主机")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            Spacer()

            // Start/Stop Forwarding Button
            Button(action: {
                configStore.updateMapping(mapping)
                tunnelManager.toggleTunnel(for: mapping)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: status.isConnected ? "stop.fill" : "play.fill")
                    Text(status.isConnected ? "停止转发" : (status.isConnecting ? "连接中..." : "启动转发"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(status.isConnected ? .red : .accentColor)
            .disabled(status.isConnecting || configStore.host(for: mapping.hostId) == nil)

            if status.isConnected && mapping.forwardType == .localPort {
                let urls = mapping.localURLs
                if urls.count == 1, let first = urls.first {
                    Button(action: {
                        NSWorkspace.shared.open(first.url)
                    }) {
                        Image(systemName: "safari")
                        Text("打开 :\(first.port)")
                    }
                    .buttonStyle(.bordered)
                } else if urls.count > 1 {
                    Menu {
                        ForEach(urls, id: \.port) { item in
                            Button("打开 http://127.0.0.1:\(item.port)") {
                                NSWorkspace.shared.open(item.url)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                            Text("打开浏览器")
                        }
                    }
                    .menuStyle(.borderedButton)
                }
            }
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基本信息")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("服务名称:")
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    TextField("例如: Web 管理后台 / 测试数据库集群", text: $mapping.name)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("备注说明:")
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    TextField("可选，添加更多描述", text: $mapping.notes)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var hostSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联跳板主机")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("选择主机:")
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    HStack {
                        Picker("", selection: $mapping.hostId) {
                            if configStore.hosts.isEmpty {
                                Text("无可用主机，请先在主机管理添加").tag(UUID())
                            } else {
                                ForEach(configStore.hosts) { h in
                                    Text("\(h.displayName) (\(h.host):\(h.port))").tag(h.id)
                                }
                            }
                        }
                        .frame(minWidth: 260)

                        if let h = configStore.host(for: mapping.hostId) {
                            Text("用户: \(h.username)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var forwardingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("端口转发规则")
                    .font(.headline)
                Spacer()

                if mapping.forwardType == .localPort {
                    Button(action: {
                        batchText = ""
                        showingBatchInput = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.plus")
                            Text("批量快速录入...")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: addNewPortRule) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("添加端口")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Picker("转发模式:", selection: $mapping.forwardType) {
                ForEach(ForwardType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            if mapping.forwardType == .socks5 {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("本地监听:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        HStack {
                            TextField("1080", value: $mapping.socks5Port, formatter: NumberFormatter())
                                .frame(width: 100)
                                .textFieldStyle(.roundedBorder)
                            Text("本机 SOCKS5 代理监听端口 (例如 1080)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                // Multi-Port Rules List
                VStack(spacing: 8) {
                    // Header Row
                    HStack(spacing: 12) {
                        Text("本机监听端口")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text("➔")
                            .foregroundColor(.clear)
                        Text("目标远端地址 : 目标端口")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 220, alignment: .leading)
                        Spacer()
                        Text("操作")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)

                    if mapping.portRules.isEmpty {
                        VStack(spacing: 8) {
                            Text("暂无端口转发规则，点击右上角快速添加。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("添加第一个端口 (默认本地=目标)") {
                                addNewPortRule()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(8)
                    } else {
                        ForEach($mapping.portRules) { $rule in
                            portRuleRow(rule: $rule)
                        }
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(8)
            }
        }
    }

    private func portRuleRow(rule: Binding<PortRule>) -> some View {
        HStack(spacing: 12) {
            // Local Port
            HStack(spacing: 4) {
                TextField("8080", value: rule.localPort, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Remote Host & Remote Port
            HStack(spacing: 4) {
                TextField("127.0.0.1", text: rule.remoteHost)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                Text(":")
                    .foregroundColor(.secondary)
                TextField("8080", value: Binding(
                    get: { rule.wrappedValue.remotePort },
                    set: { newRemote in
                        let oldRemote = rule.wrappedValue.remotePort
                        let currentLocal = rule.wrappedValue.localPort
                        rule.wrappedValue.remotePort = newRemote
                        // If local port was previously equal to remote port or default, auto-sync!
                        if currentLocal == oldRemote || currentLocal == 0 {
                            rule.wrappedValue.localPort = newRemote
                        }
                    }
                ), formatter: NumberFormatter())
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
            }

            // Sync indicator / quick sync button
            if rule.wrappedValue.localPort == rule.wrappedValue.remotePort {
                Text("本地=目标")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            } else {
                Button("对齐") {
                    rule.wrappedValue.localPort = rule.wrappedValue.remotePort
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("将本地端口对齐为目标端口 (\(rule.wrappedValue.remotePort))")
            }

            Spacer()

            // Delete Button
            Button(action: {
                deletePortRule(rule.wrappedValue.id)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("删除此端口项")
        }
        .padding(6)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
    }

    private var advancedOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("高级选项")
                .font(.headline)

            Toggle("连接意外中断时自动尝试重连", isOn: $mapping.autoReconnect)
            Toggle("PortBar 启动时自动开启此转发", isOn: $mapping.autoStart)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("查看实时日志") {
                showingLogs = true
            }
            .buttonStyle(.bordered)

            Spacer()

            if saveConfirmation {
                Text("配置已保存 ✓")
                    .foregroundColor(.green)
                    .font(.subheadline)
            }

            Button("保存端口映射") {
                configStore.updateMapping(mapping)
                withAnimation { saveConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { saveConfirmation = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    // MARK: - Batch Input Sheet

    private var batchInputSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("⚡️ 批量快速录入端口")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    showingBatchInput = false
                }
                .buttonStyle(.plain)
            }

            Text("支持输入由逗号、空格或换行分隔的端口列表，默认自动设置 本地端口 = 目标端口。\n例如：8080, 3306, 6379, 9000-9003 或映射格式 8080:8081")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $batchText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // Live Preview of parsed ports
            let parsed = PortMapping.parseBatchPorts(batchText)
            if !parsed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("解析预览 (已识别 \(parsed.count) 个端口，本地=目标):")
                        .font(.caption)
                        .fontWeight(.semibold)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(parsed) { rule in
                                Text("\(rule.localPort)➔\(rule.remotePort)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("追加到当前列表") {
                    let parsed = PortMapping.parseBatchPorts(batchText)
                    for r in parsed {
                        if !mapping.portRules.contains(where: { $0.localPort == r.localPort }) {
                            mapping.portRules.append(r)
                        }
                    }
                    showingBatchInput = false
                }
                .disabled(parsed.isEmpty)
                .buttonStyle(.bordered)

                Button("替换当前列表") {
                    let parsed = PortMapping.parseBatchPorts(batchText)
                    if !parsed.isEmpty {
                        mapping.portRules = parsed
                    }
                    showingBatchInput = false
                }
                .disabled(parsed.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    // MARK: - Actions

    private func addNewPortRule() {
        // Find next port suggestion
        let maxExisting = mapping.portRules.map { max($0.localPort, $0.remotePort) }.max() ?? 8079
        let nextPort = maxExisting + 1
        // Default: localPort = remotePort!
        let newRule = PortRule(localPort: nextPort, remotePort: nextPort, remoteHost: "127.0.0.1")
        mapping.portRules.append(newRule)
    }

    private func deletePortRule(_ id: UUID) {
        mapping.portRules.removeAll(where: { $0.id == id })
    }

    private func statusColor(_ status: TunnelState) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private func statusIcon(_ status: TunnelState) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .disconnected: return "circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
