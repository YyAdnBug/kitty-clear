import Foundation
import Hardware

// The helper behind KittyClear's 电池养护. It runs as root, because only root may tell the Mac to stop
// charging, and does nothing else: every twenty seconds it reads the one word the app has written to
// the file named on its command line (off, limit or full) and pauses or resumes charging to match.
// When it is stopped it hands charging back to macOS first.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: kittyclear-battery <mode file>\n".utf8))
    exit(64)
}
let modeFile = CommandLine.arguments[1]

func apply() {
    let word = (try? String(contentsOfFile: modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let mode = BatteryCare.Mode(rawValue: word) ?? .off
    // Without a reading of the battery, or of the switch, the safe thing is to let it charge.
    guard let battery = Charging.battery(), let pausedNow = Charging.isPaused else {
        _ = Charging.setPaused(false)
        return
    }
    let pause = BatteryCare.shouldPause(mode: mode, percent: battery.percent, pausedNow: pausedNow)
    if pause != pausedNow, !Charging.setPaused(pause) {
        FileHandle.standardError.write(Data("could not \(pause ? "pause" : "resume") charging at \(battery.percent)%\n".utf8))
    }
}

var sources: [DispatchSourceSignal] = []
for stop in [SIGTERM, SIGINT] {
    signal(stop, SIG_IGN) // the dispatch source below gets it instead
    let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
    source.setEventHandler {
        _ = Charging.setPaused(false)
        exit(0)
    }
    source.resume()
    sources.append(source)
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .seconds(20))
timer.setEventHandler(handler: apply)
timer.resume()
dispatchMain()
