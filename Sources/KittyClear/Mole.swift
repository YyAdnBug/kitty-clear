import Foundation
import Observation

/// Thin wrapper around the Mole CLI (tw93/mole, GPL-3.0).
/// `mo` is the engine: KittyClear only launches it as a separate process and renders its output.
enum Mole {
    /// The copy of Mole that build-app.sh puts inside the app, so nothing else has to be installed.
    static let bundled = Bundle.main.resourceURL.map { $0.appending(path: "mole/mole").path }
        .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }

    /// The engine in use: an in-app upgrade newer than the bundled copy, else the bundled copy, else an
    /// installed `mo` when running outside the app bundle (`swift run`).
    static private(set) var binary = Updater.installed(newerThan: bundled.flatMap(version(of:)))
        ?? bundled
        ?? ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", NSHomeDirectory() + "/.local/bin/mo"]
        .first(where: FileManager.default.isExecutableFile(atPath:))

    /// Switches to an engine that has just passed its checks. Commands started from now on use it.
    static func use(_ engine: String) { binary = engine }

    /// "1.59.1": every Mole launcher carries a `VERSION="…"` line, which its own installer reads too.
    static func version(of launcher: String) -> String? {
        (try? String(contentsOfFile: launcher, encoding: .utf8))?
            .firstMatch(of: #/(?m)^VERSION="([^"]+)"$/#).map { String($0.1) }
    }

    /// The HOME `mo` runs with. It decides where `mo` keeps its config, so KittyClear reads the same one.
    static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A file inside the engine, e.g. `lib/core/base.sh`. Mole's launcher sits either beside `lib` or, in
    /// a Homebrew install, beside `libexec/lib`.
    static func library(_ file: String, engine: String? = nil) -> String? {
        let folder = URL(fileURLWithPath: engine ?? binary ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
        return [file, "../libexec/" + file]
            .map { folder.appending(path: $0).standardizedFileURL.path }
            .first(where: FileManager.default.fileExists(atPath:))
    }

    /// Runs a few lines of bash against one of the engine's own library files (`$1`) and returns its
    /// output. This is how the app reads Mole's lists and catalogs instead of keeping copies of them.
    static func ask(_ file: String, _ script: String, engine: String? = nil, home: String? = nil) throws -> String {
        guard let library = library(file, engine: engine) else { throw Failure("在 Mole 里找不到 \(file)") }
        let bash = Process()
        let out = Pipe()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", "source \"$1\" || exit 1\n" + script, "bash", library]
        bash.environment = ["HOME": home ?? Self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1"]
        bash.standardOutput = out
        bash.standardError = FileHandle.nullDevice
        try bash.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        bash.waitUntilExit()
        guard bash.terminationStatus == 0 else { throw Failure("Mole 的 \(file) 没能读出来") }
        return output
    }

    /// Says in plain words why a page could not show what `mo` returned.
    static func describe(_ error: Error) -> String {
        error is DecodingError ? "Mole 返回的数据和这一版 Kitty Clear 预期的格式不一样。可以到设置里看看引擎版本。" : error.localizedDescription
    }

    struct ExitError: LocalizedError {
        let code: Int32
        var errorDescription: String? { "退出码 \(code)" }
    }

    /// How `mo clean` gets to ask for administrator rights. Run without a terminal it never asks, and
    /// quietly skips everything that needs them. This sources Mole's own clean script (`$1`), lets Mole
    /// put up its own password dialog, and then runs the script's entry point in that same shell,
    /// because without a terminal macOS honours the authorisation only for the shell that obtained it.
    private static let adminClean = #"""
        source "$1" || exit 1
        shift
        request_sudo_access "Kitty Clear 要清理系统缓存，需要管理员权限" || true
        main "$@"
        """#

    /// `engine` and `home` default to the engine in use and the real HOME; the compatibility checks
    /// pass their own to try a candidate engine in a throwaway HOME.
    private static func process(
        _ args: [String], engine: String?, home: String?, admin: Bool = false, environment: [String: String] = [:]
    ) -> Process {
        let home = home ?? Self.home
        let process = Process()
        if admin, args.first == "clean", let script = library("bin/clean.sh", engine: engine) {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", adminClean, "bash", script] + args.dropFirst()
        } else {
            process.executableURL = URL(fileURLWithPath: engine ?? binary ?? "mo")
            process.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" // GUI apps get a bare PATH
        env["NO_COLOR"] = "1"
        env["HOME"] = home
        // mo logs a preview or a list as if it were a run. Keep those out of its history.
        if args.contains("--dry-run") || args.contains("--list") { env["MO_NO_OPLOG"] = "1" }
        env.merge(environment) { $1 }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        return process
    }

    /// Runs `mo` to completion and decodes its stdout as JSON. Cancelling the task terminates the process.
    static func json<T: Decodable>(_ args: [String], engine: String? = nil) async throws -> T {
        let process = process(args, engine: engine, home: nil)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = await withTaskCancellationHandler {
            await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return try decoder.decode(T.self, from: data)
    }

    /// What `mo uninstall` asks before it removes anything ("➤ Remove 1 app, 8KB  Enter confirm, ESC cancel: ").
    static let uninstallQuestion = "confirm, ESC cancel"

    /// Streams merged stdout+stderr line by line and throws `ExitError` on a non-zero exit.
    /// Ending the iteration (or cancelling) terminates the process.
    /// `answering` types `key` once `question` is on screen; otherwise `mo` runs non-interactively.
    /// `admin` lets a clean ask for administrator rights; `environment` adds to what `mo` is run with.
    static func lines(
        _ args: [String], answering: (question: String, key: String)? = nil, engine: String? = nil, home: String? = nil,
        admin: Bool = false, environment: [String: String] = [:]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = process(args, engine: engine, home: home, admin: admin, environment: environment)
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            // Since 1.65 Mole takes an answer only from a terminal, so a run that is to be answered gets
            // a pseudo-terminal as its input, and the app types into the other end.
            var master: Int32 = -1, slave: Int32 = -1
            let keyboard = answering != nil && openpty(&master, &slave, nil, nil, nil) == 0
                ? FileHandle(fileDescriptor: master, closeOnDealloc: true) : nil
            process.standardInput = keyboard == nil ? FileHandle.nullDevice : FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            // The exit code arrives through this handler rather than `waitUntilExit()`: that call only
            // returns on the thread that started the process, and the reading below is on another one.
            let exit = AsyncStream<Int32> { exit in
                process.terminationHandler = {
                    exit.yield($0.terminationStatus)
                    exit.finish()
                }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            Task.detached {
                // NO_COLOR drops colors, but a few commands still emit clear-screen escapes.
                func yield(_ line: String) { continuation.yield(line.replacing(#/\x1B\[[0-9;?]*[A-Za-z]/#, with: "")) }
                do {
                    if let answering, let keyboard {
                        // The question ends without a newline, so the output is read byte by byte to see it.
                        var line = Data(), asked = false
                        for try await byte in out.fileHandleForReading.bytes {
                            guard byte != UInt8(ascii: "\n") else {
                                yield(String(decoding: line, as: UTF8.self))
                                line.removeAll()
                                continue
                            }
                            line.append(byte)
                            guard !asked, String(decoding: line, as: UTF8.self).contains(answering.question) else { continue }
                            asked = true
                            // Mole throws away whatever was typed before it starts reading, just after asking.
                            Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                try? keyboard.write(contentsOf: Data(answering.key.utf8))
                            }
                        }
                        if !line.isEmpty { yield(String(decoding: line, as: UTF8.self)) }
                    } else {
                        for try await line in out.fileHandleForReading.bytes.lines { yield(line) }
                    }
                    let code = await exit.first { _ in true } ?? -1
                    continuation.finish(throwing: code == 0 ? nil : ExitError(code: code))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Owns one streamed `mo` run and its log. Lives at the app root so a run survives sidebar navigation.
@Observable @MainActor
final class Runner {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    /// True when the last run ended because `stop()` was called.
    private(set) var wasStopped = false
    private var task: Task<Void, Never>?

    /// `onFinish` receives true only when the command ran to the end and exited 0.
    func start(
        _ args: [String], answering: (question: String, key: String)? = nil, admin: Bool = false,
        onFinish: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        wasStopped = false
        task = Task {
            var succeeded = true
            do {
                for try await text in Mole.lines(args, answering: answering, admin: admin) { append(text) }
            } catch {
                succeeded = false
                append("⚠︎ \(error.localizedDescription)")
            }
            if Task.isCancelled {
                succeeded = false
                wasStopped = true
                append("已取消")
            }
            isRunning = false
            // A run that may have removed something: what the disk analysis measured no longer holds.
            if !args.contains("--dry-run") { AnalysisCache.clear() }
            onFinish(succeeded)
        }
    }

    func stop() { task?.cancel() }

    private func append(_ text: String) {
        lines.append(Line(id: lines.count, text: text))
    }
}

/// Adds lines to one of Mole's list files for the length of a run. When nothing else has touched the
/// file since, `restore()` puts it back byte for byte, or removes it if there was none. When something
/// has (a second run that added lines of its own), it takes out exactly its own lines and leaves the
/// rest: putting the old copy back would end the other run's protection while it is still deleting.
// ponytail: quitting the app mid-run leaves the longer list behind (it protects more, never less);
// restore it on next launch if that turns out to matter.
struct ListOverride {
    private let file: URL
    private let added: [String]
    private let original: Data?
    private let written: Data

    private static let lock = NSLock()
    /// The files that hold a run's lines right now: how many runs, and what Mole's defaults were if a
    /// run had to make the file.
    private static var inUse: [String: (runs: Int, madeWith: [String]?)] = [:]

    /// True while a run has lines in `file`. Editing the list by hand has to wait: see `Whitelist`.
    static func isActive(on file: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inUse[file.path] != nil
    }

    /// `fallback` is what the list means while the file does not exist (Mole's defaults), so that
    /// creating the file does not drop them.
    init(_ file: URL, adding lines: [String], fallback: [String]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let original = FileManager.default.contents(atPath: file.path)
        guard original != nil || !FileManager.default.fileExists(atPath: file.path) else {
            throw Failure("读不了 \(file.lastPathComponent)，为安全起见没有继续。")
        }
        let written = (original ?? Data(fallback.joined(separator: "\n").utf8)) + Data(("\n" + lines.joined(separator: "\n") + "\n").utf8)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try written.write(to: file, options: .atomic)
        (self.file, added, self.original, self.written) = (file, lines, original, written)
        var use = Self.inUse[file.path] ?? (0, nil)
        use.runs += 1
        if original == nil { use.madeWith = fallback }
        Self.inUse[file.path] = use
    }

    func restore() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var use = Self.inUse[file.path] ?? (1, nil)
        use.runs -= 1
        Self.inUse[file.path] = use.runs > 0 ? use : nil
        guard let now = FileManager.default.contents(atPath: file.path) else {
            if FileManager.default.fileExists(atPath: file.path) { throw Failure("读不了 \(file.lastPathComponent)。") }
            return // gone, and this run's lines with it
        }
        if now == written {
            if let original { try original.write(to: file, options: .atomic) } else { try FileManager.default.removeItem(at: file) }
            return
        }
        var lines = String(decoding: now, as: UTF8.self).components(separatedBy: "\n")
        for line in added { if let index = lines.lastIndex(of: line) { lines.remove(at: index) } }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // Made for a run, and nothing but Mole's defaults left in it: back to there being no file.
        if use.runs == 0, let madeWith = use.madeWith, lines.filter({ !$0.isEmpty }) == madeWith {
            try FileManager.default.removeItem(at: file)
        } else {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        }
    }
}

/// Runs a command line tool to the end, off the calling thread, and returns its exit status and what it
/// printed. For the tools that are not Mole: brew, launchctl, osascript.
func runTool(_ tool: String, _ args: [String], mergingErrors: Bool = true) async -> (status: Int32, output: String) {
    await Task.detached {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" // GUI apps get a bare PATH
        env["LC_CTYPE"] = "UTF-8" // or `ps` spells a Chinese program name as "M-dM-<…"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1" // the catalog is refreshed once, by `Updates.homebrew()`
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardOutput = out
        process.standardError = mergingErrors ? out : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
}

/// An error whose whole content is a sentence for the user.
struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

let byteFormat: ByteCountFormatStyle = .byteCount(style: .file, spellsOutZero: false)

/// "861.0MB" → bytes. For sorting and totals only: the CLI reports sizes as display strings.
func parseSize(_ display: String) -> Double {
    let units: [(String, Double)] = [("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("B", 1)]
    for (suffix, scale) in units where display.hasSuffix(suffix) {
        return (Double(display.dropLast(suffix.count)) ?? 0) * scale
    }
    return 0
}
