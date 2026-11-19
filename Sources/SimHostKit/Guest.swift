import CryptoKit
import Foundation

/// simhost's helper inside the simulator: a virtual keyboard, and on iPhone Duo the hinge,
/// the held orientation and the hardware buttons.
///
/// The helper is built from source with the installed Xcode on first use and kept in
/// ~/Library/Caches/simhost, so it always matches the simulator SDK.
public final class Guest: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var waiting: [(Bool) -> Void] = []
    private var pending = Data()

    /// Starts the helper and waits until its devices are ready.
    public init(simulator: Simulator) throws(SimHostError) {
        let helper = try Self.build()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", simulator.udid, helper.path]
        var environment = ProcessInfo.processInfo.environment
        if simulator.isDuo { environment["SIMCTL_CHILD_SIMHOST_DUO"] = "1" }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw SimHostError("could not start the helper in the simulator: \(error)") }

        // The first line is READY. What came with it is the start of the next lines.
        var first = Data()
        while !first.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw SimHostError("the helper in the simulator stopped before it was ready") }
            first.append(chunk)
        }
        let rest = first[(first.firstIndex(of: UInt8(ascii: "\n"))! + 1)...]
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData) }
        if !rest.isEmpty { read(Data(rest)) }
    }

    deinit { stop() }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// A key by its HID usage on the keyboard page, such as 0x28 for return.
    public func key(_ usage: UInt32, down: Bool, done: ((Bool) -> Void)? = nil) {
        send("key \(usage) \(down ? 1 : 0)", done: done)
    }

    /// Types printable ASCII on a US layout. A line break is the return key. Other characters
    /// are left out, and then the answer is false.
    public func type(_ text: String, done: ((Bool) -> Void)? = nil) {
        var commands: [String] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if index > 0 { commands += ["key 40 1", "key 40 0"] }
            if !line.isEmpty { commands.append("type " + line) }
        }
        guard !commands.isEmpty else { done?(true); return }
        let all = Answers(count: commands.count, done: done)
        for command in commands { send(command) { all.add($0) } }
    }

    /// Sets iPhone Duo's hinge, from 0 (closed) to 180 (open flat).
    public func fold(to degrees: Double, done: ((Bool) -> Void)? = nil) {
        send("angle \(degrees)", done: done)
    }

    /// Moves iPhone Duo's hinge over `milliseconds`, one step per frame.
    public func sweep(from: Double, to: Double, milliseconds: Double, done: ((Bool) -> Void)? = nil) {
        send("sweep \(from) \(to) \(milliseconds)", done: done)
    }

    /// iPhone Duo's held orientation: 1 portrait, 2 upside down, 3 landscape left, 4 landscape right.
    public func orientation(_ value: Int, done: ((Bool) -> Void)? = nil) {
        send("orientation \(value)", done: done)
    }

    /// An iPhone Duo hardware button by HID page and usage.
    public func button(page: UInt32, usage: UInt32, down: Bool, done: ((Bool) -> Void)? = nil) {
        send("button \(page) \(usage) \(down ? 1 : 0)", done: done)
    }

    /// Sends a command and waits for its answer. For tests and the command line.
    @discardableResult
    public func sendAndWait(_ command: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        send(command) { ok = $0; semaphore.signal() }
        semaphore.wait()
        return ok
    }

    func send(_ command: String, done: ((Bool) -> Void)?) {
        lock.withLock {
            waiting.append(done ?? { _ in })
            try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        }
    }

    private func read(_ data: Data) {
        var answers: [((Bool) -> Void, Bool)] = []
        lock.withLock {
            pending.append(data)
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if !waiting.isEmpty { answers.append((waiting.removeFirst(), line == "OK")) }
            }
        }
        for (done, ok) in answers { done(ok) }
    }

    /// Builds the helper for the simulator SDK, once per source and SDK.
    static func build() throws(SimHostError) -> URL {
        let code = Data(guestSource.utf8)
        let sdk = run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
        let key = SHA256.hash(data: code + Data(sdk.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("simhost")
        let helper = caches.appendingPathComponent("guest-\(key)")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafeBytes(of: arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let partial = helper.appendingPathExtension("partial")
        let source = helper.appendingPathExtension("m")
        guard (try? code.write(to: source)) != nil else { throw SimHostError("could not write the helper's source to \(source.path)") }
        defer { try? FileManager.default.removeItem(at: source) }
        let result = run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "clang", "-arch", machine, "-mios-simulator-version-min=15.0",
                                            "-isysroot", sdk, "-fobjc-arc", "-framework", "Foundation", "-Wl,-adhoc_codesign",
                                            "-o", partial.path, source.path])
        guard FileManager.default.isExecutableFile(atPath: partial.path),
              (try? FileManager.default.moveItem(at: partial, to: helper)) != nil || FileManager.default.isExecutableFile(atPath: helper.path)
        else { throw SimHostError("could not build the helper for the simulator: \(result)") }
        return helper
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Collects the answers to several commands and reports once, true when all were OK.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    private var ok = true
    private let done: ((Bool) -> Void)?

    init(count: Int, done: ((Bool) -> Void)?) {
        left = count
        self.done = done
    }

    func add(_ answer: Bool) {
        let finished: Bool? = lock.withLock {
            ok = ok && answer
            left -= 1
            return left == 0 ? ok : nil
        }
        if let finished { done?(finished) }
    }
}
