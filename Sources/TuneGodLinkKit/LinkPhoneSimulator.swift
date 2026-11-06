// Plays the phone's part of the link on the Mac, so the helper (and later the driver) can be tested without the iPhone: it listens on the
// loopback port, ticks a 48 kHz timeline from its own timer, sends a tone as its "mic", keeps a jitter buffer of the blocks it receives,
// counts dropouts the way the phone will, and can send a note every half second to exercise MIDI.
import Foundation

public final class LinkPhoneSimulator: @unchecked Sendable {
    public struct Report: Sendable {
        public var underruns: UInt32
        public var late: UInt32
        public var bufferedFrames: Int
        public var receivedRMS: Float
        public var midiReceived: Int
        public var packets: Int
        /// Frames per second the simulator really produced (its timer, measured on the Mac's clock).
        public var effectiveRate: Double
    }

    public let port: UInt16
    public let config: LinkConfig
    public var sendMIDINotes = false
    /// Once a second while connected.
    public var onReport: (@Sendable (Report) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var blocks: [UInt64: [Float]] = [:]
    private var underruns: UInt32 = 0
    private var late: UInt32 = 0
    private var receivedAny = false
    private var sumSquares: Double = 0
    private var sampleCount = 0
    private var midiReceived = 0
    private var now: UInt64 = 0

    public init(port: UInt16 = LinkProtocol.port, config: LinkConfig = LinkPhoneSimulator.defaultConfig) {
        self.port = port
        self.config = config
    }

    public static let defaultConfig = LinkConfig(sampleRate: 48000, framesPerPacket: 64, downChannels: 2, upChannels: 2,
                                                 upLayout: LinkUpLayout.micPair.rawValue, ioBufferFrames: 64,
                                                 outputLatencyFrames: 0, inputLatencyFrames: 0)

    /// Serves one Mac at a time, forever (blocks the calling thread).
    public func run() throws {
        let listener = try LinkListener(port: port)
        onLog?("phone simulator listening on 127.0.0.1:\(port)")
        while true {
            let socket = try listener.accept()
            onLog?("Mac connected")
            serve(socket)
            onLog?("Mac disconnected")
        }
    }

    public func serve(_ socket: LinkSocket) {
        lock.withLock {
            blocks = [:]
            underruns = 0
            late = 0
            receivedAny = false
            midiReceived = 0
            now = 0
        }
        do {
            try socket.send(.hello(LinkHello(role: .phone, appVersion: "simulator")))
            try socket.send(.config(config))
            try socket.send(.start(sampleTime: 0))
        } catch {
            onLog?("\(error)")
            return
        }
        let reader = Thread { [self] in readLoop(socket) }
        reader.qualityOfService = .userInteractive
        reader.start()
        // The ticks run on their own top-priority thread, as a phone's audio IO thread would.
        let done = DispatchSemaphore(value: 0)
        let ticker = Thread { [self] in
            tickLoop(socket)
            done.signal()
        }
        ticker.qualityOfService = .userInteractive
        ticker.start()
        done.wait()
    }

    private func readLoop(_ socket: LinkSocket) {
        var decoder = LinkFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let n = try? socket.read(into: &buffer), n > 0, let messages = try? decoder.append(buffer[0..<n]) else { break }
            for m in messages {
                switch m {
                case .audioDown(let a):
                    lock.withLock {
                        receivedAny = true
                        if a.sampleTime < now { late += 1 } else { blocks[a.sampleTime] = a.samples }
                    }
                case .midi:
                    lock.withLock { midiReceived += 1 }
                case .ping(let p):
                    try? socket.send(.pong(p))
                case .hello(let h) where h.protocolVersion != LinkProtocol.version:
                    onLog?("Mac speaks protocol \(h.protocolVersion)")
                    socket.close()
                case .stop:
                    socket.close()
                default:
                    break
                }
            }
        }
        socket.close()
    }

    private func tickLoop(_ socket: LinkSocket) {
        let frames = Int(config.framesPerPacket)
        let rate = Double(config.sampleRate)
        let period = Double(frames) / rate
        let tone = ToneGenerator(frequency: 330, sampleRate: rate)
        RealtimeThread.promote(period: period, computation: period / 4)
        let began = HostClock.now()
        var start = began
        var tick: UInt64 = 0
        var lastReport = start
        var lastNote = start
        var noteOn = false
        while !socket.closed {
            let t = tick * UInt64(frames)
            // "Play" the block due now.
            lock.withLock {
                now = t
                if let block = blocks.removeValue(forKey: t) {
                    for v in block { sumSquares += Double(v * v) }
                    sampleCount += block.count
                } else if receivedAny {
                    underruns += 1
                }
                for key in blocks.keys where key < t {
                    blocks.removeValue(forKey: key)
                    late += 1
                }
            }
            let mic = tone.render(frames: frames, channels: Int(config.upChannels))
            guard (try? socket.send(.audioUp(LinkAudio(sampleTime: t, frames: UInt16(frames), samples: mic)))) != nil else { break }

            let wall = HostClock.now()
            if sendMIDINotes, wall - lastNote >= 0.5 {
                lastNote = wall
                noteOn.toggle()
                let bytes: [UInt8] = noteOn ? [0x90, 48, 100] : [0x80, 48, 0]
                try? socket.send(.midi(LinkMIDI(sampleTime: t + UInt64(4 * frames), bytes: bytes)))
            }
            if wall - lastReport >= 1 {
                lastReport = wall
                let report: Report = lock.withLock {
                    let rms = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
                    sumSquares = 0
                    sampleCount = 0
                    return Report(underruns: underruns, late: late, bufferedFrames: blocks.count * frames, receivedRMS: rms,
                                  midiReceived: midiReceived, packets: Int(tick),
                                  effectiveRate: Double(tick) * Double(frames) / (wall - began))
                }
                try? socket.send(.status(LinkStatus(underruns: report.underruns, bufferedFrames: UInt32(report.bufferedFrames),
                                                    latePackets: report.late)))
                onReport?(report)
            }
            tick += 1
            let deadline = start + Double(tick) * period
            let wait = deadline - HostClock.now()
            if wait > 0 {
                mach_wait_until(HostClock.ticks() + HostClock.ticks(seconds: wait))
            } else if wait < -2 * period {
                // Fell behind (the Mac stalled this thread): carry on from now rather than bursting packets, as a phone's IO never bursts.
                start = HostClock.now() - Double(tick) * period
            }
        }
        socket.close()
    }
}
