import AppKit
import Observation

/// Kitty Clear upgrading itself from its own GitHub releases, the way Kitty Tools does: the latest
/// release's `*_arm64.zip` (made by build-dmg.sh) is downloaded, unpacked beside the app, checked
/// (bundle id, version, and a signature from the same team) and swapped in for the running app, which
/// then reopens. A file the app downloads itself carries no quarantine flag, so the new version opens
/// without Gatekeeper asking again, and with the same certificate the permissions stay.
@Observable @MainActor
final class AppUpdate {
    struct Release: Equatable {
        let version: String
        /// The `*_arm64.zip` asset.
        let archive: URL
        /// The release page, for what changed.
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    static let shared = AppUpdate()
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    nonisolated private static let bundleID = "com.yy.kitty-clear"
    private static let latest = URL(string: "https://api.github.com/repos/YyAdnBug/kitty-clear/releases/latest")!
    /// What the new app must be signed as: this bundle id, by an Apple-issued certificate of the team
    /// build-app.sh signs with. A build signed ad-hoc can never pass, so it can never be installed.
    nonisolated private static let requirement = #"=identifier "com.yy.kitty-clear" and anchor apple generic and certificate leaf[subject.OU] = "HTX9F4KG39""#

    private(set) var state = State.idle
    /// How much of the download has arrived (0…1); nil until the server has said how big it is.
    private(set) var progress: Double?

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    func check() {
        guard !isBusy else { return }
        // `swift run` has no bundle to replace.
        guard Bundle.main.bundleIdentifier == Self.bundleID else {
            state = .failed("只有打包好的 Kitty Clear 能在应用内升级")
            return
        }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: Self.latest)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 404: nothing has been released yet.
                guard status == 200 || status == 404 else { throw Failure("GitHub 返回了 \(status)") }
                if status == 200, let release = try Self.release(from: data), Updater.isNewer(release.version, than: Self.current) {
                    state = .available(release)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    /// Downloads, checks and swaps in the new version, then quits so it can reopen. On failure the app
    /// in place is untouched.
    func install() {
        guard case .available(let release) = state else { return }
        state = .installing(release)
        progress = nil
        Task {
            do {
                let app = Bundle.main.bundleURL
                try await Self.replace(app, with: release) { fraction in
                    Task { @MainActor in self.progress = max(self.progress ?? 0, min(fraction, 1)) }
                }
                try Self.relaunch(app)
                NSApp.terminate(nil)
            } catch {
                progress = nil
                state = .failed("升级没有完成，还在用 \(Self.current)：\(error.localizedDescription)")
            }
        }
    }

    /// GitHub's "latest release" JSON → the release, if it is tagged `v<version>` and has an https `*_arm64.zip`.
    nonisolated static func release(from data: Data) throws -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let payload = try Mole.decoder.decode(Payload.self, from: data)
        guard let version = payload.tagName.wholeMatch(of: #/v(\d+(?:\.\d+)*)/#)?.1,
              let asset = payload.assets.first(where: { $0.name.hasSuffix("_arm64.zip") }),
              asset.browserDownloadUrl.scheme == "https"
        else { return nil }
        return Release(version: String(version), archive: asset.browserDownloadUrl, page: payload.htmlUrl)
    }

    /// Unpacks the release next to `target` (same volume, so the swap is atomic), checks it and replaces
    /// `target` with it. Cannot work from the disk image, or from the read-only copy macOS runs an app
    /// from when it was opened without being moved to Applications first.
    nonisolated private static func replace(_ target: URL, with release: Release, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        if folder.path.contains("/AppTranslocation/") || (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw Failure("请先把 Kitty Clear 拖进“应用程序”，从那里打开后再升级")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw Failure("没有权限替换“\(folder.path)”里的应用，请用管理员账户升级，或到发布页下载后手动替换")
        }
        let (zip, response) = try await URLSession.shared.download(from: release.archive, delegate: DownloadWatcher(report: progress))
        defer { try? fm.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("升级包下载失败") }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: staging) }
        // No ACLs or extended attributes from the archive: the signature lives inside the bundle.
        try run("/usr/bin/ditto", ["-x", "-k", "--noacl", "--noextattr", zip.path, staging.path], failure: "升级包解不开")
        guard let app = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == release.version
        else { throw Failure("升级包不对：应用或版本号对不上") }
        // Permissions are not part of the signature: nobody else may write to it once it is in Applications.
        try run("/bin/chmod", ["-R", "go-w,a-st", app.path], failure: "升级包的文件权限处理失败")
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path], failure: "升级包的签名校验没通过")
        _ = try fm.replaceItemAt(target, withItemAt: app)
    }

    /// Opens the app again once this process has gone; opened earlier, it would find this one still running.
    private static func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            app.path,
        ]
        try process.run()
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(failure) }
    }
}

/// Reports how much of a download has arrived. The async `download(from:)` does not call
/// `didWriteData` on a per-task delegate, only `didCreateTask`, so the task's byte counts are watched
/// instead (Kitty Tools found this out). Nothing is reported when the server sends no length.
private final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] _, _ in
            let expected = task.countOfBytesExpectedToReceive
            if expected > 0 { report(Double(task.countOfBytesReceived) / Double(expected)) }
        }
    }
}
