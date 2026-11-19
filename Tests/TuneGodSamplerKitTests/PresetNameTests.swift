import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct PresetNameTests {
    /// A state block of text entries, each ended by a zero byte.
    func entries(_ pairs: [(String, String)]) -> Data {
        var data = Data("HEAD".utf8)
        for (key, value) in pairs {
            data.append(Data(key.utf8))
            data.append(0)
            data.append(Data(value.utf8))
            data.append(0)
        }
        return data
    }

    @Test func theNameIsReadFromZeroEndedEntries() {
        let block = entries([("Version", "8"), ("Layer1/CurrentPresetId", "pack__Dry Room.preset"), ("Layer1/CurrentPresetName", "Dry Room"),
                             ("Layer1/PresetSaveName", "Something else")])
        #expect(presetName(inState: ["pluginState": block, "name": "Untitled"]) == "Dry Room")
    }

    @Test func theMostTrustedEntryWinsWhereverItIs() {
        let block = entries([("Bank/ProgramName", "Second"), ("Bank/CurrentPresetName", "First")])
        #expect(presetName(inState: ["data": block]) == "First")
    }

    @Test func aNameWrittenAsAnAttributeIsRead() {
        let block = Data("<state version=\"3\" presetName=\"Warm Keys\" volume=\"0.5\"/>".utf8)
        #expect(presetName(inState: ["data": block]) == "Warm Keys")
    }

    @Test func aNameInsideANestedPartOfTheStateIsRead() {
        #expect(presetName(inState: ["outer": ["inner": ["patchName": "Glass"] as [String: Any]] as [String: Any]]) == "Glass")
    }

    @Test func aStateThatDoesNotNameItsPresetGivesNone() {
        let block = entries([("Version", "8"), ("Volume", "0.5")])
        #expect(presetName(inState: ["data": block, "name": "Untitled", "version": 0]) == nil)
        #expect(presetName(inState: [:]) == nil)
    }

    @Test func anEmptyOrUnprintableNameIsNotAName() {
        #expect(presetName(inState: ["data": entries([("PresetName", "   ")])]) == nil)
        #expect(presetName(inState: ["data": entries([("PresetName", "a\u{1}b")])]) == nil)
        #expect(presetName(inState: ["data": entries([("PresetName", String(repeating: "x", count: 300))])]) == nil)
    }
}

@Suite struct PadSetupStoreTests {
    let plugin = PluginInfo(name: "Drums", maker: "Maker", type: 1, subtype: 2, manufacturer: 3)

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tgsampler-setups-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aSavedSetupComesBackTheSame() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var setup = KitSetup.standardDrums()
        setup.pads[0] = PadSetup(note: 77, label: "Crash 1", type: "cymbal", cuts: [3])
        setup.pads[5] = nil
        setup.layers = 6
        setup.channel = 10
        #expect(savedPadSetup(for: plugin, in: folder) == nil)
        try savePadSetup(setup, for: plugin, in: folder)
        #expect(savedPadSetup(for: plugin, in: folder) == setup)
        let other = PluginInfo(name: "Other", maker: "Maker", type: 1, subtype: 9, manufacturer: 3)
        #expect(savedPadSetup(for: other, in: folder) == nil)
    }

    @Test func aSetupWrittenAsTextIsRead() throws {
        let setup = try kitSetup(fromMap: """
        # pad note type label
        0 77 cymbal Crash 1
        8 49 closedHat Closed hat
        10 56 openHat Open hat
        12 36 - Low thing
        cut 8 10
        """)
        #expect(setup.pads.count == 16)
        #expect(setup.pads[0] == PadSetup(note: 77, label: "Crash 1", type: "cymbal"))
        #expect(setup.pads[8] == PadSetup(note: 49, label: "Closed hat", type: "closedHat", cuts: [10]))
        #expect(setup.pads[12] == PadSetup(note: 36, label: "Low thing", type: nil))
        #expect(setup.pads[1] == nil)
        #expect(setup.layers == 4 && setup.alternates == 1 && setup.channel == 1)
    }

    @Test func aBadLineIsRefused() {
        #expect(throws: PluginError.self) { try kitSetup(fromMap: "16 36 kick Kick") }
        #expect(throws: PluginError.self) { try kitSetup(fromMap: "0 200 kick Kick") }
        #expect(throws: PluginError.self) { try kitSetup(fromMap: "0 36 kick") }
        #expect(throws: PluginError.self) { try kitSetup(fromMap: "0 36 kick Kick\ncut 3 0") }
        #expect(throws: PluginError.self) { try kitSetup(fromMap: "# nothing") }
    }
}
