// The TuneGod Link wire format (docs/link-protocol.md): an 8-byte header (type, flags, reserved, payload length) then the payload,
// all little-endian. Encoding and decoding only; no I/O here, so it builds for macOS and iOS alike.
import Foundation

public enum LinkProtocol {
    public static let version: UInt16 = 1
    /// The port the phone listens on (loopback) while Mac Link is on.
    public static let port: UInt16 = 47820
    public static let magic: [UInt8] = Array("TGLK".utf8)
    public static let headerSize = 8
    public static let maxPayload = 1 << 20
}

public enum LinkError: Error, Equatable, CustomStringConvertible {
    case truncated
    case badMagic
    case tooLarge(Int)
    case badAudio
    case versionMismatch(UInt16)
    case socket(String, Int32)
    case usbmux(String)
    case closed

    public var description: String {
        switch self {
        case .truncated: return "message ended early"
        case .badMagic: return "not a TuneGod Link peer"
        case .tooLarge(let n): return "message too large (\(n) bytes)"
        case .badAudio: return "audio payload does not fit its frame count"
        case .versionMismatch(let v): return "protocol version \(v) does not match \(LinkProtocol.version): update TuneGod or the companion"
        case .socket(let what, let code): return "\(what) failed (\(String(cString: strerror(code))))"
        case .usbmux(let what): return what
        case .closed: return "connection closed"
        }
    }
}

public enum LinkMessageType: UInt8, Sendable {
    case hello = 0x01, config = 0x02, start = 0x03, stop = 0x04
    case audioUp = 0x10, audioDown = 0x11
    case midi = 0x20
    case ping = 0x30, pong = 0x31
    case status = 0x40
}

public enum LinkRole: UInt8, Sendable { case phone = 0, mac = 1 }

public struct LinkHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var role: LinkRole
    public var appVersion: String
    public init(protocolVersion: UInt16 = LinkProtocol.version, role: LinkRole, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.appVersion = appVersion
    }
}

/// Up-channel layouts (`upLayout`).
public enum LinkUpLayout: UInt8, Sendable {
    case none = 0, mic = 1, micPair = 2, micPairAndTuneGod = 3
    public var channels: Int { [0, 1, 2, 4][Int(rawValue)] }
}

public struct LinkConfig: Equatable, Sendable {
    public var sampleRate: UInt32
    public var framesPerPacket: UInt16
    public var downChannels: UInt8
    public var upChannels: UInt8
    public var upLayout: UInt8
    public var ioBufferFrames: UInt16
    public var outputLatencyFrames: UInt32
    public var inputLatencyFrames: UInt32
    public init(sampleRate: UInt32, framesPerPacket: UInt16, downChannels: UInt8, upChannels: UInt8, upLayout: UInt8,
                ioBufferFrames: UInt16, outputLatencyFrames: UInt32, inputLatencyFrames: UInt32) {
        self.sampleRate = sampleRate
        self.framesPerPacket = framesPerPacket
        self.downChannels = downChannels
        self.upChannels = upChannels
        self.upLayout = upLayout
        self.ioBufferFrames = ioBufferFrames
        self.outputLatencyFrames = outputLatencyFrames
        self.inputLatencyFrames = inputLatencyFrames
    }
}

/// One block of interleaved Float32 audio stamped with the phone timeline frame of its first sample.
public struct LinkAudio: Equatable, Sendable {
    public var sampleTime: UInt64
    public var frames: UInt16
    public var samples: [Float]
    public init(sampleTime: UInt64, frames: UInt16, samples: [Float]) {
        self.sampleTime = sampleTime
        self.frames = frames
        self.samples = samples
    }
    public var channels: Int { frames == 0 ? 0 : samples.count / Int(frames) }
}

public struct LinkMIDI: Equatable, Sendable {
    /// Phone timeline frame the bytes play at; 0 means as soon as possible.
    public var sampleTime: UInt64
    public var bytes: [UInt8]
    public init(sampleTime: UInt64, bytes: [UInt8]) {
        self.sampleTime = sampleTime
        self.bytes = bytes
    }
}

public struct LinkPing: Equatable, Sendable {
    public var id: UInt32
    public var senderTime: UInt64
    public init(id: UInt32, senderTime: UInt64) {
        self.id = id
        self.senderTime = senderTime
    }
}

public struct LinkStatus: Equatable, Sendable {
    public var underruns: UInt32
    public var overruns: UInt32
    public var bufferedFrames: UInt32
    public var latePackets: UInt32
    public init(underruns: UInt32 = 0, overruns: UInt32 = 0, bufferedFrames: UInt32 = 0, latePackets: UInt32 = 0) {
        self.underruns = underruns
        self.overruns = overruns
        self.bufferedFrames = bufferedFrames
        self.latePackets = latePackets
    }
}

public enum LinkMessage: Equatable, Sendable {
    case hello(LinkHello)
    case config(LinkConfig)
    case start(sampleTime: UInt64)
    case stop
    case audioUp(LinkAudio)
    case audioDown(LinkAudio)
    case midi(LinkMIDI)
    case ping(LinkPing)
    case pong(LinkPing)
    case status(LinkStatus)
    /// A type this side does not know; skipped (forward compatibility).
    case unknown(type: UInt8)

    // MARK: Encoding

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        let type: UInt8
        switch self {
        case .hello(let h):
            type = LinkMessageType.hello.rawValue
            w.raw(LinkProtocol.magic)
            w.u16(h.protocolVersion)
            w.u8(h.role.rawValue)
            w.u8(0)
            let name = Array(h.appVersion.utf8.prefix(255))
            w.u8(UInt8(name.count))
            w.raw(name)
        case .config(let c):
            type = LinkMessageType.config.rawValue
            w.u32(c.sampleRate)
            w.u16(c.framesPerPacket)
            w.u8(c.downChannels)
            w.u8(c.upChannels)
            w.u8(c.upLayout)
            w.u16(c.ioBufferFrames)
            w.u32(c.outputLatencyFrames)
            w.u32(c.inputLatencyFrames)
        case .start(let t):
            type = LinkMessageType.start.rawValue
            w.u64(t)
        case .stop:
            type = LinkMessageType.stop.rawValue
        case .audioUp(let a), .audioDown(let a):
            if case .audioUp = self { type = LinkMessageType.audioUp.rawValue } else { type = LinkMessageType.audioDown.rawValue }
            w.u64(a.sampleTime)
            w.u16(a.frames)
            w.u16(0)
            w.floats(a.samples)
        case .midi(let m):
            type = LinkMessageType.midi.rawValue
            w.u64(m.sampleTime)
            let bytes = m.bytes.prefix(Int(UInt16.max))
            w.u16(UInt16(bytes.count))
            w.raw(Array(bytes))
        case .ping(let p), .pong(let p):
            if case .ping = self { type = LinkMessageType.ping.rawValue } else { type = LinkMessageType.pong.rawValue }
            w.u32(p.id)
            w.u64(p.senderTime)
        case .status(let s):
            type = LinkMessageType.status.rawValue
            w.u32(s.underruns)
            w.u32(s.overruns)
            w.u32(s.bufferedFrames)
            w.u32(s.latePackets)
        case .unknown(let t):
            type = t
        }
        var out = ByteWriter()
        out.bytes.reserveCapacity(LinkProtocol.headerSize + w.bytes.count)
        out.u8(type)
        out.u8(0)
        out.u16(0)
        out.u32(UInt32(w.bytes.count))
        out.raw(w.bytes)
        return out.bytes
    }

    // MARK: Decoding

    public static func decode(type: UInt8, payload: ArraySlice<UInt8>) throws -> LinkMessage {
        var r = ByteReader(payload)
        guard let known = LinkMessageType(rawValue: type) else { return .unknown(type: type) }
        switch known {
        case .hello:
            guard try r.raw(4) == LinkProtocol.magic else { throw LinkError.badMagic }
            let version = try r.u16()
            let role = LinkRole(rawValue: try r.u8()) ?? .phone
            _ = try r.u8()
            let n = Int(try r.u8())
            let name = String(decoding: try r.raw(n), as: UTF8.self)
            return .hello(LinkHello(protocolVersion: version, role: role, appVersion: name))
        case .config:
            return .config(LinkConfig(sampleRate: try r.u32(), framesPerPacket: try r.u16(), downChannels: try r.u8(),
                                      upChannels: try r.u8(), upLayout: try r.u8(), ioBufferFrames: try r.u16(),
                                      outputLatencyFrames: try r.u32(), inputLatencyFrames: try r.u32()))
        case .start:
            return .start(sampleTime: try r.u64())
        case .stop:
            return .stop
        case .audioUp, .audioDown:
            let t = try r.u64()
            let frames = try r.u16()
            _ = try r.u16()
            guard r.remaining % 4 == 0 else { throw LinkError.badAudio }
            let samples = try r.floats(r.remaining / 4)
            if !samples.isEmpty { guard frames > 0, samples.count % Int(frames) == 0 else { throw LinkError.badAudio } }
            let audio = LinkAudio(sampleTime: t, frames: frames, samples: samples)
            return known == .audioUp ? .audioUp(audio) : .audioDown(audio)
        case .midi:
            let t = try r.u64()
            let n = Int(try r.u16())
            return .midi(LinkMIDI(sampleTime: t, bytes: try r.raw(n)))
        case .ping, .pong:
            let p = LinkPing(id: try r.u32(), senderTime: try r.u64())
            return known == .ping ? .ping(p) : .pong(p)
        case .status:
            return .status(LinkStatus(underruns: try r.u32(), overruns: try r.u32(), bufferedFrames: try r.u32(), latePackets: try r.u32()))
        }
    }
}

/// Splits a byte stream into messages. Feed it whatever a read returned; it keeps partial messages until the rest arrives.
public struct LinkFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: some Collection<UInt8>) throws -> [LinkMessage] {
        buffer.append(contentsOf: bytes)
        var out: [LinkMessage] = []
        while buffer.count - start >= LinkProtocol.headerSize {
            let length = Int(UInt32(buffer[start + 4]) | UInt32(buffer[start + 5]) << 8
                | UInt32(buffer[start + 6]) << 16 | UInt32(buffer[start + 7]) << 24)
            guard length <= LinkProtocol.maxPayload else { throw LinkError.tooLarge(length) }
            let end = start + LinkProtocol.headerSize + length
            guard buffer.count >= end else { break }
            out.append(try LinkMessage.decode(type: buffer[start], payload: buffer[(start + LinkProtocol.headerSize)..<end]))
            start = end
        }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 1 << 16 {
            buffer.removeFirst(start)
            start = 0
        }
        return out
    }
}

// MARK: - Little-endian byte helpers

struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func raw(_ v: some Collection<UInt8>) { bytes.append(contentsOf: v) }
    mutating func floats(_ v: [Float]) {
        bytes.reserveCapacity(bytes.count + v.count * 4)
        for x in v { u32(x.bitPattern) }
    }
}

struct ByteReader {
    let bytes: ArraySlice<UInt8>
    var index: Int
    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }
    var remaining: Int { bytes.endIndex - index }
    private mutating func take(_ n: Int) throws -> Int {
        guard remaining >= n else { throw LinkError.truncated }
        defer { index += n }
        return index
    }
    mutating func u8() throws -> UInt8 { bytes[try take(1)] }
    mutating func u16() throws -> UInt16 {
        let i = try take(2)
        return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let i = try take(4)
        return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) | UInt64(try u32()) << 32 }
    mutating func raw(_ n: Int) throws -> [UInt8] {
        let i = try take(n)
        return Array(bytes[i..<(i + n)])
    }
    mutating func floats(_ n: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: n)
        for k in 0..<n { out[k] = Float(bitPattern: try u32()) }
        return out
    }
}
