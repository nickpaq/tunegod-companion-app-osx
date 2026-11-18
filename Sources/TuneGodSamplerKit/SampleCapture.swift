// Capturing one hit: wait for silence, play the note, hold the key until the sound has ended, let it go, trim.
import Foundation

/// Keeps rendering at the speed of real time when asked to: after each block it sleeps until the clock has caught up with the audio.
struct Pacer {
    let realTime: Bool
    let sampleRate: Double
    private let began = Date()
    private var frames = 0

    init(realTime: Bool, sampleRate: Double) {
        self.realTime = realTime
        self.sampleRate = sampleRate
    }

    mutating func rendered(_ count: Int) {
        frames += count
        guard realTime else { return }
        let ahead = Double(frames) / sampleRate - Date().timeIntervalSince(began)
        if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
    }
}

/// Renders and throws away the plugin's output until it has been silent for `settleSeconds` (the last hit's tail has gone), for at
/// most `settleMaxSeconds`. Gives back the level the plugin rests at: 0 when it fell silent, and for a plugin that never does (a
/// kit with a bed of noise under it) the loudest sample of the last `noiseSeconds`, once its level has stopped falling.
@discardableResult
func settle(_ plugin: NoteRendering, settings: CaptureSettings, realTime: Bool, cancelled: () -> Bool) throws -> Float {
    let needed = Int(settings.settleSeconds * settings.sampleRate), most = Int(settings.settleMaxSeconds * settings.sampleRate)
    let window = max(1, Int(settings.noiseSeconds * settings.sampleRate / Double(settings.blockFrames)))
    var pacer = Pacer(realTime: realTime, sampleRate: settings.sampleRate)
    var quiet = 0, total = 0
    var l: [Float] = [], r: [Float] = []
    // Each block's loudest sample, to tell a steady bed of noise from a tail that is still falling.
    var peaks: [Float] = []
    while quiet < needed, total < most {
        if cancelled() { throw SamplingCancelled() }
        l.removeAll(keepingCapacity: true)
        r.removeAll(keepingCapacity: true)
        try plugin.render(frames: settings.blockFrames, left: &l, right: &r)
        pacer.rendered(l.count)
        total += l.count
        var peak: Float = 0
        for i in 0..<min(l.count, r.count) {
            let level = max(abs(l[i]), abs(r[i]))
            peak = max(peak, level)
            if level >= settings.threshold { quiet = 0 } else { quiet += 1 }
        }
        if l.isEmpty { break }
        peaks.append(peak)
        // Not silent, but no louder over the last stretch than over the one before it: this is where the plugin rests.
        if peaks.count >= window * 2 {
            let last = peaks.suffix(window).max() ?? 0, before = peaks.dropLast(window).suffix(window).max() ?? 0
            if last >= before * settings.noiseSteady { return last }
        }
    }
    return quiet >= needed ? 0 : (peaks.suffix(window).max() ?? 0)
}

/// One hit of `note` at `velocity`: the plugin's output from the note-on until it has ended (silent for `silenceSeconds`) or reached
/// `maxSeconds`, trimmed (`trimmedHit`). The key is held until then, so a plugin that stops at note-off still plays its whole hit,
/// and is always let go, also when this throws. Nil when the note made no sound within `startSeconds`.
public func captureHit(_ plugin: NoteRendering, note: Int, velocity: Int, channel: Int, settings given: CaptureSettings, realTime: Bool,
                       cancelled: () -> Bool) throws -> CapturedHit? {
    // A plugin that rests above silence (a bed of noise) is heard against that: sound is what stands clear of it.
    let rest = try settle(plugin, settings: given, realTime: realTime, cancelled: cancelled)
    var settings = given
    settings.threshold = max(settings.threshold, rest * settings.noiseClear)
    let most = Int(settings.maxSeconds * settings.sampleRate)
    let silence = Int(settings.silenceSeconds * settings.sampleRate)
    let startBy = Int(settings.startSeconds * settings.sampleRate)
    var pacer = Pacer(realTime: realTime, sampleRate: settings.sampleRate)
    var l: [Float] = [], r: [Float] = []
    var lastSound: Int?
    var cutShort = false
    plugin.noteOn(note, velocity: min(127, max(1, velocity)), channel: channel)
    defer { plugin.noteOff(note, channel: channel) }
    while true {
        if cancelled() { throw SamplingCancelled() }
        let before = l.count
        try plugin.render(frames: min(settings.blockFrames, most - before), left: &l, right: &r)
        let now = min(l.count, r.count)
        guard now > before else { break }
        pacer.rendered(now - before)
        for i in before..<now where abs(l[i]) >= settings.threshold || abs(r[i]) >= settings.threshold { lastSound = i }
        if let lastSound {
            if now - 1 - lastSound >= silence { break }
        } else if now >= startBy {
            return nil
        }
        if now >= most {
            cutShort = lastSound != nil
            break
        }
    }
    return trimmedHit(left: l, right: r, cutShort: cutShort, settings: settings)
}
