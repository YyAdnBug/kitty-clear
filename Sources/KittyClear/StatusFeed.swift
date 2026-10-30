import IOKit
import SwiftUI

/// Readings Mole's command line cannot get on every Mac, taken from the system directly.
enum Sensors {
    /// How busy the graphics processor is, 0...100, as its driver reports it.
    static func gpuUsage() -> Double? {
        var drivers: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &drivers) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(drivers) }
        var busiest: Double?
        while case let driver = IOIteratorNext(drivers), driver != 0 {
            defer { IOObjectRelease(driver) }
            let statistics = IORegistryEntryCreateCFProperty(driver, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let usage = (statistics?["Device Utilization %"] as? NSNumber)?.doubleValue { busiest = max(busiest ?? 0, usage) }
        }
        return busiest
    }

    // The chip's temperature sensors are only reachable through IOKit calls that are not in its public
    // headers. They are looked up by name when first needed, so that a macOS without them costs the
    // reading and nothing else.
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    private static func call<Function>(_ name: String, as type: Function.Type) -> Function? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) } // -2 is RTLD_DEFAULT
    }

    private static let temperatureEvent: Int64 = 15

    /// The sensors on the processor itself: "PMU tdie…" on recent chips, "… MTR Temp Sensor…" on the
    /// first ones. Found once; the client that found them has to stay alive with them.
    private static let dies: (client: AnyObject, sensors: [AnyObject])? = {
        guard let create = call("IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = call("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = call("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = call("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary) // temperature sensors
        let all = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        let onChip = all.filter { sensor in
            let name = copyProperty(sensor, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            return name.contains("tdie") || name.contains("MTR Temp")
        }
        return (client, onChip)
    }()

    /// The hottest spot on the chip, in °C. The processor and the graphics cores share that chip.
    static func chipTemperature() -> Double? {
        guard let dies, let copyEvent = call("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let value = call("IOHIDEventGetFloatValue", as: FloatValue.self) else { return nil }
        return dies.sensors
            .compactMap { copyEvent($0, temperatureEvent, 0, 0)?.takeRetainedValue() }
            .map { value($0, Int32(temperatureEvent << 16)) }
            .filter { $0 > 0 && $0 < 130 } // a sensor that is switched off reads below zero
            .max()
    }

    /// The input devices whose driver says how full they are (Apple's mice, keyboards and trackpads tell
    /// it nowhere else), with the Bluetooth address they go by.
    static func chargedDevices() -> [Accessory.Driver] {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, ["IOPropertyExistsMatch": "BatteryPercent"] as CFDictionary, &services) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(services) }
        var found: [Accessory.Driver] = []
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let percent = (value("BatteryPercent") as? NSNumber)?.intValue else { continue }
            found.append((value("Product") as? String ?? "", value("DeviceAddress") as? String ?? "", percent))
        }
        return found
    }

    /// What is connected to the Mac and runs on a battery of its own.
    static func accessories() async -> [Accessory] {
        let report = await runTool("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], mergingErrors: false).output
        return Accessory.list(report: Data(report.utf8), drivers: chargedDevices())
    }
}

/// A mouse, a keyboard, a pair of earphones: something connected that has a charge of its own. Mole's
/// command line reads these from the Bluetooth report as text, and on macOS 15 gets them wrong (what is
/// connected counts as not connected, a Magic Mouse has no charge), so the app reads them itself.
struct Accessory: Identifiable, Equatable {
    typealias Driver = (name: String, address: String, percent: Int)

    let name: String
    /// The charge of the part that runs out first, in percent.
    let percent: Int
    /// "49%", or "左 99%，右 98%，充电盒 60%" where the parts have a charge each.
    let detail: String
    /// The SF Symbol that stands for it.
    let symbol: String
    var id: String { name }

    /// `report` is `system_profiler SPBluetoothDataType -json`: it knows what is connected, what kind of
    /// thing it is, and the charge of earphones. `drivers` fills in the charge of the rest, by address,
    /// and adds what is not connected over Bluetooth at all (a keyboard on its cable).
    static func list(report: Data, drivers: [Driver]) -> [Accessory] {
        func plain(_ address: String) -> String { address.uppercased().replacing("-", with: ":") }
        func symbol(_ words: String, pair: Bool) -> String {
            if pair { return "earbuds" }
            let known = [("mouse", "magicmouse"), ("keyboard", "keyboard"), ("trackpad", "rectangle.and.hand.point.up.left"), ("head", "headphones"),
                         ("speaker", "hifispeaker"), ("game", "gamecontroller"), ("pencil", "applepencil")]
            return known.first { words.lowercased().contains($0.0) }?.1 ?? "dot.radiowaves.left.and.right"
        }
        let root = (try? JSONSerialization.jsonObject(with: report)) as? [String: Any]
        let connected = (root?["SPBluetoothDataType"] as? [[String: Any]])?.first?["device_connected"] as? [[String: [String: Any]]] ?? []
        var unclaimed = drivers
        var found: [Accessory] = []
        for (name, about) in connected.flatMap({ $0 }) {
            let parts = [("左", "Left"), ("右", "Right"), ("充电盒", "Case"), ("", "Main")].compactMap { label, key in
                (about["device_batteryLevel" + key] as? String).flatMap { Int($0.filter(\.isNumber)) }.map { (label, $0) }
            }
            let driver = unclaimed.firstIndex { !$0.address.isEmpty && plain($0.address) == plain(about["device_address"] as? String ?? "") }
            let levels = parts.isEmpty ? driver.map { [("", unclaimed[$0].percent)] } ?? [] : parts
            if let driver { unclaimed.remove(at: driver) }
            // The case only matters once the earphones are back in it.
            guard let lowest = (levels.filter { $0.0 != "充电盒" }.map(\.1).min() ?? levels.map(\.1).min()) else { continue }
            let detail = levels.map { $0.0.isEmpty ? "\($0.1)%" : "\($0.0) \($0.1)%" }.joined(separator: "，")
            let kind = about["device_minorType"] as? String ?? ""
            found.append(Accessory(name: name, percent: lowest, detail: detail, symbol: symbol(kind + " " + name, pair: parts.contains { $0.0 == "左" })))
        }
        return found + unclaimed.map { Accessory(name: $0.name, percent: $0.percent, detail: "\($0.percent)%", symbol: symbol($0.name, pair: false)) }
    }
}

/// A running app with its helper processes counted in, or a program that belongs to no app.
struct ProcessGroup: Identifiable {
    let id: String // the app's bundle, or the program's own path
    let name: String
    /// The process to ask when the whole thing should quit: the app itself rather than a helper.
    let pid: Int32
    let count: Int
    let cpu: Double // percent of one core, added up
    let memory: Int64
    var isApp: Bool { id.hasSuffix(".app") }
    /// A small background process doing nothing. A Mac runs hundreds of these; the status page leaves
    /// them out of its list, as Mole's does, and says how many.
    var isMinor: Bool { memory < 12 << 20 && cpu < 1 }
}

/// What there is to know about one process beyond its row in the list.
struct ProcessDetail {
    /// The launchd job that started it, when one did.
    struct Service {
        let label, kind, plist, reason: String
        let keepsAlive: Bool
    }

    let user, running, command: String
    /// From launchd down to the process itself.
    let ancestors: [(pid: Int32, name: String)]
    let children: Int
    let service: Service?
}

enum Processes {
    static func list() async -> [ProcessGroup] {
        groups(in: await runTool("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="], mergingErrors: false).output)
    }

    /// Reads `ps` (pid, CPU percent, resident kilobytes, program path) and puts every process under the
    /// outermost app its program lives in. `footprint` gives the memory figure Activity Monitor shows;
    /// it is not available for other users' processes, which fall back to the resident size.
    static func groups(in listing: String, footprint: (Int32) -> Int64? = footprint(of:)) -> [ProcessGroup] {
        struct Running { let pid: Int32; let cpu: Double; let memory: Int64; let path: String }
        var apps: [String: [Running]] = [:]
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let row = line.wholeMatch(of: #/\s*(\d+)\s+([\d.]+)\s+(\d+)\s+(.+)/#), let pid = Int32(row.1) else { continue }
            let path = String(row.4)
            let home = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            apps[home, default: []].append(Running(pid: pid, cpu: Double(row.2) ?? 0, memory: footprint(pid) ?? (Int64(row.3) ?? 0) * 1024, path: path))
        }
        return apps.map { home, members in
            let own = members.first { $0.path.hasPrefix(home + "/Contents/MacOS/") } ?? members.min { $0.pid < $1.pid }
            let shown = home.hasSuffix(".app") ? FileManager.default.displayName(atPath: home) : (home as NSString).lastPathComponent
            return ProcessGroup(id: home, name: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown, pid: own?.pid ?? 0, count: members.count,
                                cpu: members.reduce(0) { $0 + $1.cpu }, memory: members.reduce(0) { $0 + $1.memory })
        }
    }

    /// Who runs a process, for how long, what started it and what it started, out of
    /// `ps -Axo pid=,ppid=,user=,etime=,comm=`.
    static func family(of pid: Int32, in table: String) -> (user: String, running: String, ancestors: [(pid: Int32, name: String)], children: Int)? {
        struct Row { let parent: Int32; let user, elapsed, name: String }
        var rows: [Int32: Row] = [:]
        for line in table.split(whereSeparator: \.isNewline) {
            guard let row = line.wholeMatch(of: #/\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.+)/#), let id = Int32(row.1), let parent = Int32(row.2) else { continue }
            rows[id] = Row(parent: parent, user: String(row.3), elapsed: String(row.4), name: (String(row.5) as NSString).lastPathComponent)
        }
        guard let own = rows[pid] else { return nil }
        var chain: [(pid: Int32, name: String)] = [(pid, own.name)]
        var next = own.parent
        while let row = rows[next], chain.count < 12, !chain.contains(where: { $0.pid == next }) {
            chain.insert((next, row.name), at: 0)
            next = row.parent
        }
        return (own.user, elapsed(own.elapsed), chain, rows.values.filter { $0.parent == pid }.count)
    }

    /// `ps` gives the time a process has run as `[[days-]hours:]minutes:seconds`.
    static func elapsed(_ etime: String) -> String {
        let days = etime.contains("-") ? Int(etime.split(separator: "-")[0]) ?? 0 : 0
        let clock = (etime.split(separator: "-").last ?? "").split(separator: ":").compactMap { Int($0) }
        guard clock.count >= 2 else { return etime }
        let (hours, minutes) = (clock.count == 3 ? clock[0] : 0, clock[clock.count - 2])
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return minutes > 0 ? "\(minutes) 分钟" : "不到 1 分钟"
    }

    /// The launchd job running as `pid`, from `launchctl print <domain>`, which lists `pid status label`.
    static func job(runningAs pid: Int32, in domain: String) -> String? {
        domain.firstMatch(of: try! Regex("(?m)^\\s+\(pid)\\s+\\S+\\s+(\\S+)$")).flatMap { $0.output[1].substring.map(String.init) }
    }

    /// The `key = value` lines of `launchctl print <domain>/<label>` that describe the job itself.
    static func properties(ofJob description: String) -> [String: String] {
        Dictionary(description.matches(of: #/(?m)^\t([a-z ]+) = (.+)$/#).map { (String($0.1), String($0.2)) }) { first, _ in first }
    }

    /// Asks `ps` and launchd about the process a row stands for.
    static func detail(of group: ProcessGroup) async -> ProcessDetail? {
        let table = await runTool("/bin/ps", ["-Axo", "pid=,ppid=,user=,etime=,comm="], mergingErrors: false).output
        guard let family = family(of: group.pid, in: table) else { return nil }
        let command = await runTool("/bin/ps", ["-o", "command=", "-p", "\(group.pid)"], mergingErrors: false).output
        var service: ProcessDetail.Service?
        for domain in ["gui/\(getuid())", "system"] where service == nil {
            guard let label = job(runningAs: group.pid, in: await runTool("/bin/launchctl", ["print", domain]).output) else { continue }
            let about = properties(ofJob: await runTool("/bin/launchctl", ["print", "\(domain)/\(label)"]).output)
            service = .init(label: label, kind: about["type"] ?? "", plist: about["path"] ?? "", reason: about["immediate reason"] ?? "",
                            keepsAlive: about["properties"]?.contains("keepalive") == true)
        }
        return ProcessDetail(user: family.user, running: family.running, command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                             ancestors: family.ancestors, children: family.children, service: service)
    }

    static func footprint(of pid: Int32) -> Int64? {
        var usage = rusage_info_v4()
        let failed = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return failed == 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    /// Asks a process to quit, the way Activity Monitor's "Quit" does, or with `force` ends it on the
    /// spot. Returns what went wrong, or nil.
    static func end(_ group: ProcessGroup, force: Bool = false) -> String? {
        // To `kill`, 0 and below mean whole groups of processes, this app's own first of all.
        guard group.pid > 0 else { return "“\(group.name)”是系统内核，不能结束。" }
        guard kill(group.pid, force ? SIGKILL : SIGTERM) != 0 else { return nil }
        return errno == EPERM ? "“\(group.name)”属于系统或其他用户，这里没有权限结束它。" : String(cString: strerror(errno))
    }
}

/// Everything the status page and the menu bar panel show. Both read this one feed. It measures only
/// while one of them is open, and keeps its last readings in between, so that whichever opens next
/// has numbers to show at once instead of a wait.
// ponytail: the sparklines carry on from the last viewing with no gap drawn for the time in between;
// empty `trend` at the start of `watch()` if that ever reads wrong.
@Observable @MainActor
final class StatusFeed {
    static let shared = StatusFeed()

    private(set) var snapshot: Snapshot?
    private(set) var trend = Trend()
    private(set) var processes: [ProcessGroup] = []
    private(set) var gpu: Double?
    private(set) var temperature: Double?
    private(set) var failed = false
    private(set) var accessories: [Accessory] = []
    /// What the cleaning so far adds up to, for the menu bar panel.
    private(set) var history: History?
    private var viewers = 0
    private var watching: Task<Void, Never>?

    /// Keeps the readings current until the task it runs in is cancelled. However many views ask, they
    /// are measured once.
    func run() async {
        viewers += 1
        if viewers == 1 { watching = Task { await watch() } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        viewers -= 1
        if viewers == 0 { watching?.cancel() }
    }

    /// One long-lived `mo status --watch`, a snapshot per line, with the app's own readings taken
    /// beside it. Cancelling its task also ends the `mo` process.
    private func watch() async {
        failed = false
        var answered = false
        // The cleaning totals change with a run of `mo`, not by the second: once a watch is enough.
        Task { if let read: History = try? await Mole.json(["history", "--json", "--limit", "200"]) { history = read } }
        async let own: Void = sample()
        do {
            // A watch opens with a quick snapshot that has no chip, system version, GPU, battery or
            // proxy in it, and follows it with a whole one within a second. Showing the quick one made
            // those turn up late, so it is left out.
            for try await line in Mole.lines(["status", "--watch", "--interval", "2s"]).dropFirst() {
                if let s = try? Mole.decoder.decode(Snapshot.self, from: Data(line.utf8)) {
                    snapshot = s
                    trend.add(s)
                    answered = true
                }
            }
        } catch {}
        // `mo` gave up by itself without one answer: what an earlier watch left behind is not news.
        if !Task.isCancelled, !answered {
            snapshot = nil
            failed = true
        }
        await own
    }

    private func sample() async {
        var round = 0
        while !Task.isCancelled {
            gpu = Sensors.gpuUsage()
            trend.add(gpu: gpu ?? 0)
            temperature = Sensors.chipTemperature()
            processes = await Processes.list()
            // Accessories come and go by the minute and drain by the hour: every tenth second will do.
            if round % 5 == 0 { accessories = await Sensors.accessories() }
            round += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Memory is counted in powers of 1024, as macOS itself does ("24 GB" of RAM); disks in powers of 1000.
let memoryFormat: ByteCountFormatStyle = .byteCount(style: .memory, spellsOutZero: false)

/// A transfer rate given in MB/s, in whichever unit reads best.
func rateText(_ mbs: Double) -> String {
    mbs < 1 ? "\(Int((mbs * 1000).rounded())) KB/s" : mbs.formatted(.number.precision(.fractionLength(1))) + " MB/s"
}
