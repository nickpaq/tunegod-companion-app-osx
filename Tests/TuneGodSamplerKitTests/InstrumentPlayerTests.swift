import AVFoundation
import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct InstrumentPlayerTests {
    /// Two layers: soft (played at 64, answering up to 64) with two alternates, hard (127) with one.
    let pad = TGIPad(label: "Snare", layers: [
        TGILayer(velocity: 64, top: 64, hits: ["soft-a", "soft-b"]),
        TGILayer(velocity: 127, top: 127, hits: ["hard"]),
    ])

    @Test func theLayerIsTheFirstWhoseTopReachesTheVelocity() {
        var last: [Int: Int] = [:]
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 1, last: &last).layer == 0)
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 64, last: &last).layer == 0)
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 65, last: &last).layer == 1)
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 127, last: &last).layer == 1)
    }

    @Test func alternatesTakeTurnsWithinTheirLayer() {
        var last: [Int: Int] = [:]
        let hits = [40, 50, 127, 60, 127].map { InstrumentPlayer.choice(pad: pad, velocity: $0, last: &last).hit }
        #expect(hits == [0, 1, 0, 0, 0])
    }

    @Test func aNoteAtTheLayersOwnVelocityPlaysTheRecordingAsItIs() {
        var last: [Int: Int] = [:]
        #expect(abs(InstrumentPlayer.choice(pad: pad, velocity: 64, last: &last).gain - 1) < 1e-9)
        #expect(abs(InstrumentPlayer.choice(pad: pad, velocity: 127, last: &last).gain - 1) < 1e-9)
        #expect(abs(InstrumentPlayer.choice(pad: pad, velocity: 32, last: &last).gain - 0.5) < 1e-9)
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 100, last: &last).gain < 1)
    }

    @Test func velocitiesOutOfRangeAreBroughtIn() {
        var last: [Int: Int] = [:]
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 0, last: &last).layer == 0)
        #expect(InstrumentPlayer.choice(pad: pad, velocity: 300, last: &last).gain == 1)
    }

    @Test func aPlayerIsMadeFromABuiltInstrumentAndRefusesOneWithoutItsAudio() throws {
        var hits = [[[CapturedHit]]?](repeating: nil, count: 16)
        hits[12] = [[madeHit(level: 0.2)], [madeHit(level: 0.6, stereo: true)]]
        var pads = [PadSetup?](repeating: nil, count: 16)
        pads[12] = PadSetup(note: 36, label: "Kick")
        let built = try buildInstrument(SampledKit(hits: hits, warnings: []), setup: KitSetup(pads: pads, layers: 2), name: "Kit",
                                        madeWith: nil, id: "ID", created: "2026-11-18T09:00:00Z", sampleRate: 48_000)
        let player = try InstrumentPlayer(instrument: built.instrument, audio: built.audio)
        #expect(player.hitCount == 2)
        #expect(player.decodedBytes == 2 * 2400 * 2 * 4)
        #expect(throws: TGIError.self) { try InstrumentPlayer(instrument: built.instrument, audio: [:]) }
    }
}

/// The player's sound itself, rendered by hand instead of through the Mac's output.
@Suite(.serialized) struct InstrumentPlayerSoundTests {
    /// Kick on 12 (soft 0.2 at velocity 64, hard 0.6 at 127); a long open hat on 15 (0.3); a closed hat on 14 (0.1) that cuts it.
    func player() throws -> InstrumentPlayer {
        var hits = [[[CapturedHit]]?](repeating: nil, count: 16)
        hits[12] = [[madeHit(level: 0.2)], [madeHit(level: 0.6)]]
        hits[15] = [[madeHit(level: 0.3, frames: 48_000)], [madeHit(level: 0.3, frames: 48_000)]]
        hits[14] = [[madeHit(level: 0.1)], [madeHit(level: 0.1)]]
        var pads = [PadSetup?](repeating: nil, count: 16)
        pads[12] = PadSetup(note: 36, label: "Kick")
        pads[14] = PadSetup(note: 42, label: "Closed hat", cuts: [15])
        pads[15] = PadSetup(note: 46, label: "Open hat")
        let built = try buildInstrument(SampledKit(hits: hits, warnings: []), setup: KitSetup(pads: pads, layers: 2), name: "Kit",
                                        madeWith: nil, id: "ID", created: "2026-11-18T09:00:00Z", sampleRate: 48_000)
        let player = try InstrumentPlayer(instrument: built.instrument, audio: built.audio)
        try player.engine.enableManualRenderingMode(.offline, format: player.format, maximumFrameCount: 4096)
        return player
    }

    /// The loudest sample of the player's next 4096 frames.
    func heard(_ player: InstrumentPlayer) throws -> Float {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096))
        _ = try player.engine.renderOffline(4096, to: buffer)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return left.reduce(0) { max($0, abs($1)) }
    }

    @Test func aPadSoundsAtTheLevelItsVelocityGives() throws {
        let p = try player()
        p.play(pad: 12, velocity: 127)
        #expect(abs(try heard(p) - 0.6) < 0.01)
        p.stopAll()
        p.play(pad: 12, velocity: 64)
        #expect(abs(try heard(p) - 0.2) < 0.01)
        p.stopAll()
        p.play(pad: 12, velocity: 32)
        #expect(abs(try heard(p) - 0.1) < 0.01)
        p.stopAll()
    }

    @Test func anEmptyPadIsSilent() throws {
        let p = try player()
        p.play(pad: 0, velocity: 127)
        p.play(pad: 99, velocity: 127)
        p.play(pad: 12, velocity: 127)
        p.stopAll()
        p.play(pad: 3, velocity: 127)
        #expect(p.engine.isRunning == false)
    }

    @Test func aPadSilencesThePadsItCuts() throws {
        let p = try player()
        p.play(pad: 15, velocity: 127)
        #expect(abs(try heard(p) - 0.3) < 0.01)
        p.play(pad: 14, velocity: 127)
        // Only the closed hat is left: the open hat would still be ringing.
        #expect(abs(try heard(p) - 0.1) < 0.01)
        p.stopAll()
    }
}

@Suite struct MIDINoteTests {
    @Test func aNoteOnAndOffAreReadFromAMIDIWord() throws {
        let on = try #require(midiNote(word: 0x2090_2A64))
        #expect(on.note == 42)
        #expect(on.velocity == 100)
        #expect(on.on)
        let off = try #require(midiNote(word: 0x2085_2A40))
        #expect(off.note == 42)
        #expect(!off.on)
    }

    @Test func aNoteOnAtVelocityZeroIsANoteOff() throws {
        let off = try #require(midiNote(word: 0x2093_3C00))
        #expect(off.note == 60)
        #expect(!off.on)
    }

    @Test func otherMessagesAreNotNotes() {
        #expect(midiNote(word: 0x20B0_7B00) == nil)
        #expect(midiNote(word: 0x1000_0000) == nil)
    }
}
