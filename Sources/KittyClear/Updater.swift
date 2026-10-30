import CryptoKit
import Foundation
import Observation

/// Upgrades the Mole engine without rebuilding the app. The app bundle is signed and must not be
/// modified, so a newer Mole is installed beside it, under Application Support, and is only used once
/// it has passed `Compatibility.problem(with:)`.
enum Updater {
    private static let repo = "https://github.com/tw93/mole"
    private static let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "KittyClear/mole")

    static func isNewer(_ version: String, than other: String) -> Bool {
        let (a, b) = (version.split(separator: ".").map { Int($0) ?? 0 }, other.split(separator: ".").map { Int($0) ?? 0 })
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    /// The newest engine a past upgrade left in the store, if it beats `baseline` (the bundled version).
    /// Only folders named after the version their launcher reports count: a download is unpacked as
    /// `<version>.incoming` and renamed once it has passed its checks.
    static func installed(newerThan baseline: String?, in store: URL = store) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        return names
            .filter { name in
                let launcher = store.appending(path: "\(name)/mole").path
                return FileManager.default.isExecutableFile(atPath: launcher) && Mole.version(of: launcher) == name
                    && baseline.map { isNewer(name, than: $0) } ?? true
            }
            .max { isNewer($1, than: $0) }
            .map { store.appending(path: "\($0)/mole").path }
    }

    /// The newest macOS release, e.g. "1.59.1". Windows builds are tagged `V…-windows` and are never "latest".
    static func latestVersion() async throws -> String {
        struct Release: Decodable { let tagName: String }
        let data = try await fetch("https://api.github.com/repos/tw93/mole/releases/latest")
        let tag = try Mole.decoder.decode(Release.self, from: data).tagName
        guard let match = tag.wholeMatch(of: #/V(\d+\.\d+\.\d+)/#) else { throw Failure("没看懂最新版本号：\(tag)") }
        return String(match.1)
    }

    /// True when `sums` (a release's SHA256SUMS) lists `name` with the SHA-256 of `data`.
    static func verify(_ data: Data, named name: String, against sums: String) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return sums.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count == 2 && fields[1] == name && fields[0].lowercased() == digest
        }
    }

    /// Downloads `version` from Mole's own release into the store as `<version>.incoming` and returns its
    /// launcher. Scripts come from the tagged source archive; the two Go helpers are release assets and
    /// must match the release's SHA256SUMS before they are made executable.
    static func download(_ version: String) async throws -> String {
        let fm = FileManager.default
        let folder = store.appending(path: "\(version).incoming")
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let archive = folder.appending(path: "source.tar.gz"), source = folder.appending(path: "source")
            try await fetch("\(repo)/archive/refs/tags/V\(version).tar.gz").write(to: archive)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", source.path, "--strip-components", "1"]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw Failure("解压失败") }
            for item in ["mole", "bin", "lib"] {
                try fm.moveItem(at: source.appending(path: item), to: folder.appending(path: item))
            }
            try fm.removeItem(at: source)
            try fm.removeItem(at: archive)

            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "amd64"
            #endif
            let release = "\(repo)/releases/download/V\(version)"
            let sums = String(decoding: try await fetch("\(release)/SHA256SUMS"), as: UTF8.self)
            for helper in ["analyze", "status"] {
                let asset = "\(helper)-darwin-\(arch)"
                let data = try await fetch("\(release)/\(asset)")
                guard verify(data, named: asset, against: sums) else { throw Failure("\(asset) 的校验和不对，已放弃这次升级") }
                let file = folder.appending(path: "bin/\(helper)-go")
                try data.write(to: file)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            let launcher = folder.appending(path: "mole").path
            guard Mole.version(of: launcher) == version else { throw Failure("下载到的不是 \(version)") }
            return launcher
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Promotes a checked download to the store's engine for `version` and drops the older ones.
    static func activate(_ version: String, in store: URL = store) throws -> String {
        let fm = FileManager.default
        let folder = store.appending(path: version)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: store.appending(path: "\(version).incoming"), to: folder)
        for other in (try? fm.contentsOfDirectory(atPath: store.path)) ?? [] where other != version {
            try? fm.removeItem(at: store.appending(path: other))
        }
        return folder.appending(path: "mole").path
    }

    static func discard(_ version: String) {
        try? FileManager.default.removeItem(at: store.appending(path: "\(version).incoming"))
    }

    private static func fetch(_ url: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("下载失败：\(url)") }
        return data
    }
}

/// Does an engine still speak the dialect the app parses? Used by `--selfcheck`, and before an
/// upgraded engine is allowed to replace the current one.
enum Compatibility {
    /// nil when everything the app reads from `engine` (default: the engine in use) still parses and an
    /// unchecked row is still excluded from a clean. Previews only: nothing real is cleaned.
    static func problem(with engine: String? = nil) async -> String? {
        if let problem = await outputProblem(with: engine) { return problem }
        return await protectionProblem(with: engine)
    }

    /// Everything that decides what gets deleted or skipped, each tried in its own throwaway HOME.
    static func protectionProblem(with engine: String? = nil) async -> String? {
        if let problem = await cleanProblem(with: engine) { return problem }
        if let problem = whitelistProblem(with: engine) { return problem }
        if let problem = await purgeProblem(with: engine) { return problem }
        if let problem = await uninstallProblem(with: engine) { return problem }
        if let problem = await optimizeProblem(with: engine) { return problem }
        if let problem = await externalProblem(with: engine) { return problem }
        return await adminProblem(with: engine)
    }

    /// In a throwaway HOME: saving a protection keeps Mole's defaults in force, and removing one entry
    /// leaves the others alone. This is what makes the protection list in Settings safe to edit.
    static func whitelistProblem(with engine: String? = nil) -> String? {
        let home = URL(fileURLWithPath: "/private/tmp/kittyclear-selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            var list = try Whitelist(home: home.path, engine: engine)
            let defaults = list.entries
            guard defaults.count > 1, !list.builtIn.isEmpty, !list.isSaved else { return "读不到 Mole 的默认保护名单" }
            let mine = home.appending(path: "Library/Caches/com.example.keep").path
            try list.add(mine)
            guard list.isSaved, list.entries == defaults + [mine] else { return "加入一条保护后，默认保护名单变了" }
            try list.remove(defaults[0])
            guard list.entries == defaults.dropFirst() + [mine] else { return "移除一条保护时动到了别的条目" }
            try list.remove(mine)
            guard list.entries == Array(defaults.dropFirst()) else { return "移除自己加的保护后，名单不对" }
            return nil
        } catch {
            return "保护名单读写失败：\(error.localizedDescription)"
        }
    }

    /// Checks that the JSON the app decodes still has the shape of its models.
    static func outputProblem(with engine: String? = nil) async -> String? {
        do {
            let _: Snapshot = try await Mole.json(["status", "--json"], engine: engine)
            let _: [AppItem] = try await Mole.json(["uninstall", "--list"], engine: engine)
            let _: ScanResult = try await Mole.json(["analyze", "--json", "/usr/share"], engine: engine)
            let _: History = try await Mole.json(["history", "--json", "--limit", "200"], engine: engine)
            return nil
        } catch {
            return "读不懂它的输出：\(error)"
        }
    }

    /// In a throwaway HOME, checks that an unchecked row drops out of mo's cleanup plan while mo's default
    /// protections stay in force.
    static func cleanProblem(with engine: String? = nil) async -> String? {
        let home = URL(fileURLWithPath: "/private/tmp/kittyclear-selfcheck-\(UUID().uuidString)")
        let caches = home.appending(path: "Library/Caches")
        let keep = caches.appending(path: "com.example.keep"), drop = caches.appending(path: "com.example.drop")
        defer { try? FileManager.default.removeItem(at: home) }

        func scan() async throws -> CleanPlan {
            var log: [String] = []
            for try await line in Mole.lines(["clean", "--dry-run"], engine: engine, home: home.path) { log.append(line) }
            let list = try String(contentsOf: home.appending(path: ".config/mole/clean-list.txt"), encoding: .utf8)
            return CleanPlan(log: log, list: list)
        }
        func paths(_ plan: CleanPlan) -> Set<String> { Set(plan.sections.flatMap(\.rows).map(\.id)) }

        do {
            for dir in [keep, drop] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(count: 300_000).write(to: dir.appending(path: "blob"))
            }
            let before = try await scan()
            // The preview prints the protections it enforces; Mole's loader must report the same ones.
            let loaded = try Whitelist(home: home.path, engine: engine)
            guard Set(before.patterns) == Set(loaded.entries + loaded.builtIn) else { return "预览里的保护名单和 Mole 加载到的不一致" }
            guard paths(before).isSuperset(of: [keep.path, drop.path]), !before.patterns.isEmpty
            else { return "清理预览里找不到测试缓存或默认保护名单" }
            let protection = try Whitelist.temporarily(protecting: [keep.path], home: home.path, engine: engine)
            let after = try await scan()
            try protection.restore()
            if FileManager.default.fileExists(atPath: home.appending(path: ".config/mole/whitelist").path) { return "保护名单没有还原" }
            if paths(after).contains(keep.path) { return "取消勾选的条目仍在清理计划里" }
            if !paths(after).contains(drop.path) { return "勾选的条目从清理计划里消失了" }
            if !Set(before.patterns).isSubset(of: after.patterns) { return "默认保护名单丢失" }
            return nil
        } catch {
            return "清理预览失败：\(error)"
        }
    }
}

extension Compatibility {
    private static func sandbox() -> URL { URL(fileURLWithPath: "/private/tmp/kittyclear-selfcheck-\(UUID().uuidString)") }

    /// In a throwaway HOME with two stale projects: both build folders are offered, an unchecked one
    /// drops out of the plan, and the protection list is put back afterwards.
    static func purgeProblem(with engine: String? = nil) async -> String? {
        let fm = FileManager.default
        let home = sandbox()
        defer { try? fm.removeItem(at: home) }

        func scan() async throws -> Set<String> {
            var log: [String] = []
            for try await line in Mole.lines(["purge", "--dry-run"], engine: engine, home: home.path) { log.append(line) }
            return Set(CleanPlan(purgeLog: log, home: home.path).sections.flatMap(\.rows).map(\.id))
        }

        do {
            let projects = home.appending(path: "Projects")
            for name in ["keep-app", "drop-app"] {
                try fm.createDirectory(at: projects.appending(path: "\(name)/node_modules/dep"), withIntermediateDirectories: true)
                // Since Mole 1.65 a node_modules is only offered when npm could reinstall it: a lockfile
                // beside package.json and npm's own record of the install, with nothing edited after it.
                for file in ["package.json", "package-lock.json", "node_modules/.package-lock.json"] {
                    try Data("{}".utf8).write(to: projects.appending(path: "\(name)/\(file)"))
                }
                try Data(count: 400_000).write(to: projects.appending(path: "\(name)/node_modules/dep/blob.bin"))
            }
            // Purge leaves alone any project touched in the last week, so make these look old.
            let old = Date().addingTimeInterval(-60 * 86400)
            for item in fm.enumerator(at: projects, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [] {
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: item.path)
            }
            let keep = projects.appending(path: "keep-app/node_modules").path
            let drop = projects.appending(path: "drop-app/node_modules").path
            guard try await scan() == [keep, drop] else { return "项目清理的预览没有列出测试项目" }
            let protection = try Whitelist.temporarily(protecting: [keep], home: home.path, engine: engine)
            let after = try await scan()
            try protection.restore()
            if after != [drop] { return "取消勾选的构建产物仍在项目清理的计划里" }
            if fm.fileExists(atPath: home.appending(path: ".config/mole/whitelist").path) { return "保护名单没有还原" }
            return nil
        } catch {
            return "项目清理预览失败：\(error.localizedDescription)"
        }
    }

    /// In a throwaway HOME with a stand-in app: the preview lists it, and a real run puts its question
    /// to the terminal the app gives it and takes the key typed there. That key is "q", so nothing goes:
    /// Mole sends a removed app to the real Trash, whatever HOME says.
    static func uninstallProblem(with engine: String? = nil) async -> String? {
        let fm = FileManager.default
        let home = sandbox()
        defer { try? fm.removeItem(at: home) }
        do {
            let name = "KittyClearProbe", app = home.appending(path: "Applications/KittyClearProbe.app")
            try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try Data("""
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key>\
                <string>com.example.kittyclearprobe</string><key>CFBundleName</key><string>\(name)</string></dict></plist>
                """.utf8).write(to: app.appending(path: "Contents/Info.plist"))
            var preview: [String] = []
            for try await line in Mole.lines(["uninstall", "--dry-run", name], engine: engine, home: home.path) { preview.append(line) }
            guard UninstallPreview(log: preview).apps.map(\.name) == [name] else { return "卸载预览里找不到测试应用" }
            let run = Task {
                for try await _ in Mole.lines(["uninstall", name], answering: (Mole.uninstallQuestion, "q"), engine: engine, home: home.path) {}
            }
            let watchdog = Task {
                guard (try? await Task.sleep(for: .seconds(90))) != nil else { return }
                run.cancel()
            }
            try await run.value
            watchdog.cancel()
            if run.isCancelled { return "卸载时等不到 Mole 的确认问题" }
            return fm.fileExists(atPath: app.path) ? nil : "回答“取消”之后，测试应用还是被卸载了"
        } catch {
            return "卸载确认失败：\(error.localizedDescription)"
        }
    }

    /// A folder standing in for an external disk (Mole can be told where disks are mounted, and asks
    /// `diskutil`, here a stand-in, whether one is internal): its preview reads as one row with a size.
    static func externalProblem(with engine: String? = nil) async -> String? {
        let fm = FileManager.default
        let box = sandbox()
        defer { try? fm.removeItem(at: box) }
        do {
            let volume = box.appending(path: "Volumes/DISK"), stub = box.appending(path: "stub/diskutil")
            try fm.createDirectory(at: volume.appending(path: ".TemporaryItems"), withIntermediateDirectories: true)
            try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: box.appending(path: "home"), withIntermediateDirectories: true)
            // Not the disk's trash: Mole stopped emptying it in 1.65, since Finder can still put those items back.
            try Data(count: 300_000).write(to: volume.appending(path: ".TemporaryItems/old.bin"))
            // Mole up to 1.59 reads `diskutil info` as text; later ones ask for `diskutil info -plist`.
            try Data("""
                #!/bin/sh
                if [ "$2" = -plist ]; then
                  echo '<plist version="1.0"><dict><key>Internal</key><false/><key>BusProtocol</key><string>USB</string></dict></plist>'
                else
                  echo '   Internal:   No'; echo '   Protocol:   USB'
                fi

                """.utf8).write(to: stub)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
            var log: [String] = []
            let stream = Mole.lines(["clean", "--dry-run", "--external", volume.path], engine: engine, home: box.appending(path: "home").path,
                                    environment: ["PATH": stub.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                                                  "MOLE_EXTERNAL_VOLUMES_ROOT": box.appending(path: "Volumes").path])
            for try await line in stream { log.append(line) }
            let rows = CleanPlan(externalLog: log, volume: volume.path).sections.flatMap(\.rows)
            guard rows.count == 1, rows[0].id == volume.path, rows[0].bytes > 0 else { return "外接磁盘的预览读不出来" }
            return nil
        } catch {
            return "外接磁盘预览失败：\(error.localizedDescription)"
        }
    }

    /// The route a clean takes when it may ask for administrator rights still runs with this engine.
    /// The request itself is refused here (Mole's own test switch), so no password dialog appears.
    static func adminProblem(with engine: String? = nil) async -> String? {
        let home = sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let cache = home.appending(path: "Library/Caches/com.example.keep")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(count: 300_000).write(to: cache.appending(path: "blob"))
            var log: [String] = []
            for try await line in Mole.lines(["clean", "--dry-run"], engine: engine, home: home.path, admin: true,
                                             environment: ["MOLE_TEST_NO_AUTH": "1"]) { log.append(line) }
            let list = try String(contentsOf: home.appending(path: ".config/mole/clean-list.txt"), encoding: .utf8)
            let found = CleanPlan(log: log, list: list).sections.flatMap(\.rows).contains { $0.id == cache.path }
            return found ? nil : "带管理员权限的清理流程没有跑通"
        } catch {
            return "带管理员权限的清理流程失败：\(error.localizedDescription)"
        }
    }

    /// In a throwaway HOME: a task saved to the skip list is skipped by a preview run, the next one is not.
    static func optimizeProblem(with engine: String? = nil) async -> String? {
        let home = sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let tasks = try Optimizer.tasks(engine: engine)
            guard tasks.count > 1, Set(tasks.map(\.id)).count == tasks.count else { return "读不到 Mole 的优化任务清单" }
            try Optimizer.setSkipped([tasks[0].id], among: tasks, home: home.path)
            guard Optimizer.skipped(among: tasks, home: home.path) == [tasks[0].id] else { return "要跳过的优化任务没有保存下来" }
            var log = ""
            do {
                for try await line in Mole.lines(["optimize", "--dry-run"], engine: engine, home: home.path) { log += line + "\n" }
            } catch is Mole.ExitError where log.contains("Dry Run Complete") {
                // A task that cannot work in a throwaway HOME fails the run (Spotlight's search rules are
                // looked up in the real preferences, then read from this HOME). The skip list is what counts.
            }
            if !log.contains("Skipped (whitelisted): \(tasks[0].name)") { return "取消勾选的优化任务没有被跳过" }
            if log.contains("Skipped (whitelisted): \(tasks[1].name)") { return "勾选着的优化任务被跳过了" }
            return nil
        } catch {
            return "优化预览失败：\(error.localizedDescription)"
        }
    }
}

/// The engine section of Settings: which Mole is in use, and the in-app upgrade.
@Observable @MainActor
final class EngineModel {
    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String), verifying(String), upgraded(String)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var version = Mole.binary.flatMap(Mole.version(of:))
    let bundledVersion = Mole.bundled.flatMap(Mole.version(of:))

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying: true
        case .idle, .upToDate, .upgraded, .failed: false
        }
    }

    /// Looks for a newer Mole and, if there is one, downloads it, checks it and switches to it.
    /// Whatever goes wrong, the engine in use stays as it is.
    func upgrade() {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let latest = try await Updater.latestVersion()
                guard let current = version, Updater.isNewer(latest, than: current) else {
                    state = .upToDate
                    return
                }
                state = .downloading(latest)
                let candidate = try await Updater.download(latest)
                state = .verifying(latest)
                if let problem = await Compatibility.problem(with: candidate) {
                    Updater.discard(latest)
                    state = .failed("Mole \(latest) 和这一版 Kitty Clear 还不兼容，继续使用 \(current)。\n原因：\(problem)")
                    return
                }
                Mole.use(try Updater.activate(latest))
                version = latest
                state = .upgraded(latest)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
