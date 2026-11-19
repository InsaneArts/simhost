// Measures serve-sim 0.1.x, the way duorex uses it, against the probe app.
//
//   serve-sim-bench <udid> <port> [rounds]
//
// The probe app turns the screen white while a finger is down. Each round sends a touch down,
// waits for the first decoded frame whose sample point is white, then sends the touch up and
// waits for black. The time from send to that frame is what a user sees as input latency.
import CoreMedia
import Foundation
import VideoToolbox

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { print("usage: serve-sim-bench <udid> <port> [rounds]"); exit(2) }
let udid = arguments[1], port = arguments[2]
let rounds = arguments.count > 3 ? Int(arguments[3])! : 40
let base = URL(string: "http://127.0.0.1:\(port)/helper/\(udid)")!
let sample = (x: 0.5, y: 0.35)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// The stream, decoded. Every frame's brightness at the sample point goes to `onLevel`.
final class Feed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var pending = Data()
    var format: CMVideoFormatDescription?
    var decoder: VTDecompressionSession?
    var frames = 0
    var onLevel: ((Double, Double) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending.append(data)
        var offset = pending.startIndex
        while pending.endIndex - offset >= 4 {
            let length = pending[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard pending.endIndex - offset >= 4 + length else { break }
            let payload = Data(pending[(offset + 5)..<(offset + 4 + length)])
            switch pending[offset + 4] {
            case 0x01: makeDecoder(avcC: payload)
            case 0x02, 0x03: decode(payload)
            default: break
            }
            offset += 4 + length
        }
        pending.removeSubrange(pending.startIndex..<offset)
    }

    func makeDecoder(avcC: Data) {
        let bytes = [UInt8](avcC)
        guard bytes.count > 8 else { return }
        let spsLength = Int(bytes[6]) << 8 | Int(bytes[7])
        let sps = Array(bytes[8..<8 + spsLength])
        let ppsStart = 8 + spsLength + 1
        let ppsLength = Int(bytes[ppsStart]) << 8 | Int(bytes[ppsStart + 1])
        let pps = Array(bytes[(ppsStart + 2)..<(ppsStart + 2 + ppsLength)])
        var format: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let sets = [s.baseAddress!, p.baseAddress!]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard let format else { return }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        self.format = format
        let output: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: output as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
    }

    func decode(_ sample: Data) {
        guard let decoder, let format else { return }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) }
        var buffer: CMSampleBuffer?
        var size = sample.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                  sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard let buffer else { return }
        // Synchronous: the handler runs before this call returns.
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
            guard let image else { return }
            self.frames += 1
            self.onLevel?(level(image), now())
        }
    }
}

/// The brightness at the sample point, from 0 to 1.
func level(_ image: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
    let row = CVPixelBufferGetBytesPerRow(image)
    let x = Int(Double(width) * sample.x), y = Int(Double(height) * sample.y)
    let pixel = CVPixelBufferGetBaseAddress(image)!.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
}

let feed = Feed()
let queue = OperationQueue()
queue.maxConcurrentOperationCount = 1
let session = URLSession(configuration: .ephemeral, delegate: feed, delegateQueue: queue)

let lock = NSCondition()
var latest = (level: -1.0, time: 0.0)
var firstFrame = 0.0
feed.onLevel = { value, time in
    lock.lock()
    if firstFrame == 0 { firstFrame = time }
    latest = (value, time)
    lock.broadcast()
    lock.unlock()
}

/// Waits for a frame that is white (or black) and returns when it arrived.
func waitFor(white: Bool, after start: Double, timeout: Double = 3) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    while true {
        if latest.time >= start, white ? latest.level > 0.8 : latest.level < 0.2 { return latest.time }
        if !lock.wait(until: Date().addingTimeInterval(start + timeout - now())) { return nil }
    }
}

let connectStart = now()
var request = URLRequest(url: base.appendingPathComponent("stream.avcc"))
request.timeoutInterval = 3600
session.dataTask(with: request).resume()
var components = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
components.scheme = "ws"
let socket = session.webSocketTask(with: components.url!)
socket.resume()

guard waitFor(white: false, after: connectStart, timeout: 10) != nil else { print("no black frame from the probe app"); exit(1) }
print(String(format: "first frame after connecting: %.1f ms", (firstFrame - connectStart) * 1000))

func touch(_ type: String) {
    let json = try! JSONSerialization.data(withJSONObject: ["type": type, "x": sample.x, "y": sample.y])
    socket.send(.data(Data([0x03]) + json)) { error in if let error { print("send: \(error)") } }
}

var down: [Double] = [], up: [Double] = []
Thread.sleep(forTimeInterval: 0.5)
for _ in 0..<rounds {
    let start = now()
    touch("begin")
    if let seen = waitFor(white: true, after: start) { down.append(seen - start) }
    Thread.sleep(forTimeInterval: 0.05 + Double.random(in: 0...0.1))
    let release = now()
    touch("end")
    if let seen = waitFor(white: false, after: release) { up.append(seen - release) }
    Thread.sleep(forTimeInterval: 0.1 + Double.random(in: 0...0.15))
}

func report(_ name: String, _ values: [Double]) {
    let sorted = values.sorted().map { $0 * 1000 }
    guard !sorted.isEmpty else { print("\(name): no frames"); return }
    let pick = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
    print(String(format: "%@: median %.1f ms, p90 %.1f ms, min %.1f, max %.1f (%d of %d)", name, pick(0.5), pick(0.9), sorted.first!, sorted.last!, sorted.count, rounds))
}
report("touch down → white frame", down)
report("touch up → black frame", up)
print("frames decoded: \(feed.frames)")
exit(0)
