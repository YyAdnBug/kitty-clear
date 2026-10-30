import SwiftUI

/// `mo history --json`: what Mole's operation log remembers.
struct History: Decodable {
    struct Session: Decodable, Identifiable {
        struct Actions: Decodable {
            let removed, trashed, skipped, failed, rebuilt, other: Int
        }

        let command, startedAt, endedAt, size: String
        let actions: Actions
        /// How many things the run was about (the apps of an uninstall). Older log entries have none.
        var items: Int?
        var id: String { command + startedAt + endedAt }

        /// A preview or a list is logged like a real run, but only a real run acts on anything.
        var didSomething: Bool { actions.removed + actions.trashed + actions.rebuilt + actions.other + actions.failed > 0 }

        var summary: String {
            [(actions.removed, "删除"), (actions.trashed, "移到废纸篓"), (actions.rebuilt, "重建"), (actions.other, "其他"),
             (actions.skipped, "跳过"), (actions.failed, "失败")]
                .filter { $0.0 > 0 }
                .map { "\($0.1) \($0.0) 项" }
                .joined(separator: "，")
        }
    }

    /// One file Mole moved to the Trash.
    struct Deletion: Decodable, Identifiable {
        let timestamp, status, path: String
        let sizeKb: Int? // older log entries have no size
        var id: String { timestamp + path }
    }

    let sessions: [Session]
    let deletions: [Deletion]

    private static let sessionTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss" // local time, as mo writes it
        return formatter
    }()

    private static let deletionTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static func date(ofSession text: String) -> Date? { sessionTime.date(from: text) }

    /// The files a session sent to the Trash: the log does not link them, so they are matched by time.
    func trashed(during session: Session) -> [Deletion] {
        guard let start = Self.sessionTime.date(from: session.startedAt),
              let end = Self.sessionTime.date(from: session.endedAt) else { return [] }
        return deletions.filter { deletion in
            guard deletion.status != "dry-run", let time = Self.deletionTime.date(from: deletion.timestamp) else { return false }
            return time >= start && time <= end.addingTimeInterval(1)
        }
    }
}

extension History {
    /// What the runs on record add up to: bytes cleaned, apps uninstalled, maintenance runs. Previews do not count.
    var totals: (cleaned: Int64, uninstalled: Int, optimized: Int) {
        let real = sessions.filter(\.didSomething)
        return (Int64(real.filter { $0.command == "clean" || $0.command == "purge" }.reduce(0) { $0 + parseSize($1.size) }),
                real.filter { $0.command == "uninstall" }.reduce(0) { $0 + ($1.items ?? 1) },
                real.filter { $0.command == "optimize" }.count)
    }
}

struct HistoryView: View {
    @State private var history: History?
    @State private var error: String?
    @State private var reload = 0
    @State private var expanded: Set<String> = []

    private var sessions: [History.Session] { (history?.sessions ?? []).filter(\.didSomething) }

    var body: some View {
        Stage(size: history != nil && sessions.isEmpty ? .hero : .full, title: "历史", subtitle: "清理和卸载实际动过的东西",
              mood: history == nil && error == nil ? .searching : .calm) {
            if let history {
                if sessions.isEmpty {
                    Hero(title: "还没有记录", text: "清理、卸载或项目清理真正删除过东西之后，会记在这里。") {}
                } else {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Int64(sessions.reduce(0) { $0 + parseSize($1.size) }).formatted(byteFormat))
                                .font(Theme.display(34)).monospacedDigit()
                            Text("\(sessions.count) 次操作一共腾出的空间").font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            IconButton(title: "刷新", systemImage: "arrow.clockwise") { reload += 1 }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        Rule()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sessions) { session in
                                    row(session, files: history.trashed(during: session))
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                        }
                    }
                }
            } else if let error {
                Hero(title: "读不到历史", text: error) {
                    Button("重试") { reload += 1 }.buttonStyle(.heroQuiet)
                }
            } else {
                Waiting(text: "正在翻记录…")
            }
        }
        .task(id: reload) {
            error = nil
            do {
                history = try await Mole.json(["history", "--json", "--limit", "200"])
            } catch is CancellationError {
            } catch {
                self.error = Mole.describe(error)
            }
        }
    }

    /// One operation; opens to show the files it sent to the Trash, when the log has them.
    private func row(_ session: History.Session, files: [History.Deletion]) -> some View {
        let open = expanded.contains(session.id)
        return VStack(alignment: .leading, spacing: 0) {
        Button {
            if open { expanded.remove(session.id) } else { expanded.insert(session.id) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSoft)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(files.isEmpty ? 0 : 1)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(zh(session.command)).font(Theme.text(14, .semibold))
                    Text(session.summary).font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(zhSize(session.size)).font(Theme.text(14, .semibold)).monospacedDigit()
                    Text(History.date(ofSession: session.startedAt)?
                        .formatted(.dateTime.month().day().hour().minute()) ?? session.startedAt)
                        .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!files.isEmpty) // nothing to open, but it should not look switched off
        if open {
            ForEach(files) { file in
                HStack {
                    Text(file.path.hasPrefix(Mole.home + "/") ? "~" + file.path.dropFirst(Mole.home.count) : file.path)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(file.status == "ok" ? file.sizeKb.map { Int64($0 * 1000).formatted(byteFormat) } ?? "" : "没有移走")
                        .foregroundStyle(Theme.inkSoft).monospacedDigit()
                }
                .font(Theme.text(12))
                .padding(.leading, 24)
                .padding(.vertical, 3)
            }
        }
        Rule().opacity(0.6)
        }
    }
}
