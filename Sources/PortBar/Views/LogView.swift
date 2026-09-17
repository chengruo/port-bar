import SwiftUI
import AppKit

public struct LogView: View {
    @ObservedObject var tunnelManager = SSHTunnelManager.shared
    public let hostId: UUID
    public let hostName: String

    public init(hostId: UUID, hostName: String) {
        self.hostId = hostId
        self.hostName = hostName
    }

    public var body: some View {
        let logs = tunnelManager.logs(for: hostId)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时日志 - \(hostName)")
                    .font(.headline)
                Spacer()
                Button("清空日志") {
                    tunnelManager.clearLogs(for: hostId)
                }
                .font(.caption)

                Button("复制日志") {
                    let fullText = logs.map { "[\($0.formattedTime)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                }
                .font(.caption)
            }
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if logs.isEmpty {
                            Text("暂无日志输出。启动隧道后将在此显示诊断信息。")
                                .foregroundColor(.secondary)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.top, 20)
                        } else {
                            ForEach(logs) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("[\(entry.formattedTime)]")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(entry.message)
                                        .foregroundColor(entry.isError ? .red : .primary)
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .id(entry.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .onChange(of: logs.count) {
                    if let last = logs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 320)
    }
}
