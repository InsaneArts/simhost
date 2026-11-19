import CSimHost
import Foundation

/// The one process that owns a simulator's input. Clients connect on a Unix socket, send input,
/// and hear about the input of every other client, so each can draw what the others do.
///
/// Screens are not served here: a client on the same Mac reads them straight from the
/// simulator with `Screens`, which costs no copy and no encoding.
public final class Host: @unchecked Sendable {
    /// The socket of a simulator's host. Only this user can open it: it is in the user's own temporary folder.
    public static func socketPath(udid: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("simhost-\(udid.uppercased()).sock")
    }

    private let simulator: Simulator
    private let queue = DispatchQueue(label: "simhost.host", qos: .userInteractive)
    private let guestQueue = DispatchQueue(label: "simhost.guest", qos: .userInteractive)
    private let touchscreen: Touchscreen
    private var guest: Guest?
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [UInt32: Connection] = [:]
    private var nextClient: UInt32 = 1
    /// Each client's finger while it is down.
    private var fingers: [UInt32: (screen: Wire.Screen, point: CGPoint)] = [:]
    private var state: Wire.State
    /// The angle the host last set the hinge to.
    private var setAngle: Double?
    private var signals: [DispatchSourceSignal] = []
    private var idleSince = Date()

    public init(simulator: Simulator) throws(SimHostError) {
        guard simulator.isBooted else { throw SimHostError("\(simulator.name) is not booted") }
        self.simulator = simulator
        touchscreen = try Touchscreen(simulator: simulator)
        state = Wire.State(hinge: nil, held: .portrait)
        // The helper takes most of a second to start. Touches do not wait for it.
        guestQueue.async { [self] in
            do {
                let guest = try Guest(simulator: simulator)
                queue.sync { self.guest = guest }
            } catch {
                FileHandle.standardError.write(Data("simhost: \(error)\n".utf8))
            }
        }
        try listen()
    }

    /// Serves until the simulator shuts down, or until no client has been connected for ten minutes.
    public func run() -> Never {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [self] in
            let idle = clients.isEmpty && Date().timeIntervalSince(idleSince) > 600
            if idle || !simulator.isBooted { finish() }
        }
        timer.resume()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in finish() }
            source.resume()
            signals.append(source)
        }
        dispatchMain()
    }

    /// Stops what the host started in the simulator, and exits.
    private func finish() -> Never {
        unlink(Self.socketPath(udid: simulator.udid))
        guest?.stop()
        exit(0)
    }

    // MARK: Connections

    private func listen() throws(SimHostError) {
        let path = Self.socketPath(udid: simulator.udid)
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SimHostError("the socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 16) == 0 else { throw SimHostError("could not listen on \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        acceptSource?.setEventHandler { [self] in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let id = nextClient
            nextClient += 1
            clients[id] = Connection(fd: fd, id: id, queue: queue, onMessage: { [weak self] in self?.received($0, from: id) },
                                     onClose: { [weak self] in self?.closed(id) })
        }
        acceptSource?.resume()
    }

    private func closed(_ id: UInt32) {
        clients[id] = nil
        if clients.isEmpty { idleSince = Date() }
        // A client that leaves with a finger down lifts it.
        if let finger = fingers[id] {
            apply(.touch(.up, x: Float(finger.point.x), y: Float(finger.point.y), screen: finger.screen, edge: 0), from: id)
        }
    }

    private func received(_ message: Wire.Message, from id: UInt32) {
        guard let client = clients[id] else { return }
        switch message {
        case .hello(_, let name):
            client.name = name
            client.send(.welcome(version: Wire.version, client: id))
            client.send(.state(state))
        case .input(let input):
            apply(input, from: id)
        default:
            break
        }
    }

    // MARK: Input

    private func apply(_ input: Wire.Input, from id: UInt32) {
        switch input {
        case .touch(let phase, let x, let y, let screen, let edge):
            touch(phase, at: CGPoint(x: Double(x), y: Double(y)), screen: screen, edge: edge, from: id)
        case .pinch(let phase, let x1, let y1, let x2, let y2, let screen):
            touchscreen.touch(Self.phase(phase), at: CGPoint(x: Double(x1), y: Double(y1)), and: CGPoint(x: Double(x2), y: Double(y2)), on: Self.panel(screen))
        case .key(let usage, let down):
            withGuest { $0.key(usage, down: down) }
        case .type(let text):
            withGuest { $0.type(text) }
        case .fold(let degrees, let milliseconds):
            let from = setAngle
            setAngle = degrees
            withGuest { guest in
                if milliseconds > 0, let from { guest.sweep(from: from, to: degrees, milliseconds: milliseconds) } else { guest.fold(to: degrees) }
            }
            change { $0.hinge = degrees }
        case .orientation(let value):
            withGuest { $0.orientation(Int(value.rawValue)) }
            change { $0.held = value }
        case .button(let page, let usage, let down):
            if simulator.isDuo { withGuest { $0.button(page: page, usage: usage, down: down) } }
            else { touchscreen.button(page: page, usage: usage, down: down) }
        }
        let name = clients[id]?.name ?? ""
        let event = Wire.encode(.event(client: id, name: name, time: DispatchTime.now().uptimeNanoseconds, input: input))
        for (other, connection) in clients where other != id { connection.send(raw: event) }
    }

    /// One client's finger. When another client has a finger down on the same screen, both go
    /// to the simulator as one two-finger touch, so neither cuts the other short.
    private func touch(_ phase: Wire.Phase, at point: CGPoint, screen: Wire.Screen, edge: UInt8, from id: UInt32) {
        if phase == .up { fingers[id] = nil } else { fingers[id] = (screen, point) }
        let other = fingers.filter { $0.key != id && $0.value.screen == screen }.min { $0.key < $1.key }
        let panel = Self.panel(screen)
        if let other {
            if phase == .up {
                touchscreen.touch(.move, at: other.value.point, on: panel)
            } else {
                let (first, second) = other.key < id ? (other.value.point, point) : (point, other.value.point)
                touchscreen.touch(.move, at: first, and: second, on: panel)
            }
        } else {
            touchscreen.touch(Self.phase(phase), at: point, on: panel, edge: SHEdge(rawValue: UInt32(edge)) ?? .none)
        }
    }

    /// Changes the state, and tells every client when that changed something.
    private func change(_ edit: (inout Wire.State) -> Void) {
        var new = state
        edit(&new)
        guard new != state else { return }
        state = new
        broadcast(.state(state))
    }

    private func withGuest(_ work: @escaping (Guest) -> Void) {
        if let guest { work(guest); return }
        // Before the helper is ready, its work waits in line behind its start.
        guestQueue.async { [self] in
            if let guest = queue.sync(execute: { self.guest }) { work(guest) }
        }
    }

    private func broadcast(_ message: Wire.Message) {
        let data = Wire.encode(message)
        for connection in clients.values { connection.send(raw: data) }
    }

    private static func panel(_ screen: Wire.Screen) -> Panel {
        switch screen {
        case .main: Panel(width: 0, height: 0)
        case .duoCover: .duoCover
        case .duoInner: .duoInner
        }
    }

    private static func phase(_ phase: Wire.Phase) -> Touchscreen.Phase {
        switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        }
    }
}

/// One client's socket, read and written on the host's queue.
final class Connection: @unchecked Sendable {
    let id: UInt32
    var name = ""
    private let fd: Int32
    private let source: DispatchSourceRead
    private var reader = Wire.Reader()
    private var closed = false
    private let onClose: () -> Void

    init(fd: Int32, id: UInt32, queue: DispatchQueue, onMessage: @escaping (Wire.Message) -> Void, onClose: @escaping () -> Void) {
        self.fd = fd
        self.id = id
        self.onClose = onClose
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN { return }
            guard count > 0 else { self.close(); return }
            for message in self.reader.read(Data(buffer[0..<count])) { onMessage(message) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    func send(_ message: Wire.Message) { send(raw: Wire.encode(message)) }

    /// A client that cannot take a message at once is too slow to follow, and is let go.
    func send(raw data: Data) {
        guard !closed else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != data.count { close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
        onClose()
    }
}
