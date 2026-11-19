import Foundation
import IOSurface

/// A new picture on one panel. `surface` is the simulator's live framebuffer: it is shared
/// memory, so reading it costs no copy, and the simulator draws the next picture into it.
public struct Frame: @unchecked Sendable {
    public let panel: Panel
    public let surface: IOSurfaceRef
    /// When simhost saw the picture, in nanoseconds of `DispatchTime.now().uptimeNanoseconds`.
    public let time: UInt64
}

/// Watches the simulator's panels and reports each new picture as the simulator draws it.
///
/// SimulatorKit calls back on every frame it composes. A callback can arrive a moment before
/// the picture is in the surface, so when the surface's seed has not changed yet, simhost looks
/// again after 1, 1, 2, 4, 8 and 16 ms.
public final class Screens: @unchecked Sendable {
    private let simulator: Simulator
    private let queue: DispatchQueue
    private let onFrame: @Sendable (Frame) -> Void
    private var descriptors: [NSObject] = []
    private var callbacks: [ObjectIdentifier: UUID] = [:]
    private var seeds: [Panel: UInt32] = [:]
    private var recheck: UInt64 = 0
    private let panels: Set<Panel>

    /// `onFrame` runs on `queue`.
    public init(simulator: Simulator, queue: DispatchQueue = DispatchQueue(label: "simhost.screens", qos: .userInteractive),
                onFrame: @escaping @Sendable (Frame) -> Void) throws(SimHostError) {
        guard simulator.isBooted else { throw SimHostError("\(simulator.name) is not booted") }
        self.simulator = simulator
        self.queue = queue
        self.onFrame = onFrame
        self.panels = Set(simulator.panels)
        try queue.sync { Result { () throws(SimHostError) in try attach() } }.get()
    }

    deinit { stop() }

    /// The panels that have a live picture now, with their surfaces.
    public func current() -> [Frame] {
        queue.sync { surfaces().map { Frame(panel: $0.panel, surface: $0.surface, time: DispatchTime.now().uptimeNanoseconds) } }
    }

    public func stop() {
        let unregister = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for descriptor in descriptors {
            if let uuid = callbacks[ObjectIdentifier(descriptor)], descriptor.responds(to: unregister) {
                descriptor.perform(unregister, with: uuid)
            }
        }
        descriptors = []
        callbacks = [:]
    }

    private func attach() throws(SimHostError) {
        guard let io = simulator.device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
            throw SimHostError("the simulator has no IO client")
        }
        io.perform(NSSelectorFromString("updateIOPorts"))
        let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] ?? []
        descriptors = ports.compactMap { port in
            guard port.responds(to: NSSelectorFromString("portIdentifier")),
                  "\(port.perform(NSSelectorFromString("portIdentifier"))!.takeUnretainedValue())" == "com.apple.framebuffer.display",
                  let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: NSSelectorFromString("framebufferSurface")),
                  descriptor.responds(to: #selector(FramebufferDescriptor.registerScreenCallbacks))
            else { return nil }
            return descriptor
        }
        guard !descriptors.isEmpty else { throw SimHostError("the simulator has no framebuffer") }
        for descriptor in descriptors {
            let uuid = UUID()
            callbacks[ObjectIdentifier(descriptor)] = uuid
            let changed: @convention(block) () -> Void = { [weak self] in self?.look(attempt: 0, generation: nil) }
            unsafeBitCast(descriptor, to: FramebufferDescriptor.self).registerScreenCallbacks(
                uuid: uuid, callbackQueue: queue, frameCallback: changed, surfacesChangedCallback: changed,
                propertiesChangedCallback: {})
        }
        look(attempt: 0, generation: nil)
    }

    /// The live surface of each panel. A descriptor whose surface is not a native panel, such as
    /// Xcode 27's 7680x4320 presentation surface, is left out.
    private func surfaces() -> [(panel: Panel, surface: IOSurfaceRef)] {
        descriptors.compactMap { descriptor in
            guard let object = descriptor.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { return nil }
            let surface = unsafeBitCast(object, to: IOSurfaceRef.self)
            let panel = Panel(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            guard panel.width > 0, panels.isEmpty || panels.contains(panel) else { return nil }
            return (panel, surface)
        }
    }

    /// Reports each panel whose picture changed. When none did, looks again a moment later.
    private func look(attempt: Int, generation: UInt64?) {
        if generation == nil { recheck &+= 1 }
        else if generation != recheck { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var reported = false
        for (panel, surface) in surfaces() {
            let seed = IOSurfaceGetSeed(surface)
            guard seeds[panel] != seed else { continue }
            seeds[panel] = seed
            reported = true
            onFrame(Frame(panel: panel, surface: surface, time: now))
        }
        let delays = [1, 1, 2, 4, 8, 16]
        guard !reported, attempt < delays.count else { return }
        let generation = recheck
        queue.asyncAfter(deadline: .now() + .milliseconds(delays[attempt])) { [weak self] in
            self?.look(attempt: attempt + 1, generation: generation)
        }
    }
}

/// SimulatorKit's framebuffer descriptor, as much of it as simhost calls.
@objc protocol FramebufferDescriptor {
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreenCallbacks(uuid: UUID, callbackQueue: DispatchQueue,
                                 frameCallback: @convention(block) @escaping () -> Void,
                                 surfacesChangedCallback: @convention(block) @escaping () -> Void,
                                 propertiesChangedCallback: @convention(block) @escaping () -> Void)
}
