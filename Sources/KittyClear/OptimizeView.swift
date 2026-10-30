import SwiftUI

/// One of Mole's maintenance tasks, from its own catalog.
struct OptimizeTask: Identifiable {
    let id: String // the action name Mole's skip list uses
    let name: String
    let note: String
}

/// Mole's maintenance tasks and the list of the ones to skip (`~/.config/mole/whitelist_optimize`).
/// Mole reads that list on every run, so the checkboxes on the Optimize page are simply that file.
enum Optimizer {
    static func tasks(engine: String? = nil) throws -> [OptimizeTask] {
        let output = try Mole.ask("lib/optimize/catalog.sh", #"""
            for ((i = 0; i < ${#MOLE_OPTIMIZE_ACTIONS[@]}; i++)); do
                printf '%s\t%s\t%s\n' "${MOLE_OPTIMIZE_ACTIONS[$i]}" "${MOLE_OPTIMIZE_HEALTH_NAMES[$i]}" "${MOLE_OPTIMIZE_DESCRIPTIONS[$i]}"
            done
            """#, engine: engine)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count == 3 ? OptimizeTask(id: fields[0], name: fields[1], note: fields[2]) : nil
        }
    }

    private static func file(_ home: String) -> URL {
        URL(fileURLWithPath: home).appending(path: ".config/mole/whitelist_optimize")
    }

    private static func lines(_ home: String) -> [String] {
        ((try? String(contentsOf: file(home), encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The tasks the saved list tells Mole to skip.
    static func skipped(among tasks: [OptimizeTask], home: String = Mole.home) -> Set<String> {
        Set(lines(home).map { $0.trimmingCharacters(in: .whitespaces) }).intersection(tasks.map(\.id))
    }

    /// Saves which tasks to skip. Lines of the file that are not task names (comments, entries for
    /// tasks this Mole no longer has) are kept as they are.
    static func setSkipped(_ ids: Set<String>, among tasks: [OptimizeTask], home: String = Mole.home) throws {
        let known = Set(tasks.map(\.id))
        let kept = lines(home).filter { !known.contains($0.trimmingCharacters(in: .whitespaces)) }
        // Nothing to skip and no file yet: leave it that way.
        guard !kept.isEmpty || !ids.isEmpty || FileManager.default.fileExists(atPath: file(home).path) else { return }
        try FileManager.default.createDirectory(at: file(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try ((kept + ids.sorted()).joined(separator: "\n") + "\n").write(to: file(home), atomically: true, encoding: .utf8)
    }
}

/// What a run of `mo optimize` printed, taken apart: what it noticed about the Mac's load, each task
/// with what it did, and its own count of how the tasks came out. The report looks like this:
///
///     → DRY RUN MODE, No files will be modified
///     Performance diagnosis
///       ◎ Likely bottleneck: WindowServer (~43.0% CPU sustained)
///     ➤ DNS & Spotlight Check
///       → DNS cache flushed
///     ======
///     Dry Run Complete, No Changes Made
///     Would apply 3 optimizations
///     14 unchanged | 1 skipped | 2 unavailable
///     ======
struct OptimizeReport {
    struct Line: Identifiable {
        let id: Int
        let text: String
        /// mo marked it as something that failed or needs a look.
        let warns: Bool
    }

    struct Section: Identifiable {
        let id: Int
        let title: String
        var lines: [Line] = []
    }

    private(set) var dryRun = false
    private(set) var diagnosis: [Line] = []
    private(set) var sections: [Section] = []
    /// mo's own count, in Chinese: "会执行 3 项，14 项无需处理，1 项已跳过". Empty until the run has closed with it.
    private(set) var counts = ""

    init(log: [String]) {
        var (inDiagnosis, inSummary, summary, lines) = (false, false, "", 0)
        for raw in log {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("DRY RUN MODE") { dryRun = true }
            if line.hasPrefix("====") {
                inSummary.toggle()
            } else if inSummary {
                summary += line + "\n"
            } else if line.hasPrefix("➤") {
                sections.append(Section(id: sections.count, title: line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line == "Performance diagnosis" || line.isEmpty {
                inDiagnosis = !line.isEmpty
            } else if raw.hasPrefix("  "), let first = line.unicodeScalars.first, sections.isEmpty ? inDiagnosis : true {
                // The mark mo puts in front, when there is one: a tick, an arrow, a warning sign.
                let marked = !CharacterSet.alphanumerics.contains(first) && first != "." && first != "~" && first != "/"
                let item = Line(id: lines, text: marked ? line.dropFirst().trimmingCharacters(in: .whitespaces) : line, warns: "◎☻-".unicodeScalars.contains(first))
                lines += 1
                if sections.isEmpty { diagnosis.append(item) } else { sections[sections.count - 1].lines.append(item) }
            }
        }
        if let applied = summary.firstMatch(of: #/(?:Would apply|Applied) (\d+) optimizations?(?:, (.+))?/#) {
            let extra: String = applied.2.map { "（" + zhResult(String($0)) + "）" } ?? ""
            var parts: [String] = [(dryRun ? "会执行 " : "执行了 ") + String(applied.1) + " 项" + extra]
            let others = [("unchanged", "项无需处理"), ("skipped", "项已跳过"), ("unavailable", "项这台 Mac 用不上"), ("need attention", "项需要留意"), ("failed", "项失败")]
            for (word, label) in others {
                guard let found = summary.firstMatch(of: try! Regex("(\\d+) \(word)")), let number = found.output[1].substring else { continue }
                parts.append("\(number) \(label)")
            }
            counts = parts.joined(separator: "，")
        }
    }
}

struct OptimizeView: View {
    let runner: Runner
    @State private var tasks: [OptimizeTask]?
    @State private var skipped: Set<String> = []
    @State private var loadProblem: String?
    @State private var saveProblem: String?
    @State private var confirming = false
    @State private var showingLog = false

    var body: some View {
        Stage(size: .full, title: "优化", subtitle: "取消勾选的任务，以后每次都会跳过",
              mood: runner.isRunning || (tasks == nil && loadProblem == nil) ? .searching : .calm) {
            if showingLog {
                log
            } else if let tasks {
                list(tasks)
            } else if let loadProblem {
                Hero(title: "读不到优化任务", text: loadProblem) {}
            } else {
                Waiting(text: "正在读任务清单…")
            }
        }
        .confirmationDialog("执行勾选的 \((tasks?.count ?? 0) - skipped.count) 项优化？", isPresented: $confirming) {
            Button("执行", role: .destructive) { run(["optimize"]) }
        } message: {
            Text("过程中 mo 会弹窗请求管理员密码。想先看看它会做什么，可以点“预览”。")
        }
        .alert("没能保存", isPresented: Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })) {
        } message: {
            Text(saveProblem ?? "")
        }
        .task {
            showingLog = runner.isRunning
            do {
                let loaded = try await Task.detached { try Optimizer.tasks() }.value
                skipped = Optimizer.skipped(among: loaded)
                tasks = loaded
            } catch {
                loadProblem = error.localizedDescription
            }
        }
    }

    private func list(_ tasks: [OptimizeTask]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // One checkbox for all tasks; it shows a dash when only some are checked.
                Toggle(sources: tasks.map { binding(for: $0.id, among: tasks) }, isOn: \.self) {
                    Text("已选 \(tasks.count - skipped.count)/\(tasks.count) 项").font(Theme.text(13, .medium)).monospacedDigit()
                }
                Spacer()
                if !runner.lines.isEmpty {
                    Button("上次的输出") { showingLog = true }.buttonStyle(.quiet)
                }
                Group {
                    Button("预览") { run(["optimize", "--dry-run"]) }.buttonStyle(.quiet)
                    Button("执行…") { confirming = true }.buttonStyle(.primary)
                }
                .disabled(runner.isRunning || skipped.count == tasks.count)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks) { task in
                        Toggle(isOn: binding(for: task.id, among: tasks)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(zh(task.name)).font(Theme.text(13, .medium))
                                Text(zhOptimizeNote(task)).font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
        .toggleStyle(CheckToggleStyle())
    }

    private var log: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("正在运行…").font(Theme.text(13, .medium))
                    Spacer()
                    Button("停止", action: runner.stop).buttonStyle(.quiet)
                } else {
                    Text(report.counts.isEmpty ? "运行结束" : report.dryRun ? "预览结果，什么都没有改动" : "优化完成").font(Theme.text(13, .medium))
                    Spacer()
                    if report.dryRun, !report.counts.isEmpty { Button("执行…") { confirming = true }.buttonStyle(.quiet) }
                    Button("回到任务清单") { showingLog = false }.buttonStyle(.primary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rule()
            // A run that broke off before mo listed a single task has nothing to lay out: its own words then.
            if report.sections.isEmpty, !runner.isRunning { LogView(lines: runner.lines) } else { OptimizeReportView(report: report) }
        }
    }

    private var report: OptimizeReport { OptimizeReport(log: runner.lines.map(\.text)) }

    /// A task's checkbox. Unchecking saves it to Mole's skip list straight away.
    private func binding(for id: String, among tasks: [OptimizeTask]) -> Binding<Bool> {
        Binding(
            get: { !skipped.contains(id) },
            set: { included in
                var next = skipped
                if included { next.remove(id) } else { next.insert(id) }
                do {
                    try Optimizer.setSkipped(next, among: tasks)
                    skipped = next
                } catch {
                    saveProblem = error.localizedDescription
                }
            })
    }

    private func run(_ args: [String]) {
        runner.start(args)
        showingLog = true
    }
}

/// A run's report on the card: mo's count of how the tasks came out, what it noticed about the Mac's
/// load, then every task with what it did (or, in a preview, would do), in Chinese.
private struct OptimizeReportView: View {
    let report: OptimizeReport

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !report.counts.isEmpty {
                    Text(report.counts).font(Theme.text(15, .semibold)).monospacedDigit().padding(.top, 18)
                }
                if !report.diagnosis.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("性能诊断").font(Theme.text(12, .medium)).foregroundStyle(Theme.inkSoft)
                        ForEach(report.diagnosis) { line in
                            Text(zhResult(line.text)).font(Theme.text(13, line.warns ? .medium : .regular))
                                .foregroundStyle(line.warns ? Theme.ink : Theme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.blueLine.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 14)
                }
                ForEach(report.sections) { section in
                    Text(zh(section.title)).font(Theme.text(14, .semibold)).padding(.top, 16).padding(.bottom, 3)
                    ForEach(section.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // mo words a preview's steps like finished ones; here a dot says "nothing done yet".
                            Image(systemName: line.warns ? "exclamationmark.circle.fill" : report.dryRun ? "circle.fill" : "checkmark")
                                .font(.system(size: line.warns ? 11 : report.dryRun ? 5 : 10, weight: .bold))
                                .foregroundStyle(line.warns ? Theme.blush : Theme.shine)
                                .frame(width: 14)
                            Text(zhResult(line.text)).font(Theme.text(13)).foregroundStyle(line.warns ? Theme.ink : Theme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
