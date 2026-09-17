import SwiftUI
import AppKit

public struct PortMappingDetailView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var tunnelManager = SSHTunnelManager.shared

    @State private var mapping: PortMapping
    @State private var showingLogs: Bool = false
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

            if status.isConnected && mapping.forwardType == .localPort, let url = mapping.localURL {
                Button(action: {
                    NSWorkspace.shared.open(url)
                }) {
                    Image(systemName: "safari")
                    Text("打开浏览器")
                }
                .buttonStyle(.bordered)
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
                    TextField("例如: Web 管理后台 / 测试数据库", text: $mapping.name)
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
            Text("端口转发规则")
                .font(.headline)

            Picker("转发模式:", selection: $mapping.forwardType) {
                ForEach(ForwardType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("本地端口:")
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    HStack {
                        TextField("8080", value: $mapping.localPort, formatter: NumberFormatter())
                            .frame(width: 100)
                            .textFieldStyle(.roundedBorder)
                        Text("本机映射监听的端口 (Local Port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if mapping.forwardType == .localPort {
                    GridRow {
                        Text("目标端口:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        HStack {
                            TextField("8080", value: $mapping.remotePort, formatter: NumberFormatter())
                                .frame(width: 100)
                                .textFieldStyle(.roundedBorder)
                            Text("远程目标服务的真实端口 (Remote Port)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    GridRow {
                        Text("目标绑定:")
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        HStack {
                            TextField("127.0.0.1", text: $mapping.remoteHost)
                                .frame(width: 140)
                                .textFieldStyle(.roundedBorder)
                            Text("远程转发绑定的地址 (通常为 127.0.0.1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var advancedOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("高级选项")
                .font(.headline)

            Toggle("连接意外中断时自动尝试重连", isOn: $mapping.autoReconnect)
            Toggle("PortBar 启动时自动开启此端口转发", isOn: $mapping.autoStart)
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
