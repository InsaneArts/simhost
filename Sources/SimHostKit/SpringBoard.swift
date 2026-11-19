import Foundation

/// Which of iPhone Duo's panels shows the interface, as SpringBoard logs it.
///
/// simhost reads SpringBoard's log with `log stream` inside the simulator, as serve-sim does.
/// SimulatorKit has no property for it: both panels stay powered, and both keep their backlight.
final class SpringBoard: @unchecked Sendable {
    private static let predicate = #"process == "SpringBoard" AND category == "DisplayContentMode" AND (eventMessage CONTAINS ".cover:pri" OR eventMessage CONTAINS ".inner:pri")"#

    private let udid: String
    private let queue: DispatchQueue
    private let onLit: (Wire.Screen) -> Void
    private var stream: Process?
    /// The end of the stream that is not a whole line yet. Only the stream's reader touches it.
    private var pending = Data()
    private var heardPanel = false
    private var stopped = false

    /// `onLit` runs on `queue`, with the panel that shows the interface now.
    init(udid: String, queue: DispatchQueue, onLit: @escaping (Wire.Screen) -> Void) {
        self.udid = udid
        self.queue = queue
        self.onLit = onLit
        listen()
        seed()
    }

    /// Ends the stream. Call it on the queue.
    func stop() {
        stopped = true
        stream?.terminate()
    }

    /// The lit panel that one line of the log tells. Nil when it tells none.
    static func litPanel(in line: Substring) -> Wire.Screen? {
        guard line.contains("DisplayContentMode]"), let panel = line.firstMatch(of: /\.(cover|inner):pri\b/) else { return nil }
        // A line in a switch names each panel's state before and after it, as in
        // ".inner:off→pri .cover:pri→aux". The state before the arrow is the state now.
        return panel.1 == "cover" ? .duoCover : .duoInner
    }

    private func listen() {
        let process = Self.simctl(["spawn", udid, "log", "stream", "--style", "compact", "--predicate", Self.predicate])
        let output = Pipe()
        process.standardOutput = output
        pending = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            pending.append(data)
            var panels: [Wire.Screen] = []
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if let panel = Self.litPanel(in: line[...]) { panels.append(panel) }
            }
            guard let panel = panels.last else { return }
            queue.async {
                self.heardPanel = true
                self.onLit(panel)
            }
        }
        // The stream ends when the simulator restarts. A new one starts a moment later.
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            queue.asyncAfter(deadline: .now() + 1) { if !self.stopped { self.listen() } }
        }
        queue.async { [self] in
            guard !stopped, (try? process.run()) != nil else { return }
            stream = process
        }
    }

    /// The panel from this boot's last switch. A switch heard live wins over it.
    private func seed() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let process = Self.simctl(["spawn", udid, "log", "show", "--last", "boot", "--style", "compact", "--predicate", Self.predicate])
            let output = Pipe()
            process.standardOutput = output
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let last = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed().lazy.compactMap(Self.litPanel).first else { return }
            queue.async { if !self.heardPanel, !self.stopped { self.onLit(last) } }
        }
    }

    private static func simctl(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        process.standardError = FileHandle.nullDevice
        return process
    }
}
