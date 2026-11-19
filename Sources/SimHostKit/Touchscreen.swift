import CSimHost
import Foundation

/// Touches and hardware buttons for one simulator, sent straight to SimulatorKit.
public final class Touchscreen: @unchecked Sendable {
    public enum Phase: Sendable { case down, move, up }

    private let client: SHHIDClient
    private let isDuo: Bool
    private let lock = NSLock()

    public init(simulator: Simulator) throws(SimHostError) {
        do { client = try SHHIDClient(device: simulator.device) } catch {
            throw SimHostError("could not open the simulator's HID: \(error.localizedDescription)")
        }
        isDuo = simulator.isDuo
    }

    /// One finger on `panel`, at a point from 0 to 1 with the origin at the top left.
    @discardableResult
    public func touch(_ phase: Phase, at point: CGPoint, on panel: Panel, edge: SHEdge = .none) -> Bool {
        lock.withLock { client.touchDown(phase != .up, first: point, second: nil, target: target(panel), edge: edge) }
    }

    /// Two fingers on `panel`.
    @discardableResult
    public func touch(_ phase: Phase, at first: CGPoint, and second: CGPoint, on panel: Panel) -> Bool {
        var second = second
        return lock.withLock { client.touchDown(phase != .up, first: first, second: &second, target: target(panel), edge: .none) }
    }

    /// A hardware button by HID page and usage, such as the volume buttons on page 0x0C.
    @discardableResult
    public func button(page: UInt32, usage: UInt32, down: Bool) -> Bool {
        lock.withLock { client.usagePage(page, usage: usage, down: down, target: 0x32) }
    }

    private func target(_ panel: Panel) -> SHTouchTarget {
        guard isDuo else { return .main }
        return panel == .duoInner ? .duoInner : .duoCover
    }
}
