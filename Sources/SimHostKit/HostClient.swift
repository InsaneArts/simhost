import Foundation

/// A connection to a simulator's host.
public final class HostClient: @unchecked Sendable {
    /// The client's number at the host.
    public private(set) var id: UInt32 = 0
    private let fd: Int32
    private let queue = DispatchQueue(label: "simhost.client", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var reader = Wire.Reader()
    private let lock = NSLock()
    private let onMessage: @Sendable (Wire.Message) -> Void

    /// Connects to the host of `udid`. When none runs and `launch` is given, starts it with that
    /// command line, in a session of its own so that it outlives this process, and waits up to
    /// five seconds for it. `onMessage` runs on the client's queue for each event and state.
    public init(udid: String, name: String, launch: [String]? = nil,
                onMessage: @escaping @Sendable (Wire.Message) -> Void = { _ in }) throws(SimHostError) {
        self.onMessage = onMessage
        let path = Host.socketPath(udid: udid)
        var fd = Self.connect(path)
        if fd < 0, let launch {
            try Self.spawn(launch)
            let deadline = Date().addingTimeInterval(5)
            while fd < 0, Date() < deadline {
                usleep(20_000)
                fd = Self.connect(path)
            }
        }
        guard fd >= 0 else { throw SimHostError("no simhost runs for \(udid)") }
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // The welcome comes first. Reading it here gives the client its number before init returns.
        write(.hello(version: Wire.version, name: name))
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Messages that came in the same read as the welcome, such as the state, go to `onMessage`.
        var early: [Wire.Message] = []
        while early.isEmpty {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { Darwin.close(fd); throw SimHostError("the host closed the connection") }
            early = Array(reader.read(Data(buffer[0..<count])).drop { message in
                guard case .welcome(_, let client) = message else { return true }
                id = client
                return false
            })
        }
        early.removeFirst()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(self.fd, &buffer, buffer.count)
            guard count > 0 else { self.source?.cancel(); return }
            for message in self.reader.read(Data(buffer[0..<count])) { self.onMessage(message) }
        }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        // Queued before the source starts, so they come before anything the source reads.
        queue.async { [early] in early.forEach(onMessage) }
        source.resume()
        self.source = source
    }

    deinit { close() }

    public func close() {
        source?.cancel()
        source = nil
    }

    /// Sends input. It is on the socket when this returns.
    public func send(_ input: Wire.Input) {
        write(.input(input))
    }

    private func write(_ message: Wire.Message) {
        let data = Wire.encode(message)
        lock.withLock { _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }
    }

    private static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return fd }
        Darwin.close(fd)
        return -1
    }

    private static func spawn(_ command: [String]) throws(SimHostError) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let arguments = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, command[0], &actions, &attributes, arguments, environ)
        guard result == 0 else { throw SimHostError("could not start the host: \(String(cString: strerror(result)))") }
    }
}
