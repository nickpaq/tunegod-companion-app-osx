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
/// most `settleMaxSeconds`.
func settle(_ plugin: NoteRendering, settings: CaptureSettings, realTime: Bool, cancelled: () -> Bool) throws {
    let needed = Int(settings.settleSeconds * settings.sampleRate), most = Int(settings.settleMaxSeconds * settings.sampleRate)
    var pacer = Pacer(realTime: realTime, sampleRate: settings.sampleRate)
    var quiet = 0, total = 0
    var l: [Float] = [], r: [Float] = []
    while quiet < needed, total < most {
        if cancelled() { throw SamplingCancelled() }
        l.removeAll(keepingCapacity: true)
        r.removeAll(keepingCapacity: true)
        try plugin.render(frames: settings.blockFrames, left: &l, right: &r)
        pacer.rendered(l.count)
        total += l.count
        for i in 0..<min(l.count, r.count) {
            if abs(l[i]) >= settings.threshold || abs(r[i]) >= settings.threshold { quiet = 0 } else { quiet += 1 }
        }
        if l.isEmpty { break }
    }
}

/// One hit of `note` at `velocity`: the plugin's output from the note-on until it has ended (silent for `silenceSeconds`) or reached
/// `maxSeconds`, trimmed (`trimmedHit`). The key is held until then, so a plugin that stops at note-off still plays its whole hit,
/// and is always let go, also when this throws. Nil when the note made no sound within `startSeconds`.
public func captureHit(_ plugin: NoteRendering, note: Int, velocity: Int, channel: Int, settings: CaptureSettings, realTime: Bool,
                       cancelled: () -> Bool) throws -> CapturedHit? {
    try settle(plugin, settings: settings, realTime: realTime, cancelled: cancelled)
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
