import Foundation
import Testing
@testable import TuneGodSamplerKit

@Suite struct LayerVelocityTests {
    @Test func layersAreEvenAndEndAtFull() {
        #expect(layerVelocities(1) == [127])
        #expect(layerVelocities(2) == [64, 127])
        #expect(layerVelocities(4) == [32, 64, 95, 127])
        #expect(layerVelocities(8) == [16, 32, 48, 64, 79, 95, 111, 127])
    }

    @Test func countIsKeptBetweenOneAndEight() {
        #expect(layerVelocities(0) == [127])
        #expect(layerVelocities(-3) == [127])
        #expect(layerVelocities(20).count == 8)
    }
}

@Suite struct TrimTests {
    let settings = CaptureSettings()

    /// `lead` silent frames, then `body` frames at `level`, then `tail` silent frames.
    func hit(lead: Int, body: Int, tail: Int, level: Float = 0.5) -> [Float] {
        [Float](repeating: 0, count: lead) + [Float](repeating: level, count: body) + [Float](repeating: 0, count: tail)
    }

    @Test func startsJustBeforeTheFirstSound() throws {
        let x = hit(lead: 1000, body: 4800, tail: 0)
        let h = try #require(trimmedHit(left: x, right: x, cutShort: false, settings: settings))
        #expect(h.left[settings.leadInFrames - 1] == 0)
        #expect(h.left[settings.leadInFrames] == 0.5)
    }

    @Test func aSoundAtTheVeryStartKeepsItsStart() throws {
        let x = hit(lead: 5, body: 4800, tail: 0)
        let h = try #require(trimmedHit(left: x, right: x, cutShort: false, settings: settings))
        #expect(h.left[5] == 0.5)
        #expect(h.left[4] == 0)
    }

    @Test func trailingSilenceIsCutToTheTail() throws {
        let x = hit(lead: 0, body: 4800, tail: 48_000)
        let h = try #require(trimmedHit(left: x, right: x, cutShort: false, settings: settings))
        #expect(h.frames == 4800 + Int(settings.tailSeconds * settings.sampleRate))
    }

    @Test func identicalChannelsAreMono() throws {
        let x = hit(lead: 0, body: 100, tail: 0)
        let h = try #require(trimmedHit(left: x, right: x, cutShort: false, settings: settings))
        #expect(h.right == nil)
        #expect(h.channels == 1)
    }

    @Test func differentChannelsStayStereo() throws {
        let l = hit(lead: 0, body: 100, tail: 0)
        let r = hit(lead: 0, body: 100, tail: 0, level: 0.25)
        let h = try #require(trimmedHit(left: l, right: r, cutShort: false, settings: settings))
        #expect(h.right?.count == h.left.count)
        #expect(h.channels == 2)
    }

    @Test func soundOnlyOnTheRightIsFound() throws {
        let silent = [Float](repeating: 0, count: 2000)
        let r = hit(lead: 1000, body: 1000, tail: 0)
        let h = try #require(trimmedHit(left: silent, right: r, cutShort: false, settings: settings))
        #expect(h.right?[settings.leadInFrames] == 0.5)
    }

    @Test func nothingAboveTheThresholdIsNoHit() {
        let quiet = [Float](repeating: settings.threshold / 2, count: 4800)
        #expect(trimmedHit(left: quiet, right: quiet, cutShort: false, settings: settings) == nil)
        #expect(trimmedHit(left: [], right: [], cutShort: false, settings: settings) == nil)
    }

    @Test func aCutShortHitFadesToNothing() throws {
        let x = hit(lead: 0, body: 48_000, tail: 0)
        let h = try #require(trimmedHit(left: x, right: x, cutShort: true, settings: settings))
        let fade = Int(settings.fadeSeconds * settings.sampleRate)
        #expect(h.cutShort)
        #expect(h.frames == 48_000)
        #expect(h.left[h.frames - 1] < 0.001)
        #expect(h.left[h.frames - fade - 1] == 0.5)
        #expect(h.left[h.frames - fade / 2] < 0.5)
    }

    @Test func peakIsTheLargestOfEitherChannel() throws {
        let l = hit(lead: 0, body: 100, tail: 0, level: 0.25)
        var r = hit(lead: 0, body: 100, tail: 0, level: 0.25)
        r[50] = -1.5
        let h = try #require(trimmedHit(left: l, right: r, cutShort: false, settings: settings))
        #expect(h.peak == 1.5)
    }
}
