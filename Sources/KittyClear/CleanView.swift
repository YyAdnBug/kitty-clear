import SwiftUI

/// The two commands that share one flow: scan, review item by item, run.
enum Job {
    case clean, purge

    var title: String { self == .clean ? "清理" : "项目清理" }
    var previewArgs: [String] { self == .clean ? ["clean", "--dry-run"] : ["purge", "--dry-run"] }
    /// `--yes` is purge's own switch for running without its terminal menu.
    var runArgs: [String] { self == .clean ? ["clean"] : ["purge", "--yes"] }
    /// What a finished run prints in front of its total.
    var freedLabel: String { self == .clean ? "Tracked cleanup: " : "Estimated space freed: " }

    var headline: String { self == .clean ? "给 Mac 做个清理" : "清掉旧项目的构建产物" }
    var pitch: String {
        self == .clean
            ? "扫描缓存、日志、浏览器数据和卸载残留。\n清理之前，每一项都可以取消勾选。"
            : "查找 node_modules、target、build 这类可以重新生成的目录。\n最近 7 天动过的项目不会列出来。"
    }
    var nothingFound: String { self == .clean ? "这次没有扫描到可以清理的内容。" : "要么已经清过，要么这些项目最近都在用。" }
    var afterword: String {
        self == .clean ? "缓存会在使用中慢慢长回来，隔一阵再来扫一次就好。" : "下次构建或安装依赖时，它们会重新生成。"
    }
    var warning: String {
        self == .clean
            ? "无法撤销。清理由 mo 按它的规则执行，扫描之后新产生的同类缓存也可能被一并清理。"
            : "无法撤销，不过重新构建或安装依赖就能再生成。清理由 mo 执行，扫描之后新出现的同类目录也可能被一并清理。"
    }
}

/// The disks `mo clean --external` takes: plugged in, writable, mounted directly under /Volumes.
enum Volumes {
    static func external() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return mounted.filter { volume in
            guard volume.path.hasPrefix("/Volumes/"), let values = try? volume.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsInternal == false && values.volumeIsLocal == true && values.volumeIsReadOnly == false
        }
    }
}

struct CleanRow: Identifiable {
    let id: String // absolute path
    let size: String // as mo reports it, e.g. "38.6MB"
    var bytes: Double { parseSize(size) }

    var displayPath: String {
        id.hasPrefix(Mole.home + "/") ? "~" + id.dropFirst(Mole.home.count) : id
    }

    /// Unchecking a row means writing its path into mo's whitelist, which only takes paths it accepts.
    /// A path with `*`, `?` or `[` in it reads as a pattern there, and a pattern does not cover what is
    /// inside the folder it names: such a row cannot be promised to stay, so it cannot be unchecked.
    var excludable: Bool { Whitelist.accepts(id) && !id.contains(where: { "*?[".contains($0) }) }

    /// Something the user threw away, not a cache: emptying it cannot be taken back.
    var isInTrash: Bool { id.hasPrefix(Mole.home + "/.Trash/") }
}

struct CleanSection: Identifiable {
    let id: String // title
    var rows: [CleanRow]
}

/// Something a scan points out and leaves alone: a folder that takes a lot of room and is for the user
/// to judge (a Docker disk, a package store), or a cleanup that another tool has to do.
struct CleanHint: Identifiable {
    let id: Int
    let label: String // as mo names it
    let size: String // as mo reports it, or empty
    let path: String // absolute, or empty
    let note: String // whatever else mo says about it: "review with docker system df"
    var bytes: Double { parseSize(size) }

    init(id: Int, label: String, size: String, path: String, note: String) {
        (self.id, self.label, self.size, self.path, self.note) = (id, label, size, path, note)
    }

    /// A row as mo writes it, "⊙ pnpm store · 11.26GB · ~/Library/pnpm/store" or "⊙ Docker unused data ·
    /// review with docker system df": a name, then a size, a path or a remark.
    init?(row: String, id: Int) {
        guard row.hasPrefix("⊙ ") else { return nil }
        let fields = row.dropFirst(2).components(separatedBy: " · ")
        let size = fields.dropFirst().first { $0.wholeMatch(of: #/[\d.]+(?:KB|MB|GB|TB|B)/#) != nil } ?? ""
        let path = fields.dropFirst().first { $0.hasPrefix("/") || $0.hasPrefix("~/") } ?? ""
        self.init(id: id, label: fields[0], size: size, path: path.hasPrefix("~") ? Mole.home + path.dropFirst() : path,
                  note: fields.dropFirst().filter { $0 != size && $0 != path }.joined(separator: "，"))
    }
}

/// The folders Mole weighs for its "Large files" list. Mole gives the lot of them fifteen seconds and
/// leaves out whatever has not been added up by then, so a big package store is there after one scan
/// and gone after the next. Mole is asked only where to look; the adding up is done here, with `du`
/// and no clock.
enum LargeFolders {
    /// Mole's own threshold: a gigabyte, in the kilobytes `du` counts.
    static let threshold = 1024 * 1024

    /// The places that exist on this Mac, named as Mole names them: its own report, run with a `du`
    /// that answers at once and calls everything huge. nil when this Mole cannot be asked that way.
    static func places(engine: String? = nil) -> [CleanHint]? {
        guard let rows = try? Mole.ask("bin/clean.sh", #"""
            declare -f check_large_file_candidates > /dev/null && declare -f run_with_timeout > /dev/null || exit 1
            run_with_timeout() { shift; [[ "${1:-}" == du ]] || return 124; printf '%s\t%s\n' 99999999999 "${@: -1}"; }
            DRY_RUN=true
            check_large_file_candidates 2> /dev/null
            """#, engine: engine) else { return nil }
        return rows.split(whereSeparator: \.isNewline).compactMap { CleanHint(row: $0.trimmingCharacters(in: .whitespaces), id: 0) }.filter { !$0.path.isEmpty }
    }

    /// Every place weighed, and those that hold a gigabyte or more. nil when Mole could not say where to look.
    static func weigh() async -> (large: [CleanHint], weighed: Set<String>)? {
        guard let places = await Task.detached(operation: { places() }).value else { return nil }
        let large = await withTaskGroup(of: CleanHint?.self) { group in
            for place in places {
                group.addTask {
                    // du says what it could add up even when part of the folder is closed to it: a lower bound, as in Mole.
                    let counted = await runTool("/usr/bin/du", ["-skP", place.path], mergingErrors: false).output
                    guard let kilobytes = Int(counted.prefix { $0.isNumber }), kilobytes >= threshold else { return nil }
                    return CleanHint(id: 0, label: place.label, size: "\(kilobytes * 1024)B", path: place.path, note: "")
                }
            }
            return await group.reduce(into: [CleanHint]()) { if let hint = $1 { $0.append(hint) } }
        }
        return (large, Set(places.map(\.path)))
    }
}

/// What a finished `mo clean --dry-run` says a real run would do.
struct CleanPlan {
    var sections: [CleanSection] = []
    /// What the scan did not look into, and mo's reason ("Trash", "grant Full Disk Access to your terminal").
    var skipped: [(label: String, reason: String)] = []
    /// What it found and leaves to the user, largest first.
    var hints: [CleanHint] = []
    /// Nothing to clean and nothing to say either.
    var isEmpty: Bool { sections.isEmpty && skipped.isEmpty && hints.isEmpty }

    /// Puts the app's own weighing in the place of mo's for the folders it weighed: mo's row for one of
    /// them goes (it may be missing anyway, or stand for a folder that is under a gigabyte by now).
    mutating func replaceHints(weighed: Set<String>, with large: [CleanHint]) {
        let rest = hints.filter { !weighed.contains($0.path) } + large
        hints = rest.sorted { $0.bytes > $1.bytes }.enumerated().map { CleanHint(id: $0.offset, label: $0.element.label, size: $0.element.size, path: $0.element.path, note: $0.element.note) }
    }
    /// Whitelist patterns in effect during the scan (mo's defaults when the user has no whitelist file).
    var patterns: [String] = []
    /// Tool-run cleanups (`npm cache clean` …): they have no path rows, so they cannot be excluded per item.
    var extraSteps: [String] = []

    /// `log` is the preview's stdout, `list` the `clean-list.txt` it wrote.
    init(log: [String], list: String) {
        let lines = log.map { $0.trimmingCharacters(in: .whitespaces) }
        patterns = lines.prefix { !$0.hasPrefix("➤") }.filter { $0.hasPrefix("↳ ") }.map { String($0.dropFirst(2)) }
        extraSteps = lines.compactMap { line in
            guard line.hasPrefix("→ "), let cut = line.firstRange(of: #/ · would (clean|cleanup|remove)/#) else { return nil }
            return String(line[..<cut.lowerBound].dropFirst(2)).replacing(" cache", with: " 缓存") // "pip cache", "uv cache"
        }
        // Among the findings mo also writes what it passed over ("◎ Trash · skipped, grant Full Disk
        // Access to your terminal") and what it only points out ("⊙ pnpm store · 11.26GB · ~/Library/pnpm/store",
        // "⊙ Docker unused data · review with docker system df"): a name, then a size, a path or a remark.
        for line in lines.drop(while: { !$0.hasPrefix("➤") }) {
            if line.hasPrefix("◎ "), let cut = line.range(of: " · skipped") {
                skipped.append((String(line[..<cut.lowerBound].dropFirst(2)), line[cut.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ", ()"))))
            } else if let hint = CleanHint(row: line, id: hints.count) {
                hints.append(hint)
            }
        }
        hints.sort { $0.bytes > $1.bytes }

        var current: Int?
        var seen = Set<String>()
        for line in list.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                let title = String(line.dropFirst(4).dropLast(4))
                current = sections.firstIndex { $0.id == title } ?? sections.count
                if current == sections.count { sections.append(CleanSection(id: title, rows: [])) }
            } else if line.hasPrefix("/"), let current, let cut = line.range(of: "  # ", options: .backwards) {
                let path = String(line[..<cut.lowerBound])
                let note = line[cut.upperBound...]
                // A "counted under" row lives inside another row: it is removed, or kept, with that one.
                guard !note.contains("counted under"), seen.insert(path).inserted else { continue }
                sections[current].rows.append(CleanRow(id: path, size: String(note.prefix { $0 != "," })))
            }
        }
        // mo files what is in the Trash under "User essentials", among the caches and logs. It is the one
        // thing here that the user put there by hand, so it gets a section of its own, first.
        let trashed = sections.flatMap(\.rows).filter(\.isInTrash)
        if !trashed.isEmpty {
            for index in sections.indices { sections[index].rows.removeAll(where: \.isInTrash) }
            sections.insert(CleanSection(id: "Trash", rows: trashed), at: 0)
        }
        sections.removeAll { $0.rows.isEmpty }
        for index in sections.indices {
            sections[index].rows.sort { $0.bytes > $1.bytes }
        }
    }

    /// A `mo clean --external … --dry-run` log. Mole reports an external disk as a single amount
    /// ("→ External volume cleanup · DISK, 414KB dry": its temporary items, `.DS_Store` and `._` companion
    /// files together), so the plan is one row for the whole disk.
    init(externalLog log: [String], volume: String) {
        let found = log.lazy.compactMap {
            $0.firstMatch(of: #/External volume cleanup · .*, ([\d.]+(?:KB|MB|GB|TB|B)) dry/#)
        }.first
        if let found { sections = [CleanSection(id: "External volume", rows: [CleanRow(id: volume, size: String(found.1))])] }
    }

    /// A `mo purge --dry-run` log: one row per artifact it would remove ("✓ [DRY RUN] ~/app/node_modules,
    /// 1.2GB"), grouped by what it is. Cloud-synced rows are left out, because a real run skips them.
    init(purgeLog log: [String], home: String = Mole.home) {
        var groups: [String: [CleanRow]] = [:]
        for line in log {
            guard let row = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/✓ \[DRY RUN\] (.+), ([^,]+)/#),
                  !row.1.hasPrefix("[cloud] ") else { continue }
            let path = row.1.hasPrefix("~") ? home + row.1.dropFirst() : String(row.1)
            groups[(path as NSString).lastPathComponent, default: []].append(CleanRow(id: path, size: String(row.2)))
        }
        func total(_ rows: [CleanRow]) -> Double { rows.reduce(0) { $0 + $1.bytes } }
        sections = groups.map { CleanSection(id: $0.key, rows: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { total($0.rows) > total($1.rows) }
    }
}

@Observable @MainActor
final class CleanModel {
    enum Phase { case idle, scanning, review, cleaning, done, failed }

    let job: Job
    let runner = Runner()
    private(set) var phase = Phase.idle
    private(set) var plan: CleanPlan?
    private(set) var excluded: Set<String> = []
    /// The external disk being cleaned instead of this Mac, when the user picked one.
    private(set) var volume: String?
    /// The engine that made the plan on show.
    private var scannedWith: String?
    /// Counts the scans, so that one that was stopped or started over does not come back with its plan.
    private var scans = 0
    /// Also clean what needs administrator rights (system caches and logs). Mole asks for the password.
    var includesSystem = false
    var error: String?

    init(job: Job) { self.job = job }

    private var asksForAdmin: Bool { job == .clean && volume == nil && includesSystem }
    private func arguments(_ base: [String]) -> [String] { base + (volume.map { ["--external", $0] } ?? []) }

    var selected: [CleanRow] { (plan?.sections ?? []).flatMap(\.rows).filter { !excluded.contains($0.id) } }

    /// The step `mo` is on, from its latest `➤` header.
    var step: String? {
        runner.lines.last { $0.text.hasPrefix("➤") }.map { zh($0.text.dropFirst().trimmingCharacters(in: .whitespaces)) }
    }

    /// Running total the preview has reported so far, for the scanning screen.
    var found: Double { Self.found(in: runner.lines.map(\.text)) }

    /// Adds up the rows for what a run would remove: clean writes them as "→ … 2.13GB dry", purge as
    /// "✓ [DRY RUN] …, 2.13GB" (not the cloud-synced ones, which a real run skips). Other lines end in a
    /// size too and are not findings: mo opens with the disk's free space, and lists what it only
    /// points out ("→ Xcode DerivedData · 6 projects, 1.21GB").
    nonisolated static func found(in log: [String]) -> Double {
        log.reduce(0) { sum, line in
            let row = line.trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("→") && row.hasSuffix(" dry") || row.hasPrefix("✓ [DRY RUN] ") && !row.hasPrefix("✓ [DRY RUN] [cloud] ") else { return sum }
            return sum + (row.firstMatch(of: #/([\d.]+(?:KB|MB|GB|TB|B))(?: dry)?$/#).map { parseSize(String($0.1)) } ?? 0)
        }
    }

    /// What a finished run says it freed ("Tracked cleanup: 3.2GB | …").
    var freed: String? {
        runner.lines.last { $0.text.contains(job.freedLabel) }.flatMap { line in
            line.text.split(separator: job.freedLabel, maxSplits: 1).last?.split(separator: "|").first
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func binding(for row: CleanRow) -> Binding<Bool> {
        Binding(
            get: { !self.excluded.contains(row.id) },
            set: { included in
                if included {
                    self.excluded.remove(row.id)
                } else if row.excludable {
                    self.excluded.insert(row.id)
                }
            })
    }

    /// Puts the row on Mole's saved protection list, so no later clean offers it, and drops it from this plan.
    func protect(_ row: CleanRow) {
        do {
            var list = try Whitelist()
            try list.add(row.id)
            excluded.remove(row.id)
            for index in (plan?.sections ?? []).indices {
                plan?.sections[index].rows.removeAll { $0.id == row.id }
            }
            plan?.sections.removeAll { $0.rows.isEmpty }
        } catch {
            self.error = "没能加入保护名单：\(error.localizedDescription)"
        }
    }

    /// Scans this Mac, or the external disk at `volume`.
    func scan(volume: String?) {
        self.volume = volume
        scan()
    }

    /// Back to the start, and to this Mac.
    func reset() {
        volume = nil
        plan = nil
        phase = .idle
    }

    /// Scans whatever was scanned last.
    func scan() {
        plan = nil
        excluded = []
        phase = .scanning
        scannedWith = Mole.binary
        scans += 1
        let scan = scans
        // The large folders are weighed here while mo scans; mostly that is done long before mo is.
        let weighing = job == .clean && volume == nil ? Task { await LargeFolders.weigh() } : nil
        runner.start(arguments(job.previewArgs), admin: asksForAdmin) { [self] succeeded in
            guard succeeded, var found = previewedPlan() else {
                phase = runner.wasStopped ? .idle : .failed // a scan the user stopped just goes back to the start
                return
            }
            Task {
                if let weighed = await weighing?.value { found.replaceHints(weighed: weighed.weighed, with: weighed.large) }
                guard scan == scans, phase == .scanning else { return }
                plan = found
                phase = .review
            }
        }
    }

    /// Stops what is running. A scan whose mo has finished may still be waiting for a very large folder
    /// to be added up: that wait ends here too.
    func stop() {
        runner.stop()
        if phase == .scanning, !runner.isRunning {
            scans += 1
            phase = .idle
        }
    }

    /// Reads what the preview that just finished found. Only a completed clean preview has rewritten
    /// its list file, which is why this is not called for a stopped one.
    private func previewedPlan() -> CleanPlan? {
        let log = runner.lines.map(\.text)
        if let volume { return CleanPlan(externalLog: log, volume: volume) }
        guard job == .clean else { return CleanPlan(purgeLog: log) }
        let list = URL(fileURLWithPath: Mole.home).appending(path: ".config/mole/clean-list.txt")
        return (try? String(contentsOf: list, encoding: .utf8)).map { CleanPlan(log: log, list: $0) }
    }

    /// Runs for real. `mo` has no per-item selection, so the unchecked rows are added to its protection
    /// list for the length of the run and the list is put back afterwards.
    func clean() {
        guard plan != nil else { return }
        // An engine installed since the scan goes by its own rules, which this list does not show.
        guard scannedWith == Mole.binary else {
            error = "清理引擎在扫描之后更新过，这份清单是旧引擎列的。请重新扫描再清理。"
            return
        }
        var protection: ListOverride?
        if !excluded.isEmpty {
            do {
                protection = try Whitelist.temporarily(protecting: excluded)
            } catch {
                self.error = "没能临时保护取消勾选的条目，为安全起见没有执行。\n\(error.localizedDescription)"
                return
            }
        }
        plan = nil
        phase = .cleaning
        runner.start(arguments(job.runArgs), admin: asksForAdmin) { [self] succeeded in
            phase = succeeded ? .done : .failed
            do {
                try protection?.restore()
            } catch {
                self.error = "已经结束，但保护名单没能还原，其中多了本次取消勾选的条目。可以到设置里的保护名单删掉它们。"
            }
        }
    }
}

struct CleanView: View {
    let model: CleanModel
    @State private var confirming = false
    @State private var volumes: [URL] = []

    private var reviewing: Bool { model.phase == .review && !(model.plan?.isEmpty ?? true) }

    var body: some View {
        Stage(size: reviewing || model.phase == .failed ? .full : .hero, title: title,
              subtitle: reviewing ? "取消勾选的条目会被保留" : "没有跑完，下面是 mo 的输出", mood: mood) {
            switch model.phase {
            case .idle:
                Hero(title: model.job.headline, text: model.job.pitch) {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Button("开始扫描") { model.scan(volume: nil) }.buttonStyle(.heroPrimary).keyboardShortcut(.defaultAction)
                            // ponytail: three buttons at most; make it a menu if someone plugs in more disks.
                            ForEach(volumes.prefix(3), id: \.path) { disk in
                                Button("清理 \(disk.lastPathComponent)") { model.scan(volume: disk.path) }.buttonStyle(.heroQuiet)
                            }
                        }
                        if model.job == .clean {
                            Toggle("同时清理系统缓存，扫描和清理时各要输一次管理员密码",
                                   isOn: Binding(get: { model.includesSystem }, set: { model.includesSystem = $0 }))
                                .toggleStyle(CheckToggleStyle())
                                .font(Theme.text(12))
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }
                }
            case .scanning:
                Hero(title: Int64(model.found).formatted(byteFormat), text: "已发现可清理的空间。" + stepText, activity: .searching) {
                    Button("停止", action: model.stop).buttonStyle(.heroQuiet)
                }
            case .review:
                if let plan = model.plan, reviewing {
                    review(plan)
                } else {
                    Hero(title: "已经很干净了", text: model.volume == nil ? model.job.nothingFound : "这块盘上没有可以清理的内容。") {
                        Button("再扫描一次", action: model.scan).buttonStyle(.heroQuiet)
                        if model.volume != nil { Button("回到清理", action: model.reset).buttonStyle(.heroQuiet) }
                    }
                }
            case .cleaning:
                Hero(title: "正在清理", text: stepText, activity: .working) {
                    Button("停止", action: model.runner.stop).buttonStyle(.heroQuiet)
                }
            case .done:
                Hero(title: model.freed.map { "已释放 \(zhSize($0))" } ?? "清理完成",
                     text: model.volume == nil ? model.job.afterword : "这块盘上的临时文件、.DS_Store 和 ._ 开头的附属文件已经清掉。",
                     activity: .celebrating) {
                    Button("再扫描一次", action: model.scan).buttonStyle(.heroQuiet)
                    if model.volume != nil { Button("回到清理", action: model.reset).buttonStyle(.heroQuiet) }
                }
            case .failed:
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("重新扫描", action: model.scan).buttonStyle(.primary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    Rule()
                    LogView(lines: model.runner.lines)
                }
            }
        }
        .confirmationDialog("清理勾选的 \(model.selected.count) 项，约 \(selectedSize)？", isPresented: $confirming) {
            Button("清理", role: .destructive, action: model.clean)
        } message: {
            Text(confirmation)
        }
        .alert(model.job.title, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
        } message: {
            Text(model.error ?? "")
        }
        .task { if model.job == .clean { volumes = Volumes.external() } }
    }

    private var title: String {
        model.volume.map { "清理 \(($0 as NSString).lastPathComponent)" } ?? model.job.title
    }

    private func review(_ plan: CleanPlan) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(selectedSize).font(Theme.display(34)).monospacedDigit()
                Text("已选 \(model.selected.count) 项").font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                Spacer()
                if model.volume != nil { Button("回到清理", action: model.reset).buttonStyle(.quiet) }
                Button("重新扫描", action: model.scan).buttonStyle(.quiet)
                Button("清理…") { confirming = true }
                    .buttonStyle(.primary)
                    .disabled(model.selected.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rule()
            CleanPlanList(plan: plan, model: model)
        }
    }

    private var stepText: String { model.step.map { "正在检查\($0)…" } ?? "" }

    private var mood: Kitten.Mood {
        switch model.phase {
        case .scanning: .searching
        case .cleaning: .wiping
        case .done: .happy
        case .idle, .review, .failed: .calm
        }
    }

    private var selectedSize: String {
        Int64(model.selected.reduce(0) { $0 + $1.bytes }).formatted(byteFormat)
    }

    private var confirmation: String {
        var text = model.job.warning
        let trashed = model.selected.filter(\.isInTrash)
        if !trashed.isEmpty {
            text = "其中包括清空废纸篓里的 \(trashed.count) 项（\(Int64(trashed.reduce(0) { $0 + $1.bytes }).formatted(byteFormat))），清空后找不回来。\n" + text
        }
        if model.volume != nil { text = "无法撤销。会清掉这块盘上的废纸篓、临时文件和 ._ 开头的附属文件，你自己的文件不动。" }
        if model.includesSystem, model.volume == nil, model.job == .clean { text += "\n开始时 mo 会再弹一次窗口，请求管理员密码。" }
        if !model.excluded.isEmpty {
            text += "\n取消勾选的 \(model.excluded.count) 项会临时写入 mo 的保护名单，清理结束后还原。"
        }
        if let steps = model.plan?.extraSteps, !steps.isEmpty {
            text += "\n还会运行这些工具自带的清理命令：\(steps.joined(separator: "、"))。"
        }
        return text
    }
}

private struct CleanPlanList: View {
    let plan: CleanPlan
    let model: CleanModel
    @State private var collapsed: Set<String> = []
    @State private var showingHints = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !plan.skipped.isEmpty { skippedNotice }
                if !plan.hints.isEmpty { hints }
                ForEach(plan.sections) { section in
                    let open = !collapsed.contains(section.id)
                    HStack(spacing: 6) {
                        Button {
                            if open { collapsed.insert(section.id) } else { collapsed.remove(section.id) }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.inkSoft)
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .frame(width: 18, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((open ? "收起" : "展开") + zh(section.id))
                        // One checkbox for the whole section; it shows a dash when partly checked.
                        Toggle(sources: section.rows.map(model.binding(for:)), isOn: \.self) {
                            HStack {
                                Text(zh(section.id)).font(Theme.text(14, .semibold))
                                Spacer()
                                Text(summary(of: section)).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                            }
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    if open {
                        ForEach(section.rows) { row in
                            // A whole disk is not something to put on the protection list.
                            CleanRowView(row: row, isOn: model.binding(for: row),
                                         protect: model.volume == nil ? { model.protect(row) } : nil)
                        }
                    }
                }
                if !plan.extraSteps.isEmpty {
                    Text("还会运行这些工具自带的清理命令，无法单独取消：\(plan.extraSteps.joined(separator: "、"))")
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .toggleStyle(CheckToggleStyle())
    }

    /// What the scan passed over, with the way to the setting when that is what it takes.
    private var skippedNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.blush)
            Text("这次没有扫描：" + plan.skipped.map { "\(zh($0.label))（\(zh($0.reason))）" }.joined(separator: "；"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if plan.skipped.contains(where: { $0.reason.contains("Full Disk Access") }) {
                Button("去授权") {
                    if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(settings) }
                }
                .buttonStyle(.quiet)
            }
        }
        .font(Theme.text(12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.pinkLine.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 14)
    }

    /// What takes up room and is not for a cleaner to decide: one line, which opens into the list. They
    /// are often the largest things on the disk, so they stand above what can be cleaned, but folded.
    @ViewBuilder private var hints: some View {
        Button {
            showingHints.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSoft)
                    .rotationEffect(.degrees(showingHints ? 90 : 0))
                    .frame(width: 18, height: 28)
                Text("另有 \(plan.hints.count) 处要你自己决定").font(Theme.text(14, .semibold))
                Spacer()
                Text("不会自动清理，共 \(Int64(plan.hints.reduce(0) { $0 + $1.bytes }).formatted(byteFormat))")
                    .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .padding(.bottom, showingHints ? 6 : 0)
        .accessibilityLabel((showingHints ? "收起" : "展开") + "要你自己决定的 \(plan.hints.count) 处")
        if showingHints {
            ForEach(plan.hints) { hint in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(zh(hint.label)).font(Theme.text(13))
                        Text([hint.path.isEmpty ? "" : AISessions.shortened(hint.path), zh(hint.note)].filter { !$0.isEmpty }.joined(separator: "，"))
                            .font(Theme.text(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(zhSize(hint.size)).font(Theme.text(13)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hint.path)])
                    } label: {
                        Image(systemName: "magnifyingglass.circle").font(.system(size: 15)).foregroundStyle(Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                    .accessibilityLabel("在访达中显示 \(zh(hint.label))")
                    .opacity(hint.path.isEmpty ? 0 : 1)
                    .disabled(hint.path.isEmpty)
                }
                .padding(.leading, 24)
                .padding(.vertical, 4)
            }
        }
    }

    private func summary(of section: CleanSection) -> String {
        let rows = section.rows.filter { !model.excluded.contains($0.id) }
        return "\(rows.count)/\(section.rows.count) 项，\(Int64(rows.reduce(0) { $0 + $1.bytes }).formatted(byteFormat))"
    }
}

private struct CleanRowView: View {
    let row: CleanRow
    @Binding var isOn: Bool
    let protect: (() -> Void)?

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack {
                Text(row.displayPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(zhSize(row.size)).foregroundStyle(Theme.inkSoft).monospacedDigit()
            }
            .font(Theme.text(13))
        }
        .padding(.leading, 24)
        .padding(.vertical, 5)
        .disabled(!row.excludable)
        .help(row.excludable ? row.id : "这个路径写不进 mo 的保护名单，不能单独取消")
        .contextMenu {
            if let protect { Button("以后都保留这一项", action: protect) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)]) }
        }
    }
}
