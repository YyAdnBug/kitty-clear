import SwiftUI
import UniformTypeIdentifiers

/// The subset of `mo analyze --json <path>` the browser shows.
struct ScanResult: Decodable {
    struct Entry: Decodable, Identifiable {
        let name, path: String
        let size: Int64
        let isDir: Bool
        var id: String { path }
    }

    /// One of the biggest files anywhere under the folder.
    struct File: Decodable, Identifiable {
        let name, path: String
        let size: Int64
        var id: String { path }
    }

    var entries: [Entry]
    let totalSize: Int64
    var largeFiles: [File]?
}

/// What the disk analysis has measured, kept so that a folder already looked at is there at once when
/// it is come back to: Mole takes a quarter of a minute over a home folder, every time it is asked.
/// A measurement is good for ten minutes, and all of them are dropped as soon as something has been
/// removed, by this page or by a run of mo, since every folder above it has changed size.
@MainActor
enum AnalysisCache {
    static let lifetime: TimeInterval = 600
    private static var scans: [String: (result: ScanResult, taken: Date)] = [:]

    static func scan(of path: String, now: Date = Date()) -> ScanResult? {
        scans[path].flatMap { now.timeIntervalSince($0.taken) < lifetime ? $0.result : nil }
    }

    static func keep(_ result: ScanResult, for path: String, now: Date = Date()) { scans[path] = (result, now) }

    static func clear() { scans = [:] }
}

/// What a block of the map stands for, which decides its colour. All of them are tones of the icon's
/// blue and pink: blue for places to go into, pink for things that were made or downloaded.
enum BlockKind: String, CaseIterable {
    case folder = "文件夹", hidden = "隐藏文件夹", app = "应用和安装包", archive = "压缩包和磁盘映像"
    case media = "图片、音频和视频", document = "文档", data = "开发文件和数据", other = "其他"

    init(name: String, isFolder: Bool) {
        let type = (name as NSString).pathExtension.lowercased()
        func isOne(of types: String) -> Bool { !type.isEmpty && types.split(separator: " ").contains(Substring(type)) }
        self = if isOne(of: "app pkg mpkg xip") { .app }
        else if isOne(of: "zip dmg iso tar gz tgz bz2 xz 7z rar sparsebundle sparseimage") { .archive }
        else if isFolder { name.hasPrefix(".") ? .hidden : .folder }
        else if isOne(of: "jpg jpeg png gif heic tiff webp psd raw mp4 mov mkv avi m4v webm mp3 m4a wav flac aac aiff") { .media }
        else if isOne(of: "pdf doc docx xls xlsx ppt pptx pages numbers key txt md rtf epub csv") { .document }
        else if isOne(of: "db sqlite sqlite3 json xml plist log img bin dat o a dylib so jar class swift c h js ts py go rs") { .data }
        else { .other }
    }

    var color: Color {
        switch self {
        case .folder: Theme.sky
        case .hidden: Theme.skyDeep
        case .app: Theme.blush
        case .archive: Theme.beans
        case .media: Theme.skyTop
        case .document: Theme.pinkLine
        case .data: Theme.blueLine
        case .other: Color(hex: 0xD9CBD0)
        }
    }

    /// The label colour that reads on the block.
    var ink: Color { self == .folder || self == .hidden || self == .app ? .white : Theme.ink }
}

/// The map's geometry: rectangles whose areas are in proportion to the sizes they stand for, kept as
/// close to squares as the space allows (the "squarified" treemap).
enum Treemap {
    /// One rectangle per weight, tiling `bounds`. Give the weights largest first.
    static func layout(_ weights: [Double], in bounds: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let areas: [CGFloat] = weights.map { $0 / total * bounds.width * bounds.height }
        var rects: [CGRect] = []
        var free = bounds
        var first = 0
        while first < areas.count {
            // Fill a strip along the shorter side for as long as adding a block keeps its blocks squarer.
            let side = min(free.width, free.height)
            func worst(_ strip: ArraySlice<CGFloat>) -> CGFloat {
                let sum = strip.reduce(0, +)
                guard let largest = strip.max(), let smallest = strip.min(), smallest > 0 else { return .infinity }
                return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
            }
            var last = first + 1
            while last < areas.count, worst(areas[first...last]) <= worst(areas[first..<last]) { last += 1 }
            let strip = areas[first..<last]
            let thickness = strip.reduce(0, +) / side
            var along: CGFloat = 0
            for area in strip {
                let length = thickness > 0 ? area / thickness : 0
                rects.append(free.width >= free.height
                    ? CGRect(x: free.minX, y: free.minY + along, width: thickness, height: length)
                    : CGRect(x: free.minX + along, y: free.minY, width: length, height: thickness))
                along += length
            }
            free = free.width >= free.height
                ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            first = last
        }
        return rects
    }
}

/// Moving something to the Trash, including what macOS lets only the Finder touch.
enum Trash {
    private static let finderScript = ["-e", "on run argv", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)", "-e", "end run"]

    /// The folders everything else hangs on: the disk's own, a whole home folder, the ones macOS puts in
    /// it (Documents, Library …) and what sits right inside ~/Library. One slip must not take a whole
    /// one; what is in them can go piece by piece. The Finder refuses most of these too.
    static func isSkeleton(_ path: String, home: String = Mole.home) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let (parent, name) = ((path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent)
        let given = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public"]
        return ["/", "/Users", "/Volumes", home + "/Library"].contains(parent) || path == home || parent == home && given.contains(name)
    }

    /// Returns nil once the item is in the Trash, else why it is not, in words for the user.
    static func move(_ path: String) async -> String? {
        if isSkeleton(path) { return "“\((path as NSString).lastPathComponent)”是系统或个人文件夹的骨架，这里不会把它整个移走。请进到里面，挑具体的内容。" }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return nil
        } catch {
            guard isRefusal(error) else { return error.localizedDescription }
        }
        // The Finder would follow a link and move what it points to, which is not what was chosen.
        if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            return "这是一个指向别处的替身，macOS 没有让 Kitty Clear 移走它。它指向的内容没有动。"
        }
        // Other apps' data folders (~/Library/Containers and the like) are closed to an app without
        // Full Disk Access, but the Finder may move them. So the Finder is asked to; macOS checks with
        // the user the first time an app does that.
        let asked = await runTool("/usr/bin/osascript", finderScript + [path])
        if asked.status == 0 { return nil }
        return asked.output.contains("-1743")
            ? "macOS 保护着这个文件夹，Kitty Clear 自己动不了它，请访达代劳也没被允许。\n在“系统设置 › 隐私与安全性”里，给 Kitty Clear 打开“完全磁盘访问权限”，或在“自动化”里允许它控制访达，然后再试。"
            : "macOS 保护着这个文件夹，Kitty Clear 自己动不了它，访达也没能移走。\n在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”里加上 Kitty Clear 之后再试。"
    }

    /// A "you may not" from the file system, as opposed to a file that is busy or already gone.
    static func isRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? (error.domain == NSPOSIXErrorDomain ? error.code : -1)
        return error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
            || [Int(EPERM), Int(EACCES)].contains(underlying)
    }
}

struct AnalyzeView: View {
    private enum Listing: String, CaseIterable { case here = "当前目录", files = "大文件" }

    /// One block of the map: an entry, or everything too small to draw on its own.
    private struct Block: Identifiable {
        let id: String
        let name: String
        let size: Int64
        let kind: BlockKind
        /// Its place by size among its neighbours, which picks one of four tones of the kind's colour
        /// so that two folders side by side do not run into one.
        var rank = 0
        var entry: ScanResult.Entry?
    }

    @State private var path = Mole.home
    @State private var reload = 0
    @State private var result: ScanResult?
    /// What is inside the biggest folders here, by path. It arrives after `result`, folder by folder,
    /// and turns their blocks into maps of their own.
    @State private var inside: [String: ScanResult] = [:]
    @State private var error: String?
    @State private var listing = Listing.here
    @State private var hovered: String?
    @State private var choosingFolder = false
    @State private var pendingTrash: ScanResult.Entry?
    @State private var trashError: String?

    var body: some View {
        Stage(size: .full, title: "磁盘分析",
              subtitle: result.map { "这里一共 \($0.totalSize.formatted(byteFormat))，双击色块或文件夹进去看，右键可以移到废纸篓" } ?? "",
              mood: result == nil && error == nil ? .searching : .calm) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Crumbs(path: $path)
                    Spacer()
                    IconButton(title: "上一级", systemImage: "chevron.up") {
                        path = (path as NSString).deletingLastPathComponent
                    }
                    .disabled(path == "/")
                    IconButton(title: "选择文件夹", systemImage: "folder") { choosingFolder = true }
                    IconButton(title: "重新扫描", systemImage: "arrow.clockwise") {
                        AnalysisCache.clear()
                        reload += 1
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Rule()
                if let result {
                    if result.entries.isEmpty {
                        Hero(title: "这里是空的", text: "这个文件夹里没有东西，或者 macOS 没有让 Kitty Clear 看。") {}
                    } else {
                        HStack(spacing: 0) {
                            map(result).padding(16)
                            Rectangle().fill(Theme.pinkLine).frame(width: 1)
                            side(result).frame(width: 300)
                        }
                    }
                } else if let error {
                    Hero(title: "这里扫描不了", text: error) {}
                } else {
                    Waiting(text: "正在量这个文件夹有多大…")
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { chosen in
            if case .success(let url) = chosen { path = url.path }
        }
        .confirmationDialog(
            "把“\(pendingTrash?.name ?? "")”移到废纸篓？",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { entry in
            Button("移到废纸篓", role: .destructive) { trash(entry) }
        } message: { entry in
            Text("\(entry.path)\n可以从废纸篓恢复。")
        }
        .alert("没能移到废纸篓", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
            if trashError?.contains("隐私与安全性") == true {
                Button("打开隐私与安全性设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(trashError ?? "")
        }
        // Always the real place. Apps keep links to the user's own folders inside their containers
        // (…/Containers/x/Data/Documents is ~/Documents): followed as if it were a folder of the app's,
        // what gets trashed there would be the user's documents under an app's name.
        .onChange(of: path, initial: true) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if real != path { path = real }
        }
        .task(id: [path, String(reload)]) {
            // A folder that was measured a moment ago is shown as it was, with no wait.
            result = AnalysisCache.scan(of: path)
            inside = [:]
            error = nil
            hovered = nil
            do {
                let scan = try await measured(path)
                result = scan
                // One level further for the folders that take up real room, biggest first. They are kept
                // too, so going into one of them shows it at once.
                let roomy = scan.entries.filter { $0.isDir && $0.size >= max(scan.totalSize, 1) / 25 }.sorted { $0.size > $1.size }.prefix(6)
                for folder in roomy {
                    try Task.checkCancellation()
                    if let deeper = try? await measured(folder.path) { inside[folder.path] = deeper }
                }
            } catch is CancellationError {
            } catch {
                self.error = Mole.describe(error)
            }
        }
    }

    /// The entries worth a block of their own, largest first, and one block for all the rest: a block
    /// under half a percent of the folder would be a sliver nobody can read or hit.
    private func blocks(_ result: ScanResult, atMost limit: Int = 48) -> [Block] {
        let sorted = result.entries.sorted { $0.size > $1.size }
        let floor = max(result.totalSize, 1) / 200
        let large = sorted.prefix(limit).prefix { $0.size >= floor }
        var blocks = large.enumerated().map { rank, entry in
            Block(id: entry.id, name: entry.name, size: entry.size, kind: BlockKind(name: entry.name, isFolder: entry.isDir), rank: rank, entry: entry)
        }
        let rest = sorted.dropFirst(large.count)
        let restSize = rest.reduce(0) { $0 + $1.size }
        if restSize > 0 { blocks.append(Block(id: "rest of \(result.entries.first?.path ?? "")", name: "其余 \(rest.count) 项", size: restSize, kind: .other)) }
        return blocks
    }

    private func map(_ result: ScanResult) -> some View {
        let blocks = blocks(result)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { space in
                let frames = Treemap.layout(blocks.map { Double($0.size) }, in: CGRect(origin: .zero, size: space.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(blocks, frames)), id: \.0.id) { block, frame in
                        Group {
                            // A folder whose contents are known, and that has the room, shows them.
                            if let deeper = inside[block.id], frame.width > 150, frame.height > 110 {
                                folder(block, holding: deeper, total: result.totalSize)
                            } else {
                                tile(block, share: Double(block.size) / Double(max(result.totalSize, 1)))
                            }
                        }
                        .frame(width: max(frame.width - 3, 1), height: max(frame.height - 3, 1))
                        .offset(x: frame.minX + 1.5, y: frame.minY + 1.5)
                    }
                }
            }
            // Only the kinds on the map, so the legend explains what is there and nothing else.
            FlowLayout(spacing: 12) {
                ForEach(BlockKind.allCases.filter { kind in blocks.contains { $0.kind == kind } }, id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(kind.color).frame(width: 11, height: 11)
                        Text(kind.rawValue).font(Theme.text(11)).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }

    /// A folder's block opened up: its name on a strip, and under it a map of what it holds.
    private func folder(_ block: Block, holding deeper: ScanResult, total: Int64) -> some View {
        let held = blocks(deeper, atMost: 24)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(block.name).font(Theme.text(12.5, .semibold)).lineLimit(1)
                Text(block.size.formatted(byteFormat)).font(Theme.text(11)).foregroundStyle(Theme.inkSoft).monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = block.id } else if hovered == block.id { hovered = nil }
            }
            .onTapGesture(count: 2) { if let entry = block.entry { path = entry.path } }
            .contextMenu { if let entry = block.entry { actions(for: entry) } }
            .help("双击进到“\(block.name)”里面")
            GeometryReader { space in
                let frames = Treemap.layout(held.map { Double($0.size) }, in: CGRect(origin: .zero, size: space.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(held, frames)), id: \.0.id) { inner, frame in
                        tile(inner, share: Double(inner.size) / Double(max(total, 1)))
                            .frame(width: max(frame.width - 2, 1), height: max(frame.height - 2, 1))
                            .offset(x: frame.minX + 1, y: frame.minY + 1)
                    }
                }
            }
            .padding([.horizontal, .bottom], 4)
        }
        .background(block.kind.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2).opacity(hovered == block.id ? 1 : 0)
        }
    }

    private func tile(_ block: Block, share: Double) -> some View {
        GeometryReader { space in
            let roomy = space.size.width > 44 && space.size.height > 30
            RoundedRectangle(cornerRadius: min(8, min(space.size.width, space.size.height) / 3), style: .continuous)
                .fill(block.kind.color.opacity(1 - 0.09 * Double(block.rank % 4)))
                .overlay(alignment: .topLeading) {
                    if roomy {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.name).font(Theme.text(space.size.width > 150 ? 13 : space.size.width > 80 ? 11.5 : 10.5, .semibold))
                                .lineLimit(space.size.height > 60 ? 2 : 1).truncationMode(.middle)
                            Text(block.size.formatted(byteFormat)).font(Theme.text(space.size.width > 80 ? 11 : 10)).opacity(0.85).monospacedDigit().lineLimit(1)
                        }
                        .foregroundStyle(block.kind.ink)
                        .padding(7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: min(8, min(space.size.width, space.size.height) / 3), style: .continuous)
                        .strokeBorder(Theme.ink, lineWidth: 2)
                        .opacity(hovered == block.id && block.entry != nil ? 1 : 0)
                }
                .clipped()
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = block.id } else if hovered == block.id { hovered = nil }
        }
        .onTapGesture(count: 2) {
            if let entry = block.entry, entry.isDir { path = entry.path }
        }
        .help("\(block.name)\n\(block.size.formatted(byteFormat))，占这里的 \(share.formatted(.percent.precision(.fractionLength(1))))")
        .contextMenu { if let entry = block.entry { actions(for: entry) } }
        .accessibilityLabel("\(block.name)，\(block.size.formatted(byteFormat))")
    }

    /// The same folder as a list, or the biggest files anywhere under it.
    private func side(_ result: ScanResult) -> some View {
        VStack(spacing: 0) {
            Segments(choices: Listing.allCases.map { ($0, $0.rawValue) }, selection: $listing).padding(.vertical, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if listing == .here {
                        ForEach(result.entries.sorted { $0.size > $1.size }) { entry in
                            row(name: entry.name, path: entry.path, size: entry.size, total: result.totalSize,
                                color: BlockKind(name: entry.name, isFolder: entry.isDir).color, highlighted: hovered == entry.id)
                                .onHover { inside in
                                    if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
                                }
                                .onTapGesture(count: 2) { if entry.isDir { path = entry.path } }
                                .contextMenu { actions(for: entry) }
                        }
                    } else {
                        ForEach(result.largeFiles ?? []) { file in
                            row(name: file.name, path: file.path, size: file.size, total: result.totalSize,
                                color: BlockKind(name: file.name, isFolder: false).color, highlighted: false)
                                .contextMenu { actions(for: .init(name: file.name, path: file.path, size: file.size, isDir: false)) }
                        }
                        if result.largeFiles?.isEmpty != false {
                            Text("这里没有特别大的文件。").font(Theme.text(12)).foregroundStyle(Theme.inkSoft).padding(.top, 24)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func row(name: String, path: String, size: Int64, total: Int64, color: Color, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 9, height: 22)
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.text(12.5, .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(size.formatted(byteFormat)) · \((Double(size) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(1))))")
                    .font(Theme.text(11)).foregroundStyle(Theme.inkSoft).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(highlighted ? Theme.blueLine.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .help(path)
    }

    @ViewBuilder private func actions(for entry: ScanResult.Entry) -> some View {
        if entry.isDir { Button("进去看") { path = entry.path } }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        Divider()
        Button("移到废纸篓…", role: .destructive) { pendingTrash = entry }
    }

    private func trash(_ entry: ScanResult.Entry) {
        Task {
            if let problem = await Trash.move(entry.path) {
                trashError = problem
            } else {
                AnalysisCache.clear() // sizes above it have changed too
                reload += 1
            }
        }
    }

    /// What is in a folder: as it was measured a moment ago, or else measured by Mole now and kept.
    private func measured(_ folder: String) async throws -> ScanResult {
        if let known = AnalysisCache.scan(of: folder) { return known }
        let scan: ScanResult = try await Mole.json(["analyze", "--json", folder])
        AnalysisCache.keep(scan, for: folder)
        return scan
    }
}

/// The current path as steps you can jump back to.
private struct Crumbs: View {
    @Binding var path: String

    private struct Step: Identifiable {
        let id: String // full path
        let name: String
    }

    private var steps: [Step] {
        var steps = [Step(id: "/", name: "Macintosh HD")]
        for part in path.split(separator: "/") {
            steps.append(Step(id: (steps.last!.id as NSString).appendingPathComponent(String(part)), name: String(part)))
        }
        return Array(steps.suffix(5))
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps) { step in
                if step.id != steps.first?.id {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkSoft)
                }
                Button(step.name) { path = step.id }
                    .buttonStyle(.plain)
                    .font(Theme.text(13, step.id == path ? .semibold : .regular))
                    .foregroundStyle(step.id == path ? Theme.ink : Theme.inkSoft)
                    .lineLimit(1)
            }
        }
    }
}
