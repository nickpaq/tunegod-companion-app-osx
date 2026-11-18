import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct CaptureTests {
    let settings = CaptureSettings()

    func capture(_ plugin: FakePlugin, note: Int = 36, velocity: Int = 127, settings: CaptureSettings? = nil,
                 cancelled: () -> Bool = { false }) throws -> CapturedHit? {
        try captureHit(plugin, note: note, velocity: velocity, channel: 1, settings: settings ?? self.settings, realTime: false,
                       cancelled: cancelled)
    }

    @Test func aHardHitIsLouderThanASoftOne() throws {
        let plugin = FakePlugin()
        let soft = try #require(try capture(plugin, velocity: 32))
        let hard = try #require(try capture(plugin, velocity: 127))
        #expect(abs(hard.peak - 0.8) < 0.001)
        #expect(soft.peak < hard.peak / 3)
    }

    @Test func thePluginsDelayIsTrimmed() throws {
        let plugin = FakePlugin()
        plugin.delayFrames = 2000
        let hit = try #require(try capture(plugin))
        #expect(hit.left[settings.leadInFrames - 1] == 0)
        #expect(abs(hit.left[settings.leadInFrames] - 0.8) < 0.001)
    }

    @Test func theKeyIsHeldUntilTheHitEndsThenLetGo() throws {
        let plugin = FakePlugin()
        plugin.stopsAtNoteOff = true
        plugin.decaySeconds = 0.05
        let hit = try #require(try capture(plugin))
        // A plugin that stops at note-off still played its whole hit: about 0.45 s to fall under the threshold.
        #expect(hit.frames > Int(0.4 * 48_000))
        #expect(plugin.held.isEmpty)
        #expect(plugin.played == [[36, 127, 1]])
    }

    @Test func aSoundThatNeverEndsIsCutAtTheLongestHit() throws {
        let plugin = FakePlugin()
        plugin.endless = [36]
        var s = settings
        s.maxSeconds = 0.5
        let hit = try #require(try capture(plugin, settings: s))
        #expect(hit.cutShort)
        #expect(hit.frames == 24_000)
        #expect(hit.left[hit.frames - 1] < 0.001)
        #expect(plugin.held.isEmpty)
    }

    @Test func aNoteThatMakesNoSoundIsNoHitAndIsNotWaitedForLong() throws {
        let plugin = FakePlugin()
        plugin.silent = [36]
        #expect(try capture(plugin) == nil)
        #expect(plugin.framesRendered < Int(2 * 48_000))
        #expect(plugin.held.isEmpty)
    }

    @Test func cancellingThrowsAndLetsTheKeyGo() {
        let plugin = FakePlugin()
        plugin.endless = [36]
        var asked = 0
        #expect(throws: SamplingCancelled.self) {
            try capture(plugin) { asked += 1; return asked > 20 }
        }
        #expect(plugin.held.isEmpty)
    }

    @Test func aHitWaitsForTheLastOnesTailToEnd() throws {
        let plugin = FakePlugin()
        plugin.decaySeconds = 0.3
        plugin.delayFrames = 100
        var s = settings
        s.maxSeconds = 0.3
        // The first hit is still ringing when it is cut at the longest length (the plugin plays on after note-off).
        let first = try #require(try capture(plugin, note: 49, settings: s))
        #expect(first.cutShort)
        let second = try #require(try capture(plugin, note: 36, velocity: 64, settings: s))
        #expect(abs(second.left[0]) < s.threshold)
        #expect(abs(second.peak - 0.8 * 64 / 127) < 0.001)
    }

    @Test func stereoFromThePluginStaysStereo() throws {
        let plugin = FakePlugin()
        plugin.rightScale = 0.5
        let hit = try #require(try capture(plugin))
        #expect(hit.channels == 2)
    }
}
