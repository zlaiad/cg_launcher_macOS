import SwiftUI
import AppKit
import CGLauncherCore

@MainActor final class LauncherModel: ObservableObject {
    @Published var installation: Installation?
    @Published var regionID = 33
    @Published var username = ""
    @Published var password = ""
    @Published var session: AuthenticatedSession?
    @Published var accountID = ""
    @Published var busy = false
    @Published var status = "正在检查游戏安装…"
    @Published var isError = false
    @Published var phase = "准备就绪"
    private var processes: [Process] = []
    var region: GameRegion? { installation?.regions.first(where: { $0.id == regionID }) }
    var account: GameAccount? { session?.accounts.first(where: { $0.id == accountID }) }
    var canLaunch: Bool { !busy && account?.canLaunch == true }

    init() { refresh() }
    func refresh() {
        do {
            let found = try Installation.discover()
            installation = found
            if !found.regions.contains(where: { $0.id == regionID }) { regionID = found.regions[0].id }
            status = "已找到 CrossGate 容器和怀旧版客户端。"; isError = false
        } catch { status = error.localizedDescription; isError = true }
    }
    func clearSession() { session = nil; accountID = ""; phase = "准备就绪" }
    private func networkConfiguration() throws -> WineNetworkConfiguration {
        guard let installation, let helper = Bundle.main.url(forResource: "cg_network", withExtension: "exe") else {
            throw LauncherError.message("请从构建后的“魔力宝贝启动器.app”运行。")
        }
        return WineNetworkConfiguration(installation: installation, helper: helper)
    }
    func probe() {
        guard !busy, let endpoint = region?.billing.first else { return }
        busy = true; isError = false; phase = "检测连接"; status = "正在验证官方服务器的加密通道…"
        Task {
            do {
                let bridge = try networkConfiguration()
                try await Task.detached { try NativeAuthenticator.probe(endpoint: endpoint, bridge: bridge) }.value
                status = "官方服务器的握手与加密心跳均已通过。"
            } catch { status = error.localizedDescription; isError = true }
            busy = false; phase = session == nil ? "准备就绪" : "已验证"
        }
    }
    func login() {
        guard !busy, let endpoint = region?.billing.first else { return }
        let user = username, secret = password
        clearSession(); busy = true; isError = false; phase = "验证账号"
        status = "正在连接官方计费服务器并验证通行证…"
        Task {
            do {
                let bridge = try networkConfiguration()
                let result = try await Task.detached { try NativeAuthenticator.authenticate(username: user, password: secret, endpoint: endpoint, bridge: bridge) }.value
                session = result
                accountID = result.accounts.first(where: { $0.canLaunch })?.id ?? ""
                phase = "已验证"
                status = result.accounts.isEmpty ? "认证成功，但官方没有返回可用的怀旧服游戏账号。" : "官方认证成功，请选择游戏账号后启动。"
            } catch { status = error.localizedDescription; isError = true; phase = "验证未通过" }
            password = ""; busy = false
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
                status = "游戏进程已启动，请在游戏窗口继续。"; phase = "游戏已启动"
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
    @StateObject private var model = LauncherModel()
    private let accent = Color(red: 0.14, green: 0.43, blue: 0.47)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title3)
                    Text("CROSS GATE").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(2)
                }.foregroundStyle(Color(red: 0.88, green: 0.78, blue: 0.51))
                Spacer()
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 78, weight: .ultraLight)).foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 12) {
                    Text("魔力宝贝").font(.system(size: 34, weight: .semibold, design: .serif))
                    Text("再会，法兰城。").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                }
                Text("怀旧服 · macOS 原生启动器")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("官方账号认证", systemImage: "person.badge.key")
                    Label("CrossOver 游戏运行", systemImage: "desktopcomputer")
                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                Text("个人开发版本 0.1").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
            }
            .padding(32).frame(width: 290)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.22, blue: 0.27), Color(red: 0.07, green: 0.14, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录你的冒险").font(.system(size: 24, weight: .semibold))
                        Text("使用易玩通官方通行证").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.phase).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accent.opacity(0.09), in: Capsule()).foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("游戏大区").font(.system(size: 12, weight: .medium))
                    Picker("游戏大区", selection: $model.regionID) {
                        ForEach(model.installation?.regions ?? []) { region in Text(region.name).tag(region.id) }
                    }.labelsHidden().controlSize(.large).disabled(model.busy)
                    .onChange(of: model.regionID) { _ in model.clearSession() }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("易玩通通行证").font(.system(size: 12, weight: .medium))
                    TextField("官方通行证账号（PID）", text: $model.username)
                        .textContentType(.username).textFieldStyle(.roundedBorder).controlSize(.large)
                        .disabled(model.busy)
                        .onChange(of: model.username) { _ in if !model.busy { model.clearSession() } }
                    SecureField("通行证密码", text: $model.password)
                        .textContentType(.password).textFieldStyle(.roundedBorder).controlSize(.large)
                        .disabled(model.busy).onSubmit { model.login() }
                    Text("密码仅用于本次官方认证，不保存到本地。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let session = model.session, !session.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("游戏账号").font(.system(size: 12, weight: .medium))
                        Picker("游戏账号", selection: $model.accountID) {
                            Text("请选择游戏账号").tag("")
                            ForEach(session.accounts) { account in
                                Text("\(account.id) · \(account.statusText)").tag(account.id)
                            }
                        }.labelsHidden().controlSize(.large).disabled(model.busy)
                    }
                }
                HStack(spacing: 10) {
                    Button(action: model.login) {
                        Text(model.session == nil ? "验证官方账号" : "重新验证").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        .disabled(model.busy || model.username.isEmpty || model.password.isEmpty || model.installation == nil)
                    if model.session != nil {
                        Button(action: model.launch) { Label("启动游戏", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large).disabled(!model.canLaunch)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isError ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(model.isError ? .orange : accent) }
                    Text(model.status).font(.system(size: 12)).foregroundStyle(model.isError ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("launcherStatus")
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.frame(minHeight: 36, alignment: .top)
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Button("检测服务器", action: model.probe).disabled(model.busy || model.installation == nil)
                    Spacer()
                    Button("官方登录器 / 更新", action: model.openOfficial).disabled(model.busy || model.installation == nil)
                }.buttonStyle(.link).font(.system(size: 11))
                Text("游戏版本和更新请先在官方登录器中完成。").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(32).frame(width: 440)
        }.frame(minWidth: 730, minHeight: 610)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CGLauncherApp: App {
    var body: some Scene {
        WindowGroup("魔力宝贝启动器") { LauncherView() }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
