import Foundation
import Testing
@testable import TuneGodLinkKit

@Suite struct ProtocolTests {
    static let all: [LinkMessage] = [
        .hello(LinkHello(role: .phone, appVersion: "3.157.0")),
        .config(LinkPhoneSimulator.defaultConfig),
        .start(sampleTime: 1 << 40),
        .stop,
        .audioUp(LinkAudio(sampleTime: 64, frames: 2, samples: [0.5, -0.5, 1, -1])),
        .audioUp(LinkAudio(sampleTime: 128, frames: 64, samples: [])),
        .audioDown(LinkAudio(sampleTime: 7, frames: 1, samples: [0.25, 0.75])),
        .midi(LinkMIDI(sampleTime: 99, bytes: [0x90, 60, 100])),
        .ping(LinkPing(id: 3, senderTime: 123_456_789)),
        .pong(LinkPing(id: 3, senderTime: 123_456_789)),
        .status(LinkStatus(underruns: 1, overruns: 2, bufferedFrames: 3, latePackets: 4)),
    ]

    @Test func roundTripsEveryMessage() throws {
        for message in Self.all {
            var decoder = LinkFrameDecoder()
            #expect(try decoder.append(message.encoded()) == [message])
        }
    }

    @Test func headerIsLittleEndianWithPayloadLength() {
        let bytes = LinkMessage.start(sampleTime: 1).encoded()
        #expect(Array(bytes[0..<8]) == [0x03, 0, 0, 0, 8, 0, 0, 0])
        #expect(Array(bytes[8...]) == [1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func decodesAcrossArbitrarySplits() throws {
        let stream = Self.all.flatMap { $0.encoded() }
        var decoder = LinkFrameDecoder()
        var out: [LinkMessage] = []
        var i = 0
        var size = 1
        while i < stream.count {
            let end = min(stream.count, i + size)
            out += try decoder.append(stream[i..<end])
            i = end
            size = size % 7 + 1
        }
        #expect(out == Self.all)
    }

    @Test func skipsUnknownTypes() throws {
        var bytes: [UInt8] = [0x7E, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3]
        bytes += LinkMessage.stop.encoded()
        var decoder = LinkFrameDecoder()
        #expect(try decoder.append(bytes) == [.unknown(type: 0x7E), .stop])
    }

    @Test func rejectsBadMagicAndHugeMessages() {
        var decoder = LinkFrameDecoder()
        #expect(throws: LinkError.badMagic) { try decoder.append([0x01, 0, 0, 0, 5, 0, 0, 0, 0x41, 0x42, 0x43, 0x44, 0]) }
        var other = LinkFrameDecoder()
        #expect(throws: LinkError.tooLarge(0x0200_0000)) { try other.append([0x10, 0, 0, 0, 0, 0, 0, 2]) }
    }
}

@Suite struct MIDIUMPTests {
    @Test func channelAndSystemMessages() {
        let words = MIDIUMP.messages(fromBytes: [0x90, 60, 100, 62, 90, 0xF8, 0xC3, 5])
        #expect(words == [[0x2090_3C64], [0x2090_3E5A], [0x10F8_0000], [0x20C3_0500]])
    }

    @Test func realTimeInsideRunningStatus() {
        #expect(MIDIUMP.messages(fromBytes: [0x80, 60, 0xF8, 0]) == [[0x10F8_0000], [0x2080_3C00]])
    }

    @Test func sysexRoundTrip() {
        let sysex: [UInt8] = [0xF0] + Array(1...13) + [0xF7]
        let words = MIDIUMP.messages(fromBytes: sysex).flatMap { $0 }
        #expect(words.count == 6)
        #expect(MIDIUMP.bytes(fromWords: words) == sysex)
        let short: [UInt8] = [0xF0, 0x7E, 0x7F, 0xF7]
        #expect(MIDIUMP.bytes(fromWords: MIDIUMP.messages(fromBytes: short).flatMap { $0 }) == short)
    }

    @Test func bytesRoundTrip() {
        let bytes: [UInt8] = [0x90, 60, 100, 0xB0, 7, 127, 0xE0, 0, 64, 0xD0, 30, 0xF2, 1, 2, 0xFA, 0xFC]
        #expect(MIDIUMP.bytes(fromWords: MIDIUMP.messages(fromBytes: bytes).flatMap { $0 }) == bytes)
    }
}

@Suite struct ClockTests {
    @Test func locksToARateDifferentFromNominal() {
        // The phone runs 0.01 % fast against the Mac, with ±0.3 ms arrival jitter.
        var clock = ClockMapper(sampleRate: 48000)
        let trueRate = 48004.8
        var generator = SystemRandomNumberGenerator()
        for k in 0..<(48000 / 64 * 20) {
            let s = UInt64(k * 64)
            let jitter = Double.random(in: -0.0003...0.0003, using: &generator)
            clock.update(sampleTime: s, frames: 64, host: 100 + Double(s) / trueRate + jitter)
        }
        #expect(abs(clock.rate - trueRate) < 2)
        let s = clock.latestSample
        let predicted = clock.hostTime(forSample: s)!
        #expect(abs(predicted - (100 + Double(s) / trueRate)) < 0.0005)
        #expect(clock.resets == 0)
    }

    @Test func restartsOnAGap() {
        var clock = ClockMapper(sampleRate: 48000)
        clock.update(sampleTime: 0, frames: 64, host: 1)
        clock.update(sampleTime: 64, frames: 64, host: 1 + 64.0 / 48000)
        clock.update(sampleTime: 6400, frames: 64, host: 2)
        #expect(clock.resets == 1)
        #expect(clock.latestSample == 6464)
    }
}

@Suite(.serialized) struct LoopbackTests {
    /// The Mac session against the phone simulator over loopback TCP: the tone arrives, the phone barely runs dry, MIDI flows both ways.
    @Test func macSessionAgainstSimulator() throws {
        let port: UInt16 = 47900 + UInt16.random(in: 0..<50)
        let listener = try LinkListener(port: port)
        let sim = LinkPhoneSimulator(port: port)
        sim.sendMIDINotes = true
        let reports = Locked<[LinkPhoneSimulator.Report]>([])
        sim.onReport = { r in reports.mutate { $0.append(r) } }
        let server = Thread {
            if let socket = try? listener.accept() { sim.serve(socket) }
        }
        server.start()

        let socket = try LinkSocket.connectTCP(host: "127.0.0.1", port: port)
        let session = LinkMacSession(socket: socket, appVersion: "test")
        let tone = ToneGenerator()
        session.downSource = { _, frames, channels in tone.render(frames: frames, channels: channels) }
        let midiUp = Locked(0)
        session.onMIDI = { _, _ in midiUp.mutate { $0 += 1 } }
        session.start()
        Thread.sleep(forTimeInterval: 0.5)
        session.sendMIDI([0x90, 64, 1], hostTicks: 0)
        Thread.sleep(forTimeInterval: 3.2)
        let stats = session.stats
        session.stop()

        #expect(stats.config == LinkPhoneSimulator.defaultConfig)
        #expect(stats.packetsUp > 1200)
        #expect(stats.packetsDown > 1200)
        #expect(stats.roundTripMs != nil)
        #expect(abs((stats.measuredRate ?? 0) - 48000) < 100)
        #expect(midiUp.value >= 3)
        let last = try #require(reports.value.last)
        #expect(last.receivedRMS > 0.1)
        // Start-up may miss a block or two; a lead that keeps climbing (gaps when it moves) would show here.
        #expect(last.underruns < 6)
        #expect(stats.downLeadFrames <= 4 * 64)
        #expect(last.midiReceived == 1)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
