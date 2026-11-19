import Foundation
import IOSurface
import SimHostKit

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// The brightness of a BGRA surface at a point from 0 to 1, from 0 to 1.
func level(_ surface: IOSurfaceRef, at point: CGPoint) -> Double {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let x = Int(Double(IOSurfaceGetWidth(surface)) * point.x), y = Int(Double(IOSurfaceGetHeight(surface)) * point.y)
    let pixel = IOSurfaceGetBaseAddress(surface).advanced(by: y * IOSurfaceGetBytesPerRow(surface) + x * 4)
        .assumingMemoryBound(to: UInt8.self)
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
}

/// The brightness of the latest frame, for one thread to wait on while another notes frames.
final class Watch: @unchecked Sendable {
    private let lock = NSCondition()
    private var latest = (level: -1.0, time: 0.0)
    private(set) var frames = 0
    private(set) var firstFrame = 0.0

    func note(_ level: Double, time: Double) {
        lock.lock()
        frames += 1
        if firstFrame == 0 { firstFrame = time }
        latest = (level, time)
        lock.broadcast()
        lock.unlock()
    }

    /// Waits for a frame after `start` that is white (or black) and returns when it was seen.
    func waitFor(white: Bool, after start: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if latest.time >= start, white ? latest.level > 0.8 : latest.level < 0.2 { return latest.time }
            if !lock.wait(until: Date().addingTimeInterval(start + 3 - now())) { return nil }
        }
    }
}

/// Times a touch to the first frame that shows it, against the probe app, like serve-sim-bench.
func bench(udid: String, rounds: Int, throughHost: Bool) throws {
    let point = CGPoint(x: 0.5, y: 0.35)
    let started = now()
    let simulator = try Simulator(udid: udid)
    let panel = simulator.isDuo ? Panel.duoCover : simulator.panels.first!
    let watch = Watch()
    let screens = try Screens(simulator: simulator) { frame in
        guard frame.panel == panel else { return }
        watch.note(level(frame.surface, at: point), time: Double(frame.time) / 1e9)
    }
    let send: (Wire.Phase) -> Void
    if throughHost {
        let client = try HostClient(udid: udid, name: "bench", launch: launch(udid))
        send = { client.send(.touch($0, x: Float(point.x), y: Float(point.y), screen: Wire.Screen(panel), edge: 0)) }
    } else {
        let touchscreen = try Touchscreen(simulator: simulator)
        send = { touchscreen.touch($0 == .up ? .up : .down, at: point, on: panel) }
    }
    print(String(format: "attached and first frame after %.1f ms", (watch.firstFrame - started) * 1000))


    var down: [Double] = [], up: [Double] = []
    Thread.sleep(forTimeInterval: 0.3)
    for _ in 0..<rounds {
        let start = now()
        send(.down)
        if let seen = watch.waitFor(white: true, after: start) { down.append(seen - start) }
        Thread.sleep(forTimeInterval: 0.05 + Double.random(in: 0...0.1))
        let release = now()
        send(.up)
        if let seen = watch.waitFor(white: false, after: release) { up.append(seen - release) }
        Thread.sleep(forTimeInterval: 0.1 + Double.random(in: 0...0.15))
    }
    screens.stop()

    func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted().map { $0 * 1000 }
        guard !sorted.isEmpty else { print("\(name): no frames"); return }
        let pick = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(format: "%@: median %.1f ms, p90 %.1f ms, min %.1f, max %.1f (%d of %d)",
                     name, pick(0.5), pick(0.9), sorted.first!, sorted.last!, sorted.count, rounds))
    }
    report("touch down → white frame", down)
    report("touch up → black frame", up)
    print("frames seen: \(watch.frames)")
}

/// The last orientation of each panel. Screens calls back on its own queue only.
final class Turns: @unchecked Sendable {
    private var last: [Panel: Orientation] = [:]
    func changed(_ panel: Panel, _ orientation: Orientation) -> Bool {
        defer { last[panel] = orientation }
        return last[panel] != orientation
    }
}

/// The command line that starts this simulator's host: this program with `serve`.
func launch(_ udid: String) -> [String] {
    [Bundle.main.executablePath ?? CommandLine.arguments[0], "serve", udid]
}

let usage = """
usage: simhost serve <udid>                   run the host for a simulator
       simhost tap <udid> <x> <y> [cover|inner]   tap at a point from 0 to 1
       simhost type <udid> <text>             type text
       simhost key <udid> <usage>             press a key by HID usage, such as 40 for return
       simhost fold <udid> <degrees> [ms]     set iPhone Duo's hinge
       simhost watch <udid>                   print what every client does
       simhost bench <udid> [rounds] [--host] time a touch to the frame that shows it
"""

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let udid = arguments[1]
    func client(_ onMessage: @escaping @Sendable (Wire.Message) -> Void = { _ in }) throws -> HostClient {
        try HostClient(udid: udid, name: "simhost", launch: launch(udid), onMessage: onMessage)
    }
    switch arguments[0] {
    case "serve":
        try Host(simulator: Simulator(udid: udid)).run()
    case "tap" where arguments.count >= 4:
        let screen: Wire.Screen = arguments.count > 4 ? (arguments[4] == "inner" ? .duoInner : .duoCover)
            : (try Simulator(udid: udid).isDuo ? .duoCover : .main)
        let x = Float(arguments[2]) ?? 0.5, y = Float(arguments[3]) ?? 0.5
        let host = try client()
        host.send(.touch(.down, x: x, y: y, screen: screen, edge: 0))
        usleep(50_000)
        host.send(.touch(.up, x: x, y: y, screen: screen, edge: 0))
    case "type" where arguments.count >= 3:
        try client().send(.type(arguments[2...].joined(separator: " ")))
    case "key" where arguments.count >= 3:
        let host = try client()
        let usage = UInt32(arguments[2]) ?? 40
        host.send(.key(usage: usage, down: true))
        host.send(.key(usage: usage, down: false))
    case "fold" where arguments.count >= 3:
        try client().send(.fold(degrees: Double(arguments[2]) ?? 0, milliseconds: arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0))
    case "watch":
        let host = try client { message in
            if case .event(let client, let name, let time, let input) = message {
                print(String(format: "%.3f", Double(time) / 1e9), "client \(client) \(name):", input)
            } else if case .state(let state) = message {
                print("state: hinge \(state.hinge.map { String(format: "%.1f", $0) } ?? "unknown"), held \(state.held)")
            }
        }
        print("watching as client \(host.id)")
        // Each panel's interface orientation, printed when it changes.
        let turns = Turns()
        let screens = try Screens(simulator: Simulator(udid: udid)) { frame in
            if turns.changed(frame.panel, frame.orientation) { print("screen: \(frame.panel) interface \(frame.orientation)") }
        }
        withExtendedLifetime(screens) { dispatchMain() }
    case "bench":
        try bench(udid: udid, rounds: arguments.dropFirst(2).compactMap { Int($0) }.first ?? 40, throughHost: arguments.contains("--host"))
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("simhost: \(error)\n".utf8))
    exit(1)
}
