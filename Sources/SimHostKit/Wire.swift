import Foundation

/// simhost's protocol between a host and its clients, on a Unix socket.
///
/// Every message is `[length: UInt32 LE][kind: UInt8][body]`, where the length counts the kind
/// and the body. Numbers in a body are little endian. Points go from 0 to 1, origin top left.
public enum Wire {
    public static let version: UInt16 = 1

    /// Which panel a touch is on.
    public enum Screen: UInt8, Sendable {
        case main = 0, duoCover = 1, duoInner = 2

        public init(_ panel: Panel) {
            self = panel == .duoCover ? .duoCover : panel == .duoInner ? .duoInner : .main
        }
    }

    public enum Phase: UInt8, Sendable { case down = 0, move = 1, up = 2 }

    /// What the host knows about the device. Every client hears it when it changes.
    public struct State: Equatable, Sendable {
        /// The hinge angle in degrees, as CoreMotion reads it in the simulator. Nil until the helper there starts.
        public var hinge: Double?
        /// How the device is held, as a client last set it.
        public var held: Orientation

        public init(hinge: Double?, held: Orientation) {
            self.hinge = hinge
            self.held = held
        }
    }

    /// What a client asks the host to do. The host tells every other client about each one.
    public enum Input: Equatable, Sendable {
        /// One finger of this client.
        case touch(Phase, x: Float, y: Float, screen: Screen, edge: UInt8)
        /// Two fingers of this client.
        case pinch(Phase, x1: Float, y1: Float, x2: Float, y2: Float, screen: Screen)
        /// A keyboard key by HID usage on page 7.
        case key(usage: UInt32, down: Bool)
        /// Text to type. Printable ASCII on a US layout; a line break is the return key.
        case type(String)
        /// iPhone Duo's hinge, from 0 to 180. Over `milliseconds`, or at once when it is 0.
        case fold(degrees: Double, milliseconds: Double)
        /// How iPhone Duo is held.
        case orientation(Orientation)
        /// A hardware button by HID page and usage.
        case button(page: UInt32, usage: UInt32, down: Bool)
    }

    public enum Message: Equatable, Sendable {
        /// The first message of a client: its name, for other clients to show.
        case hello(version: UInt16, name: String)
        /// The host's answer to hello: the client's number.
        case welcome(version: UInt16, client: UInt32)
        case input(Input)
        /// Something a client did, as the host passes it on. `time` is the host's uptime in nanoseconds.
        case event(client: UInt32, name: String, time: UInt64, input: Input)
        case state(State)
    }

    // MARK: Encoding

    public static func encode(_ message: Message) -> Data {
        var body = Writer()
        let kind: UInt8
        switch message {
        case .hello(let version, let name):
            kind = 0x01; body.u16(version); body.string(name)
        case .welcome(let version, let client):
            kind = 0x02; body.u16(version); body.u32(client)
        case .input(let input):
            kind = 0x10; body.input(input)
        case .event(let client, let name, let time, let input):
            kind = 0x20; body.u32(client); body.u64(time); body.string(name); body.input(input)
        case .state(let state):
            kind = 0x30; body.f64(state.hinge ?? .nan); body.u8(state.held.rawValue)
        }
        var data = Data()
        var length = UInt32(body.data.count + 1).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(kind)
        data.append(body.data)
        return data
    }

    /// Splits a byte stream into messages. A message it cannot read is skipped.
    public struct Reader: Sendable {
        private var pending = Data()
        public init() {}

        public mutating func read(_ bytes: Data) -> [Message] {
            pending.append(bytes)
            var messages: [Message] = []
            var offset = pending.startIndex
            while pending.endIndex - offset >= 4 {
                let length = Int(pending[offset]) | Int(pending[offset + 1]) << 8 | Int(pending[offset + 2]) << 16 | Int(pending[offset + 3]) << 24
                guard length >= 1, length <= 1 << 20 else { pending.removeAll(); return messages }
                guard pending.endIndex - offset >= 4 + length else { break }
                var body = Scanner(pending[(offset + 5)..<(offset + 4 + length)])
                if let message = Wire.decode(kind: pending[offset + 4], &body) { messages.append(message) }
                offset += 4 + length
            }
            pending.removeSubrange(pending.startIndex..<offset)
            return messages
        }
    }

    static func decode(kind: UInt8, _ body: inout Scanner) -> Message? {
        switch kind {
        case 0x01: guard let version = body.u16(), let name = body.string() else { return nil }; return .hello(version: version, name: name)
        case 0x02: guard let version = body.u16(), let client = body.u32() else { return nil }; return .welcome(version: version, client: client)
        case 0x10: return body.input().map(Message.input)
        case 0x20:
            guard let client = body.u32(), let time = body.u64(), let name = body.string(), let input = body.input() else { return nil }
            return .event(client: client, name: name, time: time, input: input)
        case 0x30:
            guard let hinge = body.f64(), let held = body.u8().flatMap(Orientation.init) else { return nil }
            return .state(State(hinge: hinge.isNaN ? nil : hinge, held: held))
        default: return nil
        }
    }
}

struct Writer {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ value: Float) { u32(value.bitPattern) }
    mutating func f64(_ value: Double) { u64(value.bitPattern) }
    mutating func string(_ value: String) { let bytes = Data(value.utf8); u32(UInt32(bytes.count)); data.append(bytes) }

    mutating func input(_ input: Wire.Input) {
        switch input {
        case .touch(let phase, let x, let y, let screen, let edge):
            u8(1); u8(phase.rawValue); f32(x); f32(y); u8(screen.rawValue); u8(edge)
        case .pinch(let phase, let x1, let y1, let x2, let y2, let screen):
            u8(2); u8(phase.rawValue); f32(x1); f32(y1); f32(x2); f32(y2); u8(screen.rawValue)
        case .key(let usage, let down):
            u8(3); u32(usage); u8(down ? 1 : 0)
        case .type(let text):
            u8(4); string(text)
        case .fold(let degrees, let milliseconds):
            u8(5); f64(degrees); f64(milliseconds)
        case .orientation(let value):
            u8(6); u8(value.rawValue)
        case .button(let page, let usage, let down):
            u8(7); u32(page); u32(usage); u8(down ? 1 : 0)
        }
    }
}

struct Scanner {
    private var bytes: Data.SubSequence
    init(_ bytes: Data.SubSequence) { self.bytes = bytes }

    private mutating func take(_ count: Int) -> Data.SubSequence? {
        guard bytes.count >= count else { return nil }
        defer { bytes = bytes.dropFirst(count) }
        return bytes.prefix(count)
    }
    private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
        take(MemoryLayout<T>.size).map { $0.reversed().reduce(T(0)) { $0 << 8 | T($1) } }
    }
    mutating func u8() -> UInt8? { integer(UInt8.self) }
    mutating func u16() -> UInt16? { integer(UInt16.self) }
    mutating func u32() -> UInt32? { integer(UInt32.self) }
    mutating func u64() -> UInt64? { integer(UInt64.self) }
    mutating func f32() -> Float? { u32().map(Float.init(bitPattern:)) }
    mutating func f64() -> Double? { u64().map(Double.init(bitPattern:)) }
    mutating func string() -> String? {
        guard let count = u32(), count <= 1 << 20, let bytes = take(Int(count)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func bool() -> Bool? { u8().map { $0 != 0 } }

    mutating func input() -> Wire.Input? {
        switch u8() {
        case 1:
            guard let phase = u8().flatMap(Wire.Phase.init), let x = f32(), let y = f32(),
                  let screen = u8().flatMap(Wire.Screen.init), let edge = u8() else { return nil }
            return .touch(phase, x: x, y: y, screen: screen, edge: edge)
        case 2:
            guard let phase = u8().flatMap(Wire.Phase.init), let x1 = f32(), let y1 = f32(), let x2 = f32(), let y2 = f32(),
                  let screen = u8().flatMap(Wire.Screen.init) else { return nil }
            return .pinch(phase, x1: x1, y1: y1, x2: x2, y2: y2, screen: screen)
        case 3: guard let usage = u32(), let down = bool() else { return nil }; return .key(usage: usage, down: down)
        case 4: return string().map(Wire.Input.type)
        case 5: guard let degrees = f64(), let ms = f64() else { return nil }; return .fold(degrees: degrees, milliseconds: ms)
        case 6: return u8().flatMap(Orientation.init).map(Wire.Input.orientation)
        case 7: guard let page = u32(), let usage = u32(), let down = bool() else { return nil }; return .button(page: page, usage: usage, down: down)
        default: return nil
        }
    }
}
