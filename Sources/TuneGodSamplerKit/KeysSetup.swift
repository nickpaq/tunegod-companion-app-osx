// What the user sets before sampling a keys instrument: the range of notes, how many of them are sampled (notes per octave), how many
// velocity layers and how long each note is held. Which sampled note every key plays is worked out from that (`keyZones`).
import Foundation

/// The choices of notes sampled per octave: every key, every second key, every third (minor thirds), every fourth (major thirds),
/// every sixth (half octaves) and one an octave. 12 divided by each is a whole number of keys.
public let NOTES_PER_OCTAVE_CHOICES = [12, 6, 4, 3, 2, 1]
public let MAX_KEY_LAYERS = 4
/// How long a note may be held while it is sampled, in seconds.
public let KEY_HOLD_RANGE = 0.5...20.0

public struct KeysSetup: Equatable, Sendable {
    /// The lowest and highest notes sampled, 0…127.
    public var lowest: Int
    public var highest: Int
    /// One of `NOTES_PER_OCTAVE_CHOICES`; another value counts as the nearest of them.
    public var notesPerOctave: Int
    /// Velocity layers a note, 1…4.
    public var layers: Int
    /// How long each note's key is held before it is let go.
    public var holdSeconds: Double
    /// The MIDI channel the notes are sent on, 1…16.
    public var channel: Int

    /// C1 to C6 (five octaves), every third key, two layers, held four seconds.
    public init(lowest: Int = 36, highest: Int = 96, notesPerOctave: Int = 4, layers: Int = 2, holdSeconds: Double = 4,
                channel: Int = 1) {
        self.lowest = lowest
        self.highest = highest
        self.notesPerOctave = notesPerOctave
        self.layers = layers
        self.holdSeconds = holdSeconds
        self.channel = channel
    }

    public var layerCount: Int { min(MAX_KEY_LAYERS, max(1, layers)) }
    public var perOctave: Int {
        NOTES_PER_OCTAVE_CHOICES.min { abs($0 - notesPerOctave) < abs($1 - notesPerOctave) } ?? 4
    }
    /// Keys between one sampled note and the next.
    public var step: Int { 12 / perOctave }
    public var holdLength: Double { min(KEY_HOLD_RANGE.upperBound, max(KEY_HOLD_RANGE.lowerBound, holdSeconds)) }
    /// The range brought into 0…127, lowest first.
    public var range: ClosedRange<Int> {
        let a = min(127, max(0, lowest)), b = min(127, max(0, highest))
        return min(a, b)...max(a, b)
    }
    /// The notes that are sampled: from the lowest note up, one every `step` keys. The highest note is always among them, so the top
    /// of the range is never repitched up.
    public var roots: [Int] {
        var notes = Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
        if notes.last != range.upperBound { notes.append(range.upperBound) }
        return notes
    }
    /// How many notes sampling this will play.
    public var sampleCount: Int { roots.count * layerCount }
}

/// Which sampled note every key plays: each key plays the nearest root, one exactly between two plays the upper one (pitching a
/// sample down sounds better than pitching it up). The lowest zone takes every key below it and the highest every key above, so the
/// whole keyboard plays. `roots` ascending and distinct.
public func keyZones(roots: [Int]) -> [(root: Int, topKey: Int)] {
    guard !roots.isEmpty else { return [] }
    return roots.enumerated().map { i, root in
        guard i + 1 < roots.count else { return (root, 127) }
        let next = roots[i + 1]
        return (root, root + (next - root - 1) / 2)
    }
}

/// The zone a key falls in: the first whose top key reaches it, the last when none does.
public func keyZoneIndex(topKeys: [Int], key: Int) -> Int {
    topKeys.firstIndex { $0 >= key } ?? max(0, topKeys.count - 1)
}

/// How much faster than its root a key plays a sample: an octave up is twice.
public func keyRate(key: Int, root: Int) -> Double {
    pow(2, Double(key - root) / 12)
}
