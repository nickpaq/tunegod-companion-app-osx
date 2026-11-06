// The helper's side of its link to the TuneGod Link driver (inside the Mac's audio service): a loopback TCP server on
// `LinkProtocol.driverPort` speaking the same messages as the phone link. The helper passes the phone's CONFIG, START/STOP, mic blocks
// (AUDIO_UP) and its clock (CLOCK, once per phone packet) to the driver; the driver sends what Mac apps play (AUDIO_DOWN, by phone frame),
// which waits in `output` until the phone asks for it.
#if os(macOS)
import Foundation

public final class LinkDriverBridge: @unchecked Sendable {
    public let port: UInt16
    /// What Mac apps play through "TuneGod iPhone", by phone frame.
    public let output = AudioRing(channels: 2)
    /// The driver connected or went away (its thread).
    public var onChange: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var socket: LinkSocket?
    private var listener: LinkListener?
    private var lastConfig: LinkConfig?
    private var _blocksIn = 0

    public init(port: UInt16 = LinkProtocol.driverPort) {
        self.port = port
    }

    public var connected: Bool { lock.withLock { socket != nil } }
    public var blocksIn: Int { lock.withLock { _blocksIn } }

    /// Starts listening; false if the port is taken (another helper is running).
    @discardableResult
    public func start() -> Bool {
        guard let l = try? LinkListener(port: port) else { return false }
        lock.withLock { listener = l }
        let t = Thread { [self] in acceptLoop(l) }
        t.name = "TuneGod Link driver bridge"
        t.start()
        return true
    }

    /// Sends to the driver if it is connected (otherwise dropped: the driver runs on its own clock until it hears from the phone).
    public func send(_ message: LinkMessage) {
        if case .config(let c) = message { lock.withLock { lastConfig = c } }
        guard let s = lock.withLock({ socket }) else { return }
        if (try? s.send(message)) == nil { s.close() }
    }

    private func acceptLoop(_ listener: LinkListener) {
        while let s = try? listener.accept() {
            let previous = lock.withLock { () -> LinkSocket? in
                defer { socket = s }
                return socket
            }
            previous?.close()
            output.reset()
            if let c = lock.withLock({ lastConfig }) { try? s.send(.config(c)) }
            onChange?(true)
            let reader = Thread { [self] in readLoop(s) }
            reader.qualityOfService = .userInteractive
            reader.start()
        }
    }

    private func readLoop(_ s: LinkSocket) {
        RealtimeThread.promote(period: 64.0 / 48000, computation: 0.0003)
        var decoder = LinkFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while let n = try? s.read(into: &buffer), n > 0, let messages = try? decoder.append(buffer[0..<n]) {
            for m in messages {
                if case .audioDown(let a) = m {
                    output.write(sampleTime: a.sampleTime, samples: a.samples, channels: max(1, a.channels))
                    lock.withLock { _blocksIn += 1 }
                }
            }
        }
        s.close()
        let wasCurrent = lock.withLock { () -> Bool in
            guard socket === s else { return false }
            socket = nil
            return true
        }
        if wasCurrent { onChange?(false) }
    }
}
#endif
