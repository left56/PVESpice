import SwiftUI

// MARK: - Navigation

enum PVENavigation: Hashable {
    case vmList(UUID)
    case remote(UUID, PVEVirtualMachineRow)
}

enum PVEEditorRoute: Identifiable {
    case add
    case edit(UUID)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let uuid): return "edit-\(uuid.uuidString)"
        }
    }
}

// MARK: - Root

struct PVERootView: View {
    @StateObject private var store = PVEServerStore()
    @State private var path = NavigationPath()
    @State private var editorRoute: PVEEditorRoute?

    var body: some View {
        NavigationStack(path: $path) {
            PVEServerListView(path: $path, editorRoute: $editorRoute)
                .navigationDestination(for: PVENavigation.self) { nav in
                    switch nav {
                    case .vmList(let serverID):
                        PVEVMListView(path: $path, serverID: serverID)
                    case .remote(let serverID, let vm):
                        RemoteSessionView(serverID: serverID, vm: vm)
                    }
                }
        }
        .environmentObject(store)
        .sheet(item: $editorRoute) { route in
            // sheet 内视图在部分系统上不会稳定继承外层 .environmentObject，显式传入 store 避免崩溃
            PVEConnectionEditorView(route: route, store: store) {
                editorRoute = nil
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

// MARK: - PVE 列表（首屏）

struct PVEServerListView: View {
    @Binding var path: NavigationPath
    @Binding var editorRoute: PVEEditorRoute?
    @EnvironmentObject private var store: PVEServerStore

    var body: some View {
        Group {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加 PVE", systemImage: "server.rack")
                } description: {
                    Text("点击右上角「添加 PVE」，输入名称与 API 地址并完成验证。")
                } actions: {
                    Button("添加 PVE") {
                        editorRoute = .add
                    }
                    .keyboardShortcut("n", modifiers: [.command])
                }
            } else {
                List {
                    ForEach(store.servers) { rec in
                        HStack(alignment: .center, spacing: 12) {
                            NavigationLink(value: PVENavigation.vmList(rec.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rec.displayName)
                                        .font(.headline)
                                    Text(rec.listSubtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if rec.acceptUntrustedTLS {
                                        Text("HTTPS：已跳过证书校验")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button("修改") {
                                editorRoute = .edit(rec.id)
                            }
                            .help("修改此 PVE 的连接信息")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("PVE 服务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorRoute = .add
                } label: {
                    Label("添加 PVE", systemImage: "plus")
                }
                .help("添加新的 Proxmox 服务")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

// MARK: - 添加 / 编辑 PVE

struct PVEConnectionEditorView: View {
    let route: PVEEditorRoute
    @ObservedObject var store: PVEServerStore
    var onDismiss: () -> Void

    @State private var displayName = ""
    @State private var baseURL = "https://"
    @State private var realm = "pam"
    @State private var username = ""
    @State private var password = ""
    @State private var acceptUntrustedTLS = false
    @State private var busy = false
    @State private var alertMessage: String?

    private var editingID: UUID? {
        if case .edit(let id) = route { return id }
        return nil
    }

    private var navigationTitle: String {
        switch route {
        case .add: return "添加 PVE"
        case .edit: return "修改 PVE"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("显示名称") {
                    TextField("例如：办公室集群", text: $displayName)
                }
                Section("连接") {
                    TextField("API 基址（https://host:8006）", text: $baseURL)
                        .textContentType(.URL)
                }
                Section {
                    Toggle("允许无效或主机名不匹配的 HTTPS 证书", isOn: $acceptUntrustedTLS)
                } footer: {
                    Text("适用于内网自签名证书、或用 IP 访问但证书 CN 为其它主机名等情况。仅对您确认可信的 Proxmox 主机开启。")
                }
                Section("认证") {
                    TextField("Realm", text: $realm)
                    TextField("用户名（不含 @realm）", text: $username)
                        .textContentType(.username)
                    SecureField(passwordFieldLabel, text: $password)
                        .textContentType(.password)
                }
                Section {
                    Button {
                        Task { await validateAndSave() }
                    } label: {
                        if busy {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在验证…")
                            }
                        } else {
                            Text("验证并保存")
                        }
                    }
                    .disabled(busy || !canSubmit)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDismiss() }
                        .disabled(busy)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear(perform: loadExistingIfNeeded)
        .alert("无法保存", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var passwordFieldLabel: String {
        switch route {
        case .add: return "密码"
        case .edit: return "密码（留空则保留原密码）"
        }
    }

    private var isAdd: Bool {
        if case .add = route { return true }
        return false
    }

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isAdd ? !password.isEmpty : true)
    }

    private func loadExistingIfNeeded() {
        guard case .edit(let id) = route, let rec = store.record(id: id) else { return }
        displayName = rec.displayName
        baseURL = rec.baseURL
        realm = rec.realm
        if rec.username.contains("@") {
            let parts = rec.username.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                username = String(parts[0])
                realm = String(parts[1])
            } else {
                username = rec.username
            }
        } else {
            username = rec.username
        }
        password = ""
        acceptUntrustedTLS = rec.acceptUntrustedTLS
    }

    private func effectivePassword() throws -> String {
        if case .edit = route, password.isEmpty {
            guard let id = editingID, let p = try store.password(for: id), !p.isEmpty else {
                throw ProxmoxClient.APIError.proxmoxError("请输入密码，或保留原密码需在钥匙串中已有记录。")
            }
            return p
        }
        guard !password.isEmpty else {
            throw ProxmoxClient.APIError.proxmoxError("请填写密码")
        }
        return password
    }

    @MainActor
    private func validateAndSave() async {
        busy = true
        defer { busy = false }
        let id = editingID ?? UUID()
        let shortUser = Self.stripRealmFromUsername(username.trimmingCharacters(in: .whitespacesAndNewlines))
        let rec = PVEServerRecord(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            realm: realm.trimmingCharacters(in: .whitespacesAndNewlines),
            username: shortUser,
            cachedVersion: nil,
            cachedAPIUsername: nil,
            acceptUntrustedTLS: acceptUntrustedTLS
        )
        let userAtRealm = rec.loginUserAtRealm
        do {
            let pass = try effectivePassword()
            let result = try await ProxmoxClient.loginAndFetchVersion(
                baseURLString: rec.baseURL,
                usernameAtRealm: userAtRealm,
                password: pass,
                acceptUntrustedTLS: acceptUntrustedTLS
            )
            var saved = rec
            saved.cachedVersion = result.version.displayString
            saved.cachedAPIUsername = result.session.apiUsername
            try store.upsert(saved, password: pass)
            onDismiss()
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private static func stripRealmFromUsername(_ raw: String) -> String {
        guard let i = raw.firstIndex(of: "@") else { return raw }
        return String(raw[..<i])
    }
}

// MARK: - SPICE 虚拟机列表

struct PVEVMListView: View {
    @Binding var path: NavigationPath
    let serverID: UUID

    @EnvironmentObject private var store: PVEServerStore
    @State private var rows: [PVEVirtualMachineRow] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("正在加载虚拟机…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                }
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("没有可用的 SPICE 虚拟机", systemImage: "display")
                } description: {
                    Text("当前仅列出显示为 QXL 的 QEMU 虚拟机（与常见 SPICE 配置一致）。可为虚拟机设置 QXL 显示后重试。")
                }
            } else {
                List(rows) { vm in
                    NavigationLink(value: PVENavigation.remote(serverID, vm)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(vm.name)
                                    .font(.headline)
                                Text("VMID \(vm.vmid) · 节点 \(vm.node)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(vm.powerStatusLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(vm.powerStatus.lowercased() == "running" ? .green : .secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(store.record(id: serverID)?.displayName ?? "虚拟机")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        guard let rec = store.record(id: serverID) else {
            errorMessage = "找不到该 PVE 记录"
            return
        }
        guard let pass = try? store.password(for: serverID), !pass.isEmpty else {
            errorMessage = "无法读取已保存的密码，请修改该 PVE 并重新保存。"
            return
        }
        do {
            let sessionPair = try await ProxmoxClient.loginAndFetchVersion(
                baseURLString: rec.baseURL,
                usernameAtRealm: rec.loginUserAtRealm,
                password: pass,
                acceptUntrustedTLS: rec.acceptUntrustedTLS
            )
            let vms = try await ProxmoxClient.listSpiceQemuVMs(session: sessionPair.session)
            rows = vms
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - 远程控制（SPICE）

struct RemoteSessionView: View {
    let serverID: UUID
    let vm: PVEVirtualMachineRow

    @EnvironmentObject private var store: PVEServerStore
    @StateObject private var spiceModel = RemoteSpiceSessionModel()
    @State private var bootstrapError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.name)
                        .font(.headline)
                    Text("VMID \(vm.vmid) · \(vm.node) · \(vm.powerStatusLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .connected = spiceModel.phase {
                    Text("已连接")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let bootstrapError {
                Text(bootstrapError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding()
            } else if vm.powerStatus.lowercased() != "running" {
                ContentUnavailableView {
                    Label("虚拟机未运行", systemImage: "pause.circle")
                } description: {
                    Text("请先在该 PVE 上启动虚拟机后再连接 SPICE。")
                }
            } else {
                ZStack(alignment: .top) {
                    SpiceSessionSurfaceView(model: spiceModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.9))
                    if let banner = spiceModel.qgaPasteBanner {
                        Text(banner)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 10)
                    }
                }
            }

            if case let .failed(msg) = spiceModel.phase {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .navigationTitle("远程控制")
        .task {
            await connectIfPossible()
        }
        .onDisappear {
            spiceModel.shutdown()
        }
    }

    @MainActor
    private func connectIfPossible() async {
        bootstrapError = nil
        guard vm.powerStatus.lowercased() == "running" else { return }
        guard let rec = store.record(id: serverID) else {
            bootstrapError = "找不到 PVE 配置"
            return
        }
        guard let pass = try? store.password(for: serverID), !pass.isEmpty else {
            bootstrapError = "无法读取密码，请在「修改 PVE」中重新保存。"
            return
        }
        await spiceModel.start(record: rec, password: pass, vm: vm)
    }
}

#if DEBUG
#Preview("Root") {
    PVERootView()
        .frame(width: 800, height: 560)
}
#endif
