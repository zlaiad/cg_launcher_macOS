import SwiftUI
import AppKit
#if !STANDALONE_MODEL_CHECKS
import CGLauncherCore
#endif

@MainActor final class LauncherModel: ObservableObject {
    @Published var installation: Installation?
    @Published var regionID = 33
    @Published var username = ""
    @Published var password = ""
    @Published var savedAccounts: [SavedAccount] = []
    @Published var selectedSavedAccount = ""
    @Published var session: AuthenticatedSession?
    @Published var accountID = ""
    @Published var busy = false
    @Published var updating = false
    @Published var status = "正在检查游戏安装…"
    @Published var isError = false
    @Published var phase = "准备就绪"
    private var processes: [Process] = []
    private let accountStore: SavedAccountStore
    var region: GameRegion? { installation?.regions.first(where: { $0.id == regionID }) }
    var account: GameAccount? { session?.accounts.first(where: { $0.id == accountID }) }
    var canLaunch: Bool { !busy && account?.canLaunch == true }

    init(accountStore: SavedAccountStore = SavedAccountStore()) {
        self.accountStore = accountStore
        refresh()
        do {
            let list = try accountStore.load()
            savedAccounts = list.accounts.sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
            if let selected = list.selectedUsername ?? savedAccounts.first?.username {
                selectSavedAccount(selected)
            }
        } catch { status = error.localizedDescription; isError = true }
    }
    func refresh() {
        do {
            let found = try Installation.discover()
            installation = found
            if !found.regions.contains(where: { $0.id == regionID }) { regionID = found.regions[0].id }
            status = "准备就绪。"; isError = false
        } catch { status = error.localizedDescription; isError = true }
    }
    func clearSession() { session = nil; accountID = ""; phase = "准备就绪" }
    func selectSavedAccount(_ id: String) {
        guard !busy else { return }
        clearSession(); selectedSavedAccount = id; isError = false
        guard let saved = savedAccounts.first(where: { $0.id == id }) else {
            selectedSavedAccount = ""; username = ""; password = ""
            status = "登录成功后自动保存账号。"
            return
        }
        username = saved.username; password = saved.password
        if installation?.regions.contains(where: { $0.id == saved.regionID }) == true { regionID = saved.regionID }
        status = "已填入保存的账号。"
    }
    func editUsername(_ value: String) {
        guard !busy else { return }
        if value != username {
            clearSession()
            if !selectedSavedAccount.isEmpty { password = "" }
            selectedSavedAccount = ""
        }
        username = value
    }
    func editPassword(_ value: String) {
        guard !busy else { return }
        if value != password { clearSession() }
        password = value
    }
    private func networkConfiguration() throws -> WineNetworkConfiguration {
        guard let installation, let helper = Bundle.main.url(forResource: "cg_network", withExtension: "exe") else {
            throw LauncherError.message("请从构建后的“魔力宝贝启动器.app”运行。")
        }
        return WineNetworkConfiguration(installation: installation, helper: helper)
    }
    func probe() {
        guard !busy, let endpoint = region?.billing.first else { return }
        busy = true; isError = false; phase = "检测连接"; status = "正在检测服务器连接…"
        Task {
            do {
                let bridge = try networkConfiguration()
                try await Task.detached { try NativeAuthenticator.probe(endpoint: endpoint, bridge: bridge) }.value
                status = "服务器连接正常。"
            } catch { status = error.localizedDescription; isError = true }
            busy = false; phase = session == nil ? "准备就绪" : "已验证"
        }
    }
    func login() {
        guard !busy, let endpoint = region?.billing.first else { return }
        let user = username, secret = password, selectedRegion = regionID, store = accountStore
        clearSession(); busy = true; isError = false; phase = "验证账号"
        status = "正在验证账号…"
        Task {
            do {
                let bridge = try networkConfiguration()
                let result = try await Task.detached {
                    try RememberedLogin.authenticate(username: user, password: secret, regionID: selectedRegion, store: store) {
                        try NativeAuthenticator.authenticate(username: user, password: secret, endpoint: endpoint, bridge: bridge)
                    }
                }.value
                session = result.session
                if let saved = try? store.load() {
                    savedAccounts = saved.accounts.sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
                    selectedSavedAccount = savedAccounts.contains(where: { $0.username == user }) ? user : ""
                }
                let preferred = savedAccounts.first(where: { $0.username == user })?.gameAccountsByRegion[String(selectedRegion)]
                accountID = result.session.accounts.first(where: { $0.id == preferred && $0.canLaunch })?.id
                    ?? result.session.accounts.first(where: { $0.canLaunch })?.id ?? ""
                phase = "已验证"
                if let warning = result.storageWarning { status = warning; isError = true }
                else { status = result.session.accounts.isEmpty ? "认证成功并已保存，但官方没有返回可用的怀旧服游戏账号。" : "登录成功，账号已保存。" }
            } catch { status = error.localizedDescription; isError = true; phase = "验证未通过" }
            busy = false
        }
    }
    func launch() {
        guard canLaunch, let installation, let session, let account, let region else { return }
        guard let helper = Bundle.main.url(forResource: "cg_bridge", withExtension: "exe") else {
            status = "请从构建后的“魔力宝贝启动器.app”运行。"; isError = true; return
        }
        busy = true; isError = false; phase = "正在启动"; status = "正在交接认证并启动魔力宝贝…"
        Task { [self] in
            do {
                let process = try await Task.detached { try GameRunner.start(installation: installation, session: session, account: account, region: region, helper: helper) }.value
                processes.removeAll(where: { !$0.isRunning }); processes.append(process)
                status = "游戏已启动。"; phase = "游戏已启动"
                do {
                    try accountStore.rememberGameAccount(username: username, regionID: region.id, gameAccount: account.id)
                    savedAccounts = try accountStore.load().accounts.sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
                } catch {
                    status = "游戏已启动，但未能保存本次游戏账号选择。"; isError = true
                }
                process.terminationHandler = { [weak self] ended in
                    let code = ended.terminationStatus
                    Task { @MainActor in
                        guard let self, self.phase == "游戏已启动", !self.busy,
                              self.processes.allSatisfy({ !$0.isRunning }) else { return }
                        self.phase = "游戏已结束"
                        self.isError = code != 0
                        self.status = code == 0 ? "游戏进程已结束。再次进入请重新验证账号。" : "游戏进程已退出，请查看游戏窗口的错误提示。"
                    }
                }
                self.session = nil; accountID = ""
            } catch { status = error.localizedDescription; isError = true; phase = "启动未完成" }
            busy = false
        }
    }
    func updateGame() {
        guard !busy, let installation, let region else { return }
        clearSession(); busy = true; updating = true; isError = false
        phase = "更新游戏"; status = "正在检查游戏运行状态…"
        Task {
            do {
                status = "官方更新器将检查并下载更新，请等待完成。"
                try await Task.detached { try GameUpdater.run(installation: installation, region: region) }.value
                refresh()
                phase = "更新完成"; status = "游戏检查与更新已完成，可以登录。"
            } catch {
                phase = "更新未完成"; status = error.localizedDescription; isError = true
            }
            updating = false; busy = false
        }
    }
    func openOfficial() {
        guard let installation else { return }
        let process = Process()
        process.executableURL = installation.wine
        process.arguments = installation.wineArguments(executable: installation.launcher)
        process.environment = installation.wineEnvironment()
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); processes.append(process) }
        catch { status = error.localizedDescription; isError = true }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.colorScheme) private var colorScheme
    private let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.47, green: 0.78, blue: 0.71) : Color(red: 0.16, green: 0.46, blue: 0.43)
    }

    var body: some View {
        VStack(spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 20) {
                accountFields
                Divider().opacity(0.6)
                regionFields
                actions
            }
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.045)))
            .shadow(color: .black.opacity(0.035), radius: 12, y: 4)
            status
            footer
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
        .frame(width: 464)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit()
                    .frame(width: 60, height: 60).accessibilityLabel("魔力宝贝图标")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("魔力宝贝").font(.system(size: 24, weight: .semibold))
                Text("怀旧服").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.phase)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.isError ? Color.orange : accent)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background((model.isError ? Color.orange : accent).opacity(0.08), in: Capsule())
        }
    }

    private var accountFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("易玩通账号").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.selectSavedAccount("") } label: {
                    Label("添加账号", systemImage: "plus")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                    .disabled(model.busy).accessibilityIdentifier("addAccountButton")
            }
            if !model.savedAccounts.isEmpty {
                Picker("已保存的账号", selection: Binding(get: { model.selectedSavedAccount }, set: model.selectSavedAccount)) {
                    Text("新账号").tag("")
                    ForEach(model.savedAccounts) { saved in Text(saved.username).tag(saved.id) }
                }
                .labelsHidden().controlSize(.large).disabled(model.busy)
                .accessibilityIdentifier("savedAccountPicker")
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "person").frame(width: 16).foregroundStyle(.secondary)
                    TextField("通行证账号", text: Binding(get: { model.username }, set: model.editUsername))
                        .textContentType(.username).accessibilityIdentifier("usernameField")
                }.padding(13)
                Divider().padding(.leading, 41)
                HStack(spacing: 12) {
                    Image(systemName: "lock").frame(width: 16).foregroundStyle(.secondary)
                    SecureField("密码", text: Binding(get: { model.password }, set: model.editPassword))
                        .textContentType(.password).accessibilityIdentifier("passwordField")
                        .onSubmit { model.login() }
                }.padding(13)
            }
            .textFieldStyle(.plain).font(.system(size: 13)).disabled(model.busy)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
        }
    }

    private var regionFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("游戏大区") {
                Picker("游戏大区", selection: $model.regionID) {
                    ForEach(model.installation?.regions ?? []) { region in Text(region.name).tag(region.id) }
                }.onChange(of: model.regionID) { _ in model.clearSession() }
            }
            if let session = model.session, !session.accounts.isEmpty {
                field("游戏账号") {
                    Picker("游戏账号", selection: $model.accountID) {
                        Text("请选择").tag("")
                        ForEach(session.accounts) { account in
                            Text(account.canLaunch ? account.id : "\(account.id) · \(account.statusText)").tag(account.id)
                        }
                    }.accessibilityIdentifier("gameAccountPicker")
                }
            }
        }.disabled(model.busy)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content().labelsHidden().controlSize(.large)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.session != nil {
                Button("重新登录", action: model.login)
                    .buttonStyle(.bordered).controlSize(.large).disabled(model.busy)
            }
            Button(action: { model.session == nil ? model.login() : model.launch() }) {
                HStack(spacing: 8) {
                    Text(model.session == nil ? "登录" : "启动游戏")
                    Image(systemName: model.session == nil ? "arrow.right" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }.frame(maxWidth: .infinity).frame(height: 26)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.busy || model.installation == nil ||
                (model.session == nil ? (model.username.isEmpty || model.password.isEmpty) : !model.canLaunch))
            .accessibilityIdentifier("primaryActionButton")
        }
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else {
                Image(systemName: model.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(model.isError ? Color.orange : accent)
            }
            Text(model.status).font(.system(size: 11)).foregroundStyle(model.isError ? Color.orange : .secondary)
                .accessibilityIdentifier("launcherStatus")
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }.frame(minHeight: 30, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Button(action: model.updateGame) {
                Label(model.updating ? "正在更新…" : "更新游戏", systemImage: "arrow.down.circle")
            }.buttonStyle(.plain).foregroundStyle(accent)
                .disabled(model.busy || model.installation == nil)
                .accessibilityIdentifier("updateGameButton")
                .help("手动调用官方更新器检查并下载游戏更新")
            Spacer()
            Menu {
                Button("检测服务器", action: model.probe)
                Button("打开官方登录器", action: model.openOfficial)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            .disabled(model.busy || model.installation == nil).help("更多")
        }.font(.system(size: 12))
    }
}

@MainActor final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    var showLauncher: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Cmd+W destroys the SwiftUI window. Open the scene by ID instead of
        // searching NSApplication.windows for a window that no longer exists.
        showLauncher?()
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    let appDelegate: LauncherAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LauncherView(model: model)
            .onAppear {
                // Keep the scene action at application scope so Dock/Finder
                // reopening still works after this view has been closed.
                appDelegate.showLauncher = { openWindow(id: CGLauncherApp.mainWindowID) }
            }
    }
}

struct CGLauncherApp: App {
    static let mainWindowID = "launcher"
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate
    // Account edits, authentication and child-process ownership outlive windows.
    @StateObject private var model = LauncherModel()
    var body: some Scene {
        Window("魔力宝贝启动器", id: Self.mainWindowID) {
            LauncherRootView(model: model, appDelegate: appDelegate)
        }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
