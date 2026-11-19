import Foundation
@testable import TuneGodSamplerKit

/// A plugin for the tests: each note is a level that starts at velocity / 127 × 0.8 and dies away, the same on both channels unless
/// `rightScale` says otherwise.
final class FakePlugin: NoteRendering {
    let sampleRate = 48_000.0
    /// Silent frames before a note sounds.
    var delayFrames = 0
    /// How long a note takes to fall to 1/e.
    var decaySeconds = 0.01
    /// Notes that never die away, and notes that make no sound.
    var endless: Set<Int> = []
    var silent: Set<Int> = []
    /// Whether letting the key go stops the note at once.
    var stopsAtNoteOff = false
    /// When set, letting the key go makes the note fall to 1/e in this long (a sustained sound's release).
    var releaseSeconds: Double?
    var rightScale: Float = 1
    /// A bed of noise under everything: every frame is this much, one way then the other.
    var noise: Float = 0

    private(set) var held: Set<Int> = []
    private(set) var played: [[Int]] = []
    /// The frame (counted from the first ever rendered) each note-off came at.
    private(set) var noteOffFrames: [Int] = []
    private(set) var framesRendered = 0
    private struct Voice { var note: Int; var level: Float; var age: Int; var releasedAt: Int? }
    private var voices: [Voice] = []

    func noteOn(_ note: Int, velocity: Int, channel: Int) {
        held.insert(note)
        played.append([note, velocity, channel])
        if !silent.contains(note) { voices.append(Voice(note: note, level: Float(velocity) / 127 * 0.8, age: -delayFrames)) }
    }

    func noteOff(_ note: Int, channel: Int) {
        held.remove(note)
        noteOffFrames.append(framesRendered)
        if stopsAtNoteOff { voices.removeAll { $0.note == note } }
        if releaseSeconds != nil {
            for i in voices.indices where voices[i].note == note && voices[i].releasedAt == nil { voices[i].releasedAt = voices[i].age }
        }
    }

    private func amplitude(_ v: Voice) -> Float {
        let decayFrames = Float(decaySeconds * sampleRate)
        var a = v.level * (endless.contains(v.note) ? 1 : exp(-Float(max(0, v.age)) / decayFrames))
        if let r = v.releasedAt, let release = releaseSeconds {
            a *= exp(-Float(max(0, v.age - r)) / Float(release * sampleRate))
        }
        return a
    }

    func render(frames: Int, left: inout [Float], right: inout [Float]) throws {
        for _ in 0..<frames {
            var s: Float = 0
            for i in voices.indices {
                if voices[i].age >= 0 { s += amplitude(voices[i]) }
                voices[i].age += 1
            }
            if noise > 0 { s += (framesRendered + left.count) % 2 == 0 ? noise : -noise }
            left.append(s)
            right.append(s * rightScale)
        }
        framesRendered += frames
        voices.removeAll { $0.age > 0 && amplitude($0) < 1e-7 }
    }
}
