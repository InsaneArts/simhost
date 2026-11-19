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
func bench(udid: String, rounds: Int) throws {
    let point = CGPoint(x: 0.5, y: 0.35)
    let started = now()
    let simulator = try Simulator(udid: udid)
    let panel = simulator.isDuo ? Panel.duoCover : simulator.panels.first!
    let watch = Watch()
    let screens = try Screens(simulator: simulator) { frame in
        guard frame.panel == panel else { return }
        watch.note(level(frame.surface, at: point), time: Double(frame.time) / 1e9)
    }
    let touchscreen = try Touchscreen(simulator: simulator)
    print(String(format: "attached and first frame after %.1f ms", (watch.firstFrame - started) * 1000))


    var down: [Double] = [], up: [Double] = []
    Thread.sleep(forTimeInterval: 0.3)
    for _ in 0..<rounds {
        let start = now()
        touchscreen.touch(.down, at: point, on: panel)
        if let seen = watch.waitFor(white: true, after: start) { down.append(seen - start) }
        Thread.sleep(forTimeInterval: 0.05 + Double.random(in: 0...0.1))
        let release = now()
        touchscreen.touch(.up, at: point, on: panel)
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

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "bench" where arguments.count >= 2:
        try bench(udid: arguments[1], rounds: arguments.count > 2 ? Int(arguments[2]) ?? 40 : 40)
    default:
        print("usage: simhost bench <udid> [rounds]")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("simhost: \(error)\n".utf8))
    exit(1)
}
