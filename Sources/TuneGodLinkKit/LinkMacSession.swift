// The Mac's end of one link to one phone. The phone drives everything: each AUDIO_UP it sends (one per audio IO cycle, even with no mic)
// is a clock tick, and the session answers each tick with one AUDIO_DOWN block for `downLead` frames later on the phone's timeline. So the
// Mac never runs its own timer for audio and never drifts from the phone.
import Foundation

public final class LinkMacSession: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var phoneVersion: String?
        public var config: LinkConfig?
        public var running = false
        public var packetsUp = 0
        public var packetsDown = 0
        public var midiUp = 0
        public var midiDown = 0
        /// Last measured round trip over the link, ms.
        public var roundTripMs: Double?
        public var downLeadFrames = 0
        public var phoneStatus: LinkStatus?
        /// The phone's sample rate as measured on the Mac's clock.
        public var measuredRate: Double?
        public var clockResets = 0
        public var error: String?

        /// Mac → phone speaker, ms: the lead plus the phone's IO buffer and output latency.
        public var downLatencyMs: Double? {
            guard let c = config, c.sampleRate > 0 else { return nil }
            let frames = Double(downLeadFrames) + Double(c.ioBufferFrames) + Double(c.outputLatencyFrames)
            return frames / Double(c.sampleRate) * 1000
        }
        /// Phone mic → Mac, ms (before the Mac app's own buffer): IO buffer, input latency, one packet, half the round trip.
        public var upLatencyMs: Double? {
            guard let c = config, c.sampleRate > 0 else { return nil }
            let frames = Double(c.ioBufferFrames) + Double(c.inputLatencyFrames) + Double(c.framesPerPacket)
            return frames / Double(c.sampleRate) * 1000 + (roundTripMs ?? 0) / 2
        }
    }

    /// Audio for the phone: `frames` interleaved frames of `channels` channels for phone frame `sampleTime` (reader thread).
    public var downSource: (@Sendable (_ sampleTime: UInt64, _ frames: Int, _ channels: Int) -> [Float])?
    /// The phone's mic (and TuneGod output) block, with the config it follows (reader thread).
    public var onAudioUp: (@Sendable (LinkAudio, LinkConfig) -> Void)?
    /// MIDI from the phone with the Mac host time (ticks) it plays at; 0 = now (reader thread).
    public var onMIDI: (@Sendable ([UInt8], UInt64) -> Void)?
    /// Each phone packet: its first frame, the Mac host time (ticks) the clock puts it at, and the phone's rate (reader thread).
    public var onClock: (@Sendable (_ sampleTime: UInt64, _ hostTicks: UInt64, _ rate: Double) -> Void)?
    /// The phone's CONFIG, START and STOP as they arrive (reader thread).
    public var onControl: (@Sendable (LinkMessage) -> Void)?
    /// The link ended (reader thread). The error, if it ended on one.
    public var onClosed: (@Sendable (String?) -> Void)?

    public let socket: LinkSocket
    private let appVersion: String
    private let lock = NSLock()
    private var _stats = Stats()
    private var clock: ClockMapper?
    private var lastUnderruns: UInt32 = 0
    private var lastAdjust = 0.0
    private var pingID: UInt32 = 0
    /// The next phone frame owed a down block; keeps the down stream gapless while the lead moves.
    private var nextDown: UInt64?
    private var running = false

    public init(socket: LinkSocket, appVersion: String) {
        self.socket = socket
        self.appVersion = appVersion
    }

    public var stats: Stats { lock.withLock { _stats } }

    public func start() {
        lock.withLock { running = true }
        do {
            try socket.send(.hello(LinkHello(role: .mac, appVersion: appVersion)))
        } catch {
            finish(error: "\(error)")
            return
        }
        let reader = Thread { [self] in readLoop() }
        reader.name = "TuneGod Link reader"
        reader.qualityOfService = .userInteractive
        reader.start()
        let pinger = Thread { [self] in pingLoop() }
        pinger.name = "TuneGod Link ping"
        pinger.qualityOfService = .utility
        pinger.start()
    }

    public func stop() {
        try? socket.send(.stop)
        finish(error: nil)
    }

    /// MIDI for the phone, stamped with the Mac host time (ticks) it should play at; 0 = now.
    public func sendMIDI(_ bytes: [UInt8], hostTicks: UInt64) {
        let sampleTime: UInt64 = lock.withLock {
            guard hostTicks != 0, let clock, let s = clock.sampleTime(atHost: HostClock.seconds(ticks: hostTicks)),
                  s > clock.latestSample else { return 0 }
            return s
        }
        if (try? socket.send(.midi(LinkMIDI(sampleTime: sampleTime, bytes: bytes)))) != nil {
            lock.withLock { _stats.midiDown += 1 }
        }
    }

    /// Host time (seconds) of a phone frame, once the clock has locked.
    public func hostTime(forSample sample: UInt64) -> Double? { lock.withLock { clock?.hostTime(forSample: sample) } }

    // MARK: Threads

    private func readLoop() {
        // Each packet is answered with audio on this thread, so it runs like an audio thread (a 64-frame packet every 1.3 ms).
        RealtimeThread.promote(period: 64.0 / 48000, computation: 0.0003)
        var decoder = LinkFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        do {
            while lock.withLock({ running }) {
                let n = try socket.read(into: &buffer)
                if n == 0 { throw LinkError.closed }
                for message in try decoder.append(buffer[0..<n]) { try handle(message) }
            }
            finish(error: nil)
        } catch LinkError.closed {
            finish(error: nil)
        } catch {
            finish(error: "\(error)")
        }
    }

    private func pingLoop() {
        while lock.withLock({ running }) {
            Thread.sleep(forTimeInterval: 1)
            let id = lock.withLock { () -> UInt32 in
                pingID &+= 1
                return pingID
            }
            try? socket.send(.ping(LinkPing(id: id, senderTime: HostClock.nanos())))
        }
    }

    private func handle(_ message: LinkMessage) throws {
        switch message {
        case .hello(let h):
            guard h.protocolVersion == LinkProtocol.version else { throw LinkError.versionMismatch(h.protocolVersion) }
            lock.withLock { _stats.phoneVersion = h.appVersion }
        case .config(let c):
            defer { onControl?(message) }
            lock.withLock {
                _stats.config = c
                _stats.downLeadFrames = 2 * Int(c.framesPerPacket)
                clock = ClockMapper(sampleRate: Double(c.sampleRate))
                nextDown = nil
                lastUnderruns = 0
                lastAdjust = HostClock.now()
            }
        case .start:
            defer { onControl?(message) }
            lock.withLock {
                clock?.reset()
                nextDown = nil
                _stats.running = true
            }
        case .stop:
            lock.withLock { _stats.running = false }
            onControl?(message)
        case .audioUp(let audio):
            try tick(audio)
        case .midi(let m):
            let ticks: UInt64 = lock.withLock {
                _stats.midiUp += 1
                guard m.sampleTime != 0, let t = clock?.hostTime(forSample: m.sampleTime), t > HostClock.now() else { return 0 }
                return HostClock.ticks(seconds: t)
            }
            onMIDI?(m.bytes, ticks)
        case .ping(let p):
            try socket.send(.pong(p))
        case .pong(let p):
            let rtt = Double(HostClock.nanos() &- p.senderTime) / 1e6
            lock.withLock { _stats.roundTripMs = rtt }
        case .status(let s):
            adapt(to: s)
        case .audioDown, .unknown:
            break
        }
    }

    private func tick(_ audio: LinkAudio) throws {
        let host = HostClock.now()
        let frames = Int(audio.frames)
        // Blocks owed for this tick: everything from `nextDown` up to `lead` frames past the end of this packet. A grown lead fills its gap
        // with an extra block; a shrunk one sends nothing this tick, so the phone's stream never has a hole.
        var clockPoint: (UInt64, Double)?
        let plan: (LinkConfig, [UInt64])? = lock.withLock {
            guard let c = _stats.config else { return nil }
            clock?.update(sampleTime: audio.sampleTime, frames: frames, host: host)
            _stats.packetsUp += 1
            _stats.measuredRate = clock?.rate
            _stats.clockResets = clock?.resets ?? 0
            if let clock, let h = clock.hostTime(forSample: audio.sampleTime) { clockPoint = (HostClock.ticks(seconds: h), clock.rate) }
            guard frames > 0 else { return (c, []) }
            let lead = UInt64(_stats.downLeadFrames)
            let end = audio.sampleTime + UInt64(frames) + lead
            var next = nextDown ?? audio.sampleTime + lead
            // Behind the phone already (a stall): start again at the lead rather than send blocks it will drop.
            if next < audio.sampleTime + UInt64(frames) { next = audio.sampleTime + lead }
            var times: [UInt64] = []
            while next + UInt64(frames) <= end, times.count < 8 {
                times.append(next)
                next += UInt64(frames)
            }
            nextDown = next
            return (c, times)
        }
        guard let (config, times) = plan else { return }
        if !audio.samples.isEmpty { onAudioUp?(audio, config) }
        if let (ticks, rate) = clockPoint { onClock?(audio.sampleTime, ticks, rate) }
        let channels = Int(config.downChannels)
        guard channels > 0, let downSource else { return }
        for t in times {
            let samples = downSource(t, frames, channels)
            guard samples.count == frames * channels else { continue }
            try socket.send(.audioDown(LinkAudio(sampleTime: t, frames: audio.frames, samples: samples)))
            lock.withLock { _stats.packetsDown += 1 }
        }
    }

    /// Raises the lead by one packet when the phone ran dry, lowers it by one after 30 s without a dropout.
    private func adapt(to status: LinkStatus) {
        lock.withLock {
            _stats.phoneStatus = status
            guard let c = _stats.config else { return }
            let packet = Int(c.framesPerPacket)
            let now = HostClock.now()
            if status.underruns > lastUnderruns {
                _stats.downLeadFrames = min(_stats.downLeadFrames + packet, 32 * packet)
                lastAdjust = now
            } else if now - lastAdjust > 30, _stats.downLeadFrames > 2 * packet {
                _stats.downLeadFrames -= packet
                lastAdjust = now
            }
            lastUnderruns = status.underruns
        }
    }

    private func finish(error: String?) {
        let first = lock.withLock { () -> Bool in
            defer {
                running = false
                _stats.running = false
                if let error { _stats.error = error }
            }
            return running
        }
        socket.close()
        if first { onClosed?(error) }
    }
}

/// A sine test tone, interleaved, quiet enough not to startle (−14 dBFS).
public final class ToneGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0.0
    public var frequency: Double
    public var sampleRate: Double
    public var amplitude: Float = 0.2

    public init(frequency: Double = 440, sampleRate: Double = 48000) {
        self.frequency = frequency
        self.sampleRate = sampleRate
    }

    public func render(frames: Int, channels: Int) -> [Float] {
        lock.withLock {
            var out = [Float](repeating: 0, count: frames * channels)
            let step = 2 * Double.pi * frequency / sampleRate
            for f in 0..<frames {
                let v = Float(sin(phase)) * amplitude
                for c in 0..<channels { out[f * channels + c] = v }
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            return out
        }
    }
}
