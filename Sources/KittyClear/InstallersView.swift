import SwiftUI

/// A downloaded installer that is still lying around.
struct InstallerFile: Identifiable {
    let id: String // path
    let place: String
    let size: Int64
    let modified: Date?
    var name: String { (id as NSString).lastPathComponent }

    /// Found where people keep files of their own rather than downloads. A disk image there may be an
    /// encrypted vault or a virtual machine's disk, a zip a backup: it is listed, marked, and left out
    /// of "select all".
    var isAmongOwnFiles: Bool {
        [Mole.home + "/Desktop/", Mole.home + "/Documents/", Mole.home + "/Public/", "/Users/Shared/"].contains(where: id.hasPrefix)
    }
}

/// Finds installers the way `mo installer` does. That command only has an interactive terminal menu,
/// so the search is done here, in the same places and with the same rules, and removal goes to the Trash.
enum Installers {
    typealias Root = (place: String, path: String)

    /// Where `mo installer` looks.
    static let standardRoots: [Root] = [
        ("下载", "~/Downloads"), ("桌面", "~/Desktop"), ("文稿", "~/Documents"), ("公共", "~/Public"),
        ("资源库", "~/Library/Downloads"), ("共享", "/Users/Shared"), ("Homebrew", "~/Library/Caches/Homebrew"),
        ("iCloud", "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads"),
        ("邮件", "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
        ("Telegram", "~/Library/Application Support/Telegram Desktop"),
    ]

    /// Disk images and packages are installers by their extension alone.
    static func isInstaller(_ name: String) -> Bool {
        ["dmg", "pkg", "mpkg", "iso", "xip"].contains((name as NSString).pathExtension.lowercased())
    }

    /// A zip counts when one of its first 50 entries is an app, a package or a disk image.
    static func zipHoldsInstaller(listing: String) -> Bool {
        listing.split(whereSeparator: \.isNewline).prefix(50).contains { $0.contains(#/\.(app|pkg|dmg|xip)(\/|$)/#) }
    }

    /// Looks two levels deep in each place, like `mo installer`. Unreadable places are skipped.
    static func scan(_ roots: [Root] = standardRoots) -> [InstallerFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var found: [String: InstallerFile] = [:]
        for root in roots {
            let folder = URL(fileURLWithPath: (root.path as NSString).expandingTildeInPath)
            guard let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let file as URL in files {
                if files.level >= 2 { files.skipDescendants() }
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true, found[file.path] == nil
                else { continue }
                // An iCloud zip may not be on this Mac yet, and listing it would download it.
                let isZip = file.pathExtension.lowercased() == "zip" && root.place != "iCloud"
                guard isInstaller(file.lastPathComponent) || (isZip && zipHoldsInstaller(listing: listing(of: file))) else { continue }
                found[file.path] = InstallerFile(id: file.path, place: root.place, size: Int64(values.fileSize ?? 0),
                                                 modified: values.contentModificationDate)
            }
        }
        return found.values.sorted { $0.size > $1.size }
    }

    private static func listing(of zip: URL) -> String {
        let zipinfo = Process()
        let out = Pipe()
        zipinfo.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        zipinfo.arguments = ["-1", zip.path]
        zipinfo.standardOutput = out
        zipinfo.standardError = FileHandle.nullDevice
        guard (try? zipinfo.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        zipinfo.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct InstallersView: View {
    var roots = Installers.standardRoots
    @State private var files: [InstallerFile]?
    @State private var selection: Set<String> = []
    @State private var confirming = false
    @State private var cleared = false
    @State private var failure: String?
    @State private var reload = 0

    private var selected: [InstallerFile] { (files ?? []).filter { selection.contains($0.id) } }

    var body: some View {
        Stage(size: files?.isEmpty == true ? .hero : .full, title: "安装包", subtitle: "装完就用不上的磁盘映像、安装器和压缩包",
              mood: files == nil ? .searching : cleared && files?.isEmpty == true ? .happy : .calm) {
            if let files {
                if files.isEmpty {
                    Hero(title: cleared ? "安装包都清走了" : "没有找到安装包",
                         text: cleared ? "它们在废纸篓里，清空废纸篓后才会真正腾出空间。" : "下载、桌面、文稿这些地方都看过了。",
                         activity: cleared ? .celebrating : .resting) {
                        Button("再找一次") { reload += 1 }.buttonStyle(.heroQuiet)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            // "All" is the downloads. What lies among the user's own files is ticked one by one.
                            let downloads = files.filter { !$0.isAmongOwnFiles }
                            let summary = Text(selected.isEmpty ? "全选 \(downloads.count) 个" : "已选 \(selected.count) 个，\(size(of: selected))")
                                .font(Theme.text(13, .medium)).monospacedDigit()
                            if downloads.isEmpty { summary } else { Toggle(sources: downloads.map { binding(for: $0.id) }, isOn: \.self) { summary } }
                            if downloads.count < files.count {
                                Text("另有 \(files.count - downloads.count) 个不在下载里，要逐个勾选").font(Theme.text(12)).foregroundStyle(Theme.inkSoft)
                            }
                            Spacer()
                            IconButton(title: "重新查找", systemImage: "arrow.clockwise") { reload += 1 }
                            Button("移到废纸篓…") { confirming = true }
                                .buttonStyle(.primary)
                                .disabled(selected.isEmpty)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        Rule()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(files) { file in
                                    Toggle(isOn: binding(for: file.id)) { InstallerRow(file: file) }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                        }
                    }
                    .toggleStyle(CheckToggleStyle())
                }
            } else {
                Waiting(text: "正在找安装包…")
            }
        }
        .confirmationDialog("把 \(selected.count) 个安装包移到废纸篓？", isPresented: $confirming) {
            Button("移到废纸篓", role: .destructive, action: trash)
        } message: {
            let own = selected.filter(\.isAmongOwnFiles).count
            Text("一共 \(size(of: selected))，可以从废纸篓恢复。" + (own > 0 ? "\n其中 \(own) 个放在桌面、文稿这些你自己存文件的地方，请确认它们确实是用不上的安装包。" : ""))
        }
        .alert("有文件没能移走", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
        .task(id: reload) {
            files = nil
            selection = []
            cleared = false
            files = await Task.detached { [roots] in Installers.scan(roots) }.value
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
    }

    private func size(of files: [InstallerFile]) -> String { files.reduce(0) { $0 + $1.size }.formatted(byteFormat) }

    private func trash() {
        var failed: [String] = []
        for file in selected {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.id), resultingItemURL: nil)
                files?.removeAll { $0.id == file.id }
                cleared = true
                AnalysisCache.clear()
            } catch {
                failed.append("\(file.name)：\(error.localizedDescription)")
            }
        }
        selection = []
        if !failed.isEmpty { failure = failed.joined(separator: "\n") }
    }
}

private struct InstallerRow: View {
    let file: InstallerFile

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.id))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(Theme.text(13, .medium)).lineLimit(1).truncationMode(.middle)
                    if file.isAmongOwnFiles {
                        Text("不在下载里").font(Theme.text(11, .medium)).foregroundStyle(Theme.shine)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.blueLine.opacity(0.45), in: Capsule())
                            .fixedSize()
                            .help("它放在你自己存文件的地方，可能是加密磁盘映像、虚拟机镜像或备份，不一定是装完就用不上的安装包。全选不会选上它。")
                    }
                }
                Text(file.modified.map { "\(file.place)，\($0.formatted(.relative(presentation: .named)))" } ?? file.place)
                    .font(Theme.text(11)).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Text(file.size.formatted(byteFormat)).font(Theme.text(13)).foregroundStyle(Theme.inkSoft).monospacedDigit()
        }
        .padding(.vertical, 6)
        .help(file.id)
    }
}
