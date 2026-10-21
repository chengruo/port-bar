import SwiftUI
import AppKit

struct AutomationSettingsView: View {
    @AppStorage("portbar_cli_access") private var access = 0
    @ObservedObject private var service = AutomationService.shared
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 与 CLI 自动化").font(.headline)
            Picker("CLI 权限", selection: $access) {
                ForEach(AutomationAccess.allCases, id: \.rawValue) { level in
                    Text(level.title).tag(level.rawValue)
                }
            }
            Text("权限适用于当前 macOS 用户的本地程序。密码不会通过 CLI 返回。关闭后立即拒绝后续调用，已有隧道继续运行。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("复制 CLI 命令") {
                    let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/portbar").path
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' --help", forType: .string)
                    message = "已复制完整路径命令，可直接在终端执行。"
                }
                Button("安装 CLI…") { chooseDirectory(skill: false) }
                Button("安装 AI Skill…") { chooseDirectory(skill: true) }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("最近 CLI 调用（仅保留本次运行的最近 100 条）").font(.caption).foregroundColor(.secondary)
            Text(service.activity.suffix(4).joined(separator: "\n").isEmpty ? "暂无调用" : service.activity.suffix(4).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func chooseDirectory(skill: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = skill ? "选择 AI 客户端的 skills 目录，将创建 portbar 子目录。" : "选择 PATH 中的 bin 目录，将创建 portbar 链接。"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            if skill {
                let result = try PortBarCLI.installSkill(directory: directory)
                message = "Skill 已安装：\(result.path)。请按 AI 客户端的方式刷新 Skill。"
            } else {
                let destination = directory.appendingPathComponent("portbar")
                let target = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/portbar")
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
                message = "CLI 已安装：\(destination.path)。请确保该目录位于 PATH。"
            }
        } catch {
            message = (error as? AutomationError)?.message ?? "安装失败：请检查目录权限及是否已存在同名文件。"
        }
    }
}
