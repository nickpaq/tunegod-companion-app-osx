// What the user sets before sampling a pads instrument: which of the plugin's notes falls on which pad, and how much is sampled.
import Foundation

public let MAX_LAYERS = 8
public let MAX_ALTERNATES = 4

/// One pad: the plugin's note it plays, and how the pad reads on the phone.
public struct PadSetup: Equatable, Sendable {
    /// The plugin's note, 0…127.
    public var note: Int
    public var label: String
    /// A TuneGod sound Type's name (the pad's colour and symbol), or none.
    public var type: String?
    /// The pads (0…15) this one silences when it plays.
    public var cuts: [Int]

    public init(note: Int, label: String, type: String? = nil, cuts: [Int] = []) {
        self.note = note
        self.label = label
        self.type = type
        self.cuts = cuts
    }

    /// Gives the pad a new label. One that names a drum ("Snare 2", "Open hat") sets the pad's Type with it; any other keeps the
    /// Type the pad had.
    public mutating func rename(_ label: String) {
        self.label = label
        if let named = tgiType(forLabel: label) { type = named }
    }
}

public struct KitSetup: Equatable, Sendable {
    /// Exactly 16, row by row from the top left; nil is an empty pad.
    public var pads: [PadSetup?]
    /// Velocity layers a pad, 1…8.
    public var layers: Int
    /// Alternates a layer, 1…4: the same hit played again, for plugins that vary it.
    public var alternates: Int
    /// The MIDI channel the notes are sent on, 1…16.
    public var channel: Int

    public init(pads: [PadSetup?], layers: Int = 4, alternates: Int = 1, channel: Int = 1) {
        self.pads = pads
        self.layers = layers
        self.alternates = alternates
        self.channel = channel
    }

    public var layerCount: Int { min(MAX_LAYERS, max(1, layers)) }
    public var alternateCount: Int { min(MAX_ALTERNATES, max(1, alternates)) }
    /// How many hits sampling this will play.
    public var sampleCount: Int { pads.prefix(TGI_PADS).compactMap { $0 }.count * layerCount * alternateCount }

    /// The usual drum notes on TuneGod's own layout: kick, snare, closed hat and open hat along the bottom row, as the phone's
    /// standard kit has them; the closed and pedal hats cut the open one.
    public static func standardDrums() -> KitSetup {
        let notes: [(Int, String, [Int])] = [
            (49, "Crash", []), (51, "Ride", []), (53, "Ride bell", []), (57, "Crash 2", []),
            (41, "Floor tom", []), (45, "Low tom", []), (48, "Mid tom", []), (50, "High tom", []),
            (37, "Rim", []), (39, "Clap", []), (44, "Pedal hat", [15]), (56, "Cowbell", []),
            (36, "Kick", []), (38, "Snare", []), (42, "Closed hat", [15]), (46, "Open hat", []),
        ]
        return KitSetup(pads: notes.map { PadSetup(note: $0.0, label: $0.1, type: tgiType(forLabel: $0.1), cuts: $0.2) })
    }
}
