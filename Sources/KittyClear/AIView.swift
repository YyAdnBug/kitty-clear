import SwiftUI

/// One conversation with an AI coding tool that has not been touched for a while.
struct AISession: Identifiable {
    enum Tool: String { case claude = "Claude Code", codex = "Codex" }

    let id: String // path of its transcript
    let tool: Tool
    let project: String // the folder it was held in
    let title: String
    let modified: Date
    /// Claude Code: everything that belongs to it, the transcript last, so that a removal that stopped
    /// half way shows up again on the next search. Codex: its transcript, then those of its sub-agents.
    let files: [URL]
    let size: Int64
    /// Codex only: the ids `codex delete` takes, in the order of `files`.
    var threads: [String] = []
}

/// Finds old Claude Code conversations. Mole leaves `~/.claude` alone on purpose, because memory, plugins
/// and settings live there too, so this looks only at what is known to be one conversation's own files.
// ponytail: Claude Code and Codex. Cursor keeps its conversations inside one SQLite file and has no
// command to delete one; add it when there is a safe way to take a conversation out of that file.
enum AISessions {
    static let root = URL(fileURLWithPath: Mole.home).appending(path: ".claude")

    /// Both tools' old conversations. Codex's are only offered when its own `delete` command is there to remove them.
    static func all(olderThan days: Int) -> [AISession] {
        let codex = CodexSessions.scan(olderThan: days)
        return scan(olderThan: days) + (codex.isEmpty || CodexSessions.canDelete ? codex : [])
    }

    /// True when a conversation was written to after it was listed: it has been picked up again, and is
    /// not the old one that was offered for removal any more.
    static func usedSince(listing session: AISession) -> Bool {
        let transcripts = session.tool == .codex ? session.files.map(\.path) : [session.id]
        return transcripts.contains { file in
            ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date).map { $0 > session.modified.addingTimeInterval(1) } ?? false
        }
    }

    /// Removes one conversation the way its tool allows. Returns what went wrong, or nil.
    static func remove(_ session: AISession) -> String? {
        if usedSince(listing: session) { return "“\(session.title)”列出来之后又被用过，所以没有动。" }
        switch session.tool {
        case .codex:
            return CodexSessions.delete(session) ? nil : "codex delete 没有删掉它"
        case .claude:
            do {
                for file in session.files { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// Claude Code keeps a folder per project under `projects`; a conversation is `<id>.jsonl` there, plus
    /// `<id>/` (tool output, sub-agents), markers named `<id>.…`, and its edit backups in `file-history/<id>`.
    /// A project's `memory` folder and anything not named after a conversation id are never returned.
    static func scan(olderThan days: Int, in root: URL = root) -> [AISession] {
        let fm = FileManager.default
        var found: [AISession] = []
        for project in (try? fm.contentsOfDirectory(at: root.appending(path: "projects"), includingPropertiesForKeys: nil)) ?? [] {
            let entries = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for transcript in entries where transcript.pathExtension == "jsonl" {
                let id = transcript.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil,
                      let modified = try? transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified.timeIntervalSinceNow < -Double(days) * 86400
                else { continue }
                var files = entries.filter { $0 != transcript && ($0.lastPathComponent == id || $0.lastPathComponent.hasPrefix(id + ".")) }
                let backups = root.appending(path: "file-history/\(id)")
                if fm.fileExists(atPath: backups.path) { files.append(backups) }
                files.append(transcript)
                let about = describe(transcript)
                found.append(AISession(
                    id: transcript.path, tool: .claude, project: shortened(about.folder ?? project.lastPathComponent),
                    title: about.title ?? "没有标题的会话", modified: modified, files: files, size: files.reduce(0) { $0 + diskSize(of: $1) }))
            }
        }
        return found
    }

    /// The project folder and the title a transcript records about itself: the name the user gave it,
    /// else the generated one, else the first thing they asked. Only its two ends are read, because a
    /// transcript can run to hundreds of megabytes.
    static func describe(_ transcript: URL) -> (folder: String?, title: String?) {
        guard let file = try? FileHandle(forReadingFrom: transcript) else { return (nil, nil) }
        defer { try? file.close() }
        let head = 262_144 as UInt64
        var text = (try? file.read(upToCount: Int(head))) ?? Data()
        if let end = try? file.seekToEnd(), end > head {
            try? file.seek(toOffset: max(head, end - 65_536))
            text.append(0x0A)
            text.append((try? file.readToEnd()) ?? Data())
        }
        var folder, named, generated, asked: String?
        // A line cut off by the reads above does not parse and is skipped.
        for line in text.split(separator: 0x0A) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            folder = folder ?? entry["cwd"] as? String
            named = entry["customTitle"] as? String ?? named
            generated = entry["aiTitle"] as? String ?? entry["summary"] as? String ?? generated
            guard asked == nil, entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
                  entry["isSidechain"] as? Bool != true, let content = (entry["message"] as? [String: Any])?["content"]
            else { continue }
            asked = request(in: content as? String ?? (content as? [[String: Any]])?.lazy.compactMap { $0["text"] as? String }.first)
        }
        return (folder, named ?? generated ?? asked)
    }

    /// What the user typed, as a one-line title. The notes a tool wraps around a request (tags, its
    /// instruction files) are not something the user asked.
    static func request(in text: String?) -> String? {
        guard let said = text?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty,
              !said.hasPrefix("<"), !said.hasPrefix("# AGENTS.md") else { return nil }
        return String(said.prefix(80)).replacing("\n", with: " ")
    }

    static func shortened(_ folder: String) -> String {
        folder.hasPrefix(Mole.home + "/") ? "~" + folder.dropFirst(Mole.home.count) : folder
    }

    /// Bytes a file or a whole folder takes up. Symbolic links are not followed.
    static func diskSize(of item: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        func bytes(_ file: URL) -> Int64 {
            let values = try? file.resourceValues(forKeys: keys)
            return values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0
        }
        let inside = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys))?.allObjects as? [URL] ?? []
        return inside.reduce(bytes(item)) { $0 + bytes($1) }
    }
}

/// Finds old Codex conversations. Codex lists its conversations from a database of its own, so taking
/// the files away would leave dead entries behind. They are handed to `codex delete` instead, which
/// clears the files and the database together, for good: nothing goes to the Trash.
enum CodexSessions {
    static let root = URL(fileURLWithPath: Mole.home).appending(path: ".codex")

    /// True when there is a `codex` on this Mac and it knows `delete`.
    static let canDelete = codex(["delete", "--help"])

    private struct Rollout {
        let file: URL
        let id, folder: String
        /// Set for a conversation Codex started for itself: a sub-agent, or a review of what it was about to do.
        let isAgent: Bool
        let parent, asked: String?
        let modified: Date
        let size: Int64
    }

    /// Codex writes each conversation to `rollout-<time>-<id>.jsonl`, under `sessions/<date>` or, once
    /// archived, `archived_sessions`. One row is the user's conversation with the sub-agent conversations
    /// it started, and is as old as the newest of them.
    static func scan(olderThan days: Int, in root: URL = root) -> [AISession] {
        let fm = FileManager.default
        let live = fm.enumerator(at: root.appending(path: "sessions"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let archived = (try? fm.contentsOfDirectory(at: root.appending(path: "archived_sessions"), includingPropertiesForKeys: nil)) ?? []
        var rollouts: [String: Rollout] = [:]
        for file in live + archived where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
            if let rollout = read(file) { rollouts[rollout.id] = rollout }
        }
        /// The conversation a sub-agent's one belongs to, as long as that is still on disk.
        func owner(of id: String) -> String {
            var id = id
            for _ in 0..<8 { // sub-agents can start sub-agents; the limit is only there against a loop
                guard let parent = rollouts[id]?.parent, rollouts[parent] != nil else { break }
                id = parent
            }
            return id
        }
        let titles = names(in: root)
        return Dictionary(grouping: rollouts.values) { owner(of: $0.id) }.compactMap { id, group in
            guard let own = rollouts[id], let newest = group.map(\.modified).max(), newest.timeIntervalSinceNow < -Double(days) * 86400
            else { return nil }
            let all = [own] + group.filter { $0.id != id }
            return AISession(
                id: own.file.path, tool: .codex, project: AISessions.shortened(own.folder),
                title: own.isAgent ? "子任务留下的会话" : titles[id] ?? own.asked ?? "没有标题的会话",
                modified: newest, files: all.map(\.file), size: all.reduce(0) { $0 + $1.size }, threads: all.map(\.id))
        }
    }

    /// What a rollout says about itself in its first line, and the first thing the user asked in it.
    private static func read(_ file: URL) -> Rollout? {
        let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
        guard UUID(uuidString: id) != nil, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let entries = ((try? handle.read(upToCount: 262_144)) ?? Data()).split(separator: 0x0A)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let first = entries.first, first["type"] as? String == "session_meta", let meta = first["payload"] as? [String: Any],
              meta["id"] as? String == id,
              let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        let source = meta["source"] as? [String: Any] // the user's own conversations name their source in a word
        let spawner = ((source?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
        let isAgent = source != nil || meta["thread_source"] as? String == "subagent"
        let asked = entries.lazy.compactMap { entry -> String? in
            guard let payload = entry["payload"] as? [String: Any], payload["role"] as? String == "user" else { return nil }
            return (payload["content"] as? [[String: Any]])?.lazy.compactMap { AISessions.request(in: $0["text"] as? String) }.first
        }.first
        return Rollout(file: file, id: id, folder: meta["cwd"] as? String ?? "", isAgent: isAgent,
                       parent: isAgent ? spawner ?? meta["forked_from_id"] as? String : nil, asked: asked,
                       modified: modified, size: AISessions.diskSize(of: file))
    }

    /// The names Codex gave its conversations: `session_index.jsonl` gets a line for every (re)naming.
    private static func names(in root: URL) -> [String: String] {
        var names: [String: String] = [:]
        for line in ((try? Data(contentsOf: root.appending(path: "session_index.jsonl"))) ?? Data()).split(separator: 0x0A) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = entry["id"] as? String else { continue }
            names[id] = entry["thread_name"] as? String
        }
        return names
    }

    /// Hands a conversation, then whichever of its sub-agents' are still there, to `codex delete`. Codex
    /// takes the sub-agents it has on record along with their parent. True when no transcript is left.
    /// `home` stands in for `~/.codex` when the self-check tries this on copies.
    static func delete(_ session: AISession, home: String? = nil) -> Bool {
        let fm = FileManager.default
        for (thread, file) in zip(session.threads, session.files) where fm.fileExists(atPath: file.path) {
            codex(["delete", "--force", thread], home: home)
        }
        return !session.files.contains { fm.fileExists(atPath: $0.path) }
    }

    /// Runs the user's own `codex`. An app's PATH does not reach an npm or nvm install, so this goes
    /// through a login shell, which also finds the `node` that `codex` needs.
    // ponytail: assumes zsh, the macOS default, is where PATH gets set up; ask $SHELL if that stops holding.
    @discardableResult
    static func codex(_ args: [String], home: String? = nil) -> Bool {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "codex \"$@\"", "zsh"] + args
        if let home { shell.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": home]) { $1 } }
        shell.currentDirectoryURL = URL(fileURLWithPath: Mole.home)
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return false }
        shell.waitUntilExit()
        return shell.terminationStatus == 0
    }
}

struct AIView: View {
    private struct Group: Identifiable {
        let tool: AISession.Tool
        let project: String
        let sessions: [AISession]
        var id: String { "\(tool.rawValue) \(project)" }
    }

    @State private var sessions: [AISession]?
    @State private var days = 30
    @State private var selection: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var confirming = false
    @State private var removing = false
    @State private var cleared = false
    @State private var failure: String?
    @State private var reload = 0

    private var selected: [AISession] { (sessions ?? []).filter { selection.contains($0.id) } }
    private var selectedCodex: Int { selected.filter { $0.tool == .codex }.count }

    /// One group per tool and project: those with the most to give back first, and in each the biggest
    /// conversations first.
    private var groups: [Group] {
        Dictionary(grouping: sessions ?? []) { "\($0.tool.rawValue) \($0.project)" }.values
            .map { Group(tool: $0[0].tool, project: $0[0].project, sessions: $0.sorted { $0.size > $1.size }) }
            .sorted { size(of: $0.sessions) > size(of: $1.sessions) }
    }

    var body: some View {
        Stage(size: sessions?.isEmpty == true ? .hero : .full, title: "AI 工具", subtitle: "Claude Code 和 Codex 很久没动过的会话。缓存和旧版本在“清理”里",
              mood: sessions == nil ? .searching : removing ? .wiping : cleared && sessions?.isEmpty == true ? .happy : .calm) {
            if removing {
                Waiting(text: "正在清走 \(selected.count) 个会话…")
            } else if let sessions {
                if sessions.isEmpty {
                    Hero(title: cleared ? "旧会话都清走了" : "没有旧会话",
                         text: cleared ? "移到废纸篓的那些，清空废纸篓后才会真正腾出空间。" : "Claude Code 和 Codex 的会话在最近 \(days) 天里都用过。",
                         activity: cleared ? .celebrating : .resting) {
                        age.buttonStyle(.heroQuiet)
                        Button("再找一次") { reload += 1 }.buttonStyle(.heroQuiet)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(size(of: selected).formatted(byteFormat)).font(Theme.display(34)).monospacedDigit()
                            Text("已选 \(selected.count)/\(sessions.count) 个会话").font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            age.buttonStyle(.quiet)
                            Button(selectedCodex > 0 ? "删除…" : "移到废纸篓…") { confirming = true }
                                .buttonStyle(.primary)
                                .disabled(selected.isEmpty)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        Rule()
                        list
                    }
                }
            } else {
                Waiting(text: "正在找旧会话…")
            }
        }
        .confirmationDialog("清走 \(selected.count) 个会话？", isPresented: $confirming) {
            Button(selectedCodex > 0 ? "删除" : "移到废纸篓", role: .destructive, action: remove)
        } message: {
            Text(confirmation)
        }
        .alert("有会话没能清走", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
        .task(id: [reload, days]) {
            sessions = nil
            selection = []
            cleared = false
            sessions = await Task.detached { [days] in AISessions.all(olderThan: days) }.value
        }
    }

    /// The two tools are removed in different ways, and only one of them can be undone.
    private var confirmation: String {
        var lines = ["一共 \(size(of: selected).formatted(byteFormat))。清走后就不能在工具里继续这些会话了。"]
        if selected.count > selectedCodex {
            lines.append("Claude Code 的 \(selected.count - selectedCodex) 个移到废纸篓，可以放回原处；项目的记忆不受影响。")
        }
        if selectedCodex > 0 {
            lines.append("Codex 的 \(selectedCodex) 个交给 codex delete 永久删除，连同它们的子任务记录，无法恢复。")
        }
        return lines.joined(separator: "\n")
    }

    /// How long a conversation must have been left alone to be listed.
    private var age: some View {
        Menu("\(days) 天没动过的") {
            ForEach([7, 30, 90], id: \.self) { choice in
                Button("\(choice) 天没动过的") { days = choice }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    let open = !collapsed.contains(group.id)
                    HStack(spacing: 6) {
                        Button {
                            if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.inkSoft)
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .frame(width: 18, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((open ? "收起" : "展开") + group.id)
                        Toggle(sources: group.sessions.map { binding(for: $0.id) }, isOn: \.self) {
                            HStack(spacing: 8) {
                                Text(group.tool.rawValue).font(Theme.text(10.5, .semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(group.tool == .codex ? Theme.pinkLine : Theme.blueLine.opacity(0.7), in: Capsule())
                                Text(group.project).font(Theme.text(14, .semibold)).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text("\(group.sessions.count) 个，\(size(of: group.sessions).formatted(byteFormat))")
                                    .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                            }
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    if open {
                        ForEach(group.sessions) { session in
                            Toggle(isOn: binding(for: session.id)) { AISessionRow(session: session) }
                                .padding(.leading, 24)
                                .padding(.vertical, 5)
                                .contextMenu {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)]) }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .toggleStyle(CheckToggleStyle())
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
    }

    private func size(of sessions: [AISession]) -> Int64 { sessions.reduce(0) { $0 + $1.size } }

    /// Removes what is checked, off the main thread: `codex delete` takes about half a second a conversation.
    private func remove() {
        let doomed = selected
        removing = true
        Task {
            let problems = await Task.detached {
                doomed.reduce(into: [String: String]()) { problems, session in problems[session.id] = AISessions.remove(session) }
            }.value
            sessions?.removeAll { selection.contains($0.id) && problems[$0.id] == nil }
            AnalysisCache.clear()
            if problems.count < doomed.count { cleared = true }
            selection = []
            removing = false
            let failed = doomed.compactMap { session in problems[session.id].map { "\(session.title)：\($0)" } }
            if !failed.isEmpty { failure = failed.joined(separator: "\n") }
        }
    }
}

private struct AISessionRow: View {
    let session: AISession

    var body: some View {
        HStack {
            Text(session.title).lineLimit(1)
            Spacer()
            Text(session.modified.formatted(.relative(presentation: .named))).foregroundStyle(Theme.inkSoft)
            Text(session.size.formatted(byteFormat)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .font(Theme.text(13))
    }
}
