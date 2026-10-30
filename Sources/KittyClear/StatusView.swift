import SwiftUI

/// The subset of `mo status --json` the dashboard shows. Everything past the basics is optional: the
/// first snapshot of a watch arrives before the slower probes have answered.
struct Snapshot: Decodable {
    struct Hardware: Decodable { let model, cpuModel, osVersion: String }
    struct CPU: Decodable {
        let usage, load1: Double
        let coreCount: Int
        let perCore: [Double]?
        let pCoreCount, eCoreCount: Int?
    }
    struct GPU: Decodable {
        let name: String
        let usage: Double // -1 when macOS does not report it
        let coreCount: Int?
    }
    struct Memory: Decodable {
        let used, total: Int64
        let usedPercent: Double
        let cached, swapUsed: Int64?
        let pressure: String?

        /// By how full it is, or by what macOS itself says of the pressure, whichever is worse.
        var level: Level { max(Level(used: usedPercent / 100), pressure == "critical" ? .critical : pressure == "warn" ? .high : .fine) }
    }
    struct Disk: Decodable, Identifiable {
        let mount: String
        let used, total: Int64
        let usedPercent: Double
        let external: Bool
        var id: String { mount }
    }
    struct DiskIO: Decodable { let readRate, writeRate: Double } // MB/s
    struct Interface: Decodable {
        let name: String?
        let rxRateMbs, txRateMbs: Double
        let ip: String?
    }
    struct Proxy: Decodable {
        let enabled: Bool
        let type, host: String?
    }
    struct Battery: Decodable {
        let percent: Double
        let status, health: String
        let cycleCount: Int
        let timeLeft: String?
        let capacity: Int?
    }
    struct Thermal: Decodable {
        let cpuTemp, gpuTemp, batteryTemp, systemPower, adapterPower: Double? // °C and watts
        let fanSpeed, fanCount: Int?
    }
    struct Proc: Decodable, Identifiable {
        let pid: Int
        let name: String
        let cpu: Double
        let memoryBytes: Int64
        var id: Int { pid }
    }

    let uptime: String
    let hardware: Hardware
    let healthScore: Int
    let healthScoreMsg: String
    let cpu: CPU
    let gpu: [GPU]?
    let memory: Memory
    let disks: [Disk]?
    let diskIo: DiskIO?
    let trashSize: Int64?
    let network: [Interface]?
    let proxy: Proxy?
    let batteries: [Battery]?
    let thermal: Thermal?
    let topProcesses: [Proc]?
}

/// The last minute and a half of readings, for the sparklines.
struct Trend {
    static let capacity = 45
    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var down: [Double] = []
    private(set) var up: [Double] = []
    private(set) var gpu: [Double] = []

    private func pushed(_ value: Double, onto series: [Double]) -> [Double] { Array((series + [value]).suffix(Self.capacity)) }

    mutating func add(_ s: Snapshot) {
        cpu = pushed(s.cpu.usage, onto: cpu)
        memory = pushed(s.memory.usedPercent, onto: memory)
        down = pushed((s.network ?? []).reduce(0) { $0 + $1.rxRateMbs }, onto: down)
        up = pushed((s.network ?? []).reduce(0) { $0 + $1.txRateMbs }, onto: up)
    }

    mutating func add(gpu usage: Double) { gpu = pushed(usage, onto: gpu) }
}

/// The readings on top, always in view, and under them the list of what is running, which scrolls by
/// itself. Clicking a row opens what there is to know about that process.
struct StatusView: View {
    struct Victim: Identifiable {
        let group: ProcessGroup
        let force: Bool
        var id: String { group.id }
    }

    private let feed = StatusFeed.shared
    @State private var inspected: ProcessGroup?
    @State private var victim: Victim?
    @State private var problem: String?

    var body: some View {
        Stage(size: .full, title: "状态", subtitle: subtitle, mood: feed.snapshot == nil && !feed.failed ? .searching : .calm) {
            if let s = feed.snapshot {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        tiles(s)
                        if !feed.accessories.isEmpty {
                            Text("配件电量：" + feed.accessories.map { "\($0.name) \($0.detail)" }.joined(separator: "；"))
                                .font(Theme.text(12)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    Rule()
                    ProcessTable(processes: feed.processes, inspected: $inspected, victim: $victim)
                }
                .overlay {
                    if let inspected {
                        ZStack {
                            Theme.ink.opacity(0.3).onTapGesture { self.inspected = nil }
                            // The row's numbers keep moving while its card is open.
                            ProcessCard(group: feed.processes.first { $0.id == inspected.id } ?? inspected,
                                        close: { self.inspected = nil }, end: { victim = Victim(group: inspected, force: $0) })
                                .frame(maxWidth: 580)
                                .padding(24)
                                .id(inspected.id) // another process is another card, not this one with old answers
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: inspected?.id)
            } else if feed.failed {
                Hero(title: "读不到系统状态", text: "mo status 没有返回数据。") {}
            } else {
                Waiting(text: "正在采集…")
            }
        }
        .task { await feed.run() } // leaving the page cancels it
        .confirmationDialog(victim.map { "\($0.force ? "强制结束" : "结束")“\($0.group.name)”？" } ?? "",
                            isPresented: Binding(get: { victim != nil }, set: { if !$0 { victim = nil } }), presenting: victim) { victim in
            Button(victim.force ? "强制结束" : "结束", role: .destructive) {
                problem = Processes.end(victim.group, force: victim.force)
                if problem == nil { inspected = nil }
            }
        } message: { victim in
            Text(victim.force ? "它会立刻停下，来不及保存任何东西。" : "它里面没保存的内容可能会丢失。")
        }
        .alert("没能结束进程", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
        } message: {
            Text(problem ?? "")
        }
    }

    private var subtitle: String {
        guard let s = feed.snapshot, !s.hardware.model.isEmpty else { return "" }
        return "\(s.hardware.model)，\(s.hardware.cpuModel)，\(s.hardware.osVersion)"
    }

    private func tiles(_ s: Snapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            Tile(title: "健康度", badge: "已开机 \(s.uptime)", value: "\(s.healthScore)", note: zhHealth(s.healthScoreMsg), roomy: true,
                 level: Level(health: s.healthScore)) {
                Bar(fraction: Double(s.healthScore) / 100, level: Level(health: s.healthScore))
            }
            let busy = Level(used: s.cpu.usage / 100)
            Tile(title: "CPU", badge: feed.temperature.map { "\(whole($0))°C" } ?? "", value: "\(whole(s.cpu.usage))%", note: cores(s), roomy: true, level: busy) {
                if let perCore = s.cpu.perCore, perCore.count > 1 {
                    CoreBars(usage: perCore)
                } else {
                    Sparkline(values: feed.trend.cpu, ceiling: 100, height: 26, level: busy)
                }
            }
            if let gpu = s.gpu?.first {
                // The app's own reading where there is one: `mo` cannot see the load on every Mac.
                let usage = feed.gpu ?? (gpu.usage >= 0 ? gpu.usage : nil)
                let drawing = Level(used: (usage ?? 0) / 100)
                Tile(title: "GPU", value: usage.map { "\(whole($0))%" } ?? "—", note: gpu.coreCount ?? 0 > 0 ? "\(gpu.name)，\(gpu.coreCount ?? 0) 核" : gpu.name,
                     roomy: true, level: drawing) {
                    Sparkline(values: feed.trend.gpu, ceiling: 100, height: 26, level: drawing)
                }
            }
            Tile(title: "内存", badge: ["warn": "压力偏高", "critical": "压力严重"][s.memory.pressure ?? ""] ?? "", value: "\(whole(s.memory.usedPercent))%",
                 note: memoryNote(s), roomy: true, level: s.memory.level) {
                Sparkline(values: feed.trend.memory, ceiling: 100, height: 26, level: s.memory.level)
            }
            if let battery = s.batteries?.first {
                Tile(title: "电池", badge: battery.capacity.flatMap { $0 > 0 ? "健康 \($0)%" : nil } ?? "", value: "\(Int(battery.percent))%",
                     note: batteryNote(battery, s), roomy: true, level: Level(charge: battery.percent)) {
                    Bar(fraction: battery.percent / 100, level: Level(charge: battery.percent))
                }
            }
            if let disk = (s.disks ?? []).first(where: { !$0.external }) {
                Tile(title: "磁盘可用", badge: "共 \(gigabytes(disk.total))", value: gigabytes(disk.total - disk.used),
                     note: s.diskIo.map { "读 \(rateText($0.readRate))，写 \(rateText($0.writeRate))" } ?? "已用 \(gigabytes(disk.used))，\(Int(disk.usedPercent))%",
                     roomy: true, level: Level(used: disk.usedPercent / 100)) {
                    Bar(fraction: disk.usedPercent / 100)
                }
            }
            Tile(title: "网络", badge: (s.network ?? []).first { !($0.ip ?? "").isEmpty }?.ip ?? "", value: "↓ " + rateText(feed.trend.down.last ?? 0),
                 note: "↑ " + rateText(feed.trend.up.last ?? 0) + (s.proxy?.enabled == true ? "，代理 \(s.proxy?.type ?? "")" : ""), roomy: true) {
                Sparkline(values: feed.trend.down, height: 26)
            }
            if let heat = feed.temperature ?? s.thermal?.cpuTemp.flatMap({ $0 > 0 ? $0 : nil }) {
                Tile(title: "温度", badge: ["正常", "偏热", "过热"][Level(heat: heat).rawValue], value: "\(whole(heat))°C", note: powerNote(s), roomy: true,
                     level: Level(heat: heat)) {
                    Bar(fraction: (heat - 30) / 70, level: Level(heat: heat))
                }
            } else if let power = s.thermal?.systemPower, power > 0 {
                Tile(title: "整机功耗", value: "\(number(power, 1)) W", note: powerNote(s), roomy: true) { EmptyView() }
            }
        }
    }

    private func cores(_ s: Snapshot) -> String {
        if let p = s.cpu.pCoreCount, let e = s.cpu.eCoreCount, p > 0, e > 0 { return "\(p) 性能核 + \(e) 能效核，负载 \(number(s.cpu.load1, 1))" }
        return "\(s.cpu.coreCount) 核，负载 \(number(s.cpu.load1, 1))"
    }

    private func memoryNote(_ s: Snapshot) -> String {
        let swap = s.memory.swapUsed.flatMap { $0 > 0 ? "，交换 \($0.formatted(memoryFormat))" : nil } ?? ""
        return "\(s.memory.used.formatted(memoryFormat)) / \(s.memory.total.formatted(memoryFormat))" + swap
    }

    private func batteryNote(_ battery: Snapshot.Battery, _ s: Snapshot) -> String {
        var parts = [zh(battery.status)]
        if let left = battery.timeLeft, !left.isEmpty, left != "0:00" { parts.append(battery.status == "charging" ? "还需 \(left)" : "还能用 \(left)") }
        if let adapter = s.thermal?.adapterPower, adapter > 0 { parts.append("\(whole(adapter)) W") }
        parts.append("循环 \(battery.cycleCount) 次")
        return parts.joined(separator: "，")
    }

    private func powerNote(_ s: Snapshot) -> String {
        guard let t = s.thermal else { return "" }
        var parts: [String] = []
        if let power = t.systemPower, power > 0 { parts.append("整机 \(number(power, 1)) W") }
        if let battery = t.batteryTemp, battery > 0 { parts.append("电池 \(number(battery, 0))°C") }
        if let count = t.fanCount, count > 0, let speed = t.fanSpeed { parts.append("风扇 \(speed) 转") }
        return parts.joined(separator: "，")
    }

    private func whole(_ value: Double) -> Int { Int(value.rounded()) }
    private func number(_ value: Double, _ digits: Int) -> String { value.formatted(.number.precision(.fractionLength(digits))) }
    private func gigabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1e9).rounded())) GB" }
}

/// The running apps and programs worth a row, heaviest first, in a list that scrolls on its own. An
/// app's helper processes are counted into its row.
private struct ProcessTable: View {
    private enum Order: String, CaseIterable { case memory = "内存", cpu = "% CPU" }

    let processes: [ProcessGroup]
    @Binding var inspected: ProcessGroup?
    @Binding var victim: StatusView.Victim?
    @State private var order = Order.memory

    var body: some View {
        let shown = processes.filter { !$0.isMinor }.sorted { order == .memory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        // The busiest row sets the scale of the bars, so they stay readable on a quiet Mac.
        let peak = max(shown.map(\.cpu).max() ?? 0, 25)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("进程（\(shown.count)）").font(Theme.text(13, .medium)).foregroundStyle(Theme.inkSoft)
                Text("另有 \(processes.count - shown.count) 个很小的后台进程没列出").font(Theme.text(11)).foregroundStyle(Theme.inkSoft.opacity(0.75))
                    .help("占用不到 12 MB、也几乎不用 CPU 的后台进程。每台 Mac 都有几百个。")
                Spacer()
                ForEach(Order.allCases, id: \.self) { column in
                    Button { order = column } label: {
                        HStack(spacing: 3) {
                            Text(column.rawValue)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(order == column ? 1 : 0)
                        }
                        .font(Theme.text(12, order == column ? .semibold : .regular))
                        .foregroundStyle(order == column ? Theme.shine : Theme.inkSoft)
                        .frame(width: column == .memory ? 84 : 124, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("按\(column.rawValue)排序")
                }
                Text("PID").font(Theme.text(12)).foregroundStyle(Theme.inkSoft).frame(width: 56, alignment: .trailing)
                Color.clear.frame(width: 22, height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { group in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: group.id)).resizable().frame(width: 20, height: 20)
                            Text(group.name).lineLimit(1).truncationMode(.middle)
                            if group.count > 1 {
                                Text("\(group.count) 个进程").font(Theme.text(11)).foregroundStyle(Theme.inkSoft)
                            }
                            Spacer()
                            Text(group.memory.formatted(memoryFormat)).frame(width: 84, alignment: .trailing)
                            Bar(fraction: group.cpu / peak, level: .fine).frame(width: 64)
                            Text(group.cpu.formatted(.number.precision(.fractionLength(1)))).frame(width: 48, alignment: .trailing)
                            Text(String(group.pid)).foregroundStyle(Theme.inkSoft).frame(width: 56, alignment: .trailing)
                            Menu {
                                Button("查看详情") { inspected = group }
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.id)]) }
                                Divider()
                                Button("结束…") { victim = .init(group: group, force: false) }
                                Button("强制结束…") { victim = .init(group: group, force: true) }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(Theme.inkSoft).frame(width: 22, height: 22).contentShape(Rectangle())
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("对 \(group.name) 的操作")
                        }
                        .font(Theme.text(13))
                        .monospacedDigit()
                        .padding(.horizontal, 24)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { inspected = group }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

/// What there is to know about one process: who runs it, what started it, and where it lives.
private struct ProcessCard: View {
    let group: ProcessGroup
    let close: () -> Void
    /// Asks to end it; true for by force. The page confirms first.
    let end: (Bool) -> Void
    @State private var detail: ProcessDetail?
    @State private var looked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.id)).resizable().frame(width: 34, height: 34)
                Text(group.name).font(Theme.display(22)).lineLimit(1).truncationMode(.middle)
                Spacer()
                IconButton(title: "关闭", systemImage: "xmark", action: close).keyboardShortcut(.cancelAction)
            }
            Text(summary).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).monospacedDigit().lineLimit(1)
            // What comes from `ps` and launchd arrives a moment after the card opens. The space for it
            // is there from the start, so the card does not grow under the pointer.
            ScrollView {
                if let detail {
                    VStack(alignment: .leading, spacing: 10) {
                        if detail.user == "root" {
                            Text("这个进程在以 root 身份运行，属于系统。").font(Theme.text(11.5, .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Theme.pinkLine.opacity(0.7), in: Capsule())
                        }
                        Text(detail.ancestors.map { "\($0.name) \($0.pid)" }.joined(separator: "  ›  "))
                            .font(Theme.text(12)).lineLimit(1).truncationMode(.head)
                        Rule()
                        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                            field("用户", detail.user)
                            field("已运行", detail.running)
                            field("子进程", "\(detail.children) 个" + (group.count > 1 ? "，这一行一共 \(group.count) 个进程" : ""))
                            if let service = detail.service {
                                field("launchd 服务", service.label)
                                if !service.kind.isEmpty { field("类型", Self.kinds[service.kind] ?? service.kind) }
                                if !service.reason.isEmpty { field("触发原因", service.reason) }
                                field("自动保活", service.keepsAlive ? "是，退出后 launchd 会把它重新拉起来" : "否")
                                // An app opened by the user has no job file; launchd then names who handed it the job.
                                if service.plist.hasPrefix("/") { field("启动文件", AISessions.shortened(service.plist)) }
                            } else {
                                field("启动方式", "不是 launchd 的服务，由上面的父进程启动")
                            }
                            field(group.isApp ? "应用" : "可执行文件", AISessions.shortened(group.id))
                        }
                        Text(detail.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.blueLine.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if looked {
                    Text("它已经不在运行了。").font(Theme.text(13)).foregroundStyle(Theme.inkSoft).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .frame(height: 300)
            HStack(spacing: 8) {
                Button("结束…") { end(false) }.buttonStyle(.quiet)
                Button("强制结束…") { end(true) }.buttonStyle(.quiet)
                Spacer()
                Button("复制摘要", action: copy).buttonStyle(.quiet).disabled(detail == nil)
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.id)]) }.buttonStyle(.primary)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .foregroundStyle(Theme.ink)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.25), radius: 24, y: 10)
        .task(id: group.pid) {
            detail = await Processes.detail(of: group)
            looked = true
        }
    }

    /// launchd's words for what kind of job it is.
    private static let kinds = ["LaunchDaemon": "系统后台服务", "LaunchAgent": "用户后台服务", "Submitted": "打开的应用，由系统交给 launchd", "XPCService": "应用的辅助服务"]

    private var summary: String {
        var parts = ["PID \(group.pid)", "CPU \(group.cpu.formatted(.number.precision(.fractionLength(1))))%", "内存 \(group.memory.formatted(memoryFormat))"]
        if let detail { parts += [detail.user, "已运行 \(detail.running)"] }
        return parts.joined(separator: " · ")
    }

    private func field(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(Theme.text(12)).foregroundStyle(Theme.inkSoft).gridColumnAlignment(.trailing)
            Text(value).font(Theme.text(12.5)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
        }
    }

    private func copy() {
        guard let detail else { return }
        var lines = [group.name, summary, detail.ancestors.map { "\($0.name) \($0.pid)" }.joined(separator: " > ")]
        if let service = detail.service { lines.append("launchd: \(service.label) \(service.plist)") }
        lines += [group.id, detail.command]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// Recent readings as a small filled line; the newest is at the right edge.
struct Sparkline: View {
    let values: [Double]
    /// The reading that reaches the top. Percentages pass 100; nil scales to the largest reading shown.
    var ceiling: Double?
    var height: CGFloat = 30
    var level = Level.fine

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(ceiling ?? values.max() ?? 0, 0.01)
            let step = size.width / CGFloat(Trend.capacity - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width - CGFloat(values.count - 1 - index) * step,
                        y: size.height - 1 - CGFloat(min(value / top, 1)) * (size.height - 2))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(level == .fine ? Theme.blueLine.opacity(0.4) : level.tint.opacity(0.16)))
            context.stroke(line, with: .color(level.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One thin bar per CPU core.
struct CoreBars: View {
    let usage: [Double]

    private struct Core: Identifiable {
        let id: Int
        let usage: Double
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(usage.enumerated().map { Core(id: $0.offset, usage: $0.element) }) { core in
                Capsule()
                    .fill(Level(used: core.usage / 100).tint)
                    .frame(width: 6, height: max(6, 20 * min(core.usage, 100) / 100))
                    .frame(height: 20, alignment: .bottom)
                    .background(Theme.blueLine.opacity(0.4), in: Capsule())
            }
        }
        .accessibilityHidden(true)
    }
}
