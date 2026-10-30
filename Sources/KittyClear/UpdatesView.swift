import SwiftUI

/// A newer version of something installed on this Mac.
struct SoftwareUpdate: Identifiable {
    enum Source: Equatable {
        case formula, cask
        /// Its page in the App Store, where the update is installed.
        case appStore(URL)
        /// The app checks a feed of its own (Sparkle), so its own updater installs the update.
        case sparkle

        var label: String {
            switch self {
            case .formula, .cask: "Homebrew"
            case .appStore: "App Store"
            case .sparkle: "应用自带更新"
            }
        }
    }

    let name: String
    let installed, latest: String
    let source: Source
    var app: URL?
    var id: String { "\(source.label)/\(name)" }
}

/// Asks the three places updates come from. Nothing here installs anything except `upgrade`, which
/// hands a Homebrew package to `brew upgrade`.
enum Updates {
    struct App {
        let url: URL
        let name, bundleID, version, build: String
        let feed: URL?
        let fromAppStore: Bool
    }

    typealias Found = (updates: [SoftwareUpdate], problem: String?)

    /// The apps in the two Applications folders, with what their bundles say about updating.
    static func installedApps() -> [App] {
        let fm = FileManager.default
        return ["/Applications", Mole.home + "/Applications"].flatMap { folder -> [App] in
            let apps = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            return apps.filter { $0.pathExtension == "app" }.compactMap { url in
                guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String, let build = info["CFBundleVersion"] as? String
                else { return nil }
                let shown = fm.displayName(atPath: url.path)
                return App(url: url, name: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown, bundleID: bundleID,
                           version: info["CFBundleShortVersionString"] as? String ?? build, build: build,
                           feed: (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
                           fromAppStore: fm.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path))
            }
        }
    }

    /// Asks all three sources at once. `problems` names, in words, the ones that could not be asked.
    static func check() async -> (updates: [SoftwareUpdate], problems: [String]) {
        let apps = await Task.detached { installedApps() }.value
        async let fromBrew = homebrew()
        async let fromStore = appStore(apps.filter(\.fromAppStore))
        async let fromFeeds = sparkle(apps.filter { $0.feed != nil && !$0.fromAppStore })
        let found = await [fromStore, fromFeeds, fromBrew]
        return (found.flatMap(\.updates), found.compactMap(\.problem))
    }

    /// True when something that needs macOS `minimum` can be installed on macOS `system`.
    static func runs(on system: String = systemVersion, minimum: String?) -> Bool {
        minimum.map { !Updater.isNewer($0, than: system) } ?? true
    }

    private static let systemVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    // MARK: Homebrew

    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:))

    /// Reads `brew outdated --json=v2`. Pinned formulae are left out: `brew upgrade` would not touch them.
    static func homebrewUpdates(in json: Data) throws -> [SoftwareUpdate] {
        struct Outdated: Decodable {
            struct Item: Decodable {
                let name, currentVersion: String
                let installedVersions: [String]
                let pinned: Bool?

                enum CodingKeys: String, CodingKey { case name, currentVersion, installedVersions, pinned }
                init(from decoder: Decoder) throws {
                    let item = try decoder.container(keyedBy: CodingKeys.self)
                    name = try item.decode(String.self, forKey: .name)
                    currentVersion = try item.decode(String.self, forKey: .currentVersion)
                    pinned = try item.decodeIfPresent(Bool.self, forKey: .pinned)
                    // Older Homebrew gives a cask's installed version as one string, not a list.
                    installedVersions = try (try? item.decode([String].self, forKey: .installedVersions))
                        ?? [item.decode(String.self, forKey: .installedVersions)]
                }
            }
            let formulae, casks: [Item]
        }
        let outdated = try Mole.decoder.decode(Outdated.self, from: json)
        func rows(_ items: [Outdated.Item], _ source: SoftwareUpdate.Source) -> [SoftwareUpdate] {
            items.filter { $0.pinned != true }.map {
                SoftwareUpdate(name: $0.name, installed: $0.installedVersions.last ?? "", latest: $0.currentVersion, source: source)
            }
        }
        return rows(outdated.casks, .cask) + rows(outdated.formulae, .formula)
    }

    /// Refreshes Homebrew's catalog, then lists what it has newer versions of. No Homebrew, nothing to report.
    static func homebrew() async -> Found {
        guard let brew else { return ([], nil) }
        let refreshed = await runTool(brew, ["update", "--quiet"]).status == 0
        let listing = await runTool(brew, ["outdated", "--json=v2"], mergingErrors: false)
        guard listing.status == 0, let updates = try? homebrewUpdates(in: Data(listing.output.utf8)) else {
            return ([], "Homebrew 没查成。")
        }
        return (updates, refreshed ? nil : "Homebrew 的目录没能刷新，下面是上次刷新时的结果。")
    }

    /// Hands one package to `brew upgrade`, or with nil everything Homebrew has a newer version of.
    /// Returns what went wrong, or nil.
    static func upgrade(_ update: SoftwareUpdate?) async -> String? {
        guard let brew else { return "找不到 Homebrew。" }
        let package = update.map { [$0.source == .cask ? "--cask" : "--formula", $0.name] } ?? []
        let result = await runTool(brew, ["upgrade"] + package)
        if result.status == 0 { return nil }
        // Without a terminal brew cannot ask for a password, which some casks need.
        return "brew upgrade 没有成功，可以在终端里运行 brew upgrade \(update?.name ?? "") 看看。\n\n" + String(result.output.suffix(600))
    }

    // MARK: App Store

    /// Compares App Store apps with what Apple's lookup service (`results`) says is current. An update
    /// that needs a newer macOS than this one is not an update here.
    static func appStoreUpdates(for apps: [App], in results: Data, system: String = systemVersion) throws -> (updates: [SoftwareUpdate], known: Set<String>) {
        struct Lookup: Decodable {
            struct Entry: Decodable {
                let bundleId, version, minimumOsVersion: String?
                let trackId: Int?
            }
            let results: [Entry]
        }
        let entries = try JSONDecoder().decode(Lookup.self, from: results).results
        var updates: [SoftwareUpdate] = []
        for entry in entries {
            guard let app = apps.first(where: { $0.bundleID == entry.bundleId }), let latest = entry.version, let page = entry.trackId,
                  Updater.isNewer(latest, than: app.version), runs(on: system, minimum: entry.minimumOsVersion),
                  let link = URL(string: "macappstore://apps.apple.com/app/id\(page)")
            else { continue }
            updates.append(SoftwareUpdate(name: app.name, installed: app.version, latest: latest, source: .appStore(link), app: app.url))
        }
        return (updates, Set(entries.compactMap(\.bundleId)))
    }

    /// Asks Apple about the apps that came from the App Store: first in this Mac's region, then in the
    /// US store for the ones that region's store does not carry.
    // ponytail: one request per store carries every bundle id; batch it if someone has hundreds of App Store apps.
    static func appStore(_ apps: [App]) async -> Found {
        var updates: [SoftwareUpdate] = []
        var missing = apps
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in region == "us" ? ["us"] : [region, "us"] where !missing.isEmpty {
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [.init(name: "bundleId", value: missing.map(\.bundleID).joined(separator: ",")),
                                 .init(name: "country", value: country), .init(name: "entity", value: "macSoftware")]
            guard let data = await fetch(lookup.url!), let found = try? appStoreUpdates(for: missing, in: data) else {
                return (updates, "App Store 没查成。")
            }
            updates += found.updates
            missing.removeAll { found.known.contains($0.bundleID) }
        }
        return (updates, nil)
    }

    // MARK: Sparkle

    /// The newest release in a Sparkle feed that this Mac can run: its build number, which is what gets
    /// compared, and the version people are shown. Beta channels and other systems' builds do not count.
    static func newest(inAppcast xml: Data, system: String = systemVersion) -> (build: String, version: String)? {
        let reader = AppcastReader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return reader.items
            .filter { ($0.channel ?? "").isEmpty && ($0.os ?? "macos") == "macos" && runs(on: system, minimum: $0.minimumSystem) }
            .compactMap { item in item.build.map { (build: $0, version: item.version ?? $0) } }
            .max { Updater.isNewer($1.build, than: $0.build) }
    }

    /// Reads each app's own feed, the way the app itself does when it checks for updates.
    static func sparkle(_ apps: [App]) async -> Found {
        let checks = await withTaskGroup(of: (reached: Bool, update: SoftwareUpdate?).self) { group in
            for app in apps {
                group.addTask {
                    guard let feed = app.feed, let data = await fetch(feed) else { return (false, nil) }
                    guard let latest = newest(inAppcast: data), Updater.isNewer(latest.build, than: app.build) else { return (true, nil) }
                    // Two builds of one version would read "1.2 → 1.2"; show the build numbers then.
                    let same = latest.version == app.version
                    return (true, SoftwareUpdate(name: app.name, installed: same ? app.build : app.version,
                                                 latest: same ? latest.build : latest.version, source: .sparkle, app: app.url))
                }
            }
            var checks: [(reached: Bool, update: SoftwareUpdate?)] = []
            for await check in group { checks.append(check) }
            return checks
        }
        // One vendor's server being down is not worth a warning; none answering means no network.
        let offline = !checks.isEmpty && !checks.contains { $0.reached }
        return (checks.compactMap(\.update), offline ? "各应用自己的更新地址都没连上。" : nil)
    }

    private static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Collects the releases of a Sparkle feed. A version is either an attribute of the download or an
/// element of its own; downloads listed under `sparkle:deltas` are patches, not releases.
private final class AppcastReader: NSObject, XMLParserDelegate {
    struct Item {
        var build, version, channel, minimumSystem, os: String?
    }

    private(set) var items: [Item] = []
    private var item: Item?
    private var text = ""
    private var inDeltas = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch name {
        case "item": item = Item()
        case "sparkle:deltas": inDeltas = true
        case "enclosure" where !inDeltas:
            if let build = attributes["sparkle:version"] { item?.build = build }
            if let version = attributes["sparkle:shortVersionString"] { item?.version = version }
            item?.os = attributes["sparkle:os"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:version": item?.build = value
        case "sparkle:shortVersionString": item?.version = value
        case "sparkle:channel": item?.channel = value
        case "sparkle:minimumSystemVersion": item?.minimumSystem = value
        case "sparkle:deltas": inDeltas = false
        case "item":
            if let item { items.append(item) }
            item = nil
        default: break
        }
    }
}

/// One check and its results. Lives at the app root so a check or an upgrade survives sidebar navigation.
@Observable @MainActor
final class UpdatesModel {
    enum Phase { case idle, checking, done }

    private(set) var phase = Phase.idle
    private(set) var updates: [SoftwareUpdate] = []
    private(set) var problems: [String] = []
    /// The Homebrew package being upgraded, or `everything`. Homebrew takes one job at a time.
    private(set) var upgrading: String?
    static let everything = "Homebrew/*"

    var fromHomebrew: [SoftwareUpdate] { updates.filter { $0.source == .formula || $0.source == .cask } }
    var error: String?

    func check() {
        guard phase != .checking else { return }
        phase = .checking
        Task {
            (updates, problems) = await Updates.check()
            phase = .done
        }
    }

    /// Homebrew packages are upgraded here; an app is sent to whatever installs its updates.
    func act(on update: SoftwareUpdate) {
        switch update.source {
        case .appStore(let page):
            NSWorkspace.shared.open(page)
        case .sparkle:
            if let app = update.app { NSWorkspace.shared.open(app) }
        case .formula, .cask:
            upgrade(update)
        }
    }

    /// One Homebrew package, or with nil all of them. What was upgraded leaves the list.
    func upgrade(_ update: SoftwareUpdate?) {
        guard upgrading == nil else { return }
        upgrading = update?.id ?? Self.everything
        let done = Set((update.map { [$0] } ?? fromHomebrew).map(\.id))
        Task {
            if let problem = await Updates.upgrade(update) {
                error = problem
            } else {
                updates.removeAll { done.contains($0.id) }
            }
            upgrading = nil
        }
    }
}

struct UpdatesView: View {
    let model: UpdatesModel
    @State private var confirming = false

    private var listing: Bool { model.phase == .done && !model.updates.isEmpty }

    var body: some View {
        Stage(size: listing ? .full : .hero, title: "软件更新", subtitle: "Homebrew、App Store 和应用自带更新里的新版本",
              mood: model.phase == .checking ? .searching : model.phase == .done && model.updates.isEmpty && model.problems.isEmpty ? .happy : .calm) {
            switch model.phase {
            case .idle:
                Hero(title: "看看有没有新版本", text: "会联网查询 Homebrew、App Store 和各应用自己的更新地址。\n只在你点的时候查，查完由你决定更新哪个。") {
                    Button("检查更新", action: model.check).buttonStyle(.heroPrimary).keyboardShortcut(.defaultAction)
                }
            case .checking:
                Hero(title: "正在检查更新", text: "Homebrew 要先刷新目录，可能要等上一会儿。", activity: .searching) {}
            case .done:
                if listing {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(model.updates.count)").font(Theme.display(34)).monospacedDigit()
                            Text("个可以更新").font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            if model.upgrading == UpdatesModel.everything { ProgressView().controlSize(.small) }
                            Button("重新检查", action: model.check).buttonStyle(.quiet).disabled(model.upgrading != nil)
                            if model.fromHomebrew.count > 1 {
                                Button("升级 Homebrew 的 \(model.fromHomebrew.count) 个…") { confirming = true }
                                    .buttonStyle(.primary).disabled(model.upgrading != nil)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        Rule()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.updates) { update in
                                    UpdateRow(update: update, upgrading: model.upgrading == update.id, busy: model.upgrading != nil) {
                                        model.act(on: update)
                                    }
                                }
                                if !model.problems.isEmpty {
                                    Text(model.problems.joined(separator: "\n"))
                                        .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).padding(.top, 16)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                        }
                    }
                } else {
                    Hero(title: model.problems.isEmpty ? "都是最新的" : "没有查全",
                         text: model.problems.isEmpty ? "Homebrew、App Store 和应用自带更新里都没有新版本。" : model.problems.joined(separator: "\n"),
                         activity: model.problems.isEmpty ? .celebrating : .resting) {
                        Button("再查一次", action: model.check).buttonStyle(.heroQuiet)
                    }
                }
            }
        }
        .confirmationDialog("升级 Homebrew 里的 \(model.fromHomebrew.count) 个软件？", isPresented: $confirming) {
            Button("全部升级") { model.upgrade(nil) }
        } message: {
            Text("会运行 brew upgrade，可能要几分钟。期间正在使用的命令行工具会被换成新版本。")
        }
        .alert("没能升级", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct UpdateRow: View {
    let update: SoftwareUpdate
    let upgrading: Bool
    /// Homebrew is in the middle of another upgrade.
    let busy: Bool
    let action: () -> Void

    private var viaHomebrew: Bool { update.source == .formula || update.source == .cask }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let app = update.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                } else {
                    Image(systemName: update.source == .cask ? "macwindow" : "terminal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.shine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.blueLine.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(update.name).font(Theme.text(13, .medium)).lineLimit(1)
                Text(update.source.label).font(Theme.text(11)).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Text("\(update.installed) → \(update.latest)").font(Theme.text(13)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                .lineLimit(1).truncationMode(.middle)
            if upgrading {
                ProgressView().controlSize(.small).frame(width: 96)
            } else {
                Button(viaHomebrew ? "升级" : update.source == .sparkle ? "打开应用" : "去 App Store", action: action)
                    .buttonStyle(.quiet)
                    .disabled(viaHomebrew && busy)
                    .frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
    }
}
