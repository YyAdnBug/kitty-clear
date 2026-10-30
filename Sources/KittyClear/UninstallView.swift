import SwiftUI

/// One row of `mo uninstall --list`.
struct AppItem: Decodable, Identifiable {
    let name, source, path, size: String
    var id: String { path }
    var bytes: Double { parseSize(size) }

    /// What to call the app when asking mo to uninstall it: the name of its folder, which mo matches
    /// whole. (The list's own `uninstall_name` is the cask's name for a Homebrew app. mo does not find
    /// "postgres-app" among the app names, and of a name it cannot find whole it takes every app whose
    /// name contains it.)
    var term: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// The other apps that answer to this one's name. mo takes the first app whose name or folder name
    /// is the one it is given, so with a namesake around it cannot be told which of them is meant.
    func namesakes(among apps: [AppItem]) -> [AppItem] {
        apps.filter { $0.id != id && ($0.name.lowercased() == term.lowercased() || $0.term.lowercased() == term.lowercased()) }
    }
}

/// What `mo uninstall --dry-run` says it would remove, app by app. Its report looks like this:
///
///     Files to be removed:
///     ◎ AppCleaner , 8.6MB
///       ✓ /Applications/AppCleaner.app , 8.4MB
///       ◎ System: /Library/LaunchDaemons/x.plist , 4KB
///       ◎ Review only: /Library/Preferences/y.plist
///     ➤ Remove 1 app, 8.6MB …
struct UninstallPreview {
    struct File: Identifiable {
        enum Kind { case own, system, reviewOnly }
        let id: Int
        let path: String // as mo shows it, with the home folder as ~
        let size: String // empty when mo could not measure it
        var kind: Kind
        /// The path in full, where mo wrote `~` for the home folder.
        var fullPath: String { path.hasPrefix("~/") ? Mole.home + path.dropFirst() : path }
        /// Left in one of the system's folders, and of a kind that may be moved out on request.
        var isOffered: Bool { kind != .own && SystemLeftovers.isOffered(fullPath) }
        /// Why it is still there after the uninstall, in Chinese; nil for what went as planned.
        var kept: String?
    }

    struct App: Identifiable {
        let id: Int
        let name: String
        let size: String
        var files: [File] = []
        var notes: [String] = []
    }

    private(set) var apps: [App] = []
    private var files = 0
    /// The app bundles mo would remove, as full paths: each app's rows start with its own.
    var bundles: [String] {
        apps.compactMap { app in
            app.files.first { $0.kind == .own && $0.path.lowercased().hasSuffix(".app") }
                .map { $0.path.hasPrefix("~/") ? Mole.home + $0.path.dropFirst() : $0.path }
        }
    }

    /// How many things stay where they are: what lies in the system's own folders, which mo lists and
    /// never removes.
    var left: Int { apps.reduce(0) { $0 + $1.files.filter { $0.kind != .own }.count } }

    /// Writes down what became of the system files that were asked to go: in the Trash now (nil), or
    /// why not.
    mutating func record(_ outcome: [String: String?]) {
        for app in apps.indices {
            for file in apps[app].files.indices {
                guard let result = outcome[apps[app].files[file].fullPath] else { continue }
                if let reason = result { apps[app].files[file].kept = reason } else { apps[app].files[file].kind = .own }
            }
        }
    }

    /// True when mo matched exactly the apps that were ticked, no other and no more.
    func covers(_ wanted: [AppItem]) -> Bool { apps.count == wanted.count && Set(bundles) == Set(wanted.map(\.path)) }

    /// mo says so under an app when it left its files alone ("Shared leftovers kept (other copies unchecked)").
    func keepsLeftovers(ofAppNamed name: String) -> Bool { apps.first { $0.name == name }?.notes.contains { $0.contains("kept") } ?? false }

    /// How many things go to the Trash: the rows that are not just pointed out, left to an administrator,
    /// or reported as still there.
    var moved: Int { apps.reduce(0) { $0 + $1.files.filter { $0.kind == .own && $0.kept == nil }.count } }

    /// After its list and the confirmation, a real run names what it could not take ("◎ macOS denied
    /// access: ~/Library/Containers/x"). Marks those rows. False when it names something that is not a
    /// row here (mo sums up a whole family as "3 paths"): then this list cannot be trusted to say what went.
    mutating func markKept(in log: [String]) -> Bool {
        let reasons = [
            "Could not remove": "没能移走", "macOS denied access": "macOS 不允许，要先给完全磁盘访问权限", "Kept (protected by Mole)": "受保护，没有动",
            "Kept (app may be active)": "应用可能还在用，没有动", "Kept (agent ownership unverified; review the plist)": "不确定是不是它的，没有动",
            "Kept (selected app path exists again; select the app again)": "应用又出现了，没有动", "Kept (shared with another installed app)": "和别的应用共用，没有动",
            "Kept (other copies of the app could not be checked)": "没法确认别处还有没有这个应用，没有动",
        ]
        var complete = true
        for line in log.drop(while: { !$0.hasPrefix("➤") }) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("◎ "), let reason = reasons.first(where: { row.dropFirst(2).hasPrefix($0.key + ": ") }) else { continue }
            let path = String(row.dropFirst(2 + reason.key.count + 2))
            var found = false
            for app in apps.indices {
                for file in apps[app].files.indices where apps[app].files[file].path == path {
                    apps[app].files[file].kept = reason.value
                    found = true
                }
            }
            complete = complete && found
        }
        return complete
    }

    /// Adds what `Stragglers` found to the app called `name`, as rows like mo's own.
    mutating func add(_ found: [Stragglers.Item], toAppNamed name: String) {
        guard !found.isEmpty else { return }
        let index = apps.firstIndex { $0.name == name } ?? apps.count
        if index == apps.count { apps.append(App(id: index, name: name, size: "")) }
        for item in found {
            apps[index].files.append(File(id: files, path: AISessions.shortened(item.path), size: "\(item.bytes)B", kind: .own))
            files += 1
        }
    }

    init(log: [String]) {
        /// "path , 8.4MB" → ("path", "8.4MB"); mo leaves the size out when it has none.
        func split(_ text: String) -> (String, String) {
            guard let cut = text.range(of: " , ", options: .backwards) else { return (text, "") }
            return (String(text[..<cut.lowerBound]), String(text[cut.upperBound...]))
        }
        var started = false
        for line in log {
            if line.contains("Files to be removed:") { started = true; continue }
            guard started else { continue }
            if line.hasPrefix("➤") { break } // the confirmation prompt ends the list
            if line.hasPrefix("◎ "), line.contains(" , ") {
                let (name, size) = split(String(line.dropFirst(2)))
                apps.append(App(id: apps.count, name: name.replacing(" [Brew]", with: ""), size: size))
                continue
            }
            guard !apps.isEmpty, line.hasPrefix("  ") else { continue }
            let row = line.trimmingCharacters(in: .whitespaces)
            let kinds: [(prefix: String, kind: File.Kind)] = [("✓ ", .own), ("◎ System: ", .system), ("◎ Review only: ", .reviewOnly)]
            if let match = kinds.first(where: { row.hasPrefix($0.prefix) }) {
                let (path, size) = split(String(row.dropFirst(match.prefix.count)))
                apps[apps.count - 1].files.append(File(id: files, path: path, size: size, kind: match.kind))
                files += 1
            } else if row.hasPrefix("◎ ") {
                apps[apps.count - 1].notes.append(String(row.dropFirst(2)))
            }
        }
    }
}

/// What an app leaves in two places Mole's search does not reach: the cache and temporary folders that
/// macOS keeps per user under /var/folders, and the app's list of recent documents, whose file is named
/// by the bundle identifier in lower case (Mole looks for the identifier as written, and so misses the
/// list of "com.liguangming.Shadowrocket").
enum Stragglers {
    typealias Item = (path: String, bytes: Int64)

    /// /private/var/folders/…/C/ and …/T/, where macOS says where they are.
    static let userFolders: [String] = [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/var/") ? "/private" + path : path // the form Mole's protection rules are written in
    }

    /// Where an app with this identifier would have left something. The identifier becomes part of
    /// paths that get removed, so only a plain reverse-DNS name will do, and never one of Apple's.
    static func candidates(bundleID id: String, home: String = Mole.home, userFolders: [String] = userFolders) -> [String] {
        guard id.wholeMatch(of: #/[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+/#) != nil, !id.lowercased().hasPrefix("com.apple.") else { return [] }
        let recents = home + "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/"
        // An identifier that is lower case already is one Mole finds the list of by itself.
        return userFolders.map { $0 + id } + (id == id.lowercased() ? [] : ["sfl2", "sfl3", "sfl4"].map { recents + id.lowercased() + "." + $0 })
    }

    /// The paths among these that Mole's own rules do not protect (licence stores, the folders of
    /// security agents), or nil when Mole cannot be asked.
    static func unprotected(_ paths: [String]) -> [String]? {
        let quoted = paths.map { "'" + $0.replacing("'", with: #"'\''"#) + "'" }.joined(separator: " ")
        let free = try? Mole.ask("lib/core/app_protection.sh", #"""
            declare -f should_protect_path > /dev/null || exit 1
            for p in \#(quoted); do should_protect_path "$p" || printf '%s\n' "$p"; done
            """#)
        return free?.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// True while another copy of the app is installed: what is named after the identifier is that
    /// copy's too (its cache, its list of recent documents). `path` is the copy being uninstalled.
    static func hasOtherCopy(bundleID: String, besides path: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { copy in
            copy.path != path && !copy.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: copy.path)
        }
    }

    /// The candidates that exist and are not protected, with their sizes. Nothing counts as found when
    /// Mole cannot be asked, or while another copy of the app is around. What Mole's `log` names is left
    /// to Mole: since 1.65 it finds the /var/folders ones itself and keeps them as personal data.
    static func find(bundleID: String, appPath: String, besides log: [String]) async -> [Item] {
        await Task.detached {
            guard !bundleID.isEmpty, !hasOtherCopy(bundleID: bundleID, besides: appPath) else { return [] }
            let present = candidates(bundleID: bundleID).filter { path in
                FileManager.default.fileExists(atPath: path)
                    && !log.contains { $0.contains(path.replacing(#/^\/private/#, with: "")) || $0.contains(AISessions.shortened(path)) }
            }
            guard !present.isEmpty else { return [] }
            return (unprotected(present) ?? []).map { ($0, AISessions.diskSize(of: URL(fileURLWithPath: $0))) }
        }.value
    }

    /// Moves what `find` finds to the Trash and returns what went.
    static func trash(bundleID: String, appPath: String, besides log: [String]) async -> [Item] {
        await find(bundleID: bundleID, appPath: appPath, besides: log).filter { (try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0.path), resultingItemURL: nil)) != nil }
    }
}

/// What an uninstalled app left in the system's own folders. Mole lists these and never removes them.
/// Here they can be ticked, and the ticked ones are moved out with administrator rights: into a folder
/// of this app's first, from where the app itself puts them in the Trash, so that they can be looked at
/// and put back. Nothing is deleted.
enum SystemLeftovers {
    /// Where such a file has to lie to be offered at all: the places apps keep their own support files,
    /// settings, logs, helpers and install records. Not extensions, frameworks or plug-ins, which other
    /// software may be using.
    static let places = [
        "/Library/Application Support/", "/Library/Caches/", "/Library/Logs/", "/Library/Preferences/", "/Library/LaunchAgents/",
        "/Library/LaunchDaemons/", "/Library/PrivilegedHelperTools/", "/Library/Receipts/", "/private/var/db/receipts/",
    ]

    static func isOffered(_ path: String) -> Bool {
        places.contains { path.hasPrefix($0) && path.count > $0.count } && !path.contains("//") && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// Run as root: $1 the user's id, $2 the folder to move things into, $3 a folder that stands in for
    /// the disk's root when this is tried out (empty otherwise), then the paths. It decides for itself
    /// again what it will touch, from where each path really leads, and says what it did line by line.
    static let script = #"""
        uid="$1"; staging="$2"; prefix="$3"; shift 3
        [ -d "$staging" ] || exit 1
        for path in "$@"; do
            name=$(/usr/bin/basename "$path")
            dir=$(cd "$(/usr/bin/dirname "$path")" 2> /dev/null && /bin/pwd -P) || { echo "GONE $path"; continue; }
            real="$dir/$name"
            case "$name" in . | ..) echo "REFUSED $path"; continue ;; esac
            case "$real" in
                "$prefix/Library/Application Support/"?* | "$prefix/Library/Caches/"?* | "$prefix/Library/Logs/"?* | "$prefix/Library/Preferences/"?*) ;;
                "$prefix/Library/LaunchAgents/"?* | "$prefix/Library/LaunchDaemons/"?* | "$prefix/Library/PrivilegedHelperTools/"?*) ;;
                "$prefix/Library/Receipts/"?* | "$prefix/private/var/db/receipts/"?*) ;;
                *) echo "REFUSED $path"; continue ;;
            esac
            [ -e "$real" ] || [ -L "$real" ] || { echo "GONE $path"; continue; }
            if [ -z "$prefix" ]; then
                case "$real" in
                    /Library/LaunchDaemons/*.plist) domain=system ;;
                    /Library/LaunchAgents/*.plist) domain="gui/$uid" ;;
                    *) domain="" ;;
                esac
                if [ -n "$domain" ]; then
                    label=$(/usr/bin/plutil -extract Label raw -o - "$real" 2> /dev/null)
                    case "$label" in "" | */*) ;; *) /bin/launchctl bootout "$domain/$label" 2> /dev/null ;; esac
                fi
            fi
            target="$staging/$name"; n=1
            while [ -e "$target" ] || [ -L "$target" ]; do n=$((n + 1)); target="$staging/$n $name"; done
            if /bin/mv -n "$real" "$target" 2> /dev/null && { [ -e "$target" ] || [ -L "$target" ]; }; then
                /usr/sbin/chown -R -P "$uid" "$target" 2> /dev/null
                echo "MOVED $path"; echo "AS $target"
            else
                echo "FAILED $path"
            fi
        done
        exit 0
        """#

    /// What the script said, path by path: where a moved thing is now, or the word it gave instead.
    static func outcomes(of report: String) -> [String: (moved: String?, word: String)] {
        var result: [String: (moved: String?, word: String)] = [:]
        var last: String?
        for line in report.split(whereSeparator: \.isNewline).map(String.init) { // `do shell script` hands lines back with returns
            guard let space = line.firstIndex(of: " ") else { continue }
            let (word, rest) = (String(line[..<space]), String(line[line.index(after: space)...]))
            if word == "AS", let last { result[last]?.moved = rest } else { result[rest] = (nil, word); last = word == "MOVED" ? rest : nil }
        }
        return result
    }

    /// Moves `paths` to the Trash, asking for an administrator's password once. For each path: nil when
    /// it is in the Trash now, else why it is not.
    static func remove(_ paths: [String]) async -> [String: String?] {
        var answer: [String: String?] = Dictionary(uniqueKeysWithValues: paths.map { ($0, "不在可以处理的系统目录里，没有动") })
        let offered = paths.filter(isOffered)
        guard let free = await Task.detached(operation: { Stragglers.unprotected(offered) }).value else { return answer }
        for path in offered where !free.contains(path) { answer[path] = "受 Mole 的规则保护，没有动" }
        guard !free.isEmpty, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return answer }
        let staging = support.appending(path: "KittyClear/system-leftovers/\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else { return answer }
        let reason = "Kitty Clear 要把勾选的 \(free.count) 项系统级残留移到废纸篓。"
        let asked = await runTool("/usr/bin/osascript", ["-e", BatteryCareModel.rootRequest, script, reason, "\(getuid())", staging.path, ""] + free)
        let said = outcomes(of: asked.output)
        for path in free {
            guard asked.status == 0, let outcome = said[path] else {
                answer[path] = asked.output.contains("-128") ? "没有得到管理员批准，没有动" : "没能移走"
                continue
            }
            switch outcome {
            case (let moved?, _):
                // Out of the system's folder and the user's own now: the Trash is the app's to put it in.
                let trashed = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: moved), resultingItemURL: nil)) != nil
                answer[path] = trashed ? nil : "已移出系统目录，但没能放进废纸篓，现在在 \(AISessions.shortened(staging.path))"
            case (nil, "GONE"): answer[path] = "已经不在了"
            case (nil, "REFUSED"): answer[path] = "不在可以处理的系统目录里，没有动"
            default: answer[path] = "没能移走"
            }
        }
        rmdir(staging.path) // goes only when empty: whatever did not reach the Trash is still in it
        return answer
    }
}

struct UninstallView: View {
    /// What the card is showing, in the order an uninstall goes: the app list, the search for what the
    /// selected apps leave behind, what it found (nothing is removed before this has been seen and
    /// agreed to), the uninstall itself, and what it took away (mo's own output when it did not go well).
    private enum Phase {
        case list, inspecting, details(UninstallPreview), running(UninstallPreview?), finished(UninstallPreview?)
    }

    let runner: Runner
    @State private var apps: [AppItem]?
    @State private var error: String?
    /// Why an uninstall was not started.
    @State private var refusal: String?
    /// The system-level leftovers ticked to go along, by full path. None to begin with.
    @State private var ticked: Set<String> = []
    @State private var selection: Set<AppItem.ID> = []
    @State private var search = ""
    @State private var phase = Phase.list

    private var selected: [AppItem] { (apps ?? []).filter { selection.contains($0.id) } }

    var body: some View {
        Stage(size: .full, title: "卸载", subtitle: "应用和它留下的文件一起移到废纸篓", mood: mood) {
            switch phase {
            case .list:
                if let apps {
                    list(apps)
                } else if let error {
                    Hero(title: "读不到应用列表", text: error) {
                        Button("重试") { Task { await load() } }.buttonStyle(.heroQuiet)
                    }
                } else {
                    Waiting(text: "正在查看装了哪些应用…")
                }
            case .inspecting:
                VStack(spacing: 0) {
                    header("正在找它们留下的文件…", busy: true) {
                        Button("取消", action: runner.stop).buttonStyle(.quiet)
                    }
                    Waiting(text: selected.map(\.name).joined(separator: "、"))
                }
            case .details(let preview):
                VStack(spacing: 0) {
                    header("卸载这 \(preview.apps.count) 个应用，会把下面 \(preview.moved + ticked.count) 项移到废纸篓") {
                        Button("返回") { phase = .list }.buttonStyle(.quiet)
                        Button("确认卸载") { uninstall(preview) }.buttonStyle(.primary)
                    }
                    Leftovers(preview: preview, ticked: $ticked)
                }
            case .running(let agreed):
                VStack(spacing: 0) {
                    header("正在卸载…", busy: true) {
                        Button("停止", action: runner.stop).buttonStyle(.quiet)
                    }
                    // The list that was agreed to stays up. Coming back to the page mid-run there is none:
                    // then it is what mo itself lists before it takes anything.
                    let found = agreed ?? UninstallPreview(log: runner.lines.map(\.text))
                    if found.apps.isEmpty { Waiting(text: "正在卸载…") } else { Leftovers(preview: found, ticked: nil) }
                }
            case .finished(let result):
                VStack(spacing: 0) {
                    header(result.map { "已卸载 \($0.apps.count) 个应用，连同残留共 \($0.moved) 项移到了废纸篓" + ($0.left > 0 ? "；\($0.left) 项系统级文件留在原处" : "") } ?? "卸载结束") {
                        Button("回到应用列表") { phase = .list }.buttonStyle(.primary)
                    }
                    if let result { Leftovers(preview: result, ticked: nil) } else { LogView(lines: runner.lines) }
                }
            }
        }
        .alert("没有卸载", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
        } message: {
            Text(refusal ?? "")
        }
        .task {
            if runner.isRunning { phase = .running(nil) } // came back to the page while an uninstall is going
            await load()
        }
    }

    private var mood: Kitten.Mood {
        switch phase {
        case .list: apps == nil && error == nil ? .searching : .calm
        case .inspecting: .searching
        case .running: .wiping
        case .details: .calm
        case .finished(let result): result == nil ? .calm : .happy
        }
    }

    private func list(_ apps: [AppItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(text: $search, prompt: "搜索 \(apps.count) 个应用")
                Spacer()
                if !selected.isEmpty {
                    Text("已选 \(selected.count) 个，\(Int64(selected.reduce(0) { $0 + $1.bytes }).formatted(byteFormat))")
                        .font(Theme.text(13)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                }
                Button("卸载…", action: inspect).buttonStyle(.primary)
                    .disabled(selected.isEmpty || runner.isRunning)
                    .help("先找出它们留下的文件，列出来给你确认")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rule()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown(apps)) { app in
                        Toggle(isOn: binding(for: app.id)) { AppRow(app: app) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .toggleStyle(CheckToggleStyle())
        }
    }

    /// The strip at the top of the card: what is going on, and what can be done about it.
    private func header(_ text: String, busy: Bool = false, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                Text(text).font(Theme.text(13, .medium))
                Spacer()
                actions()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rule()
        }
    }

    private func shown(_ apps: [AppItem]) -> [AppItem] {
        apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.bytes > $1.bytes }
    }

    private func binding(for id: AppItem.ID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
    }

    private func load() async {
        error = nil
        do {
            apps = try await Mole.json(["uninstall", "--list"])
        } catch is CancellationError {
        } catch {
            self.error = Mole.describe(error)
        }
    }

    // The real run answers Mole's "Enter confirm, ESC cancel" with "y": the app asks on a page of its
    // own, with the list of what would go. A preview asks nothing.

    /// Has mo work out, without removing anything, what uninstalling the selected apps would take along.
    private func inspect() {
        let wanted = selected
        if let twin = wanted.first(where: { !$0.namesakes(among: apps ?? []).isEmpty }) {
            refusal = "还有一个应用也叫“\(twin.term)”。引擎只按名字找应用，分不清要卸载的是哪一个，所以这里不动它。\n可以在访达里把不要的那个移到废纸篓。"
            return
        }
        phase = .inspecting
        ticked = []
        let targets = wanted.map { (name: $0.name, path: $0.path, id: Bundle(path: $0.path)?.bundleIdentifier ?? "") }
        runner.start(["uninstall", "--dry-run"] + wanted.map(\.term)) { succeeded in
            let log = runner.lines.map(\.text)
            let found = UninstallPreview(log: log)
            guard succeeded, !found.apps.isEmpty else {
                phase = runner.wasStopped ? .list : .finished(nil) // show mo's output when it could not say
                return
            }
            // The real run finds the apps by the same names in the same way: what it would take is settled here.
            guard found.covers(wanted) else {
                refusal = "引擎按名字找到的应用和勾选的不一样：它会卸载 \(found.apps.map(\.name).joined(separator: "、"))。为了不卸错，没有继续。"
                phase = .list
                return
            }
            Task {
                var preview = found
                for target in targets where !preview.keepsLeftovers(ofAppNamed: target.name) {
                    preview.add(await Stragglers.find(bundleID: target.id, appPath: target.path, besides: log), toAppNamed: target.name)
                }
                phase = .details(preview)
            }
        }
    }

    private func uninstall(_ agreed: UninstallPreview) {
        let wanted = selected
        guard agreed.covers(wanted) else { // the list that was agreed to is not for what is ticked now
            phase = .list
            return
        }
        phase = .running(agreed)
        // The identifiers have to be read now: afterwards the apps are in the Trash.
        let targets = selected.map { (name: $0.name, path: $0.path, id: Bundle(path: $0.path)?.bundleIdentifier ?? "") }
        runner.start(["uninstall"] + selected.map(\.term), answering: (Mole.uninstallQuestion, "y")) { succeeded in
            let log = runner.lines.map(\.text)
            selection = []
            Task {
                var result = UninstallPreview(log: log)
                let accounted = result.markKept(in: log)
                // An app that is still there was not uninstalled, and keeps what belongs to it.
                for target in targets where !FileManager.default.fileExists(atPath: target.path) && !result.keepsLeftovers(ofAppNamed: target.name) {
                    result.add(await Stragglers.trash(bundleID: target.id, appPath: target.path, besides: log), toAppNamed: target.name)
                }
                // What was ticked in the system's folders goes last, and only for the apps that are gone.
                // It is what the run itself lists that counts, not the earlier look.
                let gone = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.name))
                let chosen = result.apps.filter { gone.contains($0.name) }.flatMap(\.files).filter { $0.isOffered && ticked.contains($0.fullPath) }.map(\.fullPath)
                if !chosen.isEmpty { result.record(await SystemLeftovers.remove(chosen)) }
                ticked = []
                // mo's own words when something did not go: they say what and why.
                phase = .finished(succeeded && accounted && result.covers(wanted) && !log.contains { $0.contains("Failed:") } ? result : nil)
                await load()
            }
        }
    }
}

private struct AppRow: View {
    let app: AppItem

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 30, height: 30)
            Text(app.name).font(Theme.text(13, .medium)).lineLimit(1)
            if app.source != "App" {
                Text(app.source).font(Theme.text(11, .medium)).foregroundStyle(Theme.shine)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.blueLine.opacity(0.45), in: Capsule())
            }
            Spacer()
            Text(zhSize(app.size)).font(Theme.text(13)).foregroundStyle(Theme.inkSoft).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

/// Each app with everything mo would take along: its own files, the ones that need an administrator,
/// and the ones mo only points out.
private struct Leftovers: View {
    let preview: UninstallPreview
    /// Where the choice of system-level files is kept while it can still be made: before the uninstall.
    let ticked: Binding<Set<String>>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if ticked != nil, preview.apps.contains(where: { $0.files.contains(where: \.isOffered) }) {
                    Text("带勾选框的几项在系统目录里，默认不动。勾上的会在卸载之后要一次管理员密码，再一起移到废纸篓。")
                        .font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
                        .padding(.top, 14)
                }
                ForEach(preview.apps) { app in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(app.name).font(Theme.text(14, .semibold))
                            Spacer()
                            Text("\(app.files.count) 项，\(zhSize(app.size))")
                                .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        ForEach(app.notes, id: \.self) { note in
                            Text(zh(note)).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).padding(.bottom, 4)
                        }
                        ForEach(app.files) { file in
                            HStack(spacing: 8) {
                                if let ticked, file.isOffered {
                                    Toggle("", isOn: Binding(
                                        get: { ticked.wrappedValue.contains(file.fullPath) },
                                        set: { if $0 { ticked.wrappedValue.insert(file.fullPath) } else { ticked.wrappedValue.remove(file.fullPath) } }))
                                        .toggleStyle(CheckToggleStyle())
                                        .labelsHidden()
                                        .accessibilityLabel("一起移走 \(file.path)")
                                }
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                if let tag = file.kept ?? (ticked != nil && file.isOffered ? "系统目录，勾选后一起移走" : tag(for: file.kind)) {
                                    Text(tag).font(Theme.text(11, .medium)).foregroundStyle(Theme.shine)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Theme.blueLine.opacity(0.45), in: Capsule())
                                        .fixedSize()
                                }
                                Spacer()
                                Text(zhSize(file.size)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                                // What stays behind stays findable: in the Finder it can be looked at and, with
                                // the Finder's own asking for a password, removed by hand.
                                if file.kind != .own || file.kept != nil {
                                    Button {
                                        let path = file.path.hasPrefix("~/") ? Mole.home + file.path.dropFirst() : file.path
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    } label: {
                                        Image(systemName: "magnifyingglass.circle").font(.system(size: 15)).foregroundStyle(Theme.inkSoft)
                                    }
                                    .buttonStyle(.plain)
                                    .help("在访达中显示")
                                    .accessibilityLabel("在访达中显示 \(file.path)")
                                }
                            }
                            .font(Theme.text(13))
                            .padding(.leading, 14)
                            .padding(.vertical, 4)
                            .help(file.path)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func tag(for kind: UninstallPreview.File.Kind) -> String? {
        switch kind {
        case .own: nil
        case .system: "需要管理员密码"
        case .reviewOnly: "系统级文件，不会自动删"
        }
    }
}
