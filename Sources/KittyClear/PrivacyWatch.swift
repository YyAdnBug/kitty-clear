import CoreAudio
import CoreMediaIO
import SwiftUI
import UserNotifications

/// What macOS will say about the camera and the microphone without being given access to either:
/// whether they are switched on, and for sound, which processes are recording.
enum Privacy {
    /// True while any camera is on. macOS does not say for which app.
    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }
        var cameras = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &cameras) == noErr else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return cameras.contains { camera in
            var running: UInt32 = 0
            return CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr && running != 0
        }
    }

    private static func number<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: Value) -> Value {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var (size, value) = (UInt32(MemoryLayout<Value>.size), zero)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : zero
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr ? list : []
    }

    /// True while any microphone (a sound device with inputs) is on.
    static func microphoneInUse() -> Bool {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).contains { device in
            !objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
                && number(device, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) != 0
        }
    }

    /// The apps recording sound right now, by name. A helper process counts as the app it belongs to;
    /// system services, which are no app, are left out. Empty before macOS 14.2, which cannot tell.
    static func microphoneApps() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        let recording = objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .filter { number($0, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 }
            .map { number($0, kAudioProcessPropertyPID, pid_t(0)) }
        return Set(recording.compactMap { pid in
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return appName(ofProgram: String(cString: buffer))
        })
    }

    /// "/Applications/WeChat.app/Contents/…/Helper" → "微信": the name of the outermost app a program
    /// lives in, or nil for a program outside any app.
    static func appName(ofProgram path: String) -> String? {
        guard let end = path.range(of: ".app/")?.lowerBound else { return nil }
        let shown = FileManager.default.displayName(atPath: path[..<end] + ".app")
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }
}

/// Watches for the camera or the microphone coming on, shows it in the menu bar panel and, when the
/// user has asked for it, says so in a notification. Kitty Tools has no such thing; macOS itself only
/// shows a dot.
@Observable @MainActor
final class PrivacyWatch: NSObject, UNUserNotificationCenterDelegate {
    struct Usage: Equatable {
        var camera = false
        var microphone = false
        /// The apps recording, when macOS names them.
        var apps: Set<String> = []
    }

    static let shared = PrivacyWatch()
    /// Where Settings keeps the switch and the apps not to mention again.
    nonisolated static let switchKey = "privacyReminders"
    nonisolated static let mutedKey = "privacyMutedApps"
    private nonisolated static let category = "privacy.app"
    private nonisolated static let muteAction = "privacy.mute"

    private(set) var usage = Usage()
    /// False once macOS has said that Kitty Clear may not post notifications.
    private(set) var mayNotify = true
    private var looked = false

    /// Without a bundle (the bare program, as the self-checks run it) there is no notification centre to talk to.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    var muted: [String] { UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [] }

    /// One line for the menu bar panel.
    var status: String {
        let who = usage.apps.isEmpty ? "" : "（\(usage.apps.sorted().joined(separator: "、"))）"
        return switch (usage.camera, usage.microphone) {
        case (true, true): "摄像头和麦克风使用中" + who
        case (true, false): "摄像头使用中"
        case (false, true): "麦克风使用中" + who
        case (false, false): "未在使用"
        }
    }

    /// Call at launch: notifications come back to this object, and "不再提醒此应用" needs registering.
    func start() {
        center?.delegate = self
        let mute = UNNotificationAction(identifier: Self.muteAction, title: "不再提醒此应用")
        center?.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [mute], intentIdentifiers: [])])
    }

    /// Looks again; the menu bar's two-second tick calls this. What was already on when the app
    /// started is not news.
    func check() {
        let microphone = Privacy.microphoneInUse()
        let now = Usage(camera: Privacy.cameraInUse(), microphone: microphone, apps: microphone ? Privacy.microphoneApps() : [])
        defer {
            if now != usage { usage = now }
            looked = true
        }
        guard looked, UserDefaults.standard.bool(forKey: Self.switchKey), let news = Self.news(from: usage, to: now, muted: Set(muted)) else { return }
        let content = UNMutableNotificationContent()
        content.title = "隐私提醒"
        content.body = news.text
        if let app = news.app {
            content.categoryIdentifier = Self.category
            content.userInfo = ["app": app]
        }
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// What to say when `now` follows `before`: nothing unless the camera came on, the microphone came
    /// on, or another app started recording. An app the user muted is not mentioned, and when it is the
    /// only one recording, neither is the microphone. `app` is set when the news is about exactly one
    /// app, which is then the one "不再提醒此应用" silences.
    nonisolated static func news(from before: Usage, to now: Usage, muted: Set<String>) -> (text: String, app: String?)? {
        let camera = now.camera && !before.camera
        let started = now.microphone && !before.microphone
        let fresh = (started ? now.apps : now.apps.subtracting(before.apps)).subtracting(muted)
        // The microphone is news when it came on for someone not muted, or for nobody macOS can name.
        let microphone = !fresh.isEmpty || (started && now.apps.isEmpty)
        guard camera || microphone else { return nil }
        let who = fresh.sorted().joined(separator: "、")
        let what = camera && microphone ? "摄像头和麦克风" : camera ? "摄像头" : "麦克风"
        return (microphone && !who.isEmpty ? "\(who) 正在使用\(what)" : "\(what)正在使用", fresh.count == 1 ? fresh.first : nil)
    }

    /// Switching the reminder on is when macOS asks the user whether Kitty Clear may post notifications.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.switchKey)
        guard on, let center else { return }
        Task { mayNotify = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    }

    func setMuted(_ app: String, _ silent: Bool) {
        UserDefaults.standard.set(silent ? Array(Set(muted + [app])).sorted() : muted.filter { $0 != app }, forKey: Self.mutedKey)
    }

    // A notification arriving while Kitty Clear is in front is still shown.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.muteAction, let app = response.notification.request.content.userInfo["app"] as? String else { return }
        await MainActor.run { setMuted(app, true) }
    }
}
