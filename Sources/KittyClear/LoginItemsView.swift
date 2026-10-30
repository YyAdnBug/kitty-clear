import SwiftUI

/// Something that starts by itself: an app macOS opens at login, or a job launchd runs in the background.
struct StartupItem: Identifiable {
    enum Kind {
        /// On the user's "Open at Login" list.
        case opened
        /// A launchd job of this user's (`~/Library/LaunchAgents`). The only kind of job that can be changed here.
        case mine
        /// A launchd job installed for the whole Mac (`/Library/LaunchAgents`, `/Library/LaunchDaemons`).
        case shared
    }

    let id: String // the job's file, or "login item: <name>"
    let kind: Kind
    let label: String // launchd's name for the job, or the login item's name
    /// What it runs. nil for a job file that does not say, which launchd cannot run either.
    let program: String?
    let disabled: Bool
    let running: Bool
    /// The program is named by its full path and is not there any more.
    let missing: Bool

    /// False for what is switched off and for what has nothing left to start.
    var starts: Bool { !disabled && !missing && (kind == .opened || program != nil) }

    /// The app the program lives in, when it lives in one.
    var app: URL? {
        guard let program else { return nil }
        if program.hasSuffix(".app") { return URL(fileURLWithPath: program) }
        return program.range(of: ".app/").map { URL(fileURLWithPath: program[..<$0.lowerBound] + ".app") }
    }

    var name: String {
        app.map { FileManager.default.displayName(atPath: $0.path) }.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? label
    }

    /// The line under the name: what is wrong with it, else the other half of what identifies it.
    var detail: String {
        if kind != .opened, program == nil { return "这个文件没有写明要运行什么" }
        if missing { return "程序已经不在了：\(program ?? "")" }
        return app != nil && kind != .opened ? label : AISessions.shortened(program ?? "")
    }
}

/// Reads what starts by itself and switches the user's own background jobs on and off.
// ponytail: jobs shared by the whole Mac are only listed; changing them needs administrator rights.
// Background items an app registers with macOS itself are not listed at all: only System Settings sees them.
enum StartupItems {
    private static let launchctl = "/bin/launchctl"
    /// launchd's name for the user's own session.
    private static let session = "gui/\(getuid())"

    /// Every launchd job file in the three places they are installed to.
    static func jobs() async -> [StartupItem] {
        let alive = running(in: await runTool(launchctl, ["list"]).output)
        let mine = switches(in: await runTool(launchctl, ["print-disabled", session]).output)
        let system = switches(in: await runTool(launchctl, ["print-disabled", "system"]).output)
        let places: [(folder: String, kind: StartupItem.Kind, switches: [String: Bool])] = [
            (Mole.home + "/Library/LaunchAgents", .mine, mine), ("/Library/LaunchAgents", .shared, mine), ("/Library/LaunchDaemons", .shared, system),
        ]
        return places.flatMap { place in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: place.folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "plist" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { job(at: $0, kind: place.kind, switches: place.switches, running: alive) }
        }
    }

    /// One job file. launchd's own switch (`launchctl disable`) wins over the file's `Disabled` key.
    static func job(at file: URL, kind: StartupItem.Kind, switches: [String: Bool], running: Set<String>) -> StartupItem {
        let job = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)) as? [String: Any] ?? [:]
        let label = job["Label"] as? String ?? file.deletingPathExtension().lastPathComponent
        let program = job["Program"] as? String ?? (job["ProgramArguments"] as? [String])?.first
        return StartupItem(id: file.path, kind: kind, label: label, program: program,
                           disabled: switches[label] ?? (job["Disabled"] as? Bool ?? false), running: running.contains(label),
                           missing: program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false)
    }

    /// `launchctl print-disabled` prints `"label" => disabled` or `=> enabled` for every job someone has switched.
    static func switches(in output: String) -> [String: Bool] {
        Dictionary(output.matches(of: #/"([^"]+)" => (enabled|disabled)/#).map { (String($0.1), $0.2 == "disabled") }) { $1 }
    }

    /// `launchctl list` prints `PID Status Label`, with `-` for a job that is loaded but not running.
    static func running(in listing: String) -> Set<String> {
        Set(listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t")
            return fields.count == 3 && Int(fields[0]) != nil ? String(fields[2]) : nil
        })
    }

    private static let listScript = """
        set out to ""
        tell application "System Events"
            repeat with entry in login items
                set place to ""
                try
                    set place to path of entry
                end try
                set out to out & (name of entry) & tab & place & linefeed
            end repeat
        end tell
        return out
        """

    /// The apps macOS opens at login. System Events is the one way to read that list, and macOS asks the
    /// user before letting an app talk to it. nil when the answer was no.
    static func loginItems() async -> [StartupItem]? {
        let answer = await runTool("/usr/bin/osascript", ["-e", listScript], mergingErrors: false)
        return answer.status == 0 ? loginItems(in: answer.output) : nil
    }

    /// One login item per line, name and path with a tab between.
    static func loginItems(in output: String) -> [StartupItem] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let path = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
            return StartupItem(id: "login item: \(name)", kind: .opened, label: name, program: path, disabled: false, running: false,
                               missing: path.map { !FileManager.default.fileExists(atPath: $0) } ?? false)
        }
    }

    /// Stops one of the user's jobs and keeps it from starting at login, or lets it start again and
    /// starts it. Returns what went wrong, or nil.
    /// A job is addressed as `gui/501/<label>`. With no label, or one with a slash in it, that address
    /// would name something else: the whole login session, at worst.
    static func isAddressable(_ label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty && !label.contains("/")
    }

    static func setDisabled(_ disabled: Bool, _ item: StartupItem) async -> String? {
        guard item.kind == .mine else { return "这一项不能在这里开关。" }
        guard isAddressable(item.label) else { return "这个启动项的名称（Label）不能用，这里不动它。" }
        let job = "\(session)/\(item.label)"
        if disabled {
            _ = await runTool(launchctl, ["bootout", job]) // fails when it was not loaded, which is the goal anyway
            return await runTool(launchctl, ["disable", job]).status == 0 ? nil : "launchctl 没能停用它。"
        }
        guard await runTool(launchctl, ["enable", job]).status == 0 else { return "launchctl 没能启用它。" }
        _ = await runTool(launchctl, ["bootstrap", session, item.id]) // fails when it is loaded already
        return nil
    }

    /// Takes a login item off the list, or stops one of the user's jobs and moves its file to the Trash.
    static func remove(_ item: StartupItem) async -> String? {
        switch item.kind {
        case .opened:
            let script = ["-e", "on run argv", "-e", "tell application \"System Events\" to delete login item (item 1 of argv)", "-e", "end run"]
            return await runTool("/usr/bin/osascript", script + [item.label]).status == 0 ? nil : "系统没有让 Kitty Clear 改登录项。"
        case .mine:
            guard isAddressable(item.label) else { return "这个启动项的名称（Label）不能用，这里不动它。可以在访达里处理它的文件。" }
            _ = await runTool(launchctl, ["bootout", "\(session)/\(item.label)"])
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.id), resultingItemURL: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .shared:
            return "这一项属于整台 Mac，需要管理员权限。"
        }
    }
}

struct LoginItemsView: View {
    /// The "Open at Login" list is only read once the user has asked for it, because the first read
    /// makes macOS put up a permission dialog.
    private enum Opened { case unread, reading, refused, read([StartupItem]) }

    @State private var jobs: [StartupItem]?
    @State private var opened = Opened.unread
    @AppStorage("readsLoginItems") private var readsLoginItems = false
    @State private var busy: String?
    @State private var doomed: StartupItem?
    @State private var problem: String?
    @State private var reload = 0

    var body: some View {
        Stage(size: .full, title: "登录项", subtitle: "开机或登录时自己启动的程序", mood: jobs == nil ? .searching : .calm) {
            if let jobs {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\((jobs + openedItems).filter(\.starts).count)").font(Theme.display(34)).monospacedDigit()
                        Text("项会自己启动").font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                        Spacer()
                        IconButton(title: "重新读取", systemImage: "arrow.clockwise") { reload += 1 }
                        Button("系统设置…") { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }.buttonStyle(.quiet)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    Rule()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            section("登录时打开") { openedRows }
                            let mine = jobs.filter { $0.kind == .mine }
                            section("后台启动，只属于你的账号") {
                                if mine.isEmpty { note("没有。") }
                                ForEach(mine) { job in
                                    StartupRow(item: job) {
                                        if busy == job.id {
                                            ProgressView().controlSize(.small).frame(width: 60)
                                        } else {
                                            Button(job.disabled ? "启用" : "停用") { toggle(job) }.buttonStyle(.quiet).disabled(busy != nil)
                                        }
                                        IconButton(title: "移到废纸篓", systemImage: "trash") { doomed = job }.disabled(busy != nil)
                                    }
                                }
                            }
                            let shared = jobs.filter { $0.kind == .shared }
                            if !shared.isEmpty {
                                section("后台启动，整台 Mac 共用") {
                                    note("改动它们需要管理员权限，这里只能查看。")
                                    ForEach(shared) { job in StartupRow(item: job) {} }
                                }
                            }
                            note("应用向 macOS 登记的后台项目不在这里，只有“系统设置 > 通用 > 登录项”能开关。")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    }
                }
            } else {
                Waiting(text: "正在看有什么会自己启动…")
            }
        }
        .confirmationDialog(doomed?.kind == .opened ? "不再在登录时打开“\(doomed?.name ?? "")”？" : "把“\(doomed?.name ?? "")”移到废纸篓？",
                            isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } }), presenting: doomed) { item in
            Button(item.kind == .opened ? "移除" : "移到废纸篓", role: .destructive) { remove(item) }
        } message: { item in
            Text(item.kind == .opened ? "只是从登录项里拿掉，应用本身不动。" : "会先让它停下，再把它的启动文件移到废纸篓。放回原处后要重新登录才会再启动。")
        }
        .alert("登录项", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
        } message: {
            Text(problem ?? "")
        }
        .task(id: reload) {
            jobs = await StartupItems.jobs()
            if readsLoginItems { await readOpened() }
        }
    }

    private var openedItems: [StartupItem] {
        if case .read(let items) = opened { items } else { [] }
    }

    @ViewBuilder private var openedRows: some View {
        switch opened {
        case .unread:
            HStack {
                note("读这份名单要经过 macOS 的“系统事件”，第一次读时系统会弹窗问你是否允许。")
                Spacer()
                Button("读取") { Task { await readOpened() } }.buttonStyle(.quiet)
            }
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note("正在读取。如果系统弹了窗，先回答它。")
            }
        case .refused:
            HStack {
                note("macOS 没有让 Kitty Clear 读这份名单。可以在“隐私与安全性 > 自动化”里允许它控制“System Events”。")
                Spacer()
                Button("去允许") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }.buttonStyle(.quiet)
                Button("再试") { Task { await readOpened() } }.buttonStyle(.quiet)
            }
        case .read(let items):
            if items.isEmpty { note("没有。") }
            ForEach(items) { item in
                StartupRow(item: item) {
                    IconButton(title: "从登录项里移除", systemImage: "minus") { doomed = item }.disabled(busy != nil)
                }
            }
        }
    }

    private func readOpened() async {
        opened = .reading
        if let items = await StartupItems.loginItems() {
            opened = .read(items)
            readsLoginItems = true // allowed once, so later visits read it straight away
        } else {
            opened = .refused
        }
    }

    private func toggle(_ job: StartupItem) {
        busy = job.id
        Task {
            problem = await StartupItems.setDisabled(!job.disabled, job)
            jobs = await StartupItems.jobs()
            busy = nil
        }
    }

    private func remove(_ item: StartupItem) {
        busy = item.id
        Task {
            problem = await StartupItems.remove(item)
            if item.kind == .opened { await readOpened() } else { jobs = await StartupItems.jobs() }
            busy = nil
        }
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.text(13, .medium)).foregroundStyle(Theme.inkSoft)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
    }
}

private struct StartupRow<Actions: View>: View {
    let item: StartupItem
    @ViewBuilder let actions: Actions

    private var broken: Bool { !item.starts && !item.disabled }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let app = item.app, !item.missing {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                } else {
                    Image(systemName: broken ? "questionmark" : "gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(broken ? Theme.blush : Theme.shine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background((broken ? Theme.pinkLine : Theme.blueLine).opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Theme.text(13, .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(Theme.text(11)).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.middle)
            }
            .opacity(item.disabled ? 0.5 : 1)
            Spacer()
            Text(item.disabled ? "已停用" : item.running ? "运行中" : "").font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
            actions
        }
        .padding(.vertical, 2)
        .help(item.kind == .opened ? item.program ?? "" : item.id)
        .contextMenu {
            if let file = item.kind == .opened ? item.program : item.id {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
            }
        }
    }
}
