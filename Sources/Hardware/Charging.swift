import Foundation
import IOKit

/// The System Management Controller: the chip that, among much else, decides whether the battery
/// charges. Its keys are four letters, undocumented, and differ from one generation of Mac to the next.
/// Anyone may read them; writing takes root.
public enum SMC {
    /// The one structure every SMC call passes both ways. Its layout is the C one, byte for byte; the
    /// `gap` is the padding C puts after `info`, which Swift would otherwise leave out.
    private struct Message {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var info: (size: UInt32, type: UInt32, attributes: UInt8) = (0, 0, 0)
        var gap: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 { case read = 5, write = 6, describe = 9 }

    /// True when the structure above still lines up with the C one the driver expects.
    public static var layoutIsRight: Bool {
        MemoryLayout<Message>.stride == 80 && MemoryLayout<Message>.offset(of: \.limits) == 12 && MemoryLayout<Message>.offset(of: \.info) == 28
            && MemoryLayout<Message>.offset(of: \.result) == 40 && MemoryLayout<Message>.offset(of: \.data32) == 44
            && MemoryLayout<Message>.offset(of: \.bytes) == 48
    }

    private static let connection: io_connect_t? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess ? connection : nil
    }()

    private static func send(_ message: Message) -> Message? {
        guard layoutIsRight, let connection else { return nil }
        var (input, output, size) = (message, Message(), MemoryLayout<Message>.stride)
        let sent = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Message>.stride, &output, &size)
        return sent == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// A key's bytes, or nil when this Mac has no such key.
    public static func read(_ key: String) -> [UInt8]? {
        guard key.utf8.count == 4, let about = send(Message(key: code(key), command: Command.describe.rawValue)) else { return nil }
        var ask = Message(key: code(key), command: Command.read.rawValue)
        ask.info.size = about.info.size
        guard let answer = send(ask) else { return nil }
        return withUnsafeBytes(of: answer.bytes) { Array($0.prefix(Int(about.info.size))) }
    }

    /// Sets a key's bytes: as many as the key holds, or nothing is written. False without root.
    public static func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard key.utf8.count == 4, let about = send(Message(key: code(key), command: Command.describe.rawValue)),
              Int(about.info.size) == bytes.count, bytes.count <= 32 else { return false }
        var order = Message(key: code(key), command: Command.write.rawValue)
        order.info.size = about.info.size
        withUnsafeMutableBytes(of: &order.bytes) { $0.copyBytes(from: bytes) }
        return send(order) != nil
    }
}

/// Whether the battery is allowed to charge, and how full it is.
public enum Charging {
    /// The keys that pause charging. Macs with Apple silicon had `CH0B` and `CH0C` (2 = paused) until
    /// the firmware that came with macOS 15, which replaced them with `CHTE` (first byte 1 = paused).
    private enum Switch { case chte, ch0 }

    private static let found: Switch? =
        SMC.read("CHTE")?.count == 4 ? .chte : SMC.read("CH0B")?.count == 1 && SMC.read("CH0C")?.count == 1 ? .ch0 : nil

    /// False on a Mac whose charging cannot be paused this way (Intel, or keys this code does not know).
    public static var canBePaused: Bool { found != nil }

    /// True while charging is paused; nil when that cannot be told.
    public static var isPaused: Bool? {
        switch found {
        case .chte: SMC.read("CHTE").map { $0[0] != 0 }
        case .ch0: SMC.read("CH0B").map { $0[0] == 2 }
        case nil: nil
        }
    }

    /// Pauses charging or lets it go on. Needs root; returns whether the Mac took it.
    public static func setPaused(_ paused: Bool) -> Bool {
        switch found {
        case .chte: SMC.write("CHTE", [paused ? 1 : 0, 0, 0, 0])
        case .ch0: [SMC.write("CH0B", [paused ? 2 : 0]), SMC.write("CH0C", [paused ? 2 : 0])].allSatisfy { $0 }
        case nil: false
        }
    }

    /// The battery's charge in percent and whether the Mac is on mains power; nil without a battery.
    public static func battery() -> (percent: Int, pluggedIn: Bool)? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let now = value("CurrentCapacity") as? Int, let full = value("MaxCapacity") as? Int, full > 0 else { return nil }
        return (min(100, now * 100 / full), value("ExternalConnected") as? Bool ?? false)
    }
}

/// 电池养护: keeping the battery around 80% instead of full, which slows its ageing.
public enum BatteryCare {
    public enum Mode: String, Sendable {
        case off
        /// Stop charging at the limit.
        case limit
        /// Charge to 100% this once; the limit is not applied until the mode is set back.
        case full
    }

    public static let limit = 80

    /// Whether charging should be paused. Between the limit and two points under it nothing changes,
    /// so the charger is not switched on and off as the reading wobbles.
    public static func shouldPause(mode: Mode, percent: Int, pausedNow: Bool) -> Bool {
        guard mode == .limit else { return false }
        if percent >= limit { return true }
        return percent >= limit - 2 && pausedNow
    }
}
