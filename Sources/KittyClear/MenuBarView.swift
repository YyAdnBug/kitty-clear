import Hardware
import ServiceManagement
import SwiftUI

/// CPU and memory load, read straight from the kernel's counters.
enum SystemLoad {
    typealias Ticks = (busy: UInt32, total: UInt32)

    /// How long the processors have been busy, and how long they have been running at all, since the
    /// Mac started. The counters are 32 bits wide and wrap around.
    static func cpuTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = info.cpu_ticks
        return (user &+ system &+ nice, user &+ system &+ nice &+ idle)
    }

    /// The share of the time between two readings that the processors were busy.
    static func usage(from earlier: Ticks, to later: Ticks) -> Double? {
        let total = later.total &- earlier.total
        return total == 0 ? nil : Double(later.busy &- earlier.busy) / Double(total)
    }

    /// The share of memory in use, counted the way `mo status` counts it (everything except free and
    /// inactive pages), so that the menu bar and the panel agree.
    static func memoryUsed() -> Double? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let available = UInt64(info.free_count + info.inactive_count) * UInt64(getpagesize())
        return 1 - Double(available) / Double(ProcessInfo.processInfo.physicalMemory)
    }
}

extension SystemLoad {
    /// Bytes received and sent since the Mac started, over its Ethernet and Wi-Fi interfaces together
    /// (a VPN's tunnel would count the same traffic a second time). 32 bits wide, like the processor's
    /// counters, and wrapping around like them.
    static func networkBytes() -> (received: UInt32, sent: UInt32)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var (received, sent): (UInt32, UInt32) = (0, 0)
        var next = first
        while let entry = next?.pointee {
            next = entry.ifa_next
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: entry.ifa_name).hasPrefix("en"),
                  let counted = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            received &+= counted.ifi_ibytes
            sent &+= counted.ifi_obytes
        }
        return (received, sent)
    }
}

/// What stands in the menu bar: KittyClear's own icon and, beside it, a reading. The reading is measured
/// here rather than taken from `mo status`, which is far too heavy to keep running for as long as the
/// app does.
@Observable @MainActor
final class MenuBarGauge {
    enum Reading: String, CaseIterable, Identifiable {
        case none, cpu, memory, network
        var id: Self { self }
        var title: String { ["none": "不显示数字", "cpu": "CPU 占用", "memory": "内存占用", "network": "网速"][rawValue] ?? rawValue }
    }

    /// The same two looks as Kitty Tools' menu bar icon.
    enum Style: String, CaseIterable, Identifiable {
        /// The app icon, as in the Dock.
        case color
        /// The kitten as a one-colour outline that follows the menu bar's light or dark.
        case mono
        var id: Self { self }
        var title: String { self == .color ? "彩色" : "单色" }
    }

    /// Where Settings keeps the user's choices.
    static let choice = "menuBarReading"
    static let look = "menuBarStyle"

    private(set) var image = NSImage()
    private var shown = ""
    private var share: Double?
    private var traffic: String?

    init() {
        render()
        // A change in Settings shows at once instead of at the next measurement. Not from inside the
        // notification, though: AppKit posts one while it is still setting itself up, and asking it for
        // the menu bar's appearance right then sends it back into that same setup (it traps).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        Task {
            var earlier = SystemLoad.cpuTicks()
            var before = SystemLoad.networkBytes()
            while true {
                try? await Task.sleep(for: .seconds(2))
                let now = SystemLoad.cpuTicks()
                let after = SystemLoad.networkBytes()
                share = switch reading {
                case .none, .network: nil
                case .cpu: earlier.flatMap { earlier in now.flatMap { SystemLoad.usage(from: earlier, to: $0) } }
                case .memory: SystemLoad.memoryUsed()
                }
                traffic = before.flatMap { before in after.map { Self.rate(down: Double($0.received &- before.received) / 2, up: Double($0.sent &- before.sent) / 2) } }
                (earlier, before) = (now, after)
                render()
                // The same tick looks whether the camera or the microphone has come on.
                PrivacyWatch.shared.check()
            }
        }
    }

    private var reading: Reading { Reading(rawValue: UserDefaults.standard.string(forKey: Self.choice) ?? "") ?? .cpu }

    /// Draws the picture again when what it shows has changed: the number, the style, or whether the
    /// menu bar behind it turned light or dark (it follows the wallpaper, not the system's appearance).
    private func render() {
        let style = Style(rawValue: UserDefaults.standard.string(forKey: Self.look) ?? "") ?? .color
        let text = reading == .none ? "" : reading == .network ? traffic ?? "" : share.map(Self.percent) ?? ""
        let bar = NSApp?.windows.first { String(describing: type(of: $0)).contains("StatusBar") }?.effectiveAppearance ?? NSApp?.effectiveAppearance
        let onDark = bar?.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
        // The app icon cannot be had before the app object exists; the picture is drawn again once it can.
        let artwork = style == .color ? Self.artwork() : nil
        let key = "\(text) \(style.rawValue) \(onDark) \(artwork != nil)"
        guard key != shown else { return }
        shown = key
        image = Self.badge(text, widest: reading == .network ? "↓999K" : "100%", style: style, onDark: onDark, artwork: artwork)
    }

    nonisolated static func percent(_ share: Double) -> String { "\(Int((min(max(share, 0), 1) * 100).rounded()))%" }

    /// A transfer rate in bytes a second, in the little room the menu bar has: the busier direction with
    /// its arrow, "↓850K", "↑1.2M", "↓12M".
    nonisolated static func rate(down: Double, up: Double) -> String {
        let (arrow, bytes) = up > down ? ("↑", up) : ("↓", down)
        if bytes < 999_500 { return "\(arrow)\(Int((bytes / 1000).rounded()))K" }
        return bytes < 9_950_000 ? arrow + String(format: "%.1fM", bytes / 1e6) : "\(arrow)\(Int((bytes / 1e6).rounded()))M"
    }

    /// The icon and the number as one picture. The menu bar draws its own text with digits of different
    /// widths, which would nudge every icon to the left of this one each time the number changed; here
    /// the digits are all one width and there is always room for `widest`.
    static func badge(_ text: String, widest: String = "100%", style: Style, onDark: Bool, artwork: CGImage?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        // The silhouette is a template, coloured by the menu bar itself. The app icon keeps its colours,
        // so the number beside it has to be given the menu bar's text colour here.
        let ink = style == .mono ? NSColor.black : onDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
        let number = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        let icon = style == .mono ? CGSize(width: 22, height: 16) : CGSize(width: 16, height: 16)
        let room = text.isEmpty ? 0 : 5 + ceil(NSAttributedString(string: widest, attributes: [.font: font]).size().width)
        let image = NSImage(size: NSSize(width: icon.width + room, height: 18), flipped: true) { frame in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0, y: (frame.height - icon.height) / 2)
            if style == .mono { silhouette(context) } else if let artwork { appIcon(context, artwork, side: icon.width) }
            context.restoreGState()
            number.draw(at: NSPoint(x: frame.width - number.size().width, y: (frame.height - number.size().height) / 2))
            return true
        }
        image.isTemplate = style == .mono
        return image
    }

    /// The kitten leaning on its card, 22 × 16 points with the origin top left: the same outline as
    /// Kitty Tools' menu bar icon, since it is the same kitten. Only its opacity matters.
    private static func silhouette(_ context: CGContext) {
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            context.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
        context.setFillColor(.black)
        context.setStrokeColor(.black)
        context.setLineWidth(1)
        context.setLineJoin(.round)
        for flip in [false, true] {
            let ear = [CGPoint(x: 4.4, y: 7.4), CGPoint(x: 5.0, y: 1.0), CGPoint(x: 9.0, y: 3.9)].map { flip ? CGPoint(x: 22 - $0.x, y: $0.y) : $0 }
            context.addLines(between: ear)
            context.closePath()
            context.drawPath(using: .fillStroke)
        }
        // The head, down to the edge of the card.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: 22, height: 11))
        ellipse(11, 8.3, 7.4, 6.2)
        context.restoreGState()
        // A gap around the paws sets them off from the head; then the card's edge, the paws, and the eyes cut out.
        context.setBlendMode(.clear)
        for cx: CGFloat in [7, 15] { ellipse(cx, 12.9, 3, 2.3) }
        context.setBlendMode(.normal)
        context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 14, width: 21, height: 2), cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
        for cx: CGFloat in [7, 15] { ellipse(cx, 12.9, 2.3, 1.8) }
        context.setBlendMode(.clear)
        for cx: CGFloat in [8, 14] { ellipse(cx, 7, 1.35, 1.45) }
        context.setBlendMode(.normal)
    }

    private static var body: CGImage?

    /// The app icon's body without the margin and the shadow its artwork carries (1024 canvas, body 824,
    /// see scripts/brand-icon.swift), so that the plate itself fills the height of the menu bar icon.
    /// Fetched before any drawing: asking for it from inside the drawing would start another drawing.
    private static func artwork() -> CGImage? {
        if let body { return body }
        var whole = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let icon = NSApp?.applicationIconImage.cgImage(forProposedRect: &whole, context: nil, hints: nil) else { return nil }
        let unit = CGFloat(icon.width) / 1024
        body = icon.cropping(to: CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit))
        return body
    }

    private static func appIcon(_ context: CGContext, _ iconBody: CGImage, side: CGFloat) {
        // The plate's outline: the superellipse macOS icons use. Clipping to it drops the shadow in the corners.
        let outline = CGMutablePath()
        for step in 0..<128 {
            let angle = CGFloat(step) / 128 * 2 * .pi
            let (x, y) = (cos(angle), sin(angle))
            let point = CGPoint(x: side / 2 * (1 + (x < 0 ? -1 : 1) * pow(abs(x), 0.4)), y: side / 2 * (1 + (y < 0 ? -1 : 1) * pow(abs(y), 0.4)))
            if step == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
        }
        outline.closeSubpath()
        context.addPath(outline)
        context.clip()
        context.interpolationQuality = .high
        // Images draw upside down in a flipped context.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.draw(iconBody, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
}

/// KittyClear on the user's list of login items.
enum LaunchAtLogin {
    static var state: SMAppService.Status { SMAppService.mainApp.status }

    /// Puts the app on the list or takes it off. Returns what went wrong, or nil.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True when macOS started the app as a login item, rather than the user opening it. Only the
    /// launch itself knows: ask in `applicationDidFinishLaunching`.
    static var startedByLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// What a right-click on the menu bar icon brings up: the way to every page, and out. The left click
/// keeps the panel; that part is SwiftUI's, which has no notion of a second kind of click, so this one
/// is caught before it gets there.
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()

    /// Starts listening for right-clicks (and control-clicks, their keyboard twin) on the icon.
    func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window = event.window, String(describing: type(of: window)).contains("StatusBar"), let icon = window.contentView
            else { return event }
            // The panel a left click opened hangs right where the menu comes up, and would cover it. It is
            // put away first, the way a click on the icon puts it away, so that SwiftUI knows it is shut.
            // Its going takes a moment and takes any menu that is up along with it, so the menu waits.
            if Self.panelIsOpen {
                Self.button(in: icon)?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in pop(under: icon) }
            } else {
                pop(under: icon)
            }
            return nil
        }
    }

    /// Under the icon, whichever way up its view counts.
    private func pop(under icon: NSView) {
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: icon.isFlipped ? icon.bounds.maxY + 6 : -6), in: icon)
    }

    /// True while the panel of the left click is on screen.
    static var panelIsOpen: Bool {
        NSApp.windows.contains { String(describing: type(of: $0)).contains("MenuBarExtra") && $0.isVisible }
    }

    /// The icon's button inside the status bar's window.
    static func button(in view: NSView?) -> NSControl? {
        if let found = view as? NSControl { return found }
        return view?.subviews.lazy.compactMap { button(in: $0) }.first
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("打开 Kitty Clear", symbol: "macwindow") { MainWindow.shared.show() })
        menu.addItem(.separator())
        for page in Page.allCases where page != .settings {
            menu.addItem(item(page.rawValue, symbol: page.icon) { MainWindow.shared.show(page) })
        }
        menu.addItem(.separator())
        menu.addItem(item("设置…", symbol: Page.settings.icon, key: ",") { MainWindow.shared.show(.settings) })
        menu.addItem(item("关于 Kitty Clear", symbol: "info.circle") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item("退出 Kitty Clear", symbol: "power", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// An item that runs a closure. The closure rides in `representedObject`, which the item keeps.
    private func item(_ title: String, symbol: String, key: String = "", _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        item.target = self
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) { (sender.representedObject as? @MainActor () -> Void)?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With "menu bar only" switched on, KittyClear is in the Dock only while it has a window. A window
    /// minimised into the Dock counts, or it would vanish with the icon. Without the menu bar icon
    /// there would be no way back to the app, so then the Dock icon stays whatever the switch says.
    static func syncDockIcon() {
        let defaults = UserDefaults.standard
        let menuBarOnly = defaults.bool(forKey: "menuBarOnly") && defaults.object(forKey: "menuBarIcon") as? Bool ?? true
        let hasWindow = NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
        let wanted: NSApplication.ActivationPolicy = menuBarOnly && !hasWindow ? .accessory : .regular
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for change in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            // A closing window is still there while it says so; look again once it has gone.
            NotificationCenter.default.addObserver(forName: change, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { Self.syncDockIcon() }
            }
        }
        // Started with the Mac, KittyClear stays in the menu bar: the window SwiftUI has just made is
        // closed again straight away. (Hiding the app instead would bring the window back at the first
        // click on the menu bar icon.) With the icon switched off there would be no way to reach the
        // app, so then the window stays.
        if LaunchAtLogin.startedByLogin, UserDefaults.standard.object(forKey: "menuBarIcon") as? Bool ?? true {
            NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
        }
        Self.syncDockIcon()
        PrivacyWatch.shared.start()
        StatusMenu.shared.install()
        // A first reading now, so that the menu bar panel has numbers the first time it is opened.
        Task {
            let reading = Task { await StatusFeed.shared.run() }
            try? await Task.sleep(for: .seconds(5))
            reading.cancel()
        }
    }
}

/// What the menu bar icon opens: the status page at pocket size, with a few things worth having at
/// hand. It only measures while it is open.
struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private let feed = StatusFeed.shared
    @State private var problem: String?

    private static let kitten: CGFloat = 84
    private static let above = kitten / Kitten.aspect * Kitten.aboveEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = feed.snapshot {
                summary(s)
                tiles(s)
                battery(s)
                busiest
                tools
            } else {
                Waiting(text: feed.failed ? "读不到系统状态" : "正在采集…").frame(height: 220)
            }
            HStack {
                Button("打开 Kitty Clear", action: showMainWindow).buttonStyle(.primary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.quiet)
            }
        }
        .padding(14)
        .foregroundStyle(Theme.ink)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // The kitten leans over the card, as it does in the main window.
        .padding(.top, Self.above)
        .background(alignment: .topTrailing) { Kitten(layer: .head).frame(width: Self.kitten).padding(.trailing, 20) }
        .overlay(alignment: .topTrailing) {
            Kitten(layer: .paws).frame(width: Self.kitten).padding(.trailing, 20).allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Text("Kitty Clear").font(Theme.display(17)).foregroundStyle(.white)
                .padding(.leading, 6)
                .frame(height: Self.above - 8, alignment: .bottom)
        }
        .padding(12)
        .frame(width: 372)
        .background(Sky())
        .preferredColorScheme(.light)
        .tint(Theme.shine)
        // The panel's view comes and goes with the panel, so these run only while it is open.
        .task { await feed.run() }
        .task { BatteryCareModel.shared.refresh() }
    }

    private func summary(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(s.healthScore, format: .number).font(Theme.display(34)).foregroundStyle(Level(health: s.healthScore).ink).monospacedDigit()
                Text(zhHealth(s.healthScoreMsg)).font(Theme.text(13, .semibold)).lineLimit(1)
            }
            let facts = [s.hardware.cpuModel, s.memory.total.formatted(memoryFormat), s.hardware.osVersion, "已开机 \(s.uptime)",
                         s.proxy?.enabled == true ? "代理 \(s.proxy?.type ?? "")" : ""]
            FlowLayout(spacing: 5) {
                ForEach(facts.filter { !$0.isEmpty }, id: \.self) { fact in
                    Text(fact).font(Theme.text(11, .medium)).foregroundStyle(Theme.inkSoft)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.pinkLine.opacity(0.55), in: Capsule())
                }
            }
        }
    }

    private func tiles(_ s: Snapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            Tile(title: "CPU", badge: feed.temperature.map { "\(Int($0.rounded()))°C" } ?? "", value: percent(s.cpu.usage),
                 note: "负载 \(s.cpu.load1.formatted(.number.precision(.fractionLength(1)))) / \(s.cpu.coreCount) 核", level: Level(used: s.cpu.usage / 100)) {
                if let cores = s.cpu.perCore, cores.count > 1 { CoreBars(usage: cores) } else { Bar(fraction: s.cpu.usage / 100) }
            }
            let gpu = s.gpu?.first
            Tile(title: "GPU", value: feed.gpu.map(percent) ?? "—", note: gpu.map { $0.coreCount ?? 0 > 0 ? "\($0.name)，\($0.coreCount ?? 0) 核" : $0.name } ?? "",
                 level: Level(used: (feed.gpu ?? 0) / 100)) {
                Bar(fraction: (feed.gpu ?? 0) / 100)
            }
            Tile(title: "内存", badge: ["warn": "压力偏高", "critical": "压力严重"][s.memory.pressure ?? ""] ?? "", value: percent(s.memory.usedPercent),
                 note: "\(s.memory.used.formatted(memoryFormat)) / \(s.memory.total.formatted(memoryFormat))", level: s.memory.level) {
                Bar(fraction: s.memory.usedPercent / 100, level: s.memory.level)
            }
            if let disk = (s.disks ?? []).first(where: { !$0.external }) {
                Tile(title: "磁盘可用", badge: "共 \(gigabytes(disk.total))", value: gigabytes(disk.total - disk.used),
                     note: "已用 \(gigabytes(disk.used))，\(Int(disk.usedPercent))%", level: Level(used: disk.usedPercent / 100)) {
                    Bar(fraction: disk.usedPercent / 100)
                }
            }
            let (down, up) = (feed.trend.down.last ?? 0, feed.trend.up.last ?? 0)
            Tile(title: "网络", value: rateText(down + up), note: "↑ \(rateText(up))  ↓ \(rateText(down))") {
                Sparkline(values: feed.trend.down, height: 16)
            }
            let watts = s.thermal?.systemPower.flatMap { $0 > 0 ? "\($0.formatted(.number.precision(.fractionLength(1)))) W" : nil }
            if let heat = feed.temperature {
                Tile(title: "温度", badge: ["正常", "偏热", "过热"][Level(heat: heat).rawValue], value: "\(Int(heat.rounded()))°C", note: watts.map { "整机功耗 \($0)" } ?? "",
                     level: Level(heat: heat)) {
                    Bar(fraction: (heat - 30) / 70, level: Level(heat: heat))
                }
            } else if let watts {
                Tile(title: "整机功耗", value: watts, note: "") { EmptyView() }
            }
        }
    }

    /// The battery on a card of its own, as wide as the panel. How full it is comes straight from the
    /// Mac, so the card is there the moment the panel opens; what Mole knows besides (health, cycles,
    /// the charger's power, connected accessories) fills in when its snapshot has it.
    @ViewBuilder private func battery(_ s: Snapshot) -> some View {
        if let now = Charging.battery() {
            let more = s.batteries?.first
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("电池").font(Theme.text(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Text(more?.capacity.flatMap { $0 > 0 ? "健康 \($0)%" : nil } ?? "").font(Theme.text(10.5, .medium)).foregroundStyle(Theme.inkSoft)
                }
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(now.percent)%").font(Theme.display(22)).foregroundStyle(Level(charge: Double(now.percent)).ink).monospacedDigit()
                            Text(more.map { zh($0.status) } ?? (now.pluggedIn ? "接着电源" : "用电池中")).font(Theme.text(12, .semibold))
                            if let power = s.thermal?.adapterPower, power > 0, now.pluggedIn {
                                Label("\(Int(power)) W", systemImage: "bolt.fill").font(Theme.text(11.5)).foregroundStyle(Theme.inkSoft).labelStyle(.titleAndIcon)
                            }
                        }
                        // Always a line, so that the card is the same height whatever there is to say.
                        Text(batteryNote(more)).font(Theme.text(10.5)).foregroundStyle(Theme.inkSoft).monospacedDigit()
                    }
                    .lineLimit(1)
                    Spacer(minLength: 2)
                    // The Mac first, then what is connected to it, each charge round its icon.
                    ChargeRing(symbol: "laptopcomputer", percent: now.percent).help("这台 Mac \(now.percent)%").accessibilityLabel("这台 Mac \(now.percent)%")
                    // ponytail: three accessories fit beside the text; wrap or scroll if someone connects more.
                    ForEach(feed.accessories.prefix(3)) { item in
                        ChargeRing(symbol: item.symbol, percent: item.percent).help("\(item.name) \(item.detail)").accessibilityLabel("\(item.name) \(item.detail)")
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.blueLine.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func batteryNote(_ battery: Snapshot.Battery?) -> String {
        if let left = battery?.timeLeft, !left.isEmpty, left != "0:00" { return battery?.status == "charging" ? "还需 \(left)" : "还能用 \(left)" }
        return battery.flatMap { $0.cycleCount > 0 ? "循环 \($0.cycleCount) 次" : nil } ?? " "
    }

    /// The five heaviest apps, with a way to ask one to quit.
    private var busiest: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("高占用进程")
                Spacer()
                Text("内存").frame(width: 70, alignment: .trailing)
                Text("CPU").frame(width: 40, alignment: .trailing)
                Color.clear.frame(width: 18, height: 1)
            }
            .font(Theme.text(11.5, .medium))
            .foregroundStyle(Theme.inkSoft)
            .padding(.bottom, 2)
            ForEach(feed.processes.sorted { $0.memory > $1.memory }.prefix(5)) { group in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: group.id)).resizable().frame(width: 16, height: 16)
                    Text(group.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(group.memory.formatted(memoryFormat)).frame(width: 70, alignment: .trailing)
                    Text(group.cpu.formatted(.number.precision(.fractionLength(1)))).frame(width: 40, alignment: .trailing)
                    Menu {
                        // The list re-sorts every two seconds: the name says whose menu this turned out to be.
                        Button("结束“\(group.name)”") { problem = Processes.end(group) }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.id)]) }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Theme.inkSoft).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("对 \(group.name) 的操作")
                }
                .font(Theme.text(12))
                .monospacedDigit()
                .padding(.vertical, 3)
            }
            if let problem {
                Text(problem).font(Theme.text(11)).foregroundStyle(Theme.inkSoft).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }

    /// Whether the camera and microphone are in use, the battery care's "full this once", and what the
    /// cleaning so far adds up to. Keeping the screen awake and ejecting disks are Kitty Tools' job.
    private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                privacy
                Spacer(minLength: 4)
                if BatteryCareModel.shared.isOn {
                    let care = BatteryCareModel.shared
                    Button(care.mode == .full ? "恢复 \(BatteryCare.limit)%" : "充到 100%") { care.ask(for: care.mode == .full ? .limit : .full) }
                        .buttonStyle(.quiet)
                        .help(care.status)
                }
            }
            if let totals = feed.history?.totals {
                Text("已清理 \(totals.cleaned.formatted(byteFormat))，卸载 \(totals.uninstalled) 个，优化 \(totals.optimized) 次")
                    .font(Theme.text(11)).foregroundStyle(Theme.inkSoft).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    /// Whether the camera and the microphone are on, and for the microphone whose doing it is.
    private var privacy: some View {
        let watch = PrivacyWatch.shared
        return HStack(spacing: 5) {
            Image(systemName: "video.fill").foregroundStyle(watch.usage.camera ? Theme.blush : Theme.ink.opacity(0.28))
            Image(systemName: "mic.fill").foregroundStyle(watch.usage.microphone ? Theme.blush : Theme.ink.opacity(0.28))
            Text(watch.status).foregroundStyle(watch.usage == .init() ? Theme.inkSoft : Theme.ink).lineLimit(1).truncationMode(.tail)
        }
        .font(Theme.text(11.5, watch.usage == .init() ? .regular : .semibold))
        .help("摄像头和麦克风现在有没有被用着。在设置里打开“隐私提醒”，它们一被用上就会通知你。")
        .accessibilityElement(children: .combine)
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// A disk size in whole gigabytes: at this size the decimals are noise.
    private func gigabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1e9).rounded())) GB" }

    /// Puts the panel away and brings the main window forward: out of the Dock, or as a new window when
    /// it was closed. In menu-bar-only mode the Dock icon has to come back first.
    private func showMainWindow() {
        dismiss()
        MainWindow.shared.open = { openWindow(id: KittyClearApp.mainWindow) }
        MainWindow.shared.show()
    }
}
