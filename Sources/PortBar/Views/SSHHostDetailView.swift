import SwiftUI
import AppKit

public struct SSHHostDetailView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var tunnelManager = SSHTunnelManager.shared

    @State private var host: SSHHost
    @State private var showPasswordPlain: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var testResultAlert: String?
    @State private var saveConfirmation: Bool = false

    public init(host: SSHHost) {
        _host = State(initialValue: host)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: "server.rack")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(host.username)@\(host.host):\(host.port)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: runTestConnection) {
                        HStack(spacing: 4) {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("测试 SSH 连通性")
                        }
                    }
                    .disabled(isTestingConnection)
                    .buttonStyle(.bordered)
                }

                Divider()

                // Form
                VStack(alignment: .leading, spacing: 14) {
                    Text("主机基本信息")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("别名备注:")
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            TextField("例如: 生产环境跳板机 / 公司开发机", text: $host.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("主机地址:")
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            HStack {
                                TextField("IP 或域名 (如: 1.2.3.4)", text: $host.host)
                                    .textFieldStyle(.roundedBorder)
                                Text("SSH 端口:")
                                    .foregroundColor(.secondary)
                                TextField("22", value: $host.port, formatter: NumberFormatter())
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        GridRow {
                            Text("用户名:")
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            TextField("root / ubuntu / admin", text: $host.username)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("SSH 密码:")
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if showPasswordPlain {
                                        TextField("输入 SSH 密码 (明文)", text: $host.password)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("输入 SSH 密码", text: $host.password)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    Button(action: { showPasswordPlain.toggle() }) {
                                        Image(systemName: showPasswordPlain ? "eye.slash" : "eye")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(showPasswordPlain ? "隐藏明文" : "显示明文密码")
                                }
                                Text("明文存储于本地配置文件中。若留空则自动回退使用系统本地密钥 (~/.ssh 等)。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        GridRow {
                            Text("备注说明:")
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            TextField("可选，添加更多备注说明", text: $host.notes)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                // Associated mappings summary
                let associatedMappings = configStore.mappings.filter { $0.hostId == host.id }
                if !associatedMappings.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前主机下的端口映射 (\(associatedMappings.count) 个)")
                            .font(.headline)
                        ForEach(associatedMappings) { mapping in
                            HStack {
                                Image(systemName: "arrow.triangle.swap")
                                    .foregroundColor(.blue)
                                Text(mapping.name)
                                    .fontWeight(.medium)
                                Text(mapping.forwardingSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                let status = tunnelManager.status(for: mapping.id)
                                Text(status.displayText)
                                    .font(.caption)
                                    .foregroundColor(status.isConnected ? .green : .secondary)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }

                Divider()

                // Bottom Save
                HStack {
                    Spacer()
                    if saveConfirmation {
                        Text("主机配置已保存 ✓")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    }

                    Button("保存主机配置") {
                        configStore.updateHost(host)
                        withAnimation { saveConfirmation = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saveConfirmation = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(24)
        }
        .alert(item: Binding(
            get: { testResultAlert.map { AlertHostItem(message: $0) } },
            set: { _ in testResultAlert = nil }
        )) { item in
            Alert(title: Text("SSH 连接测试结果"), message: Text(item.message), dismissButton: .default(Text("确定")))
        }
    }

    private func runTestConnection() {
        isTestingConnection = true
        tunnelManager.testConnection(host: host) { success, message in
            isTestingConnection = false
            testResultAlert = message
        }
    }
}

private struct AlertHostItem: Identifiable {
    let id = UUID()
    let message: String
}
