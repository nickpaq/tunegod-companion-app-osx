// The arithmetic of sampling: which velocities the layers are played at, and how a recording of one hit is trimmed.
import Foundation

/// How a hit is captured. The numbers are the plan's (docs/superpowers/plans/2026-11-18-instrument-maker-pads.md).
public struct CaptureSettings: Sendable {
    public var sampleRate = 48_000.0
    /// Frames asked of the plugin at a time.
    public var blockFrames = 512
    /// A sample at or above this (of full scale) is sound; below it, silence. −80 dB.
    public var threshold: Float = 1e-4
    /// A hit has ended when it has stayed silent this long.
    public var silenceSeconds = 0.3
    /// The longest a hit may be; one still sounding then is faded and reported as cut short.
    public var maxSeconds = 10.0
    /// Frames kept before the first sound.
    public var leadInFrames = 24
    /// Kept after the last sound.
    public var tailSeconds = 0.01
    /// The fade at the end of a hit that was cut short.
    public var fadeSeconds = 0.02
    /// Before a hit, the plugin must have been silent this long (the last hit's tail has gone), waited for at most `settleMaxSeconds`.
    public var settleSeconds = 0.1
    public var settleMaxSeconds = 5.0
    /// A note that has made no sound by now makes none.
    public var startSeconds = 1.0

    public init() {}
}

/// One hit as it is stored: exactly what the plugin played, trimmed. `right` is nil when both channels were the same.
public struct CapturedHit: Equatable, Sendable {
    public var left: [Float]
    public var right: [Float]?
    /// The largest magnitude in either channel; above 1 the plugin played louder than full scale.
    public var peak: Float
    /// It was still sounding at the longest length and was faded there.
    public var cutShort: Bool

    public init(left: [Float], right: [Float]?, peak: Float, cutShort: Bool) {
        self.left = left
        self.right = right
        self.peak = peak
        self.cutShort = cutShort
    }

    public var frames: Int { left.count }
    public var channels: Int { right == nil ? 1 : 2 }
}

/// The velocities `count` layers (1…8) are played at: evenly spaced, each the top of its range, the hardest 127.
public func layerVelocities(_ count: Int) -> [Int] {
    let n = min(8, max(1, count))
    return (1...n).map { Int((127 * Double($0) / Double(n)).rounded()) }
}

/// A recording of one hit, trimmed: it starts `leadInFrames` before the first sound and ends `tailSeconds` after the last (one cut
/// short keeps its whole length and fades out). Nil when nothing in it is sound.
public func trimmedHit(left: [Float], right: [Float], cutShort: Bool, settings: CaptureSettings) -> CapturedHit? {
    trimmedHitAndStart(left: left, right: right, cutShort: cutShort, settings: settings)?.hit
}

/// `trimmedHit`, with the frame of the recording the trimmed hit starts at.
func trimmedHitAndStart(left: [Float], right: [Float], cutShort: Bool, settings: CaptureSettings) -> (hit: CapturedHit, start: Int)? {
    let n = min(left.count, right.count)
    let threshold = settings.threshold
    let isSound = { (i: Int) in abs(left[i]) >= threshold || abs(right[i]) >= threshold }
    guard let first = (0..<n).first(where: isSound), let last = (0..<n).last(where: isSound) else { return nil }
    let start = max(0, first - settings.leadInFrames)
    let end = cutShort ? n : min(n, last + 1 + Int(settings.tailSeconds * settings.sampleRate))
    var l = Array(left[start..<end]), r = Array(right[start..<end])
    let peak = max(l.reduce(0) { max($0, abs($1)) }, r.reduce(0) { max($0, abs($1)) })
    if cutShort {
        let fade = min(l.count, Int(settings.fadeSeconds * settings.sampleRate))
        for i in 0..<fade {
            let gain = Float(fade - 1 - i) / Float(fade)
            l[l.count - fade + i] *= gain
            r[r.count - fade + i] *= gain
        }
    }
    return (CapturedHit(left: l, right: l == r ? nil : r, peak: peak, cutShort: cutShort), start)
}

/// A MIDI note's name, with 36 as C1 (the kick of the usual drum layout) and 60 as C3.
public func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[((note % 12) + 12) % 12])\(Int((Double(note) / 12).rounded(.down)) - 2)"
}
