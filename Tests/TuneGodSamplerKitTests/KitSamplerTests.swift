import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct KitSamplerTests {
    /// Kick on pad 12 and snare on pad 13, two layers, two alternates, on channel 10.
    func twoPads() -> KitSetup {
        var pads = [PadSetup?](repeating: nil, count: 16)
        pads[12] = PadSetup(note: 36, label: "Kick", type: "kick", cuts: [])
        pads[13] = PadSetup(note: 38, label: "Snare", type: "snare", cuts: [])
        return KitSetup(pads: pads, layers: 2, alternates: 2, channel: 10)
    }

    func sample(_ plugin: FakePlugin, _ setup: KitSetup, settings: CaptureSettings = CaptureSettings(),
                progress: (Int, Int, String) -> Void = { _, _, _ in }) throws -> SampledKit {
        try sampleKit(plugin, setup: setup, settings: settings, realTime: false, progress: progress, cancelled: { false })
    }

    @Test func everyPadLayerAndAlternateIsPlayedInOrder() throws {
        let plugin = FakePlugin()
        let kit = try sample(plugin, twoPads())
        #expect(plugin.played == [[36, 64, 10], [36, 64, 10], [36, 127, 10], [36, 127, 10],
                                  [38, 64, 10], [38, 64, 10], [38, 127, 10], [38, 127, 10]])
        let kick = try #require(kit.hits[12])
        #expect(kick.count == 2)
        #expect(kick.allSatisfy { $0.count == 2 })
        #expect(kick[1][0].peak > kick[0][0].peak)
        #expect(kit.hits[0] == nil)
        #expect(kit.hits.count == 16)
        #expect(kit.warnings.isEmpty)
    }

    @Test func progressCountsUpToTheTotal() throws {
        var seen: [[Int]] = []
        var labels: [String] = []
        let setup = twoPads()
        _ = try sample(FakePlugin(), setup) { done, total, label in seen.append([done, total]); labels.append(label) }
        #expect(setup.sampleCount == 8)
        #expect(seen.first == [0, 8])
        #expect(seen.last == [8, 8])
        #expect(labels.first == "Kick")
        #expect(labels.contains("Snare"))
    }

    @Test func aPadThatMakesNoSoundIsLeftEmptyAndNamed() throws {
        let plugin = FakePlugin()
        plugin.silent = [38]
        let kit = try sample(plugin, twoPads())
        #expect(kit.hits[13] == nil)
        #expect(kit.hits[12] != nil)
        #expect(kit.warnings.count == 1)
        #expect(kit.warnings[0].contains("Snare"))
        #expect(!kit.warnings[0].contains("Kick"))
    }

    @Test func aPadThatWasCutShortIsNamed() throws {
        let plugin = FakePlugin()
        plugin.endless = [36]
        plugin.stopsAtNoteOff = true
        var s = CaptureSettings()
        s.maxSeconds = 0.2
        let kit = try sample(plugin, twoPads(), settings: s)
        #expect(kit.warnings.count == 1)
        #expect(kit.warnings[0].contains("Kick"))
    }

    @Test func cancellingStopsTheKit() {
        var asked = 0
        #expect(throws: SamplingCancelled.self) {
            try sampleKit(FakePlugin(), setup: twoPads(), settings: CaptureSettings(), realTime: false, progress: { _, _, _ in },
                          cancelled: { asked += 1; return asked > 50 })
        }
    }

    @Test func theStandardDrumsFollowTuneGodsOwnKit() {
        let kit = KitSetup.standardDrums()
        #expect(kit.pads.count == 16)
        #expect(kit.pads.allSatisfy { $0 != nil })
        #expect(kit.pads[12]?.note == 36)
        #expect(kit.pads[12]?.type == "kick")
        #expect(kit.pads[13]?.note == 38)
        #expect(kit.pads[14]?.note == 42)
        #expect(kit.pads[14]?.cuts == [15])
        #expect(kit.pads[15]?.note == 46)
        #expect(kit.pads[15]?.type == "openHat")
        #expect(kit.layers == 4)
        #expect(kit.alternates == 1)
        #expect(kit.channel == 1)
        #expect(kit.sampleCount == 64)
    }

    @Test func renamingAPadToADrumsNameSetsItsType() {
        var pad = PadSetup(note: 40, label: "Pad 1")
        pad.rename("Snare 2")
        #expect(pad.label == "Snare 2")
        #expect(pad.type == "snare")
    }

    @Test func renamingAPadToAnotherNameKeepsTheTypeItHad() {
        var pad = PadSetup(note: 37, label: "Rim", type: "perc")
        pad.rename("Stick")
        #expect(pad.label == "Stick")
        #expect(pad.type == "perc")
    }

    @Test func layersAndAlternatesAreKeptInRange() {
        var kit = KitSetup.standardDrums()
        kit.layers = 40
        kit.alternates = 9
        #expect(kit.sampleCount == 16 * 8 * 4)
    }
}

@Suite struct PadPresetTests {
    @Test func kickSnareHatsFillsEveryPadWithKickSnareAndHats() {
        let setup = KitSetup.kickSnareHats()
        #expect(setup.pads.count == TGI_PADS)
        let pads = setup.pads.compactMap { $0 }
        #expect(pads.count == TGI_PADS)
        for row in 0..<4 {
            #expect(setup.pads[row * 4]?.type == "kick")
            #expect(setup.pads[row * 4 + 1]?.type == "snare")
            #expect(setup.pads[row * 4 + 2]?.type == "closedHat")
            #expect(setup.pads[row * 4 + 3]?.type == "openHat")
        }
        #expect(setup.pads[12...].map { $0?.label } == ["Kick", "Rimshot", "Closed hat", "Open hat"])
        // Each row's snare and hats are different hits.
        #expect(Set(stride(from: 1, to: 16, by: 4).compactMap { setup.pads[$0]?.note }).count == 4)
        #expect(Set(stride(from: 2, to: 16, by: 4).compactMap { setup.pads[$0]?.note }).count == 4)
        #expect(Set(stride(from: 3, to: 16, by: 4).compactMap { setup.pads[$0]?.note }).count == 4)
        // Every hat cuts the open hats other than itself; kicks and snares cut nothing.
        #expect(setup.pads[14]?.cuts == [3, 7, 11, 15])
        #expect(setup.pads[15]?.cuts == [3, 7, 11])
        #expect(setup.pads[12]?.cuts == [])
    }

    @Test func fillingPadsKeepsLayersAlternatesAndChannel() {
        let before = KitSetup(pads: KitSetup.standardDrums().pads, layers: 6, alternates: 2, channel: 10)
        let after = before.withPads(of: KitSetup.kickSnareHats())
        #expect(after.pads == KitSetup.kickSnareHats().pads)
        #expect([after.layers, after.alternates, after.channel] == [6, 2, 10])
    }
}
