import AudioToolbox
import Foundation
import Testing
@testable import TuneGodSamplerKit

/// These run a real Audio Unit: the system's own General MIDI instrument, which every Mac has. Its drums are on channel 10.
@Suite(.serialized) struct PluginHostTests {
    func systemInstrument() throws -> PluginInfo {
        try #require(installedInstruments().first { $0.subtype == kAudioUnitSubType_DLSSynth && $0.manufacturer == kAudioUnitManufacturer_Apple })
    }

    @Test func theInstalledInstrumentsIncludeTheSystemsOwn() throws {
        let all = installedInstruments()
        #expect(all.contains { $0.subtype == kAudioUnitSubType_DLSSynth })
        #expect(all.allSatisfy { $0.type == kAudioUnitType_MusicDevice && !$0.name.isEmpty })
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func aNoteMakesSoundAndAHardOneIsLouder() async throws {
        let host = try await PluginHost.load(try systemInstrument(), sampleRate: 48_000)
        host.sampling = true
        host.offline = true
        let settings = CaptureSettings()
        let soft = try #require(try captureHit(host, note: 36, velocity: 32, channel: 10, settings: settings, realTime: false, cancelled: { false }))
        let hard = try #require(try captureHit(host, note: 36, velocity: 127, channel: 10, settings: settings, realTime: false, cancelled: { false }))
        #expect(hard.peak > soft.peak * 1.5)
        #expect(hard.peak > 0.01)
        #expect(hard.frames > 480)
        #expect(!hard.cutShort)
        // Silent again once the hit is over.
        var l: [Float] = [], r: [Float] = []
        try host.render(frames: 4800, left: &l, right: &r)
        #expect(l.count == 4800)
        #expect(l.allSatisfy { abs($0) < settings.threshold } && r.allSatisfy { abs($0) < settings.threshold })
    }

    @Test func theSpeakerGetsNothingWhileASampleIsTaken() async throws {
        let host = try await PluginHost.load(try systemInstrument(), sampleRate: 48_000)
        var left = [Float](repeating: 1, count: 512), right = [Float](repeating: 1, count: 512)
        host.sampling = true
        #expect(!host.liveRender(frames: 512, left: &left, right: &right))
        host.sampling = false
        host.noteOn(36, velocity: 127, channel: 10)
        var heard: Float = 0
        for _ in 0..<20 {
            #expect(host.liveRender(frames: 512, left: &left, right: &right))
            heard = max(heard, left.map(abs).max() ?? 0)
        }
        host.allNotesOff()
        #expect(heard > 0.01)
    }

    @Test func aWholeKitFromTheSystemInstrumentIsAFileThePhoneAccepts() async throws {
        let host = try await PluginHost.load(try systemInstrument(), sampleRate: 48_000)
        host.sampling = true
        host.offline = true
        var pads = [PadSetup?](repeating: nil, count: 16)
        pads[12] = PadSetup(note: 36, label: "Kick", type: "kick")
        pads[13] = PadSetup(note: 38, label: "Snare", type: "snare")
        let setup = KitSetup(pads: pads, layers: 2, alternates: 1, channel: 10)
        let kit = try sampleKit(host, setup: setup, settings: CaptureSettings(), realTime: false, progress: { _, _, _ in }, cancelled: { false })
        let built = try buildInstrument(kit, setup: setup, name: "System drums", madeWith: host.info.name, id: UUID().uuidString,
                                        created: "2026-11-18T09:00:00Z", sampleRate: host.sampleRate)
        let back = try readTGI(try writeTGI(built.instrument, audio: built.audio))
        #expect(back.instrument.pads?.compactMap { $0 }.count == 2)
        #expect(back.audio.count == 4)
        let soft = try decodeAudio(try #require(back.audio["p12-l0-a0.caf"]))
        let hard = try decodeAudio(try #require(back.audio["p12-l1-a0.caf"]))
        #expect(hard.left.map(abs).max()! > soft.left.map(abs).max()!)
    }
}
