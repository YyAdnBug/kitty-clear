import Foundation

/// The paths `mo clean` must never touch. It is read through Mole's own loader, so the app shows
/// exactly what a clean will enforce, and saved to the file Mole reads (`~/.config/mole/whitelist`).
struct Whitelist {
    /// The entries that can be removed: the saved list, or Mole's defaults while nothing is saved.
    private(set) var entries: [String] = []
    /// Protections built into Mole. They hold whatever the list says, so they are shown but stay.
    private(set) var builtIn: [String] = []
    /// False while Mole's defaults are in effect because the user has not saved a list yet.
    private(set) var isSaved = false
    private var defaults: [String] = []
    private let home: String
    private let engine: String?
    private var file: URL { URL(fileURLWithPath: home).appending(path: ".config/mole/whitelist") }

    init(home: String = Mole.home, engine: String? = nil) throws {
        self.home = home
        self.engine = engine
        try reload()
    }

    /// Mole silently drops list lines it considers malformed or system-protected, so the app refuses them
    /// up front instead of promising a protection that would not hold.
    static func accepts(_ pattern: String) -> Bool {
        pattern.hasPrefix("/") && !pattern.contains("..") && !pattern.contains("//")
            && !pattern.contains("$HOME") && !pattern.contains("${HOME}")
            && pattern == pattern.trimmingCharacters(in: .whitespaces)
            && !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/etc/", "/var/db/"].contains(where: pattern.hasPrefix)
    }

    /// Starts protecting `pattern`: a path, where `*` matches anything. The first change also saves
    /// Mole's defaults, because a saved list replaces them.
    mutating func add(_ pattern: String) throws {
        guard Self.accepts(pattern) else { throw Failure("这个路径不能加入保护名单：\(pattern)") }
        guard !entries.contains(pattern), !builtIn.contains(pattern) else { return }
        try save(savedLines() + [pattern])
    }

    mutating func remove(_ pattern: String) throws {
        try save(savedLines().filter { resolved($0) != pattern })
    }

    /// Protects `paths` for the length of one run, on top of whatever is in force now.
    static func temporarily(protecting paths: Set<String>, home: String = Mole.home, engine: String? = nil) throws -> ListOverride {
        let current = try Whitelist(home: home, engine: engine)
        guard paths.allSatisfy(accepts) else { throw Failure("有路径不能加入保护名单") }
        return try ListOverride(current.file, adding: paths.sorted(), fallback: current.isSaved ? [] : current.entries)
    }

    /// Goes back to Mole's defaults. The saved list is moved to the Trash, not deleted.
    mutating func reset() throws {
        try waitForRuns()
        if isSaved { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        try reload()
    }

    /// The saved file's lines as they are, comments included, or Mole's defaults when nothing is saved.
    private func savedLines() throws -> [String] {
        guard isSaved else { return defaults }
        return try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// A list line the way Mole reads it: trimmed, with `~` and `$HOME` expanded.
    private func resolved(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("~") { line = home + line.dropFirst() }
        return line.replacing("${HOME}", with: home).replacing("$HOME", with: home)
    }

    /// A clean that is running keeps what was unchecked for it in this very file. Changing the file under
    /// it could end that protection half way, so the list is not to be edited until the run is over.
    private func waitForRuns() throws {
        if ListOverride.isActive(on: file) { throw Failure("有清理正在进行，它正借用这份名单保住没勾选的条目。等它结束再改。") }
    }

    private mutating func save(_ lines: [String]) throws {
        try waitForRuns()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try reload()
    }

    /// Asks Mole's own loader what is in force.
    private mutating func reload() throws {
        let output = try Mole.ask("lib/core/base.sh", #"""
            load_mole_whitelist "$HOME" || exit 1
            printf 'E %s\n' "${WHITELIST_PATTERNS[@]}"
            printf 'S %s\n' "${SAFETY_WHITELIST_PATTERNS[@]}"
            printf 'D %s\n' "${DEFAULT_WHITELIST_PATTERNS[@]}"
            """#, engine: engine, home: home)

        // Only real paths: Mole also lists an internal marker that is not one.
        func paths(_ tag: String) -> [String] {
            output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(tag + " /") }.map { String($0.dropFirst(2)) }
        }
        builtIn = paths("S")
        entries = paths("E").filter { !builtIn.contains($0) }
        defaults = paths("D").filter { !builtIn.contains($0) }
        isSaved = FileManager.default.fileExists(atPath: file.path)
    }
}
