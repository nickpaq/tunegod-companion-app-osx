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
    var rightScale: Float = 1

    private(set) var held: Set<Int> = []
    private(set) var played: [[Int]] = []
    private(set) var framesRendered = 0
    private struct Voice { var note: Int; var level: Float; var age: Int }
    private var voices: [Voice] = []

    func noteOn(_ note: Int, velocity: Int, channel: Int) {
        held.insert(note)
        played.append([note, velocity, channel])
        if !silent.contains(note) { voices.append(Voice(note: note, level: Float(velocity) / 127 * 0.8, age: -delayFrames)) }
    }

    func noteOff(_ note: Int, channel: Int) {
        held.remove(note)
        if stopsAtNoteOff { voices.removeAll { $0.note == note } }
    }

    func render(frames: Int, left: inout [Float], right: inout [Float]) throws {
        let decayFrames = Float(decaySeconds * sampleRate)
        for _ in 0..<frames {
            var s: Float = 0
            for i in voices.indices {
                if voices[i].age >= 0 {
                    s += voices[i].level * (endless.contains(voices[i].note) ? 1 : exp(-Float(voices[i].age) / decayFrames))
                }
                voices[i].age += 1
            }
            left.append(s)
            right.append(s * rightScale)
        }
        framesRendered += frames
        voices.removeAll { !endless.contains($0.note) && $0.age > 0 && $0.level * exp(-Float($0.age) / decayFrames) < 1e-7 }
    }
}
