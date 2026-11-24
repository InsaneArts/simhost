import Foundation

extension Simulator {
    /// Turns a device that has no hinge, as Simulator.app turns it: a GraphicsServices event of
    /// type 50, device orientation changed, to the simulator's PurpleWorkspacePort. iPhone Duo
    /// takes its orientation from the helper instead. False when the port or the send failed.
    @discardableResult
    public func rotate(to orientation: Orientation) -> Bool {
        let selector = NSSelectorFromString("lookup:error:")
        guard device.responds(to: selector) else { return false }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> mach_port_t
        let lookup = unsafeBitCast(device.method(for: selector), to: Lookup.self)
        let port = lookup(device, selector, "PurpleWorkspacePort", nil)
        guard port != mach_port_t(MACH_PORT_NULL) else { return false }
        defer { mach_port_deallocate(mach_task_self_, port) }

        // The layout idb found in Simulator.app: the type at 0x18, the size of the record at
        // 0x48, and the orientation, a UIDeviceOrientation, at 0x4C.
        var message = [UInt8](repeating: 0, count: 112)
        return message.withUnsafeMutableBytes { bytes in
            let header = bytes.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
            header.pointee.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
            header.pointee.msgh_size = 108
            header.pointee.msgh_remote_port = port
            header.pointee.msgh_local_port = mach_port_t(MACH_PORT_NULL)
            header.pointee.msgh_id = 0x7B
            bytes.storeBytes(of: UInt32(50 | 0x20000), toByteOffset: 0x18, as: UInt32.self)
            bytes.storeBytes(of: UInt32(4), toByteOffset: 0x48, as: UInt32.self)
            bytes.storeBytes(of: UInt32(orientation.rawValue), toByteOffset: 0x4C, as: UInt32.self)
            return mach_msg_send(header) == KERN_SUCCESS
        }
    }
}
