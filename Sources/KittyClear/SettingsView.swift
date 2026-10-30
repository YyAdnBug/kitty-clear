import Hardware
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// What macOS has allowed the app to do.
enum Permissions {
    /// Whether the app may read every folder ("Full Disk Access"). macOS has no call that says; a file
    /// only that permission opens is the test. Trying does not make macOS ask the user anything.
    /// (macOS 27 has no per-user TCC.db any more, which is what this used to open.)
    static var fullDiskAccess: Bool {
        ["/Library/Application Support/com.apple.TCC/TCC.db", Mole.home + "/Library/Safari/Bookmarks.plist"]
            .contains { FileHandle(forReadingAtPath: $0) != nil }
    }
}

struct SettingsView: View {
    private enum Tab: String, CaseIterable { case general = "通用", menuBar = "菜单栏", cleaning = "清理", about = "关于" }

    let engine: EngineModel
    @State private var tab = Tab.general
    @State private var whitelist: Whitelist?
    @State private var draft = ""
    @State private var choosing = false
    @State private var showingBuiltIn = false
    @State private var confirmingReset = false
    /// The entry whose removal is being asked about.
    @State private var unprotecting: String?
    @State private var problem: String?
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage(MenuBarGauge.choice) private var reading = MenuBarGauge.Reading.cpu
    @AppStorage(MenuBarGauge.look) private var iconStyle = MenuBarGauge.Style.color
    @State private var launch = LaunchAtLogin.state
    @State private var launchProblem: String?
    @State private var removingHelper = false
    @AppStorage(PrivacyWatch.switchKey) private var privacyReminders = false
    @State private var mutedApps = PrivacyWatch.shared.muted
    @State private var fullDiskAccess = Permissions.fullDiskAccess
    private var care: BatteryCareModel { .shared }
    private var update: AppUpdate { .shared }

    var body: some View {
        Stage(size: .full, title: "设置", subtitle: "通用、菜单栏、清理和关于", mood: engine.isBusy ? .searching : .calm) {
            VStack(spacing: 0) {
                Segments(choices: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                    .padding(.vertical, 16)
                Rule()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .general: general
                        case .menuBar: menuBar
                        case .cleaning: cleaning
                        case .about: about
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        // The user comes back from System Settings with a different answer.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = Permissions.fullDiskAccess
            launch = LaunchAtLogin.state
        }
        .onChange(of: [menuBarOnly, menuBarIcon]) { AppDelegate.syncDockIcon() }
        .confirmationDialog("移除电池养护的助手？", isPresented: $removingHelper) {
            Button("移除", role: .destructive, action: care.removeHelper)
        } message: {
            Text("电池养护会关闭，充电恢复由 macOS 管理。移除时要输一次管理员密码。")
        }
        .task {
            // The helper looks at the battery every twenty seconds; keep the line under the switch honest.
            while !Task.isCancelled {
                care.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task {
            do {
                whitelist = try await Task.detached { try Whitelist() }.value
            } catch {
                problem = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .item]) { chosen in
            if case .success(let url) = chosen { change { try $0.add(url.path) } }
        }
        .confirmationDialog("不再保护这一条？", isPresented: Binding(get: { unprotecting != nil }, set: { if !$0 { unprotecting = nil } }), presenting: unprotecting) { entry in
            Button("不再保护", role: .destructive) { change { try $0.remove(entry) } }
        } message: { entry in
            Text("\(short(entry))\n之后的清理会照规则处理它，那里的内容可能被清掉。")
        }
        .confirmationDialog("恢复 Mole 的默认保护名单？", isPresented: $confirmingReset) {
            Button("恢复默认", role: .destructive) { change { try $0.reset() } }
        } message: {
            Text("你保存的名单会移到废纸篓。")
        }
        .alert("保护名单", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder private var general: some View {
        row("完全磁盘访问权限", "有了它，扫描和清理才进得去邮件、Safari 和各应用容器这些受保护的文件夹，磁盘分析里也能直接把它们移到废纸篓。") {
            if fullDiskAccess {
                Text("已授权").font(Theme.text(13, .semibold)).foregroundStyle(Theme.shine)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.blueLine.opacity(0.45), in: Capsule())
            } else {
                Button("去授权") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }.buttonStyle(.primary)
            }
        }
        line
        row("登录时自动启动", "随登录启动时不弹出主窗口，只留在菜单栏。之后要是挪动了这个应用，需要回来重新打开一次。") {
            Toggle("登录时自动启动", isOn: Binding(get: { launch == .enabled }, set: setLaunch)).toggleStyle(SwitchToggleStyle()).accessibilityLabel("登录时自动启动")
        }
        if launch == .requiresApproval {
            HStack {
                note("macOS 的登录项设置里把 Kitty Clear 关掉了，要在那里重新打开。", systemImage: "exclamationmark.circle.fill", tint: Theme.blush)
                Spacer()
                Button("打开系统设置", action: SMAppService.openSystemSettingsLoginItems).buttonStyle(.quiet)
            }
            .padding(.bottom, 14)
        }
        if let launchProblem {
            note("没能改动登录项：\(launchProblem)", systemImage: "exclamationmark.circle.fill", tint: Theme.blush).padding(.bottom, 14)
        }
        line
        row("电池养护", "把充电上限控制在 \(BatteryCare.limit)% 上下，减缓电池老化。\(care.status)") {
            Toggle("电池养护", isOn: Binding(get: { care.isOn }, set: care.set)).toggleStyle(SwitchToggleStyle()).accessibilityLabel("电池养护")
                .disabled(care.unsupported != nil || care.isBusy)
        }
        if care.isOn || care.helperInstalled {
            HStack(spacing: 8) {
                if care.mode == .limit { Button("这次充到 100%") { care.ask(for: .full) }.buttonStyle(.quiet) }
                if care.mode == .full { Button("恢复 \(BatteryCare.limit)% 上限") { care.ask(for: .limit) }.buttonStyle(.quiet) }
                Spacer()
                if care.helperInstalled { Button("移除助手…") { removingHelper = true }.buttonStyle(.quiet).disabled(care.isBusy) }
            }
            .padding(.bottom, 14)
        }
        if let problem = care.problem {
            note(problem, systemImage: "exclamationmark.circle.fill", tint: Theme.blush).padding(.bottom, 14)
        }
        line
        row("隐私提醒", "摄像头或麦克风一开始被使用就发一条通知，认得出是哪个应用在录音时会写上名字。通知里可以让某个应用以后不再提醒。") {
            Toggle("隐私提醒", isOn: Binding(get: { privacyReminders }, set: { privacyReminders = $0; PrivacyWatch.shared.setEnabled($0) }))
                .toggleStyle(SwitchToggleStyle()).accessibilityLabel("隐私提醒")
        }
        if privacyReminders, !PrivacyWatch.shared.mayNotify {
            HStack {
                note("macOS 没有允许 Kitty Clear 发通知，提醒发不出来。", systemImage: "exclamationmark.circle.fill", tint: Theme.blush)
                Spacer()
                Button("打开通知设置") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }.buttonStyle(.quiet)
            }
            .padding(.bottom, 14)
        }
        if !mutedApps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("不再提醒的应用").font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
                ForEach(mutedApps, id: \.self) { app in
                    HStack {
                        Text(app).font(Theme.text(13))
                        Spacer()
                        Button("恢复提醒") {
                            PrivacyWatch.shared.setMuted(app, false)
                            mutedApps = PrivacyWatch.shared.muted
                        }
                        .buttonStyle(.quiet)
                    }
                }
            }
            .padding(.bottom, 14)
        }
        line
        row("仅菜单栏模式", menuBarIcon ? "关掉窗口后不占程序坞，只留菜单栏的图标；窗口打开期间程序坞图标会回来。" : "要先在“菜单栏”里打开图标，不然关掉窗口就找不到 Kitty Clear 了。") {
            Toggle("仅菜单栏模式", isOn: $menuBarOnly).toggleStyle(SwitchToggleStyle()).accessibilityLabel("仅菜单栏模式").disabled(!menuBarIcon)
        }
    }

    @ViewBuilder private var menuBar: some View {
        row("在菜单栏显示图标", "点它可以看 CPU、显卡、内存、磁盘、网速、电池和占用最高的进程，还有摄像头和麦克风有没有在用。关掉主窗口后 Kitty Clear 还在运行，从这里能把窗口叫回来。") {
            Toggle("在菜单栏显示图标", isOn: $menuBarIcon).toggleStyle(SwitchToggleStyle()).accessibilityLabel("在菜单栏显示小猫图标")
        }
        line
        row("图标样式", "彩色是 Kitty Clear 的应用图标；单色是小猫探头的剪影，会跟着菜单栏的深浅变色。") {
            Segments(choices: MenuBarGauge.Style.allCases.map { ($0, $0.title) }, selection: $iconStyle).disabled(!menuBarIcon)
        }
        line
        row("图标旁边的数字", "直接读系统的计数器，每两秒更新一次，不另外启动进程。") {
            Menu(reading.title) {
                ForEach(MenuBarGauge.Reading.allCases) { choice in
                    Button(choice.title) { reading = choice }
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quiet)
            .fixedSize()
            .disabled(!menuBarIcon)
        }
    }

    @ViewBuilder private var cleaning: some View {
        row("清理引擎：Mole \(engine.version ?? "未知")", source + "。升级包从 Mole 的 GitHub 发布页下载，校验无误并通过兼容性检查后才会启用，否则继续用现在这一版。") {
            Button("检查更新", action: engine.upgrade).buttonStyle(.primary).disabled(engine.isBusy)
        }
        progress.padding(.bottom, engine.state == .idle ? 0 : 14)
        line
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("保护名单").font(Theme.text(14, .semibold))
                Text("列在这里的路径，清理时会跳过。保护一个文件夹，它里面的内容也一起保护。")
                    .font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
            }
            if let whitelist {
                protections(whitelist)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 14)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Kitty Clear \(AppUpdate.current)", "新版本从 Kitty Clear 的 GitHub 发布页下载，核对签名后替换现在这个应用并重新打开，权限和设置都保留。") {
                if case .available(let release) = update.state {
                    Button("升级到 \(release.version)", action: update.install).buttonStyle(.primary)
                } else {
                    Button("检查更新", action: update.check).buttonStyle(.quiet).disabled(update.isBusy)
                }
            }
            updateProgress.padding(.bottom, update.state == .idle ? 0 : 14)
            line
            row("基于 Mole", "清理、卸载、磁盘分析和状态数据都来自开源项目 Mole（GPL-3.0）。Kitty Clear 是独立的界面，不是 Mole 的官方应用。") {
                Link("Mole 的 GitHub 页面", destination: URL(string: "https://github.com/tw93/mole")!).buttonStyle(.quiet)
            }
        }
        // Opening 关于 is asking "is there a newer one?"; the answer is then one click away.
        .task { if update.state == .idle { update.check() } }
    }

    @ViewBuilder private var updateProgress: some View {
        switch update.state {
        case .idle:
            EmptyView()
        case .checking:
            note("正在查看最新版本…", busy: true)
        case .upToDate:
            note("已经是最新版本", systemImage: "checkmark.circle.fill")
        case .available(let release):
            HStack(spacing: 12) {
                note("有新版本 \(release.version)", systemImage: "arrow.down.circle.fill")
                Link("更新内容", destination: release.page).buttonStyle(.quiet)
            }
        case .installing(let release):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: update.progress ?? 0).tint(Theme.shine).frame(maxWidth: 320)
                Text(update.progress.map { $0 < 1 ? "正在下载 \(release.version) · \(Int($0 * 100))%" : "正在安装 \(release.version)，装好会自动重新打开" }
                     ?? "正在下载 \(release.version)…")
                    .font(Theme.text(13))
            }
        case .failed(let reason):
            note(reason, systemImage: "exclamationmark.circle.fill", tint: Theme.blush)
        }
    }

    /// One setting: what it is, what it does, and the control for it.
    private func row(_ title: String, _ detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.text(14, .semibold))
                Text(detail).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 14)
    }

    private var line: some View { Rule().opacity(0.55) }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    @ViewBuilder private func protections(_ list: Whitelist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.entries, id: \.self) { entry in
                HStack(spacing: 8) {
                    Text(short(entry)).font(Theme.text(13)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button {
                        unprotecting = entry
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.blush).frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("不再保护")
                    .accessibilityLabel("不再保护 \(short(entry))")
                }
                .padding(.vertical, 2)
            }
        }
        HStack(spacing: 8) {
            TextField("路径，可以用 * 代表任意内容", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.text(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.blueLine.opacity(0.35), in: Capsule())
                .onSubmit(addDraft)
            Button("添加", action: addDraft)
                .buttonStyle(.quiet)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("选择文件夹…") { choosing = true }.buttonStyle(.quiet)
        }
        Button {
            showingBuiltIn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showingBuiltIn ? 90 : 0))
                Text("另有 \(list.builtIn.count) 条 Mole 内置的保护，始终生效")
            }
            .font(Theme.text(12))
            .foregroundStyle(Theme.inkSoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showingBuiltIn {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(list.builtIn, id: \.self) { entry in
                    Text(short(entry)).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, 15)
        }
        HStack {
            Text(list.isSaved ? "这是你保存的名单。" : "现在用的是 Mole 的默认名单，改动后会保存成你自己的名单。")
                .font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
            Spacer()
            if list.isSaved {
                Button("恢复默认…") { confirmingReset = true }.buttonStyle(.quiet)
            }
        }
    }

    private func setLaunch(_ on: Bool) {
        launchProblem = LaunchAtLogin.set(on)
        launch = LaunchAtLogin.state
    }

    /// Applies an edit to the list and keeps the result, or says why it could not be saved.
    private func change(_ edit: (inout Whitelist) throws -> Void) {
        guard var list = whitelist else { return }
        do {
            try edit(&list)
            whitelist = list
        } catch {
            problem = error.localizedDescription
        }
    }

    private func addDraft() {
        var pattern = draft.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        if pattern.hasPrefix("~") { pattern = Mole.home + pattern.dropFirst() }
        let before = whitelist?.entries
        change { try $0.add(pattern) }
        if whitelist?.entries != before { draft = "" }
    }

    private func short(_ path: String) -> String {
        path.hasPrefix(Mole.home + "/") ? "~" + path.dropFirst(Mole.home.count) : path
    }

    /// Where the engine in use came from.
    private var source: String {
        guard let bundled = engine.bundledVersion else { return "本机安装的 Mole，这个应用里没有内置引擎" }
        return engine.version == bundled ? "应用内置的版本" : "已在应用内升级，内置的是 \(bundled)"
    }

    @ViewBuilder private var progress: some View {
        switch engine.state {
        case .idle:
            EmptyView()
        case .checking:
            note("正在查看最新版本…", busy: true)
        case .downloading(let version):
            note("正在下载 Mole \(version)…", busy: true)
        case .verifying(let version):
            note("正在检查 Mole \(version) 和应用是否兼容，大约半分钟…", busy: true)
        case .upToDate:
            note("已经是最新版本", systemImage: "checkmark.circle.fill")
        case .upgraded(let version):
            note("已升级到 Mole \(version)", systemImage: "checkmark.circle.fill")
        case .failed(let reason):
            note(reason, systemImage: "exclamationmark.circle.fill", tint: Theme.blush)
        }
    }

    private func note(_ text: String, busy: Bool = false, systemImage: String = "", tint: Color = Theme.shine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Text(text).font(Theme.text(13)).textSelection(.enabled)
        }
    }
}
