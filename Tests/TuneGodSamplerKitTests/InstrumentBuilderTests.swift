import Foundation
import Testing
@testable import TuneGodSamplerKit

/// A hit of `frames` frames whose samples step through a fixed pattern at `level`.
func madeHit(level: Float = 0.5, frames: Int = 2400, stereo: Bool = false, peak: Float? = nil) -> CapturedHit {
    let left = (0..<frames).map { level * Float(($0 * 37) % 101 - 50) / 50 }
    let right = stereo ? left.map { $0 * 0.5 } : nil
    return CapturedHit(left: left, right: right, peak: peak ?? level, cutShort: false)
}

@Suite struct AudioCodingTests {
    @Test func aStereoHitComesBackAsItWent() throws {
        let hit = madeHit(level: 0.9, stereo: true)
        let back = try decodeAudio(try encodeAppleLossless(hit, sampleRate: 48_000))
        #expect(back.sampleRate == 48_000)
        #expect(back.left.count == hit.frames)
        let right = try #require(back.right)
        // 24 bits: within one step of what went in.
        let step: Float = 1 / 8_388_608
        #expect(zip(back.left, hit.left).allSatisfy { abs($0 - $1) <= step })
        #expect(zip(right, hit.right!).allSatisfy { abs($0 - $1) <= step })
    }

    @Test func aMonoHitStaysMono() throws {
        let back = try decodeAudio(try encodeAppleLossless(madeHit(), sampleRate: 48_000))
        #expect(back.right == nil)
        #expect(back.left.count == 2400)
    }

    @Test func whatIsNotAudioIsRefused() {
        #expect(throws: (any Error).self) { try decodeAudio(Data("not audio".utf8)) }
    }
}

@Suite struct InstrumentBuilderTests {
    /// Kick on 12 (two alternates), closed hat on 14 cutting the open hat on 15, two layers.
    func setup() -> KitSetup {
        var pads = [PadSetup?](repeating: nil, count: 16)
        pads[12] = PadSetup(note: 36, label: "Kick", type: "kick")
        pads[14] = PadSetup(note: 42, label: "Closed hat", type: "closedHat", cuts: [15, 14, 99])
        pads[15] = PadSetup(note: 46, label: "Open hat", type: "openHat")
        return KitSetup(pads: pads, layers: 2, alternates: 2)
    }

    func kit(openHat: Bool = true) -> SampledKit {
        var hits = [[[CapturedHit]]?](repeating: nil, count: 16)
        hits[12] = [[madeHit(level: 0.2), madeHit(level: 0.21)], [madeHit(level: 0.6), madeHit(level: 0.61)]]
        hits[14] = [[madeHit(level: 0.1, stereo: true)], [madeHit(level: 0.3, stereo: true)]]
        if openHat { hits[15] = [[madeHit(level: 0.1)], [madeHit(level: 0.3)]] }
        return SampledKit(hits: hits, warnings: [])
    }

    func build(_ kit: SampledKit, _ setup: KitSetup, name: String = "Studio Kit") throws
        -> (instrument: TGIInstrument, audio: [String: Data], warnings: [String]) {
        try buildInstrument(kit, setup: setup, name: name, madeWith: "A plugin", id: "ID-1", created: "2026-11-18T09:00:00Z",
                            sampleRate: 48_000)
    }

    @Test func aBuiltKitIsAPadsInstrumentThePhoneAccepts() throws {
        let built = try build(kit(), setup())
        let i = built.instrument
        #expect(i.kind == .pads)
        #expect(i.name == "Studio Kit")
        #expect(i.id == "ID-1")
        #expect(i.madeWith == "A plugin")
        #expect(i.pads?.count == 16)
        let kick = try #require(i.pads?[12])
        #expect(kick.label == "Kick")
        #expect(kick.type == "kick")
        #expect(kick.layers.map(\.velocity) == [64, 127])
        #expect(kick.layers.map(\.top) == [64, 127])
        #expect(kick.layers[0].hits == ["p12-l0-a0.caf", "p12-l0-a1.caf"])
        #expect(kick.layers[1].hits == ["p12-l1-a0.caf", "p12-l1-a1.caf"])
        #expect(i.pads?[0] == nil)
        #expect(built.audio.count == 8)
        #expect(built.warnings.isEmpty)
        try validateTGI(i)
        let back = try readTGI(try writeTGI(i, audio: built.audio))
        #expect(back.instrument == i)
        #expect(back.audio == built.audio)
    }

    @Test func aCutKeepsOnlyOtherPadsThatExist() throws {
        #expect(try build(kit(), setup()).instrument.pads?[14]?.cuts == [15])
        #expect(try build(kit(openHat: false), setup()).instrument.pads?[14]?.cuts == nil)
    }

    @Test func aLayerThatMadeNoSoundIsLeftOutAndTheHardestStillAnswersEverything() throws {
        var k = kit()
        k.hits[12] = [[], [madeHit()], [madeHit()]]
        k.hits[14] = [[madeHit()], [madeHit()], []]
        var s = setup()
        s.layers = 3
        let i = try build(k, s).instrument
        #expect(i.pads?[12]?.layers.map(\.velocity) == [85, 127])
        #expect(i.pads?[12]?.layers.map(\.top) == [85, 127])
        #expect(i.pads?[14]?.layers.map(\.velocity) == [42, 85])
        #expect(i.pads?[14]?.layers.map(\.top) == [42, 127])
        try validateTGI(i)
    }

    @Test func hitsLouderThanFullScaleAreCountedInAWarning() throws {
        var k = kit()
        k.hits[12]?[1] = [madeHit(peak: 1.4), madeHit(peak: 1.01)]
        k.warnings = ["Earlier warning."]
        let warnings = try build(k, setup()).warnings
        #expect(warnings.count == 2)
        #expect(warnings[0] == "Earlier warning.")
        #expect(warnings[1].contains("2 hits"))
        #expect(warnings[1].contains("full scale"))
    }

    @Test func aKitWithNoSoundAtAllIsRefused() {
        let empty = SampledKit(hits: [[[CapturedHit]]?](repeating: nil, count: 16), warnings: [])
        #expect(throws: TGIError.self) { try build(empty, setup()) }
    }

    @Test func anEmptyNameOrLabelGetsOne() throws {
        var s = setup()
        s.pads[12]?.label = "  "
        let i = try build(kit(), s, name: " ").instrument
        #expect(i.name == "Instrument")
        #expect(i.pads?[12]?.label == "Pad 13")
    }

    @Test func theFileNameIsSafe() {
        #expect(instrumentFileName("Studio Kit") == "Studio Kit.tgi")
        #expect(instrumentFileName("a/b:c") == "a-b-c.tgi")
        #expect(instrumentFileName("  ") == "Instrument.tgi")
    }
}
