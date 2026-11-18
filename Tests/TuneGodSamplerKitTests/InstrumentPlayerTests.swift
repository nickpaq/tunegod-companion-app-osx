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
