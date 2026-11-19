import Foundation
import SimHostKit
import Testing

struct WireTests {
    static let messages: [Wire.Message] = [
        .hello(version: 1, name: "duorex"),
        .welcome(version: 1, client: 7),
        .input(.touch(.down, x: 0.25, y: 0.75, screen: .duoInner, edge: 3)),
        .input(.pinch(.move, x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4, screen: .duoCover)),
        .input(.key(usage: 40, down: true)),
        .input(.type("Hello, world!\n")),
        .input(.fold(degrees: 130, milliseconds: 250)),
        .input(.orientation(.landscapeRight)),
        .input(.button(page: 0x0C, usage: 0xE9, down: false)),
        .event(client: 3, name: "agent", time: 123_456_789, input: .touch(.up, x: 0.5, y: 0.5, screen: .main, edge: 0)),
        .state(Wire.State(hinge: 92.6, held: .upsideDown, lit: .duoInner)),
        .state(Wire.State(hinge: nil, held: .portrait, lit: nil)),
    ]

    @Test(arguments: messages) func roundTrip(_ message: Wire.Message) {
        var reader = Wire.Reader()
        #expect(reader.read(Wire.encode(message)) == [message])
    }

    @Test func messagesSplitAcrossReads() {
        let bytes = Self.messages.map(Wire.encode).reduce(Data(), +)
        var reader = Wire.Reader()
        var read: [Wire.Message] = []
        // One byte at a time is the worst split a socket can give.
        for byte in bytes { read += reader.read(Data([byte])) }
        #expect(read == Self.messages)
    }
}
