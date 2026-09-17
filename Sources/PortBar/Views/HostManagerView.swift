import SwiftUI
import AppKit

public enum ManagerTab: Int, CaseIterable, Identifiable {
    case mappings = 0
    case hosts = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .mappings: return "端口映射管理"
        case .hosts: return "主机独立管理"
        }
    }

    public var icon: String {
        switch self {
        case .mappings: return "arrow.triangle.swap"
        case .hosts: return "server.rack"
        }
    }
}

public struct HostManagerView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var tunnelManager = SSHTunnelManager.shared

    @State private var selectedTab: ManagerTab = .mappings
    @State private var selectedMappingId: UUID?
    @State private var selectedHostId: UUID?
    @State private var searchText: String = ""

    @State private var showingPreferences: Bool = false
    @AppStorage("portbar_show_dock_icon") private var showDockIcon: Bool = false

    public init(initialTab: ManagerTab = .mappings) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Tab Bar
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(ManagerTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                // Quick Shortcut Badge & Settings
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                        Text("随时唤起: ⌥ P")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)

                    Button(action: { showingPreferences = true }) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("唤起设置与防刘海指南")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content Split View according to selected tab
            Group {
                if selectedTab == .mappings {
                    mappingsSplitView
                } else {
                    hostsSplitView
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $showingPreferences) {
            preferencesSheet
        }
        .onAppear {
            if selectedMappingId == nil, let firstMapping = configStore.mappings.first {
                selectedMappingId = firstMapping.id
            }
            if selectedHostId == nil, let firstHost = configStore.hosts.first {
                selectedHostId = firstHost.id
            }
            if showDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private var preferencesSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("唤起方式与防刘海指南")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    showingPreferences = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // Method 1: Global Shortcut
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "keyboard.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 全局快捷键随时呼出 (推荐)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("在系统的任意软件中按下 ⌥ P (Option + P)，即可立即呼出或收起 PortBar，完全无视刘海遮挡。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Method 2: Spotlight / Launchpad
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2. 聚焦搜索 (Spotlight) / 启动台")
                            .font(.system(size: 13, weight: .semibold))
                        Text("随时按 ⌘ 空格 输入 PortBar 回车，秒级打开控制面板。若使用 Raycast 或 Alfred 同理。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Method 3: Keep in Dock toggle
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "dock.rectangle")
                        .font(.title2)
                        .foregroundColor(.green)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("3. 在 Dock 栏常驻显示图标", isOn: $showDockIcon)
                            .font(.system(size: 13, weight: .semibold))
                            .onChange(of: showDockIcon) {
                                if showDockIcon {
                                    NSApp.setActivationPolicy(.regular)
                                } else {
                                    NSApp.setActivationPolicy(.accessory)
                                }
                            }
                        Text("开启后，PortBar 图标将常驻在屏幕底部的 Dock 栏，点击即可唤起。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Method 4: Terminal command / URL Scheme
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("4. 终端命令与 URL Scheme")
                            .font(.system(size: 13, weight: .semibold))
                        Text("在终端中输入 open portbar:// 即可直接唤起窗口。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Method 5: Ice recommendation
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundColor(.indigo)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 终极解决 MacBook 刘海遮挡菜单栏神器")
                            .font(.system(size: 13, weight: .semibold))
                        Text("推荐搭配免费开源的 Ice (菜单栏管理工具)。它能够将超长菜单栏图标折叠收起或滚动显示，彻底解决被刘海吃掉的问题！")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("在 GitHub 查看开源工具 Ice ➔") {
                            if let url = URL(string: "https://github.com/jordanbaird/Ice") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 440)
    }

    // MARK: - Port Mappings Split View

    private var filteredMappings: [PortMapping] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configStore.mappings
        }
        let q = searchText.lowercased()
        return configStore.mappings.filter {
            $0.name.lowercased().contains(q) ||
            $0.forwardingSummary.lowercased().contains(q) ||
            $0.portRules.contains(where: { String($0.localPort).contains(q) || String($0.remotePort).contains(q) }) ||
            (configStore.host(for: $0.hostId)?.displayName.lowercased().contains(q) ?? false)
        }
    }

    private var mappingsSplitView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search Bar
                searchBar(placeholder: "搜索端口映射、端口、主机...")

                // Mapping List
                List(selection: $selectedMappingId) {
                    ForEach(filteredMappings) { mapping in
                        mappingRow(for: mapping)
                            .tag(mapping.id)
                            .contextMenu {
                                let status = tunnelManager.status(for: mapping.id)
                                Button(status.isConnected ? "停止转发" : "启动转发") {
                                    tunnelManager.toggleTunnel(for: mapping)
                                }
                                Divider()
                                Button("复制映射规则") {
                                    _ = configStore.duplicateMapping(id: mapping.id)
                                }
                                Button("删除映射", role: .destructive) {
                                    deleteMapping(mapping.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Bottom actions
                HStack(spacing: 12) {
                    Button(action: addNewMapping) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加新端口映射")

                    Button(action: deleteSelectedMapping) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedMappingId == nil)
                    .help("删除选中端口映射")

                    Spacer()

                    Menu {
                        Button("导出所有配置为 JSON...") { exportConfiguration() }
                        Button("从 JSON 导入配置...") { importConfiguration() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("导入/导出")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 270)
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            if let id = selectedMappingId, let mapping = configStore.mapping(for: id) {
                PortMappingDetailView(mapping: mapping)
                    .id(mapping.id)
            } else {
                emptyPlaceholder(
                    title: "未选择端口映射",
                    subtitle: "从左侧列表选择或点击 '+' 添加新端口映射",
                    buttonTitle: "新建端口映射",
                    action: addNewMapping
                )
            }
        }
    }

    private func mappingRow(for mapping: PortMapping) -> some View {
        let status = tunnelManager.status(for: mapping.id)
        let hostName = configStore.host(for: mapping.hostId)?.displayName ?? "未知主机"

        return HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor(status))
                .frame(width: 8, height: 8)

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

            if status.isConnected {
                Text("运行中")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(4)
            } else if status.isConnecting {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Hosts Split View

    private var filteredHosts: [SSHHost] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configStore.hosts
        }
        let q = searchText.lowercased()
        return configStore.hosts.filter {
            $0.name.lowercased().contains(q) ||
            $0.host.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    private var hostsSplitView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search Bar
                searchBar(placeholder: "搜索主机名、IP、用户名...")

                // Host List
                List(selection: $selectedHostId) {
                    ForEach(filteredHosts) { host in
                        hostRow(for: host)
                            .tag(host.id)
                            .contextMenu {
                                Button("删除主机", role: .destructive) {
                                    deleteHost(host.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Bottom actions
                HStack(spacing: 12) {
                    Button(action: addNewHost) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加新主机")

                    Button(action: deleteSelectedHost) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedHostId == nil)
                    .help("删除选中主机")

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 260)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 350)
        } detail: {
            if let id = selectedHostId, let host = configStore.host(for: id) {
                SSHHostDetailView(host: host)
                    .id(host.id)
            } else {
                emptyPlaceholder(
                    title: "未选择主机",
                    subtitle: "从左侧列表选择或点击 '+' 添加新远程主机",
                    buttonTitle: "新建主机",
                    action: addNewHost
                )
            }
        }
    }

    private func hostRow(for host: SSHHost) -> some View {
        let count = configStore.mappings.filter { $0.hostId == host.id }.count

        return HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(host.username)@\(host.host):\(host.port)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if count > 0 {
                Text("\(count) 个转发")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers & Actions

    private func searchBar(placeholder: String) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(8)
    }

    private func emptyPlaceholder(title: String, subtitle: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: selectedTab == .mappings ? "arrow.triangle.swap" : "server.rack")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.4))
            Text(title)
                .font(.title2)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusDotColor(_ status: TunnelState) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray.opacity(0.6)
        case .error: return .red
        }
    }

    private func addNewMapping() {
        let maxExisting = configStore.mappings.flatMap { $0.portRules.map { max($0.localPort, $0.remotePort) } }.max() ?? 8079
        let nextPort = maxExisting + 1
        let defaultHostId = configStore.hosts.first?.id ?? UUID()
        let newMapping = PortMapping(
            name: "端口映射 \(configStore.mappings.count + 1)",
            hostId: defaultHostId,
            portRules: [PortRule(localPort: nextPort, remotePort: nextPort)] // default localPort = remotePort!
        )
        configStore.addMapping(newMapping)
        selectedMappingId = newMapping.id
    }

    private func deleteSelectedMapping() {
        guard let id = selectedMappingId else { return }
        deleteMapping(id)
    }

    private func deleteMapping(_ id: UUID) {
        tunnelManager.stopTunnel(for: id)
        configStore.deleteMapping(id: id)
        if selectedMappingId == id {
            selectedMappingId = configStore.mappings.first?.id
        }
    }

    private func addNewHost() {
        let newHost = SSHHost(
            name: "主机 \(configStore.hosts.count + 1)",
            host: "127.0.0.1",
            port: 22,
            username: "root"
        )
        configStore.addHost(newHost)
        selectedHostId = newHost.id
    }

    private func deleteSelectedHost() {
        guard let id = selectedHostId else { return }
        deleteHost(id)
    }

    private func deleteHost(_ id: UUID) {
        configStore.deleteHost(id: id)
        if selectedHostId == id {
            selectedHostId = configStore.hosts.first?.id
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "portbar_config.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? configStore.exportConfig(to: url)
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? configStore.importConfig(from: url)
            selectedMappingId = configStore.mappings.first?.id
            selectedHostId = configStore.hosts.first?.id
        }
    }
}
