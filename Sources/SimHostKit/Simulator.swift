import Foundation

/// Something simhost could not do, said for a person.
public struct SimHostError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Xcode's private simulator frameworks, loaded once from the active Xcode.
/// They are used through the Objective-C runtime and never linked, because their place
/// changes between Xcode releases: Xcode 27 moved SimulatorKit to Contents/SharedFrameworks.
enum Frameworks {
    /// DEVELOPER_DIR when it is set, else what `xcode-select -p` prints.
    static let developerDir: String = {
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "/Applications/Xcode.app/Contents/Developer" }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : path
    }()

    /// True when CoreSimulator and SimulatorKit are in the process.
    static let isLoaded: Bool = {
        for path in [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developerDir)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ] { dlopen(path, RTLD_NOW) }
        return NSClassFromString("SimServiceContext") != nil
            && NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") != nil
    }()
}

/// A panel of the simulator: the screen of an ordinary device, or one of iPhone Duo's two screens.
public struct Panel: Hashable, Sendable, CustomStringConvertible {
    /// The framebuffer size in pixels, portrait.
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = min(width, height)
        self.height = max(width, height)
    }

    public static let duoCover = Panel(width: 1398, height: 2034)
    public static let duoInner = Panel(width: 2007, height: 2853)

    public var description: String {
        switch self {
        case .duoCover: "cover"
        case .duoInner: "inner"
        default: "\(width)x\(height)"
        }
    }
}

/// How the device is held, or how the interface is turned inside a panel's framebuffer.
/// The raw values are SimulatorKit's, and the names are the ones `simctl io enumerate` prints.
public enum Orientation: UInt8, Sendable {
    case portrait = 1, upsideDown = 2, landscapeLeft = 3, landscapeRight = 4
}

/// One simulator device, found through CoreSimulator.
public final class Simulator: @unchecked Sendable {
    public let udid: String
    /// CoreSimulator's SimDevice.
    let device: NSObject

    public init(udid: String) throws(SimHostError) {
        guard Frameworks.isLoaded else {
            throw SimHostError("Xcode's simulator frameworks did not load from \(Frameworks.developerDir)")
        }
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type,
              let context = contextClass.perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
                                                 with: Frameworks.developerDir, with: nil)?.takeUnretainedValue() as? NSObject,
              let set = context.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue() as? NSObject,
              let devices = set.value(forKey: "devices") as? [NSObject]
        else { throw SimHostError("CoreSimulator gave no device set") }
        guard let device = devices.first(where: { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid.uppercased() }) else {
            throw SimHostError("no simulator has the UDID \(udid)")
        }
        self.udid = udid.uppercased()
        self.device = device
    }

    public var name: String { device.value(forKey: "name") as? String ?? udid }
    public var isBooted: Bool { (device.value(forKey: "stateString") as? String) == "Booted" }

    /// When the simulator last started. A simulator shows an Apple logo for a minute or two after it.
    public var bootedAt: Date? {
        device.responds(to: NSSelectorFromString("lastBootedAt")) ? device.value(forKey: "lastBootedAt") as? Date : nil
    }

    var deviceTypeIdentifier: String? {
        (device.value(forKey: "deviceType") as? NSObject)?.value(forKey: "identifier") as? String
    }

    public var isDuo: Bool { deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" }

    /// Makes every animation on the simulator slow, or normal again. False when CoreSimulator refused.
    @discardableResult
    public func setSlowAnimations(_ on: Bool) -> Bool {
        unsafeBitCast(device, to: DeviceDebugging.self).setCADebugOption("debug_slow_animations", enabled: on)
    }

    /// Tells the apps on the simulator that memory is low.
    public func simulateMemoryWarning() {
        unsafeBitCast(device, to: DeviceDebugging.self).simulateMemoryWarning()
    }

    /// The panels with a touchscreen, from the device type's capabilities.
    public var panels: [Panel] {
        guard let type = device.value(forKey: "deviceType") as? NSObject,
              let bundle = (type.value(forKey: "bundlePath") as? String) ?? (type.value(forKey: "bundleURL") as? URL)?.path,
              let data = FileManager.default.contents(atPath: bundle + "/Contents/Resources/capabilities.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        let capabilities = plist["capabilities"] as? [String: Any] ?? plist
        let displays = capabilities["displays"] as? [[String: Any]] ?? []
        return displays.compactMap { display in
            guard display["displayType"] as? String == "integrated",
                  (display["hasDigitizer"] as? NSNumber)?.boolValue == true,
                  !((display["chromeIdentifier"] as? String) ?? "").isEmpty,
                  let width = (display["width"] as? NSNumber)?.intValue,
                  let height = (display["height"] as? NSNumber)?.intValue, width > 0, height > 0
            else { return nil }
            return Panel(width: width, height: height)
        }
    }
}

/// CoreSimulator's SimDevice, as much of it as the debugging inputs call.
@objc protocol DeviceDebugging {
    @objc(setCADebugOption:enabled:) func setCADebugOption(_ name: String, enabled: Bool) -> Bool
    func simulateMemoryWarning()
}
