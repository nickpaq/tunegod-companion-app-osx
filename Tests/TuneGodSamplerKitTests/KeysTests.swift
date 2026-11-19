import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct KeysSetupTests {
    @Test func theDefaultSamplesEveryThirdKeyFromC1ToC6() {
        let keys = KeysSetup()
        #expect(keys.step == 3)
        #expect(keys.roots.first == 36)
        #expect(keys.roots.last == 96)
        #expect(keys.roots.count == 21)
        #expect(keys.sampleCount == 42)
    }

    @Test func theHighestNoteIsAlwaysSampled() {
        let keys = KeysSetup(lowest: 60, highest: 70, notesPerOctave: 4)
        #expect(keys.roots == [60, 63, 66, 69, 70])
    }

    @Test func notesPerOctaveSetHowManyAreSampled() {
        #expect(KeysSetup(lowest: 48, highest: 72, notesPerOctave: 12).roots.count == 25)
        #expect(KeysSetup(lowest: 48, highest: 72, notesPerOctave: 1).roots == [48, 60, 72])
        #expect(KeysSetup(lowest: 48, highest: 72, notesPerOctave: 2).roots == [48, 54, 60, 66, 72])
        // A value that is no choice counts as the nearest.
        #expect(KeysSetup(notesPerOctave: 7).perOctave == 6)
        #expect(KeysSetup(notesPerOctave: 40).perOctave == 12)
    }

    @Test func aRangeGivenUpsideDownOrOutOfBoundsIsBroughtIn() {
        let keys = KeysSetup(lowest: 200, highest: 120, notesPerOctave: 12, layers: 9, holdSeconds: 99)
        #expect(keys.range == 120...127)
        #expect(keys.layerCount == MAX_KEY_LAYERS)
        #expect(keys.holdLength == KEY_HOLD_RANGE.upperBound)
    }

    @Test func eachKeyPlaysTheNearestRootAndATieGoesUp() {
        let zones = keyZones(roots: [60, 63, 66])
        #expect(zones.map(\.root) == [60, 63, 66])
        #expect(zones.map(\.topKey) == [61, 64, 127])
        // Two keys apart: the key between them plays the upper root.
        #expect(keyZones(roots: [60, 62]).map(\.topKey) == [60, 127])
        #expect(keyZones(roots: [60]).map(\.topKey) == [127])
        #expect(keyZones(roots: []).isEmpty)
    }

    @Test func aKeyFindsItsZone() {
        let tops = [61, 64, 127]
        #expect(keyZoneIndex(topKeys: tops, key: 0) == 0)
        #expect(keyZoneIndex(topKeys: tops, key: 61) == 0)
        #expect(keyZoneIndex(topKeys: tops, key: 62) == 1)
        #expect(keyZoneIndex(topKeys: tops, key: 127) == 2)
    }

    @Test func anOctaveIsTwiceAsFast() {
        #expect(abs(keyRate(key: 72, root: 60) - 2) < 1e-12)
        #expect(abs(keyRate(key: 48, root: 60) - 0.5) < 1e-12)
        #expect(keyRate(key: 60, root: 60) == 1)
    }

    @Test func notesAreNamedWithMiddleCAsC3() {
        #expect(noteName(60) == "C3")
        #expect(noteName(36) == "C1")
        #expect(noteName(61) == "C♯3")
        #expect(noteName(0) == "C-2")
    }
}

@Suite struct CaptureNoteTests {
    let hold = 4800

    func capture(_ plugin: FakePlugin, note: Int = 60, hold: Int? = nil, settings: CaptureSettings = CaptureSettings()) throws -> CapturedNote? {
        try captureNote(plugin, note: note, velocity: 127, channel: 1, holdFrames: hold ?? self.hold, settings: settings,
                        realTime: false, cancelled: { false })
    }

    @Test func theKeyIsHeldForTheHoldThenTheReleaseIsRecorded() throws {
        let plugin = FakePlugin()
        plugin.endless = [60]
        plugin.releaseSeconds = 0.05
        let note = try #require(try capture(plugin))
        #expect(note.released)
        #expect(note.start == 0)
        #expect(plugin.held.isEmpty)
        #expect(plugin.noteOffFrames.count == 1)
        // Full level up to the note-off, then falling as the plugin releases it.
        #expect(abs(note.hit.left[hold - 1] - 0.8) < 1e-4)
        let release = Int(0.05 * plugin.sampleRate)
        #expect(abs(note.hit.left[hold + release] - Float(0.8 / M_E)) < 0.01)
        #expect(note.lastSound > hold)
        #expect(!note.hit.cutShort)
    }

    @Test func theNoteOffFallsOnTheHoldsFrameWhateverTheBlocks() throws {
        let plugin = FakePlugin()
        plugin.endless = [60]
        plugin.stopsAtNoteOff = true
        // 1000 frames is no whole number of 512-frame blocks.
        let note = try #require(try capture(plugin, hold: 1000))
        #expect(note.released)
        #expect(note.hit.left[999] > 0.5)
        #expect(note.lastSound == 999)
    }

    @Test func aSoundThatEndsWhileTheKeyIsHeldEndsThere() throws {
        let plugin = FakePlugin()
        let note = try #require(try capture(plugin, hold: 48_000))
        #expect(!note.released)
        #expect(note.lastSound < 48_000)
        #expect(note.hit.frames < 48_000)
        #expect(plugin.held.isEmpty)
    }

    @Test func aNoteThatMakesNoSoundWhileHeldIsNone() throws {
        let plugin = FakePlugin()
        plugin.silent = [60]
        #expect(try capture(plugin) == nil)
        #expect(plugin.held.isEmpty)
    }

    @Test func aReleaseThatNeverEndsIsCutShort() throws {
        let plugin = FakePlugin()
        plugin.endless = [60]
        var s = CaptureSettings()
        s.maxSeconds = 0.2
        let note = try #require(try capture(plugin, settings: s))
        #expect(note.hit.cutShort)
        #expect(note.released)
        #expect(note.hit.frames == hold + Int(0.2 * plugin.sampleRate))
    }

    @Test func thePluginsDelayIsWhereTheHitStarts() throws {
        let plugin = FakePlugin()
        plugin.delayFrames = 200
        plugin.endless = [60]
        plugin.releaseSeconds = 0.01
        let note = try #require(try capture(plugin))
        #expect(note.start == 200 - CaptureSettings().leadInFrames)
    }
}

@Suite struct KeysSamplerTests {
    func setup() -> KeysSetup { KeysSetup(lowest: 60, highest: 66, notesPerOctave: 4, layers: 2, holdSeconds: 0.5, channel: 2) }

    func sample(_ plugin: FakePlugin, _ keys: KeysSetup, progress: (Int, Int, String) -> Void = { _, _, _ in }) throws -> SampledKeys {
        try sampleKeys(plugin, setup: keys, settings: CaptureSettings(), realTime: false, progress: progress, cancelled: { false })
    }

    func sustained() -> FakePlugin {
        let plugin = FakePlugin()
        plugin.endless = Set(0...127)
        plugin.releaseSeconds = 0.02
        return plugin
    }

    @Test func everyNoteAndLayerIsPlayedInOrder() throws {
        let plugin = sustained()
        let keys = try sample(plugin, setup())
        #expect(plugin.played == [[60, 64, 2], [60, 127, 2], [63, 64, 2], [63, 127, 2], [66, 64, 2], [66, 127, 2]])
        #expect(keys.notes.map(\.note) == [60, 63, 66])
        #expect(keys.notes.allSatisfy { $0.layers.count == 2 && $0.layers.allSatisfy { $0 != nil } })
        #expect(keys.holdFrames == 24_000)
        #expect(keys.warnings.isEmpty)
    }

    @Test func progressCountsUpToTheTotalByNoteName() throws {
        var seen: [[Int]] = [], labels: [String] = []
        _ = try sample(sustained(), setup()) { done, total, label in seen.append([done, total]); labels.append(label) }
        #expect(seen.first == [0, 6])
        #expect(seen.last == [6, 6])
        #expect(labels.first == "C3")
        #expect(labels.contains("F♯3"))
    }

    @Test func aSilentNoteIsNamed() throws {
        let plugin = sustained()
        plugin.silent = [63]
        let keys = try sample(plugin, setup())
        #expect(keys.warnings.count == 1)
        #expect(keys.warnings[0].contains("D♯3"))
    }

    @Test func cancellingStops() {
        var asked = 0
        #expect(throws: SamplingCancelled.self) {
            try sampleKeys(sustained(), setup: setup(), settings: CaptureSettings(), realTime: false, progress: { _, _, _ in },
                           cancelled: { asked += 1; return asked > 30 })
        }
    }
}

@Suite struct KeysBuilderTests {
    func note(start: Int, level: Float = 0.5, frames: Int = 2400, lastSound: Int = 5800, released: Bool = true) -> CapturedNote {
        CapturedNote(hit: madeHit(level: level, frames: frames), start: start, lastSound: lastSound, released: released)
    }

    func build(_ keys: SampledKeys, layers: Int = 2) throws -> (instrument: TGIInstrument, audio: [String: Data], warnings: [String]) {
        try buildKeysInstrument(keys, setup: KeysSetup(layers: layers), name: " Strings ", madeWith: "Maker: Strings", id: "ID",
                                created: "2026-11-19T09:00:00Z", sampleRate: 48_000)
    }

    @Test func zonesLayersHoldAndReleaseAreWorkedOut() throws {
        let sampled = SampledKeys(notes: [
            (60, [note(start: 100), note(start: 100)]),
            (63, [note(start: 130), note(start: 120)]),
            (66, [nil, note(start: 110)]),
        ], holdFrames: 1000, warnings: [])
        let built = try build(sampled)
        let i = built.instrument
        #expect(i.kind == .keys)
        #expect(i.name == "Strings")
        #expect(i.madeWith == "Maker: Strings")
        let zones = try #require(i.zones)
        #expect(zones.map(\.root) == [60, 63, 66])
        #expect(zones.map(\.topKey) == [61, 64, 127])
        #expect(zones[0].layers.map(\.velocity) == [64, 127])
        #expect(zones[0].layers.map(\.top) == [64, 127])
        // The soft layer made no sound on 66: the hard one answers every velocity.
        #expect(zones[2].layers.map(\.velocity) == [127])
        #expect(zones[2].layers.map(\.top) == [127])
        // Every hit starts where the earliest did (100 frames after its note-on), so the key was let go 900 frames into each.
        #expect(i.holdFrames == 900)
        // From the note-off (1000) to the last sound (5800): 4800 frames, 100 ms.
        #expect(i.releaseMs == 100)
        #expect(built.audio.count == 5)
        #expect(built.warnings.isEmpty)
        try validateTGI(i)
    }

    @Test func aLaterHitIsGivenSilenceToStartWithTheOthers() throws {
        let sampled = SampledKeys(notes: [(60, [note(start: 100)]), (72, [note(start: 130)])], holdFrames: 1000, warnings: [])
        let built = try build(sampled, layers: 1)
        let early = try decodeAudio(try #require(built.audio[keyHitName(note: 60, layer: 0)]))
        let late = try decodeAudio(try #require(built.audio[keyHitName(note: 72, layer: 0)]))
        #expect(early.left.count == 2400)
        #expect(late.left.count == 2430)
        #expect(late.left.prefix(30).allSatisfy { $0 == 0 })
    }

    @Test func aSilentNoteIsLeftOutAndItsKeysPlayTheNearest() throws {
        let sampled = SampledKeys(notes: [(60, [note(start: 0)]), (63, [nil]), (66, [note(start: 0)])], holdFrames: 1000,
                                  warnings: ["silent"])
        let built = try build(sampled, layers: 1)
        let zones = try #require(built.instrument.zones)
        #expect(zones.map(\.root) == [60, 66])
        #expect(zones.map(\.topKey) == [62, 127])
        #expect(built.warnings == ["silent"])
    }

    @Test func withNoReleaseHeardTheReleaseIsTheDefault() throws {
        let sampled = SampledKeys(notes: [(60, [note(start: 0, released: false)])], holdFrames: 48_000, warnings: [])
        #expect(try build(sampled, layers: 1).instrument.releaseMs == DEFAULT_RELEASE_MS)
    }

    @Test func clippedNotesAreCounted() throws {
        var loud = note(start: 0)
        loud.hit.peak = 1.4
        let sampled = SampledKeys(notes: [(60, [loud])], holdFrames: 1000, warnings: [])
        let warnings = try build(sampled, layers: 1).warnings
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("1 note is louder"))
    }

    @Test func noSoundAtAllIsRefused() {
        let sampled = SampledKeys(notes: [(60, [nil, nil])], holdFrames: 1000, warnings: [])
        #expect(throws: TGIError.self) { try build(sampled) }
    }

    @Test func theFileIsReadBackByTuneGodCore() throws {
        let sampled = SampledKeys(notes: [(48, [note(start: 0)]), (60, [note(start: 0)])], holdFrames: 1000, warnings: [])
        let built = try build(sampled, layers: 1)
        let back = try readTGI(try writeTGI(built.instrument, audio: built.audio))
        #expect(back.instrument == built.instrument)
        #expect(back.audio.count == 2)
    }

    @Test func aWholeKeysInstrumentFromThePluginToTheFile() throws {
        let plugin = FakePlugin()
        plugin.endless = Set(0...127)
        plugin.releaseSeconds = 0.02
        let keys = KeysSetup(lowest: 48, highest: 60, notesPerOctave: 2, layers: 2, holdSeconds: 0.5)
        let sampled = try sampleKeys(plugin, setup: keys, settings: CaptureSettings(), realTime: false, progress: { _, _, _ in },
                                     cancelled: { false })
        let built = try buildKeysInstrument(sampled, setup: keys, name: "Pad", madeWith: nil, id: "ID", created: "2026-11-19T09:00:00Z",
                                            sampleRate: plugin.sampleRate)
        #expect(built.instrument.zones?.map(\.root) == [48, 54, 60])
        #expect(built.instrument.holdFrames == 24_000)
        let release = try #require(built.instrument.releaseMs)
        // A release falling to 1/e in 20 ms reaches −80 dB (from 0.8, or 0.4 for the soft layer) in about 170 ms.
        #expect(release > 120 && release < 220)
        _ = try readTGI(try writeTGI(built.instrument, audio: built.audio))
    }
}

@Suite struct KeysVoicesTests {
    /// One zone, rooted at 60, layers at 64 and 127; a constant sound `frames` long; the key let go 100 frames in; releases in 10 ms.
    func voices(frames: Int = 2000, hold: Int = 100) -> KeysVoices {
        let instrument = TGIInstrument(id: "ID", name: "Test", kind: .keys, created: "2026-11-19T09:00:00Z", zones: [
            TGIZone(root: 60, topKey: 127, layers: [TGILayer(velocity: 64, top: 64, hits: ["soft"]), TGILayer(velocity: 127, top: 127, hits: ["hard"])]),
        ], releaseMs: 10, holdFrames: hold)
        let soft = [Float](repeating: 0.25, count: frames), hard = [Float](repeating: 0.5, count: frames)
        return KeysVoices(instrument: instrument, sounds: ["soft": (soft, soft), "hard": (hard, hard)], sampleRate: 48_000)
    }

    func render(_ v: KeysVoices, _ frames: Int) -> [Float] {
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in _ = v.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!) } }
        return l
    }

    @Test func theVelocityPicksTheLayerAndTheLevel() {
        let v = voices()
        v.noteOn(key: 60, velocity: 127)
        #expect(abs(render(v, 10)[5] - 0.5) < 1e-6)
        v.allOff()
        v.noteOn(key: 60, velocity: 32)
        // The soft layer, at half its own velocity.
        #expect(abs(render(v, 10)[5] - 0.25 * 32 / 64) < 1e-6)
    }

    @Test func anOctaveUpPlaysTheSampleTwiceAsFast() {
        let v = voices(frames: 1000)
        v.noteOn(key: 72, velocity: 127)
        let out = render(v, 600)
        #expect(out[499] > 0.4)
        #expect(out[500] == 0)
        #expect(v.sounding == 0)
    }

    @Test func aKeyLetGoBeforeTheHoldFades() {
        let v = voices()
        v.noteOn(key: 60, velocity: 127)
        _ = render(v, 50)
        v.noteOff(key: 60)
        let out = render(v, 600)
        // 10 ms is 480 frames.
        #expect(abs(out[0] - 0.5) < 0.002)
        #expect(abs(out[240] - 0.25) < 0.01)
        #expect(out[490] == 0)
        #expect(v.sounding == 0)
    }

    @Test func aKeyHeldPastTheHoldPlaysOnToTheEnd() {
        let v = voices()
        v.noteOn(key: 60, velocity: 127)
        _ = render(v, 200)
        v.noteOff(key: 60)
        let out = render(v, 2000)
        #expect(abs(out[1000] - 0.5) < 1e-6)
        #expect(out[1800] == 0)
    }

    @Test func playingAKeyAgainLetsItsLastNoteGo() {
        let v = voices()
        v.noteOn(key: 60, velocity: 127)
        v.noteOn(key: 60, velocity: 127)
        #expect(v.sounding == 2)
        _ = render(v, 600)
        #expect(v.sounding == 1)
    }

    @Test func aPlayerIsMadeFromABuiltInstrument() throws {
        let sampled = SampledKeys(notes: [(60, [CapturedNote(hit: madeHit(level: 0.3), start: 0, lastSound: 1500, released: true)])],
                                  holdFrames: 1000, warnings: [])
        let built = try buildKeysInstrument(sampled, setup: KeysSetup(layers: 1), name: "K", madeWith: nil, id: "ID",
                                            created: "2026-11-19T09:00:00Z", sampleRate: 48_000)
        let player = try KeysPlayer(instrument: built.instrument, audio: built.audio)
        #expect(player.hitCount == 1)
        #expect(player.decodedBytes == 2400 * 2 * 4)
        #expect(throws: TGIError.self) { try KeysPlayer(instrument: built.instrument, audio: [:]) }
    }
}
