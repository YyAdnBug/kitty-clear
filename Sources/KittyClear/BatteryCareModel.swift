import Hardware
import SwiftUI

/// 电池养护 as the app sees it: a wish written to a file (off, limit, or full this once) and a helper,
/// installed once with the administrator's say-so, that makes the Mac follow it. Only root may tell
/// the Mac to stop charging, so the app itself only reads how things stand.
@Observable @MainActor
final class BatteryCareModel {
    static let shared = BatteryCareModel()

    nonisolated static let label = "com.yy.kitty-clear.battery"
    nonisolated static let helper = "/Library/PrivilegedHelperTools/\(label)"
    nonisolated static let job = "/Library/LaunchDaemons/\(label).plist"
    private static let modeFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "KittyClear/battery-care")

    private(set) var mode = BatteryCare.Mode.off
    private(set) var helperInstalled = false
    private(set) var isPaused = false
    private(set) var percent: Int?
    private(set) var isBusy = false
    var problem: String?

    /// Why this Mac cannot have it, or nil when it can.
    let unsupported: String? = {
        if Charging.battery() == nil { return "这台 Mac 没有内置电池。" }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 { return "这一版 macOS 自己就能设充电上限，请在“系统设置 › 电池 › 充电”里调。" }
        return Charging.canBePaused ? nil : "这台 Mac 没有开放 Kitty Clear 能用的充电控制接口。"
    }()

    private init() { refresh() }

    /// Reads how things stand: what was asked for, whether the helper is there, what the Mac is doing.
    func refresh() {
        let word = (try? String(contentsOf: Self.modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mode = BatteryCare.Mode(rawValue: word) ?? .off
        helperInstalled = FileManager.default.fileExists(atPath: Self.job) && FileManager.default.isExecutableFile(atPath: Self.helper)
        isPaused = Charging.isPaused ?? false
        percent = Charging.battery()?.percent
        // "Full this once" has done its job when the battery is full; the limit applies again.
        if mode == .full, percent == 100 { ask(for: .limit) }
    }

    var isOn: Bool { mode != .off && helperInstalled }

    /// One line on what is happening, for Settings and the menu bar panel.
    var status: String {
        if let unsupported { return unsupported }
        if isBusy { return "正在等管理员批准…" }
        switch mode {
        case .off: return helperInstalled ? "已关闭" : "已关闭。打开时要输一次管理员密码，用来安装控制充电的小助手。"
        case _ where !helperInstalled: return "助手还没有装上，再打开一次开关试试。"
        case .full: return "正在充到 100%，充满后恢复 \(BatteryCare.limit)% 的上限。"
        case .limit: return isPaused ? "已暂停充电，电量会保持在 \(BatteryCare.limit)% 上下。" : "\(BatteryCare.limit)% 上限已开启，充到 \(BatteryCare.limit)% 就停。"
        }
    }

    /// Writes the wish. The helper looks every twenty seconds.
    func ask(for wanted: BatteryCare.Mode) {
        do {
            try FileManager.default.createDirectory(at: Self.modeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((wanted.rawValue + "\n").utf8).write(to: Self.modeFile, options: .atomic)
            mode = wanted
        } catch {
            problem = "没能保存电池养护的设置：\(error.localizedDescription)"
        }
    }

    /// Switches the care on, installing the helper first when it is not there yet, or off.
    func set(_ on: Bool) {
        guard unsupported == nil, !isBusy else { return }
        guard on, !helperInstalled else { return ask(for: on ? .limit : .off) }
        guard let source = Bundle.main.resourceURL?.appending(path: "kittyclear-battery").path, FileManager.default.isExecutableFile(atPath: source) else {
            problem = "这个 Kitty Clear 里没有带电池助手，用 build-app.sh 重新打包。"
            return
        }
        ask(for: .limit)
        isBusy = true
        Task {
            if let failure = await Self.asRoot(Self.installScript, source, Self.modeFile.path, saying: "Kitty Clear 要安装电池养护的助手，由它在充到 \(BatteryCare.limit)% 时暂停充电。") {
                ask(for: .off)
                problem = failure
            }
            isBusy = false
            refresh()
        }
    }

    /// Stops the helper, which lets the Mac charge as usual again, and takes it off the disk.
    func removeHelper() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            if let failure = await Self.asRoot(Self.removeScript, saying: "Kitty Clear 要移除电池养护的助手，充电恢复由 macOS 管理。") {
                problem = failure
            } else {
                ask(for: .off)
            }
            isBusy = false
            refresh()
        }
    }

    // $1 is the helper inside the app, $2 the file the wish is written to. The copy root runs belongs
    // to root, so nothing but an administrator can change what runs with those rights.
    nonisolated static let installScript = """
        set -e
        /bin/launchctl bootout system/\(label) 2> /dev/null || true
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 755 "$1" \(helper)
        /usr/bin/plutil -create xml1 \(job)
        /usr/bin/plutil -insert Label -string \(label) \(job)
        /usr/bin/plutil -insert ProgramArguments -json '[]' \(job)
        /usr/bin/plutil -insert ProgramArguments.0 -string \(helper) \(job)
        /usr/bin/plutil -insert ProgramArguments.1 -string "$2" \(job)
        /usr/bin/plutil -insert RunAtLoad -bool true \(job)
        /usr/bin/plutil -insert KeepAlive -bool true \(job)
        /usr/sbin/chown root:wheel \(job)
        /bin/chmod 644 \(job)
        /bin/launchctl bootstrap system \(job)
        """

    nonisolated static let removeScript = """
        /bin/launchctl bootout system/\(label) 2> /dev/null || true
        /bin/rm -f \(helper) \(job)
        """

    /// Runs a shell script with administrator rights; macOS puts up its own password dialog, with
    /// `reason` in it. Returns what went wrong, or nil. Cancelling the dialog is not an error to report.
    private static func asRoot(_ script: String, _ arguments: String..., saying reason: String) async -> String? {
        let asked = await runTool("/usr/bin/osascript", ["-e", rootRequest, script, reason] + arguments)
        if asked.status == 0 { return nil }
        return asked.output.contains("-128") ? "没有得到管理员批准，电池养护没有打开。" : "没能完成：\(asked.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The AppleScript that does the asking: argument 1 is the shell script, 2 the reason shown in the
    /// dialog, the rest are handed to the script as $1, $2…
    nonisolated static let rootRequest = """
            on run argv
                set command to "/bin/sh -c " & quoted form of (item 1 of argv) & " sh"
                repeat with index from 3 to count of argv
                    set command to command & " " & quoted form of (item index of argv)
                end repeat
                do shell script command with prompt (item 2 of argv) with administrator privileges
            end run
            """
}
