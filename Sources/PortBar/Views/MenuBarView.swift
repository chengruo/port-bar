import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var tunnelManager = SSHTunnelManager.shared

    public var onOpenManager: (ManagerTab) -> Void
    public var onQuit: () -> Void

    public init(onOpenManager: @escaping (ManagerTab) -> Void, onQuit: @escaping () -> Void) {
        self.onOpenManager = onOpenManager
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("PortBar 端口转发")
                    .font(.headline)
                Spacer()
                if tunnelManager.activeTunnelCount > 0 {
                    Text("\(tunnelManager.activeTunnelCount) 活跃")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Port Mapping List
            ScrollView {
                VStack(spacing: 4) {
                    if configStore.mappings.isEmpty {
                        VStack(spacing: 8) {
                            Text("尚未配置任何端口映射")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("新建端口映射") {
                                onOpenManager(.mappings)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(configStore.mappings) { mapping in
                            mappingItemRow(for: mapping)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)

            Divider()

            // Footer
            HStack(spacing: 12) {
                Button(action: { onOpenManager(.mappings) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.swap")
                        Text("端口管理")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)

                Button(action: { onOpenManager(.hosts) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                        Text("主机管理")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                Spacer()

                if tunnelManager.activeTunnelCount > 0 {
                    Button(action: {
                        tunnelManager.stopAll()
                    }) {
                        Text("全部断开")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                }

                Button(action: onQuit) {
                    Text("退出")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 330)
    }

    private func mappingItemRow(for mapping: PortMapping) -> some View {
        let status = tunnelManager.status(for: mapping.id)
        let hostName = configStore.host(for: mapping.hostId)?.displayName ?? "未知主机"

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                // Status Light
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 9, height: 9)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(mapping.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("[\(hostName)]")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.blue)
                        Text(mapping.forwardingSummary)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .lineLimit(1)
                }

                Spacer()

                // Action Toggle / Button
                Button(action: {
                    tunnelManager.toggleTunnel(for: mapping)
                }) {
                    if status.isConnecting {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 44)
                    } else {
                        Text(status.isConnected ? "断开" : "连接")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(status.isConnected ? .red : .primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(status.isConnected ? Color.red.opacity(0.12) : Color.gray.opacity(0.12))
                            .cornerRadius(5)
                    }
                }
                .buttonStyle(.plain)
            }

            // Quick open link if connected
            if status.isConnected && mapping.forwardType == .localPort, let url = mapping.localURL {
                HStack(spacing: 8) {
                    Button(action: {
                        NSWorkspace.shared.open(url)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text("打开 http://127.0.0.1:\(mapping.localPort)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://127.0.0.1:\(mapping.localPort)", forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制本地地址")
                }
                .padding(.leading, 19)
                .padding(.top, 2)
            }

            // Error display if any
            if case .error(let msg) = status {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(status.isConnected ? Color.accentColor.opacity(0.06) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 6)
    }

    private func statusColor(_ status: TunnelState) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray.opacity(0.5)
        case .error: return .red
        }
    }
}
