import Hardware
import SwiftUI

@main
enum Main {
    static func main() {
        // `--selfcheck…` flags run a check and exit; build-app.sh --check uses the first two. `-update` and
        // `-software` go online, `-codex` needs Codex and one of its conversations on this Mac.
        let checks: [String: () async -> String?] = [
            "--selfcheck": selfCheck,
            "--selfcheck-clean": { await Compatibility.protectionProblem() },
            "--selfcheck-update": updateSelfCheck,
            "--selfcheck-software": softwareSelfCheck,
            "--selfcheck-codex": codexSelfCheck,
        ]
        if let check = CommandLine.arguments.dropFirst().compactMap({ checks[$0] }).first {
            Task {
                let problem = await check()
                print(problem.map { "FAILED: \($0)" } ?? "OK")
                exit(problem == nil ? 0 : 1)
            }
            dispatchMain()
        }
        KittyClearApp.main()
    }
}

/// `--selfcheck`: the app's own parsing rules, then whether the engine's output still matches its models.
private func selfCheck() async -> String? {
    precondition(parseSize("861.0MB") == 861e6 && parseSize("442KB") == 442e3)
    precondition(parseSize("0B") == 0 && parseSize("size unknown") == 0)

    // The in-app upgrade reads GitHub's latest release: a `v` tag and the `_arm64.zip` build-dmg.sh makes
    // (GitHub turns the space in its name into a dot).
    func release(_ tag: String, _ asset: String) -> AppUpdate.Release? {
        try! AppUpdate.release(from: Data(#"""
        {"tag_name": "\#(tag)", "html_url": "https://github.com/YyAdnBug/kitty-clear/releases/tag/\#(tag)",
         "assets": [{"name": "Kitty.Clear_0.2.0_arm64.dmg", "browser_download_url": "https://github.com/a.dmg"},
                    {"name": "\#(asset)", "browser_download_url": "https://github.com/a.zip"}]}
        """#.utf8))
    }
    precondition(release("v0.2.0", "Kitty.Clear_0.2.0_arm64.zip")?.version == "0.2.0")
    precondition(release("v0.2.0", "Kitty.Clear_0.2.0_arm64.zip")?.archive.absoluteString == "https://github.com/a.zip")
    precondition(release("V1.65.0", "Kitty.Clear_0.2.0_arm64.zip") == nil)
    precondition(release("v0.2.0", "notes.txt") == nil)
    precondition(Updater.isNewer("0.1.10", than: "0.1.9") && !Updater.isNewer("0.1.0", than: "0.1.0"))

    let plan = CleanPlan(
        log: ["✓ Whitelist: 2 core patterns active", "  ↳ /Users/a/Library/Caches/JetBrains*", "➤ Developer tools",
              "  → npm cache · would clean", "  → npm logs · 3KB dry", "  ↳ not a pattern"],
        list: """
        # Mole Cleanup Preview
        === User essentials ===
        /Users/a/Library/Caches/Geo  # 38.6MB
        /Users/a/Library/Caches/Geo/x.pbd  # 291KB, counted under /Users/a/Library/Caches/Geo
        /Users/a/Library/Caches/Big  # 1.2GB, 25 items
        === Nothing here ===
        """)
    precondition(plan.patterns == ["/Users/a/Library/Caches/JetBrains*"] && plan.extraSteps == ["npm 缓存"])
    precondition(plan.sections.map(\.id) == ["User essentials"])
    precondition(plan.sections[0].rows.map(\.id) == ["/Users/a/Library/Caches/Big", "/Users/a/Library/Caches/Geo"])
    precondition(plan.sections[0].rows[0].size == "1.2GB")
    // mo keeps a folder named like this when its path is in the list, but not what is inside it (a path
    // with [ in it is a pattern to mo): unchecking it would promise more than holds.
    precondition(!CleanRow(id: "/Users/a/Library/Caches/weird [x] name", size: "").excludable)
    for path in ["/Users/a/../b", "/Users/a//b", "/etc/x", "/Users/a/b ", "relative"] {
        precondition(!CleanRow(id: path, size: "").excludable)
    }
    precondition(zh("Developer tools") == "开发工具" && zh("Some New Section") == "Some New Section")
    precondition(zhHealth("Excellent") == "状态很好")
    precondition(zhSize("3.2GB") == Int64(3.2e9).formatted(byteFormat) && zhSize("Partially measured") == "部分已统计")
    precondition(zhSize("At least 3.2GB") == "至少 " + Int64(3.2e9).formatted(byteFormat))
    precondition(zhHealth("Good: Disk Almost Full, High CPU") == "良好：磁盘快满了、CPU 占用高")
    let purge = CleanPlan(purgeLog: ["✓ [DRY RUN] ~/a/node_modules, 1.2GB", "  ✓ [DRY RUN] ~/b, c/target, 300MB",
                                     "✓ [DRY RUN] [cloud] ~/d/node_modules, 9GB", "✓ [DRY RUN] ~/e/node_modules, 2KB", "Dry run complete"],
                          home: "/Users/a")
    precondition(purge.sections.map(\.id) == ["node_modules", "target"])
    precondition(purge.sections[0].rows.map(\.id) == ["/Users/a/a/node_modules", "/Users/a/e/node_modules"])
    precondition(purge.sections[1].rows[0].id == "/Users/a/b, c/target" && purge.sections[1].rows[0].size == "300MB")
    let disk = CleanPlan(externalLog: ["➤ External volume", "  → External volume cleanup · MY, DISK, 414KB dry"], volume: "/Volumes/MY, DISK")
    precondition(disk.sections.count == 1 && disk.sections[0].rows[0].id == "/Volumes/MY, DISK" && disk.sections[0].rows[0].size == "414KB")
    precondition(CleanPlan(externalLog: ["➤ External volume", "  ✓ Nothing to clean"], volume: "/Volumes/X").sections.isEmpty)
    // What a scan passed over and what it only points out, taken from among its findings: the line about
    // system caches before the first section is neither, and the largest hint comes first.
    let noted = CleanPlan(log: [
        "◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview", "➤ User essentials",
        "  ◎ Trash · skipped, grant Full Disk Access to your terminal", "  ◎ Firefox caches · skipped (process state unknown)", "  → Chrome cache · 724.5MB dry",
        "➤ Developer tools", "  ⊙ Docker unused data · review with docker system df", "➤ Large files",
        "  ⊙ Xcode DerivedData · 1.21GB · 2026-09-01 · /Users/a/Library/Developer/Xcode/DerivedData", "  ⊙ pnpm store · 11.26GB · ~/Library/pnpm/store",
    ], list: "")
    precondition(noted.skipped.map(\.label) == ["Trash", "Firefox caches"] && noted.skipped.map(\.reason) == ["grant Full Disk Access to your terminal", "process state unknown"])
    precondition(noted.hints.map(\.label) == ["pnpm store", "Xcode DerivedData", "Docker unused data"] && noted.hints.map(\.size) == ["11.26GB", "1.21GB", ""])
    precondition(noted.hints[0].path == Mole.home + "/Library/pnpm/store" && noted.hints[1].note == "2026-09-01" && noted.hints[2].note == "review with docker system df")
    precondition(noted.sections.isEmpty && !noted.isEmpty && plan.hints.isEmpty && plan.skipped.isEmpty && !plan.isEmpty)
    // The app's own weighing takes the place of mo's for the folders it weighed: a row mo had for one of
    // them goes (here the Xcode one, under a gigabyte by now), what mo only remarks on stays.
    var weighed = noted
    weighed.replaceHints(weighed: [Mole.home + "/Library/pnpm/store", "/Users/a/Library/Developer/Xcode/DerivedData", "/Users/a/.m2/repository"],
                         with: [CleanHint(id: 0, label: "pnpm store", size: "11000000000B", path: Mole.home + "/Library/pnpm/store", note: ""),
                                CleanHint(id: 0, label: "Maven local repository", size: "2000000000B", path: "/Users/a/.m2/repository", note: "")])
    precondition(weighed.hints.map(\.label) == ["pnpm store", "Maven local repository", "Docker unused data"] && weighed.hints.map(\.id) == [0, 1, 2])
    // This Mole can still be asked where its large folders are (the home folder's Library is always there to be found in).
    guard let places = LargeFolders.places() else { return "问不出 Mole 的大文件位置清单，大文件提示会退回它自己限时量出来的结果" }
    precondition(places.allSatisfy { $0.path.hasPrefix("/") && !$0.label.isEmpty })

    // What is in the Trash gets a section of its own in front, and a row whose path would read as a
    // pattern in mo's list cannot be unchecked, because the pattern would not cover what is inside it.
    let binned = CleanPlan(log: [], list: "=== User essentials ===\n\(Mole.home)/Library/Caches/a  # 2MB\n\(Mole.home)/.Trash/report.docx  # 1MB\n")
    precondition(binned.sections.map(\.id) == ["Trash", "User essentials"] && binned.sections[0].rows.map(\.isInTrash) == [true])
    precondition(CleanRow(id: "/Users/a/Library/Caches/plain", size: "1MB").excludable)
    for odd in ["/Users/a/Library/Caches/app [beta]", "/Users/a/Library/Caches/a*b", "/Users/a/Library/Caches/what?"] {
        precondition(!CleanRow(id: odd, size: "1MB").excludable)
    }

    // The scanning screen's running total: findings only, not the free space mo opens with, what it only
    // points out, or cloud-synced folders.
    precondition(CleanModel.found(in: ["⚙ Apple Silicon | Free space: 191.96GB", "  → Chrome cache · 724.5MB dry", "  → Xcode DerivedData · 6 projects, 1.21GB",
                                       "✓ [DRY RUN] ~/a/node_modules, 1.5GB", "✓ [DRY RUN] [cloud] ~/d/node_modules, 9GB", "Potential space: 4.86GB | Items: 537"])
        == 724.5e6 + 1.5e9)
    checkListOverride()

    let leftovers = UninstallPreview(log: [
        "◎ Matched 2 app(s):", "1. AppCleaner  8.4MB  |  Last: 1m ago", "Files to be removed:",
        "◎ Homebrew apps will be fully cleaned, --zap removes configs and data",
        "◎ AppCleaner , 8.6MB", "  ✓ /Applications/AppCleaner.app , 8.4MB", "  ✓ ~/Library/Preferences/a, b.plist",
        "◎ Docker [Brew] , 2.24GB", "  ◎ Needs the vendor's own uninstaller", "  ◎ System: /Library/LaunchDaemons/com.docker.vmnetd.plist , 4KB",
        "  ◎ Review only: /Library/Preferences/x.plist", "➤ Remove 2 apps, 2.25GB  Enter confirm, ESC cancel: ", "◎ not an app , 1KB",
    ])
    precondition(leftovers.apps.map(\.name) == ["AppCleaner", "Docker"] && leftovers.apps.map(\.size) == ["8.6MB", "2.24GB"])
    precondition(leftovers.apps[0].files.map(\.path) == ["/Applications/AppCleaner.app", "~/Library/Preferences/a, b.plist"])
    precondition(leftovers.apps[0].files.map(\.size) == ["8.4MB", ""])
    precondition(leftovers.apps[1].notes == ["Needs the vendor's own uninstaller"])
    precondition(leftovers.apps[1].files.map(\.kind) == [.system, .reviewOnly] && leftovers.apps[1].files[0].size == "4KB")

    // An installer found among the user's own files is told apart from a download.
    func found(_ path: String) -> InstallerFile { InstallerFile(id: path, place: "", size: 1, modified: nil) }
    precondition(found(Mole.home + "/Documents/vault.dmg").isAmongOwnFiles && found(Mole.home + "/Desktop/vm/disk.iso").isAmongOwnFiles && found("/Users/Shared/x.pkg").isAmongOwnFiles)
    precondition(!found(Mole.home + "/Downloads/app.dmg").isAmongOwnFiles && !found(Mole.home + "/Library/Caches/Homebrew/x.pkg").isAmongOwnFiles)

    // What may not be moved to the Trash whole, and what may.
    for whole in ["/", "/Applications", "/Users/a", "/Users/b", "/Volumes/Disk", "/Users/a/Documents", "/Users/a/Library", "/Users/a/Library/Containers", "/Users/a/Desktop/"] {
        precondition(Trash.isSkeleton(whole, home: "/Users/a"))
    }
    for piece in ["/Users/a/Documents/x.pdf", "/Users/a/old-project", "/Users/a/Library/Caches/com.x", "/Applications/Foo.app", "/Volumes/Disk/Folder"] {
        precondition(!Trash.isSkeleton(piece, home: "/Users/a"))
    }
    // A conversation written to after it was listed is not removed; one that was not, may be.
    let talk = FileManager.default.temporaryDirectory.appending(path: "kittyclear-talk-\(UUID().uuidString).jsonl")
    try! Data("{}".utf8).write(to: talk)
    defer { try? FileManager.default.removeItem(at: talk) }
    func listed(_ when: Date) -> AISession {
        AISession(id: talk.path, tool: .claude, project: "", title: "t", modified: when, files: [talk], size: 2, threads: [])
    }
    precondition(AISessions.usedSince(listing: listed(Date().addingTimeInterval(-3600))) && !AISessions.usedSince(listing: listed(Date().addingTimeInterval(5))))
    // The kernel's row is not something to send a signal to (pid 0 would be this app's own group), and a
    // job without a usable label is not something to hand to launchctl.
    precondition(Processes.end(ProcessGroup(id: "kernel_task", name: "kernel_task", pid: 0, count: 1, cpu: 0, memory: 0)) != nil)
    precondition(!StartupItems.isAddressable("") && !StartupItems.isAddressable("  ") && !StartupItems.isAddressable("a/b") && StartupItems.isAddressable("com.example.agent"))

    // mo is told which app by the name of its folder. It must then have matched exactly the ticked apps:
    // not another with the same name, not more, not fewer.
    let ticked = AppItem(name: "AppCleaner", source: "App", path: "/Applications/AppCleaner.app", size: "8.4MB")
    let cask = AppItem(name: "Docker", source: "Homebrew", path: "/Applications/Docker.app", size: "2GB")
    precondition(ticked.term == "AppCleaner" && cask.term == "Docker")
    precondition(ticked.namesakes(among: [ticked, cask]).isEmpty)
    precondition(ticked.namesakes(among: [ticked, AppItem(name: "appcleaner", source: "App", path: "/Users/a/Applications/Other.app", size: "1MB")]).count == 1)
    precondition(ticked.namesakes(among: [ticked, AppItem(name: "X", source: "App", path: "/Users/a/Applications/AppCleaner.app", size: "1MB")]).count == 1)
    let matched = UninstallPreview(log: ["Files to be removed:", "◎ AppCleaner , 8.6MB", "  ✓ /Applications/AppCleaner.app , 8.4MB", "  ✓ ~/Library/Preferences/x.plist",
                                         "◎ Mine , 1MB", "  ✓ ~/Applications/Mine.app , 1MB", "  ◎ Shared leftovers kept (other copies unchecked)", "➤ Remove 2 apps"])
    let mine = AppItem(name: "Mine", source: "App", path: Mole.home + "/Applications/Mine.app", size: "1MB")
    precondition(matched.bundles == ["/Applications/AppCleaner.app", Mole.home + "/Applications/Mine.app"] && matched.covers([mine, ticked]))
    precondition(!matched.covers([ticked]) && !matched.covers([ticked, cask]) && !matched.covers([ticked, mine, cask]))
    precondition(matched.keepsLeftovers(ofAppNamed: "Mine") && !matched.keepsLeftovers(ofAppNamed: "AppCleaner"))
    precondition(!leftovers.covers([ticked, cask])) // no bundle row for Docker in that list: not proven, so not covered

    // A real run names what it could not take; those rows say so and do not count as moved. When it names
    // something the list does not have, the list is not to be trusted.
    var ran = leftovers
    precondition(ran.markKept(in: ["Files to be removed:", "➤ Remove 2 apps", "  ◎ macOS denied access: ~/Library/Preferences/a, b.plist", "  ✓ done"]))
    precondition(ran.apps[0].files.map { $0.kept != nil } == [false, true] && ran.moved == 1 && leftovers.moved == 2)
    precondition(!ran.markKept(in: ["➤ Remove 2 apps", "  ◎ Kept (shared with another installed app): 3 paths"]))

    // What Mole's search misses of an app: named by its identifier, in lower case for the recent documents
    // (which Mole finds by itself when the identifier is lower case already), and nothing at all for an
    // identifier that could lead a path astray or that is Apple's.
    let stragglers = Stragglers.candidates(bundleID: "com.liguangming.Shadowrocket", home: "/Users/a", userFolders: ["/private/var/folders/x/y/C/"])
    precondition(stragglers.count == 4 && stragglers[0] == "/private/var/folders/x/y/C/com.liguangming.Shadowrocket")
    precondition(stragglers[2] == "/Users/a/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.liguangming.shadowrocket.sfl3")
    precondition(Stragglers.candidates(bundleID: "com.example.app", home: "/Users/a", userFolders: ["/c/"]) == ["/c/com.example.app"])
    for bad in ["", "unknown", "../x.y", "com.a/b", "com.apple.Safari", "a b.c"] { precondition(Stragglers.candidates(bundleID: bad).isEmpty) }
    var withMore = leftovers
    withMore.add([(path: Mole.home + "/Library/x.sfl3", bytes: 799)], toAppNamed: "AppCleaner")
    precondition(withMore.apps[0].files.last?.path == "~/Library/x.sfl3" && parseSize(withMore.apps[0].files.last?.size ?? "") == 799 && withMore.moved == 3)
    // A run of mo optimize, taken apart: preview or not, what it noticed, each task's lines with the ones
    // that warn, mo's own count, and its words in Chinese (as mo wrote them when they are new to the app).
    let optimized = OptimizeReport(log: [
        "Optimize", "→ DRY RUN MODE, No files will be modified", "", "⚙ System  15/24 GB RAM | 243/460 GB Disk | Uptime 2d", "",
        "Performance diagnosis", "  ◎ Likely bottleneck: WindowServer (~43.0% CPU sustained)", "  ⊙ Simulator runtime disk-image services are active.", "",
        "➤ DNS & Spotlight Check", "  → DNS cache flushed", "  → Spotlight index verified", "",
        "➤ Shared File Lists", "  - Shared file lists not readable (check directory permissions and Full Disk Access)", "",
        "➤ Prevent Finder .DS_Store", "  → .DS_Store prevention enabled on network & USB volumes", "",
        "======", "Dry Run Complete, No Changes Made", "Would apply 3 optimizations", "14 unchanged | 1 skipped | 2 unavailable",
        "Run without --dry-run to apply these changes", "======",
    ])
    precondition(optimized.dryRun && optimized.counts == "会执行 3 项，14 项无需处理，1 项已跳过，2 项这台 Mac 用不上")
    precondition(optimized.diagnosis.map(\.text) == ["Likely bottleneck: WindowServer (~43.0% CPU sustained)", "Simulator runtime disk-image services are active."])
    precondition(optimized.diagnosis.map(\.warns) == [true, false] && optimized.sections.map(\.title) == ["DNS & Spotlight Check", "Shared File Lists", "Prevent Finder .DS_Store"])
    precondition(optimized.sections[0].lines.map(\.text) == ["DNS cache flushed", "Spotlight index verified"] && optimized.sections[1].lines.map(\.warns) == [true])
    precondition(optimized.sections[2].lines[0].text == ".DS_Store prevention enabled on network & USB volumes")
    let done = OptimizeReport(log: ["➤ App State Cleanup", "  ✓ Removed 4 old saved state(s)", "====", "Optimization Complete",
                                    "Applied 5 optimizations, 1.2GB cache cleaned", "12 unchanged | 2 need attention | 1 failed", "Review the warnings above", "===="])
    precondition(!done.dryRun && done.counts == "执行了 5 项（清掉 1.2GB 缓存），12 项无需处理，2 项需要留意，1 项失败")
    precondition(OptimizeReport(log: ["➤ App State Cleanup", "  ✓ App saved states optimized"]).counts.isEmpty)
    precondition(zhResult("Likely bottleneck: WindowServer (~43.0% CPU sustained)") == "最可能拖慢这台 Mac 的是 WindowServer，它一直占着约 43.0% 的 CPU")
    precondition(zhResult("Login items all healthy (4 checked)") == "登录项都有效（检查了 4 个）" && zhResult("Removed 4 old saved state(s)") == "移除 4 份过期的窗口状态记录")
    precondition(zhResult("Network stack refresh · skipped (admin access required)") == "没有管理员权限，跳过" && zhResult("Something new in Mole") == "Something new in Mole")

    // Accessories with a charge: earphones say theirs in the Bluetooth report, a mouse only through its
    // driver (matched by address, however each of the two writes it), and what is not connected or has no
    // charge to tell is left out. What only a driver knows of (on a cable) comes last.
    let report = Data(#"""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Magic Mouse":{"device_address":"10:CF:0F:E8:3D:AA","device_minorType":"Mouse"}},
          {"助听器":{"device_address":"18:3F:70:00:00:01","device_batteryLevelLeft":"99%","device_batteryLevelRight":"87%","device_batteryLevelCase":"40%","device_minorType":"Headphones"}},
          {"Speaker":{"device_address":"AA:BB:CC:00:00:02","device_minorType":"Speaker"}}],
         "device_not_connected":[{"Old":{"device_address":"1C:8E:2A:00:00:03","device_batteryLevelMain":"50%"}}]}]}
        """#.utf8)
    let accessories = Accessory.list(report: report, drivers: [("mouse as its driver calls it", "10-cf-0f-e8-3d-aa", 49), ("Magic Keyboard", "", 15)])
    precondition(accessories.map(\.name) == ["Magic Mouse", "助听器", "Magic Keyboard"] && accessories.map(\.percent) == [49, 87, 15])
    precondition(accessories.map(\.detail) == ["49%", "左 99%，右 87%，充电盒 40%", "15%"] && accessories.map(\.symbol) == ["magicmouse", "earbuds", "keyboard"])
    precondition(Accessory.list(report: Data("not json".utf8), drivers: []).isEmpty)
    for accessory in await Sensors.accessories() where !(0...100).contains(accessory.percent) { return "配件“\(accessory.name)”的电量读出来是 \(accessory.percent)%" }

    // Mole's own rules decide what of that may go: a licence store stays.
    guard Stragglers.unprotected(["/private/var/folders/x/y/C/com.example.app", "/private/var/folders/x/y/C/com.native-instruments.Kontakt"])
        == ["/private/var/folders/x/y/C/com.example.app"] else { return "Mole 的保护规则没有按预期回答哪些残留可以移走" }

    precondition(Updater.isNewer("1.60.0", than: "1.59.1") && Updater.isNewer("1.59.10", than: "1.59.9"))
    precondition(!Updater.isNewer("1.59.1", than: "1.59.1") && !Updater.isNewer("1.9.0", than: "1.10.0"))
    let sums = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc-file\n"
    precondition(Updater.verify(Data("abc".utf8), named: "abc-file", against: sums))
    precondition(!Updater.verify(Data("abd".utf8), named: "abc-file", against: sums))
    precondition(!Updater.verify(Data("abc".utf8), named: "other-file", against: sums))
    checkEngineStore()
    precondition(Installers.isInstaller("Xcode.DMG") && Installers.isInstaller("a.pkg") && !Installers.isInstaller("notes.zip"))
    precondition(Installers.zipHoldsInstaller(listing: "Foo.app/\nFoo.app/Contents/Info.plist\n"))
    precondition(Installers.zipHoldsInstaller(listing: "release/setup.pkg\n"))
    precondition(!Installers.zipHoldsInstaller(listing: "photos/a.jpg\nnotes/app-ideas.txt\n"))
    checkInstallerScan()
    let real = History.Session.Actions(removed: 0, trashed: 4, skipped: 1, failed: 0, rebuilt: 0, other: 0)
    let preview = History.Session.Actions(removed: 0, trashed: 0, skipped: 124, failed: 0, rebuilt: 0, other: 0)
    let run = History.Session(command: "uninstall", startedAt: "2026-10-08 17:06:43", endedAt: "2026-10-08 17:09:24", size: "3.34GB", actions: real)
    precondition(run.didSomething && run.summary == "移到废纸篓 4 项，跳过 1 项")
    precondition(!History.Session(command: "clean", startedAt: "", endedAt: "", size: "4.79GB", actions: preview).didSomething)
    let log = History(sessions: [run], deletions: [
        .init(timestamp: "2026-10-08T17:08:00+0900", status: "ok", path: "/a", sizeKb: 4),
        .init(timestamp: "2026-10-08T17:08:01+0900", status: "dry-run", path: "/b", sizeKb: 4),
        .init(timestamp: "2026-10-08T18:00:00+0900", status: "ok", path: "/c", sizeKb: 4),
    ])
    precondition(TimeZone.current.secondsFromGMT() != 9 * 3600 || log.trashed(during: run).map(\.path) == ["/a"])
    var gone = History.Session(command: "uninstall", startedAt: "", endedAt: "", size: "1GB", actions: real)
    gone.items = 3
    let cleaned = History.Session(command: "clean", startedAt: "", endedAt: "", size: "2.5GB", actions: real)
    let previewed = History.Session(command: "clean", startedAt: "", endedAt: "", size: "9GB", actions: preview)
    let tuned = History.Session(command: "optimize", startedAt: "", endedAt: "", size: "0B", actions: real)
    let totals = History(sessions: [run, gone, cleaned, previewed, tuned, tuned], deletions: []).totals
    precondition(totals.cleaned == Int64(2.5e9) && totals.uninstalled == 4 && totals.optimized == 2)
    precondition(rateText(0.3524) == "352 KB/s" && rateText(12.34) == 12.3.formatted(.number.precision(.fractionLength(1))) + " MB/s")
    checkAISessions()
    checkCodexSessions()
    checkSoftwareUpdates()
    checkStartupItems()
    checkProcessGroups()
    checkTreemap()
    // 电池养护: charging pauses at the limit, resumes two points under it, and in between stays as it is.
    precondition(BatteryCare.shouldPause(mode: .limit, percent: 80, pausedNow: false) && BatteryCare.shouldPause(mode: .limit, percent: 100, pausedNow: false))
    precondition(BatteryCare.shouldPause(mode: .limit, percent: 79, pausedNow: true) && !BatteryCare.shouldPause(mode: .limit, percent: 79, pausedNow: false))
    precondition(!BatteryCare.shouldPause(mode: .limit, percent: 77, pausedNow: true))
    precondition(!BatteryCare.shouldPause(mode: .full, percent: 95, pausedNow: true) && !BatteryCare.shouldPause(mode: .off, percent: 100, pausedNow: true))
    precondition(SMC.layoutIsRight && SMC.read("no such key") == nil && SMC.read("XXXX") == nil)
    checkPrivacyNews()
    precondition(SystemLoad.usage(from: (100, 1000), to: (150, 1200)) == 0.25 && SystemLoad.usage(from: (1, 5), to: (1, 5)) == nil)
    precondition(SystemLoad.usage(from: (.max - 9, .max - 99), to: (40, 100)) == 0.25) // the counters wrapped around
    precondition(MenuBarGauge.percent(0.094) == "9%" && MenuBarGauge.percent(0.235) == "24%" && MenuBarGauge.percent(1.2) == "100%")
    // The network speed beside the icon: the busier direction, in at most five characters.
    precondition(MenuBarGauge.rate(down: 850_400, up: 1200) == "↓850K" && MenuBarGauge.rate(down: 0, up: 0) == "↓0K")
    precondition(MenuBarGauge.rate(down: 20_000, up: 1_240_000) == "↑1.2M" && MenuBarGauge.rate(down: 12_300_000, up: 0) == "↓12M" && MenuBarGauge.rate(down: 999_700, up: 0) == "↓1.0M")
    guard SystemLoad.networkBytes() != nil else { return "读不到网络流量计数" }
    precondition(leftoversLeftBehind())
    // The icon's right-click menu: a way to every page in the sidebar's order, then settings, about and
    // quit; and choosing a page there is what the main window shows.
    let chosen = await MainActor.run {
        let menu = StatusMenu.shared.menu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        let expected = ["打开 Kitty Clear"] + Page.allCases.filter { $0 != .settings }.map(\.rawValue) + ["设置…", "关于 Kitty Clear", "退出 Kitty Clear"]
        return titles == expected && menu.items.allSatisfy { $0.isSeparatorItem || ($0.image != nil && $0.target != nil && $0.representedObject != nil) }
    }
    guard chosen else { return "菜单栏图标的右键菜单内容不对" }
    // The colours of the readings: orange past 80% and red past 90% of what can be used up; a battery
    // the other way round; Mole's own words for its health score; and the worse of two signs wins.
    precondition([0.5, 0.8, 0.81, 0.9, 0.91, 1.2].map { Level(used: $0) } == [.fine, .fine, .high, .high, .critical, .critical])
    precondition([100, 21, 20, 11, 10, 0].map { Level(charge: $0) } == [.fine, .fine, .high, .high, .critical, .critical])
    precondition([98, 65, 64, 45, 44].map { Level(health: $0) } == [.fine, .fine, .high, .high, .critical] && [52, 80, 95].map { Level(heat: $0) } == [.fine, .high, .critical])
    precondition(max(Level.fine, .critical) == .critical && Level.high.ink != Level.fine.ink && Level.fine.ink == Theme.ink)
    // What the disk analysis measured is there again for ten minutes, per folder, until it is cleared.
    let kept = await MainActor.run {
        let (measured, taken) = (ScanResult(entries: [], totalSize: 42, largeFiles: nil), Date(timeIntervalSince1970: 1000))
        AnalysisCache.clear()
        AnalysisCache.keep(measured, for: "/a", now: taken)
        let fresh = AnalysisCache.scan(of: "/a", now: taken.addingTimeInterval(599))?.totalSize == 42 && AnalysisCache.scan(of: "/b", now: taken) == nil
        let stale = AnalysisCache.scan(of: "/a", now: taken.addingTimeInterval(601)) == nil
        AnalysisCache.clear()
        return fresh && stale && AnalysisCache.scan(of: "/a", now: taken) == nil
    }
    guard kept else { return "磁盘分析的缓存没有按预期保留和失效" }
    if let problem = await checkSystemLeftovers() { return problem }

    // The installer for the battery helper: both scripts are sound shell, and the job file the first one
    // writes (here to a throwaway path instead of /Library/LaunchDaemons) tells launchd the right things.
    let jobFile = "/private/tmp/kittyclear-job-\(UUID().uuidString).plist"
    defer { try? FileManager.default.removeItem(atPath: jobFile) }
    for script in [BatteryCareModel.installScript, BatteryCareModel.removeScript] {
        guard await runTool("/bin/sh", ["-n", "-c", script]).status == 0 else { return "电池助手的安装脚本有语法错误" }
    }
    let writing = BatteryCareModel.installScript.split(separator: "\n").filter { $0.contains("plutil") }.joined(separator: "\n")
        .replacing(BatteryCareModel.job, with: jobFile)
    let wrote = await runTool("/bin/sh", ["-c", "set -e\n" + writing, "sh", "/Applications/A B.app/helper", "/Users/a b/battery-care"])
    let job = NSDictionary(contentsOfFile: jobFile)
    guard wrote.status == 0, job?["Label"] as? String == BatteryCareModel.label, job?["RunAtLoad"] as? Bool == true, job?["KeepAlive"] as? Bool == true,
          job?["ProgramArguments"] as? [String] == [BatteryCareModel.helper, "/Users/a b/battery-care"]
    else { return "电池助手的启动文件写得不对：\(wrote.output) \(String(describing: job))" }

    // The charging switch can be read on a Mac that has one, and its reading and the battery's make sense.
    if Charging.canBePaused, Charging.isPaused == nil { return "读不到充电开关的状态" }
    if let battery = Charging.battery(), !(0...100).contains(battery.percent) { return "电池电量读出来是 \(battery.percent)%" }

    // What the app reads from the system itself: where a reading exists it has to be a sane one, and the
    // process list has to have this very process in it.
    if let gpu = Sensors.gpuUsage(), !(0...100).contains(gpu) { return "显卡占用读出来是 \(gpu)" }
    if let heat = Sensors.chipTemperature(), !(1...129).contains(heat) { return "芯片温度读出来是 \(heat)" }
    let running = await Processes.list()
    // "Kitty Clear" is the app as packaged, "KittyClear" the bare program that `swift build` makes.
    guard running.contains(where: { ["Kitty Clear", "KittyClear"].contains($0.name) && $0.memory > 0 }) else { return "进程列表里找不到 Kitty Clear 自己" }

    // The number in the menu bar is measured by the app itself; it has to tell the same story as Mole's.
    guard let ticks = SystemLoad.cpuTicks(), ticks.total >= ticks.busy, let memory = SystemLoad.memoryUsed(),
          let status: Snapshot = try? await Mole.json(["status", "--json"])
    else { return "读不到系统负载" }
    guard abs(memory * 100 - status.memory.usedPercent) < 5 else {
        return "菜单栏算出的内存占用是 \(Int(memory * 100))%，Mole 报的是 \(Int(status.memory.usedPercent))%"
    }

    if let problem = await checkStatusFeed() { return problem }
    return await Compatibility.outputProblem()
}

/// The status page and the menu bar panel read one feed: two viewers start a single `mo status --watch`,
/// the first snapshot they are shown is a whole one, and once both have gone the watch has stopped
/// while the readings stay for the next opening.
@MainActor private func checkStatusFeed() async -> String? {
    func watches() async -> Int {
        await runTool("/usr/bin/pgrep", ["-P", "\(getpid())", "-f", "status-go --watch"]).output.split(whereSeparator: \.isNewline).count
    }
    let feed = StatusFeed.shared
    let viewers = [Task { await feed.run() }, Task { await feed.run() }]
    for _ in 0..<100 where feed.snapshot == nil && !feed.failed { try? await Task.sleep(for: .milliseconds(100)) }
    guard let first = feed.snapshot else { return "状态数据流没有给出读数" }
    guard !first.hardware.cpuModel.isEmpty, !first.hardware.osVersion.isEmpty else { return "状态数据流给出的第一份读数不完整" }
    guard await watches() == 1 else { return "两个界面同时看状态时，mo status 应该只运行一份" }
    viewers.forEach { $0.cancel() }
    try? await Task.sleep(for: .seconds(1))
    guard await watches() == 0 else { return "没有界面在看状态了，mo status 还在运行" }
    // The cleaning totals are read beside the watch and take mo a second or several, depending on how busy the Mac is.
    for _ in 0..<200 where feed.history == nil { try? await Task.sleep(for: .milliseconds(100)) }
    return feed.snapshot == nil || feed.history == nil ? "状态数据流停下后没有留住最后的读数和清理统计" : nil
}

/// A list file gets extra lines for one run and comes back exactly as it was; when there was no file,
/// the fallback (Mole's defaults) goes in with them and the file is gone again afterwards.
private func checkListOverride() {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appending(path: "kittyclear-list-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: folder) }
    let saved = folder.appending(path: "saved"), missing = folder.appending(path: "sub/missing")
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try! Data("# mine\n/keep".utf8).write(to: saved)

    let first = try! ListOverride(saved, adding: ["/x", "/y"], fallback: ["/default"])
    precondition(try! Data(contentsOf: saved) == Data("# mine\n/keep\n/x\n/y\n".utf8))
    try! first.restore()
    precondition(try! Data(contentsOf: saved) == Data("# mine\n/keep".utf8))

    let second = try! ListOverride(missing, adding: ["/x"], fallback: ["/d1", "/d2"])
    precondition(try! Data(contentsOf: missing) == Data("/d1\n/d2\n/x\n".utf8))
    try! second.restore()
    precondition(!fm.fileExists(atPath: missing.path))

    // Two runs at once, in either order of finishing: each takes out its own lines only, so the other's
    // stay in force until it is done, and a line saved in between stays for good.
    func lines(_ file: URL) -> [String] { (try! String(contentsOf: file, encoding: .utf8)).split(separator: "\n").map(String.init) }
    let a = try! ListOverride(saved, adding: ["/a"], fallback: []), b = try! ListOverride(saved, adding: ["/b"], fallback: [])
    precondition(ListOverride.isActive(on: saved))
    try! a.restore()
    precondition(lines(saved) == ["# mine", "/keep", "/b"] && ListOverride.isActive(on: saved))
    try! Data((lines(saved) + ["/saved-meanwhile"]).joined(separator: "\n").utf8).write(to: saved)
    try! b.restore()
    precondition(lines(saved) == ["# mine", "/keep", "/saved-meanwhile"] && !ListOverride.isActive(on: saved))
    // A file made for the first of two runs is gone again once both are done, whichever ends first.
    for firstEnds in [true, false] {
        let c = try! ListOverride(missing, adding: ["/c"], fallback: ["/d1"]), d = try! ListOverride(missing, adding: ["/d"], fallback: [])
        try! (firstEnds ? c : d).restore()
        precondition(lines(missing) == (firstEnds ? ["/d1", "/d"] : ["/d1", "/c"]))
        try! (firstEnds ? d : c).restore()
        precondition(!fm.fileExists(atPath: missing.path) && !ListOverride.isActive(on: missing))
    }
}

/// The installer search takes disk images and packages up to two levels deep, opens zips to see whether
/// they hold an app, and leaves everything else alone.
private func checkInstallerScan() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "kittyclear-installers-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try! fm.createDirectory(at: root.appending(path: "sub/deep"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appending(path: "Foo.app"), withIntermediateDirectories: true)
    for (path, bytes) in [("big.dmg", 3000), ("sub/tool.pkg", 2000), ("sub/deep/buried.dmg", 9000), ("notes.txt", 10), ("Foo.app/x", 5)] {
        try! Data(count: bytes).write(to: root.appending(path: path))
    }
    try! fm.createSymbolicLink(at: root.appending(path: "link.dmg"), withDestinationURL: root.appending(path: "big.dmg"))
    for (archive, member) in [("app.zip", "Foo.app"), ("text.zip", "notes.txt")] {
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", archive, member]
        zip.currentDirectoryURL = root
        try! zip.run()
        zip.waitUntilExit()
    }
    let found = Installers.scan([("测试", root.path)])
    precondition(found.map(\.name) == ["big.dmg", "sub/tool.pkg", "app.zip"].map { ($0 as NSString).lastPathComponent },
                 "installer scan found \(found.map(\.name))")
    precondition(found[0].size == 3000 && found[0].place == "测试")
}

/// Only a conversation left alone long enough is offered, with everything that is its own and nothing
/// else: not the project's memory, not a newer conversation, not a file that is no conversation.
private func checkAISessions() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/kittyclear-ai-\(UUID().uuidString)") // a path with no symlink in it
    defer { try? fm.removeItem(at: root) }
    let project = root.appending(path: "projects/-Users-a-app")
    let old = "11111111-2222-3333-4444-555555555555", recent = "99999999-2222-3333-4444-555555555555"
    for folder in ["projects/-Users-a-app/\(old)/tool-results", "projects/-Users-a-app/memory", "file-history/\(old)", "file-history/\(recent)"] {
        try! fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
    }
    let transcript = """
        {"type":"user","isMeta":true,"message":{"content":"<note>not typed</note>"},"cwd":"/Users/a/app"}
        {"type":"user","message":{"content":[{"type":"text","text":"fix the\\nlogin page"}]}}
        {"type":"ai-title","aiTitle":"Login fix"}
        """
    let files = ["\(old).jsonl": transcript, "\(old)/tool-results/out.txt": "12345", "\(old).desktop-released.json": "",
                 "\(recent).jsonl": transcript, "notes.jsonl": "{}", "memory/MEMORY.md": "keep"]
    for (name, text) in files { try! Data(text.utf8).write(to: project.appending(path: name)) }
    try! Data("abc".utf8).write(to: root.appending(path: "file-history/\(old)/a@v1"))
    for name in ["\(old).jsonl", "notes.jsonl"] {
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: project.appending(path: name).path)
    }

    let found = AISessions.scan(olderThan: 30, in: root)
    precondition(found.count == 1 && found[0].title == "Login fix" && found[0].project == "/Users/a/app", "AI scan found \(found)")
    precondition(found[0].files.last?.lastPathComponent == "\(old).jsonl")
    precondition(Set(found[0].files.map(\.path)) == Set([
        "\(old).jsonl", "\(old)", "\(old).desktop-released.json"].map { project.appending(path: $0).path }
        + [root.appending(path: "file-history/\(old)").path]))
    precondition(found[0].size == Int64(transcript.utf8.count + 5 + 3))
    precondition(AISessions.scan(olderThan: 90, in: root).isEmpty)
    // Without a title of either kind, a conversation goes by the first thing that was asked.
    try! Data(transcript.split(separator: "\n").dropLast().joined(separator: "\n").utf8).write(to: project.appending(path: "notes.jsonl"))
    precondition(AISessions.describe(project.appending(path: "notes.jsonl")).title == "fix the login page")
}

/// A Codex conversation is offered together with the sub-agent conversations it started, only when all
/// of them are old; a fork the user made is a conversation of its own.
private func checkCodexSessions() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/kittyclear-codex-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func id(_ n: Int) -> String { "aaaaaaaa-0000-0000-0000-00000000000\(n)" }
    func rollout(_ n: Int, in folder: String = "sessions/2026/01/02", source: String = "\"vscode\"", more: String = "", days: Double = 40) {
        let file = root.appending(path: "\(folder)/rollout-2026-01-02T03-04-05-\(id(n)).jsonl")
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("""
            {"type":"session_meta","payload":{"id":"\(id(n))","cwd":"/Users/a/app","source":\(source)\(more)}}
            {"type":"response_item","payload":{"role":"user","content":[{"text":"<environment_context>zsh"},{"text":"# AGENTS.md instructions"}]}}
            {"type":"response_item","payload":{"role":"user","content":[{"text":"fix it \(n)"}]}}
            """.utf8).write(to: file)
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: file.path)
    }
    func spawned(by n: Int) -> String { "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(id(n))\"}}}" }
    rollout(1)
    rollout(2, source: spawned(by: 1))
    rollout(3, source: "{\"subagent\":{\"other\":\"guardian\"}}", more: ",\"forked_from_id\":\"\(id(1))\"")
    rollout(4, in: "archived_sessions")
    rollout(5)
    rollout(6, source: spawned(by: 5), days: 2) // its sub-agent was busy two days ago, so 5 is not old yet
    rollout(7, source: spawned(by: 0)) // what a conversation deleted earlier left behind
    rollout(8, source: "\"cli\"", more: ",\"forked_from_id\":\"\(id(1))\"")
    try! Data("{\"id\":\"\(id(4))\",\"thread_name\":\"Old name\"}\n{\"id\":\"\(id(4))\",\"thread_name\":\"Named\"}\n".utf8)
        .write(to: root.appending(path: "session_index.jsonl"))
    try! Data("{}".utf8).write(to: root.appending(path: "sessions/2026/01/02/notes.jsonl"))

    let found = Dictionary(uniqueKeysWithValues: CodexSessions.scan(olderThan: 30, in: root).map { ($0.threads[0], $0) })
    precondition(Set(found.keys) == Set([1, 4, 7, 8].map(id)), "Codex scan found \(found.keys.sorted())")
    let whole = found[id(1)]!
    precondition(Set(whole.threads) == Set([1, 2, 3].map(id)) && whole.files.map(\.lastPathComponent) == whole.threads.map { "rollout-2026-01-02T03-04-05-\($0).jsonl" })
    precondition(whole.title == "fix it 1" && whole.project == "/Users/a/app" && whole.tool == .codex)
    precondition(whole.size == whole.files.reduce(0) { $0 + AISessions.diskSize(of: $1) } && whole.size > 600)
    precondition(found[id(4)]!.title == "Named" && found[id(7)]!.title == "子任务留下的会话" && found[id(8)]!.threads == [id(8)])
    precondition(CodexSessions.scan(olderThan: 90, in: root).isEmpty)
}

/// What the three update sources send back is read correctly, and a release this Mac cannot run, a beta
/// or a patch is never taken for an update.
private func checkSoftwareUpdates() {
    let brew = try! Updates.homebrewUpdates(in: Data("""
        {"formulae":[{"name":"git","installed_versions":["2.54.0"],"current_version":"2.56.0_1","pinned":false,"pinned_version":null},
                     {"name":"node","installed_versions":["20.0"],"current_version":"22.0","pinned":true,"pinned_version":"20.0"}],
         "casks":[{"name":"iterm2","installed_versions":"3.6.11","current_version":"3.7.4"}]}
        """.utf8))
    precondition(brew.map(\.name) == ["iterm2", "git"] && brew.map(\.source) == [.cask, .formula]) // apps before tools
    precondition(brew[1].installed == "2.54.0" && brew[1].latest == "2.56.0_1" && brew[0].installed == "3.6.11")

    func app(_ bundleID: String, _ version: String) -> Updates.App {
        Updates.App(url: URL(fileURLWithPath: "/Applications/\(bundleID).app"), name: bundleID, bundleID: bundleID,
                    version: version, build: version, feed: nil, fromAppStore: true)
    }
    let store = try! Updates.appStoreUpdates(for: [app("a", "1.0"), app("b", "2.5.0"), app("c", "26.3"), app("d", "1.0")], in: Data("""
        {"resultCount":3,"results":[{"bundleId":"a","version":"1.1","trackId":42,"minimumOsVersion":"13.0"},
          {"bundleId":"b","version":"2.5.0","trackId":43,"minimumOsVersion":"10.14"},
          {"bundleId":"c","version":"27.0","trackId":44,"minimumOsVersion":"26.6"}]}
        """.utf8), system: "15.6.0")
    precondition(store.updates.map(\.name) == ["a"] && store.updates[0].latest == "1.1" && store.known == ["a", "b", "c"])
    precondition(store.updates[0].source == .appStore(URL(string: "macappstore://apps.apple.com/app/id42")!))
    precondition(Updates.runs(on: "15.6.0", minimum: "15.6") && Updates.runs(on: "15.6.0", minimum: nil) && !Updates.runs(on: "15.6.0", minimum: "15.6.1"))

    let feed = Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:minimumSystemVersion>12.4</sparkle:minimumSystemVersion>
          <enclosure url="a.zip" sparkle:version="310" sparkle:shortVersionString="3.1"/></item>
        <item><sparkle:version>320</sparkle:version><sparkle:shortVersionString>3.2</sparkle:shortVersionString>
          <sparkle:deltas><enclosure url="d.delta" sparkle:version="999" sparkle:deltaFrom="310"/></sparkle:deltas>
          <enclosure url="b.zip"/></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure url="c.zip" sparkle:version="400" sparkle:shortVersionString="4.0b1"/></item>
        <item><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="e.zip" sparkle:version="500"/></item>
        <item><enclosure url="w.exe" sparkle:version="600" sparkle:os="windows"/></item>
        </channel></rss>
        """.utf8)
    let newest = Updates.newest(inAppcast: feed, system: "15.6.0")
    precondition(newest?.build == "320" && newest?.version == "3.2", "appcast gave \(String(describing: newest))")
    precondition(Updates.newest(inAppcast: feed, system: "26.1.0")?.build == "500")
    precondition(Updates.newest(inAppcast: Data("not a feed".utf8)) == nil)
}

/// The map's rectangles fill the space exactly, each as large as its share, none outside or overlapping,
/// and none a sliver when the sizes allow squares.
/// 隐私提醒 speaks when the camera or the microphone comes on or another app starts recording, names the
/// app when there is a name, keeps quiet about an app the user muted, and says nothing when things stop.
private func checkPrivacyNews() {
    typealias Usage = PrivacyWatch.Usage
    let idle = Usage()
    func news(_ before: Usage, _ now: Usage, muted: Set<String> = []) -> String? { PrivacyWatch.news(from: before, to: now, muted: muted)?.text }
    let call = Usage(camera: true, microphone: true, apps: ["微信"])
    precondition(news(idle, call) == "微信 正在使用摄像头和麦克风" && PrivacyWatch.news(from: idle, to: call, muted: [])?.app == "微信")
    precondition(news(idle, Usage(camera: true)) == "摄像头正在使用" && news(idle, Usage(microphone: true)) == "麦克风正在使用")
    precondition(news(call, call) == nil && news(call, idle) == nil && news(call, Usage(microphone: true, apps: ["微信"])) == nil)
    // A second app joining is news about that app alone; two at once are named together and cannot be muted in one tap.
    let both = Usage(microphone: true, apps: ["微信", "Zoom"])
    precondition(news(Usage(microphone: true, apps: ["微信"]), both) == "Zoom 正在使用麦克风")
    precondition(news(idle, both) == "Zoom、微信 正在使用麦克风" && PrivacyWatch.news(from: idle, to: both, muted: [])?.app == nil)
    // Muted: no word about that app's recording, but its camera coming on is still said, without the name.
    precondition(news(idle, Usage(microphone: true, apps: ["微信"]), muted: ["微信"]) == nil && news(idle, both, muted: ["微信"]) == "Zoom 正在使用麦克风")
    precondition(news(idle, call, muted: ["微信"]) == "摄像头正在使用")
    precondition(Privacy.appName(ofProgram: "/usr/libexec/corespeechd") == nil)
    precondition(Privacy.appName(ofProgram: "/nowhere/My Tool.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "My Tool")
}

private func checkTreemap() {
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
    let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let rects = Treemap.layout(weights, in: bounds)
    precondition(rects.count == weights.count)
    for (rect, weight) in zip(rects, weights) {
        precondition(abs(rect.width * rect.height - weight / 24 * 240_000) < 1, "area of \(rect) for \(weight)")
        precondition(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect) && max(rect.width / rect.height, rect.height / rect.width) < 4)
    }
    for (index, rect) in rects.enumerated() {
        precondition(!rects[(index + 1)...].contains { $0.insetBy(dx: 0.01, dy: 0.01).intersects(rect.insetBy(dx: 0.01, dy: 0.01)) })
    }
    precondition(Treemap.layout([], in: bounds).isEmpty && Treemap.layout([0, 0], in: bounds).isEmpty && Treemap.layout([1], in: bounds) == [bounds])
    precondition(BlockKind(name: "Xcode.app", isFolder: true) == .app && BlockKind(name: ".cache", isFolder: true) == .hidden)
    precondition(BlockKind(name: "Movies", isFolder: true) == .folder && BlockKind(name: "a.MOV", isFolder: false) == .media)
    precondition(BlockKind(name: "disk.dmg", isFolder: false) == .archive && BlockKind(name: "README", isFolder: false) == .other)
}

/// An app's helpers are counted into the app, the app's own process is the one to quit, and a program
/// outside any app stands alone, however many copies of it run.
private func checkProcessGroups() {
    let listing = """
          501  12.5  2048 /Applications/My App.app/Contents/MacOS/My App
          502   2.5  1024 /Applications/My App.app/Contents/Frameworks/My App Helper (Renderer).app/Contents/MacOS/My App Helper (Renderer)
          161  35.0  4096 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          700   0.0   512 /usr/libexec/mdworker_shared
          701   1.0   512 /usr/libexec/mdworker_shared
        not a process line
        """
    // The memory figure comes from the system when it gives one (here only for 501), else from the listing.
    let groups = Processes.groups(in: listing) { $0 == 501 ? 9_000_000 : nil }
    let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
    precondition(Set(byName.keys) == ["My App", "WindowServer", "mdworker_shared"], "process groups: \(byName.keys.sorted())")
    let app = byName["My App"]!
    precondition(app.id == "/Applications/My App.app" && app.isApp && app.pid == 501 && app.count == 2 && app.cpu == 15)
    precondition(app.memory == 9_000_000 + 1024 * 1024)
    let workers = byName["mdworker_shared"]!
    precondition(!workers.isApp && workers.count == 2 && workers.pid == 700 && workers.memory == 2 * 512 * 1024 && workers.cpu == 1)
    // Small and idle is left out of the list; busy or big is not.
    precondition(byName["WindowServer"]!.isMinor == false && !workers.isMinor && Processes.groups(in: "  9 0.2 900 /usr/libexec/idle\n")[0].isMinor)
    precondition(!Processes.groups(in: "  9 0.0 20000 /usr/libexec/big\n")[0].isMinor)

    let table = """
            1     0 root    01-16:10:41 /sbin/launchd
          116     1 root    01-16:10:39 /System/Library/Frameworks/Metadata.framework/Support/mds
          501     1 yy         03:05:12 /Applications/My App.app/Contents/MacOS/My App
          502   501 yy            07:30 /Applications/My App.app/Contents/Frameworks/My App Helper.app/Contents/MacOS/My App Helper
          503   501 yy               0:09 /usr/bin/some tool
        """
    let helper = Processes.family(of: 502, in: table)!
    precondition(helper.user == "yy" && helper.running == "7 分钟" && helper.children == 0)
    precondition(helper.ancestors.map(\.pid) == [1, 501, 502] && helper.ancestors.map(\.name) == ["launchd", "My App", "My App Helper"])
    let parent = Processes.family(of: 501, in: table)!
    precondition(parent.children == 2 && parent.running == "3 小时 5 分" && Processes.family(of: 116, in: table)!.running == "1 天 16 小时")
    precondition(Processes.family(of: 503, in: table)!.running == "不到 1 分钟" && Processes.family(of: 999, in: table) == nil)
    let domain = "\tservices = {\n\t\t       0      - \tcom.example.idle\n\t\t     116      - \tcom.apple.metadata.mds\n\t\t    1160      - \tcom.example.other\n\t}\n"
    precondition(Processes.job(runningAs: 116, in: domain) == "com.apple.metadata.mds" && Processes.job(runningAs: 16, in: domain) == nil)
    let job = Processes.properties(ofJob: """
        system/com.apple.metadata.mds = {
        \tpath = /System/Library/LaunchDaemons/com.apple.metadata.mds.plist
        \ttype = LaunchDaemon
        \timmediate reason = speculative
        \tenvironment = {
        \t\tPATH => /usr/bin
        \t}
        \tproperties = keepalive | runatload
        }
        """)
    precondition(job["path"] == "/System/Library/LaunchDaemons/com.apple.metadata.mds.plist" && job["type"] == "LaunchDaemon")
    precondition(job["immediate reason"] == "speculative" && job["properties"]?.contains("keepalive") == true)

    precondition(Trash.isRefusal(CocoaError(.fileWriteNoPermission)) && Trash.isRefusal(POSIXError(.EPERM)))
    precondition(!Trash.isRefusal(CocoaError(.fileNoSuchFile)) && !Trash.isRefusal(POSIXError(.ENOENT)))
}

/// launchd's listings and job files are read correctly: its own switch beats a file's `Disabled` key, and
/// a job that points nowhere or says nothing is told apart from a healthy one.
private func checkStartupItems() {
    let switches = StartupItems.switches(in: """
        \tdisabled services = {
        \t\t"com.example.off" => disabled
        \t\t"com.example.back-on" => enabled
        \t}
        """)
    precondition(switches == ["com.example.off": true, "com.example.back-on": false])
    let running = StartupItems.running(in: "PID\tStatus\tLabel\n549\t0\tcom.example.app\n-\t1\tcom.example.off\n")
    precondition(running == ["com.example.app"])

    let fm = FileManager.default
    let folder = URL(fileURLWithPath: "/private/tmp/kittyclear-jobs-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: folder) }
    try! fm.createDirectory(at: folder.appending(path: "Tool.app/Contents/MacOS"), withIntermediateDirectories: true)
    let tool = folder.appending(path: "Tool.app/Contents/MacOS/tool").path
    try! Data().write(to: URL(fileURLWithPath: tool))
    func job(_ name: String, _ contents: [String: Any]) -> StartupItem {
        let file = folder.appending(path: "\(name).plist")
        try! PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: file)
        return StartupItems.job(at: file, kind: .mine, switches: switches, running: running)
    }
    let healthy = job("a", ["Label": "com.example.app", "ProgramArguments": [tool, "--serve"]])
    precondition(healthy.running && !healthy.disabled && !healthy.missing && healthy.app?.lastPathComponent == "Tool.app")
    precondition(healthy.name == "Tool" && healthy.detail == "com.example.app")
    let gone = job("b", ["Label": "com.example.off", "Program": "/nowhere/helper"])
    precondition(gone.disabled && gone.missing && !gone.running && gone.name == "com.example.off")
    precondition(job("c", ["Label": "com.example.back-on", "Program": tool, "Disabled": true]).disabled == false)
    precondition(job("d", ["Label": "com.example.other", "Program": tool, "Disabled": true]).disabled)
    let empty = job("com.example.empty", [:])
    precondition(empty.label == "com.example.empty" && empty.program == nil && !empty.missing && empty.detail.contains("没有写明"))

    let opened = StartupItems.loginItems(in: "Tool\t\(folder.path)/Tool.app\nGone\t/nowhere/Gone.app\nNameless\t\n")
    precondition(opened.map(\.label) == ["Tool", "Gone", "Nameless"] && opened.map(\.missing) == [false, true, false])
    precondition(opened[0].kind == .opened && opened[0].app?.lastPathComponent == "Tool.app" && opened[2].program == nil)
}

/// A checked download becomes the engine for its version, older ones go, and only an engine newer than
/// the bundled one whose folder name matches its launcher is ever picked up.
private func checkEngineStore() {
    let fm = FileManager.default
    let store = fm.temporaryDirectory.appending(path: "kittyclear-store-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: store) }
    for (folder, version) in [("9.9.9.incoming", "9.9.9"), ("1.0.0", "1.0.0"), ("8.8.8", "7.7.7")] {
        let launcher = store.appending(path: "\(folder)/mole")
        try! fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/bash\nVERSION=\"\(version)\"\n".utf8).write(to: launcher)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    }
    precondition(Updater.installed(newerThan: "0.1.0", in: store) == store.appending(path: "1.0.0/mole").path)
    let active = try! Updater.activate("9.9.9", in: store)
    precondition(active == store.appending(path: "9.9.9/mole").path && Mole.version(of: active) == "9.9.9")
    precondition(try! fm.contentsOfDirectory(atPath: store.path) == ["9.9.9"])
    precondition(Updater.installed(newerThan: "1.59.1", in: store) == active)
    precondition(Updater.installed(newerThan: nil, in: store) == active)
    precondition(Updater.installed(newerThan: "9.9.9", in: store) == nil)
}

/// `--selfcheck-update`: downloads the latest Mole the way the in-app upgrade does, verifies it and runs
/// the compatibility checks against it, then throws it away. The engine in use is not touched.
private func updateSelfCheck() async -> String? {
    do {
        let latest = try await Updater.latestVersion()
        let candidate = try await Updater.download(latest)
        let problem = await Compatibility.problem(with: candidate)
        Updater.discard(latest)
        print("Mole \(latest) downloaded and verified")
        return problem
    } catch {
        return error.localizedDescription
    }
}

/// `--selfcheck-software`: asks the real update sources, as the 软件更新 page does, and prints what they
/// answer. Homebrew's catalog gets refreshed; nothing is installed.
private func softwareSelfCheck() async -> String? {
    let found = await Updates.check()
    for update in found.updates { print("\(update.source.label)\t\(update.name)\t\(update.installed) → \(update.latest)") }
    return found.problems.isEmpty ? nil : found.problems.joined(separator: " ")
}

/// `--selfcheck-codex`: copies the smallest Codex conversation on this Mac, one with sub-agents if there
/// is any, into a throwaway Codex home under new ids, and removes the copy the way the AI 工具 page does. The real one is not touched: even if
/// `codex` ignored the throwaway home, it would be asked for ids that exist nowhere else.
private func codexSelfCheck() async -> String? {
    let fm = FileManager.default
    guard CodexSessions.canDelete else { return "这台 Mac 上没有带 delete 命令的 codex" }
    let all = CodexSessions.scan(olderThan: 0).sorted { $0.size < $1.size }
    guard let real = all.first(where: { $0.threads.count > 1 }) ?? all.first else { return "没有可以拿来试的 Codex 会话" }
    let home = URL(fileURLWithPath: "/private/tmp/kittyclear-selfcheck-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    do {
        let fresh = Dictionary(uniqueKeysWithValues: real.threads.map { ($0, UUID().uuidString.lowercased()) })
        for file in real.files {
            var name = file.lastPathComponent, text = try String(contentsOf: file, encoding: .utf8)
            for (old, new) in fresh { (name, text) = (name.replacing(old, with: new), text.replacing(old, with: new)) }
            let copy = home.appending(path: "sessions/2026/01/02/\(name)")
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: copy)
        }
        let copies = CodexSessions.scan(olderThan: -1, in: home)
        guard copies.count == 1, Set(copies[0].threads) == Set(fresh.values) else { return "复制出来的会话读不回来" }
        guard CodexSessions.delete(copies[0], home: home.path) else { return "codex delete 没有删掉复制出来的会话" }
        guard CodexSessions.scan(olderThan: -1, in: home).isEmpty else { return "删除之后还能扫到复制出来的会话" }
        guard real.files.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return "真实的会话文件不见了" }
        print("codex delete removed a copy of \(real.threads.count) conversation(s), \(real.size.formatted(byteFormat))")
        return nil
    } catch {
        return error.localizedDescription
    }
}

struct KittyClearApp: App {
    static let mainWindow = "main"
    /// Read by Settings too, where the switch is.
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var gauge = MenuBarGauge()

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)

        // Closing the main window leaves the app running, with this as the way back in.
        MenuBarExtra(isInserted: $menuBarIcon) {
            MenuBarPanel()
        } label: {
            Image(nsImage: gauge.image).accessibilityLabel("Kitty Clear")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case status = "状态"
    case clean = "清理"
    case uninstall = "卸载"
    case updates = "软件更新"
    case loginItems = "登录项"
    case installers = "安装包"
    case analyze = "磁盘分析"
    case optimize = "优化"
    case purge = "项目清理"
    case ai = "AI 工具"
    case history = "历史"
    case settings = "设置"

    var id: Self { self }

    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .uninstall: "trash"
        case .analyze: "chart.pie"
        case .optimize: "wrench.and.screwdriver"
        case .purge: "shippingbox"
        case .installers: "archivebox"
        case .updates: "arrow.down.circle"
        case .loginItems: "power"
        case .ai: "bubble.left.and.bubble.right"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// The main window, as seen from outside it: which page it shows, and how to bring it up. The menu bar
/// icon's menu sends people straight to a page.
@Observable @MainActor
final class MainWindow {
    static let shared = MainWindow()
    var page = Page.status
    /// SwiftUI's way of opening the window when it has been closed, handed over by a view that has it.
    var open: (() -> Void)?

    /// Brings the window forward: out of the Dock, or as a new window when it was closed. In menu-bar-
    /// only mode the Dock icon has to come back first.
    func show(_ page: Page? = nil) {
        if let page { self.page = page }
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if let open {
            open()
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL) // asks the app to reopen, which makes SwiftUI put up a window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @Environment(\.openWindow) private var openWindow
    private let window = MainWindow.shared
    @State private var clean = CleanModel(job: .clean)
    @State private var purge = CleanModel(job: .purge)
    @State private var optimize = Runner()
    @State private var uninstall = Runner()
    @State private var engine = EngineModel()
    @State private var updates = UpdatesModel()

    var body: some View {
        Group {
            if Mole.binary == nil {
                Stage(size: .hero) {
                    Hero(title: "缺少清理引擎", text: "这个 Kitty Clear 里没有内置 Mole，本机也没有安装。\n用 build-app.sh 重新打包，或先运行 brew install mole。") {}
                }
            } else {
                HStack(spacing: 0) {
                    Sidebar(page: Binding(get: { window.page }, set: { window.page = $0 }))
                    detail
                }
            }
        }
        .onAppear { window.open = { openWindow(id: KittyClearApp.mainWindow) } }
        .frame(minWidth: 920, minHeight: 640)
        .background(Sky().dragsWindow())
        .ignoresSafeArea()
        // The window is the icon, in every appearance: a bright sky with a cream card.
        .preferredColorScheme(.light)
        .tint(Theme.shine)
    }

    @ViewBuilder private var detail: some View {
        switch window.page {
        case .status:
            StatusView()
        case .uninstall:
            UninstallView(runner: uninstall)
        case .analyze:
            AnalyzeView()
        case .clean:
            CleanView(model: clean)
        case .installers:
            InstallersView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView(engine: engine)
        case .optimize:
            OptimizeView(runner: optimize)
        case .purge:
            CleanView(model: purge)
        case .updates:
            UpdatesView(model: updates)
        case .loginItems:
            LoginItemsView()
        case .ai:
            AIView()
        }
    }
}

/// Navigation written straight onto the sky; the current page is a slip of the cream card.
private struct Sidebar: View {
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Kitty Clear")
                .font(Theme.display(17))
                .foregroundStyle(.white)
                .padding(.leading, 12)
                .padding(.bottom, 16)
            ForEach(Page.allCases.filter { $0 != .settings }) { item in
                link(to: item)
            }
            Spacer()
            link(to: .settings)
        }
        .padding(.top, 56)
        .padding(.bottom, 16)
        .padding(.horizontal, 12)
        .frame(width: 176)
    }

    private func link(to item: Page) -> some View {
        let selected = item == page
        return Button {
            page = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .foregroundStyle(selected ? Theme.shine : .white)
                    .frame(width: 20)
                Text(item.rawValue).foregroundStyle(selected ? Theme.ink : .white)
            }
            .font(Theme.text(14, .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.cream : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Renders `mo`'s report on the card: `➤` lines become section headers, `====` rules become dividers.
struct LogView: View {
    let lines: [Runner.Line]

    var body: some View {
        ScrollViewReader { proxy in
            List(lines) { line in
                LogRow(text: line.text)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 20)
            .onChange(of: lines.count) {
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }
}

private struct LogRow: View {
    let text: String

    var body: some View {
        if text.hasPrefix("➤") {
            Text(zh(text.dropFirst().trimmingCharacters(in: .whitespaces)))
                .font(Theme.text(14, .semibold))
                .padding(.top, 10)
        } else if text.hasPrefix("====") {
            Rule()
        } else {
            Text(text)
                .font(Theme.text(12.5))
                .foregroundStyle(text.contains("✓") ? Theme.inkSoft : Theme.ink)
                .textSelection(.enabled)
        }
    }
}

/// The script that moves ticked system leftovers, tried out without administrator rights on a throwaway
/// tree that stands in for the disk: it takes what lies in the allowed folders, by where the path really
/// leads, and nothing else. Returns what is wrong, or nil.
func checkSystemLeftovers() async -> String? {
    let fm = FileManager.default
    guard await runTool("/bin/sh", ["-n", "-c", SystemLeftovers.script]).status == 0 else { return "移走系统级残留的脚本有语法错误" }
    for good in ["/Library/LaunchDaemons/com.x.plist", "/Library/Application Support/Avid/Sibelius", "/private/var/db/receipts/com.x.bom"] {
        precondition(SystemLeftovers.isOffered(good))
    }
    for bad in ["/Library/LaunchDaemons/", "/Library/Extensions/x.kext", "/System/Library/x", "/Users/a/Library/Caches/x", "/Library/Caches/../x", "/Library/Caches//x"] {
        precondition(!SystemLeftovers.isOffered(bad))
    }
    let root = URL(fileURLWithPath: "/private/tmp/kittyclear-system-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let staging = root.appending(path: "staging")
    do {
        for folder in ["Library/LaunchDaemons", "Library/Application Support/Example", "Library/Extensions", "Library/Caches", "elsewhere", "staging"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["Library/LaunchDaemons/com.x.plist", "Library/Application Support/Example/data", "Library/Extensions/x.kext", "elsewhere/mine.txt"] {
            try Data("x".utf8).write(to: root.appending(path: file))
        }
        // A folder among the caches that is really a link to somewhere else: what is in it is not the system's.
        try fm.createSymbolicLink(at: root.appending(path: "Library/Caches/link"), withDestinationURL: root.appending(path: "elsewhere"))
    } catch {
        return "没能搭起测试目录：\(error.localizedDescription)"
    }
    func at(_ path: String) -> String { root.path + path }
    let paths = ["/Library/LaunchDaemons/com.x.plist", "/Library/Application Support/Example", "/Library/Extensions/x.kext", "/Library/Caches/link/mine.txt",
                 "/Library/Caches/missing", "/Library/Caches/..", "/elsewhere/mine.txt"].map(at)
    let ran = await runTool("/bin/sh", ["-c", SystemLeftovers.script, "sh", "\(getuid())", staging.path, root.path] + paths)
    let said = SystemLeftovers.outcomes(of: ran.output)
    guard ran.status == 0, said.count == paths.count else { return "移走系统级残留的脚本没有逐项回答：\(ran.output)" }
    guard said[paths[0]]?.word == "MOVED", said[paths[1]]?.word == "MOVED", said[paths[0]]?.moved == staging.path + "/com.x.plist" else { return "该移走的系统级残留没有移走" }
    guard said[paths[2]]?.word == "REFUSED", said[paths[3]]?.word == "REFUSED", said[paths[5]]?.word == "REFUSED", said[paths[6]]?.word == "REFUSED", said[paths[4]]?.word == "GONE"
    else { return "不该碰的路径没有被拒绝：\(ran.output)" }
    guard fm.fileExists(atPath: staging.path + "/com.x.plist"), fm.fileExists(atPath: staging.path + "/Example/data"), !fm.fileExists(atPath: paths[0]),
          fm.fileExists(atPath: at("/Library/Extensions/x.kext")), fm.fileExists(atPath: at("/elsewhere/mine.txt")), fm.fileExists(atPath: at("/Library/Caches"))
    else { return "移走系统级残留之后，文件不在该在的地方" }
    // The list keeps the score: what went counts as moved, what did not says why.
    var listed = UninstallPreview(log: ["Files to be removed:", "◎ A , 1MB", "  ✓ /Applications/A.app , 1MB", "  ◎ Review only: /Library/LaunchDaemons/a.plist",
                                        "  ◎ Review only: /Library/Preferences/a.plist", "  ◎ Review only: /Library/Extensions/a.kext", "➤ Remove 1 app"])
    precondition(listed.apps[0].files.map(\.isOffered) == [false, true, true, false])
    listed.record(["/Library/LaunchDaemons/a.plist": nil, "/Library/Preferences/a.plist": "没能移走"])
    precondition(listed.moved == 2 && listed.left == 2 && listed.apps[0].files[2].kept == "没能移走")
    return nil
}

/// What mo lists and leaves in the system's folders is counted apart from what goes to the Trash.
private func leftoversLeftBehind() -> Bool {
    let listed = UninstallPreview(log: ["Files to be removed:", "◎ A , 1MB", "  ✓ /Applications/A.app , 1MB", "  ◎ Review only: /private/var/db/receipts/a.bom , 4KB",
                                        "  ◎ Review only: /Library/LaunchDaemons/a.plist", "➤ Remove 1 app"])
    return listed.moved == 1 && listed.left == 2
}
