// Sampling a whole keys instrument, and turning what it recorded into a TuneGod instrument: every sampled note at every layer's
// velocity, each held for the same time; then the zones (`keyZones`), the hold and the release the phone needs.
import Foundation

/// What sampling a keys instrument recorded.
public struct SampledKeys: Sendable {
    /// Every sampled note, ascending, with its layers from soft to hard; a layer that made no sound is nil.
    public var notes: [(note: Int, layers: [CapturedNote?])]
    /// How long each key was held, in frames from its note-on.
    public var holdFrames: Int
    /// What the user should know about the result, ready to show.
    public var warnings: [String]

    public init(notes: [(note: Int, layers: [CapturedNote?])], holdFrames: Int, warnings: [String]) {
        self.notes = notes
        self.holdFrames = holdFrames
        self.warnings = warnings
    }
}

/// Plays and records `setup` on `plugin`, note by note from the lowest. `progress` is told how many notes are done of how many and
/// which note is being played; `cancelled` is asked between blocks, and answering true ends it with `SamplingCancelled`.
public func sampleKeys(_ plugin: NoteRendering, setup: KeysSetup, settings: CaptureSettings, realTime: Bool,
                       progress: (Int, Int, String) -> Void, cancelled: () -> Bool) throws -> SampledKeys {
    let velocities = layerVelocities(setup.layerCount)
    let hold = Int(setup.holdLength * settings.sampleRate)
    let total = setup.sampleCount
    var done = 0
    var notes: [(note: Int, layers: [CapturedNote?])] = []
    var silent: [String] = [], cutShort: [String] = []
    for root in setup.roots {
        var layers: [CapturedNote?] = []
        for velocity in velocities {
            progress(done, total, noteName(root))
            layers.append(try captureNote(plugin, note: root, velocity: velocity, channel: setup.channel, holdFrames: hold,
                                          settings: settings, realTime: realTime, cancelled: cancelled))
            done += 1
        }
        if layers.allSatisfy({ $0 == nil }) { silent.append(noteName(root)) }
        if layers.contains(where: { $0?.hit.cutShort == true }) { cutShort.append(noteName(root)) }
        notes.append((root, layers))
    }
    progress(total, total, "")
    var warnings: [String] = []
    if !silent.isEmpty {
        warnings.append("The plugin made no sound for \(silent.joined(separator: ", ")). The keys around \(silent.count == 1 ? "it" : "them") play the nearest note that did.")
    }
    if !cutShort.isEmpty {
        let seconds = settings.maxSeconds.formatted(.number.precision(.fractionLength(0...1)))
        warnings.append("Still sounding \(seconds) seconds after the key was let go, and faded out there: \(cutShort.joined(separator: ", ")).")
    }
    return SampledKeys(notes: notes, holdFrames: hold, warnings: warnings)
}

/// The name of a sampled note's audio in the file: note, layer.
func keyHitName(note: Int, layer: Int) -> String {
    String(format: "k%03d-l%d.caf", note, layer)
}

/// How fast a note fades on the phone when its key is let go early, when no note was held long enough to show the plugin's own release.
public let DEFAULT_RELEASE_MS = 150.0

/// A keys instrument from sampled notes. Every hit is made to start the same number of frames after its note-on (the earliest any
/// started), so `holdFrames` is the same for all of them; a layer that made no sound is left out and the hardest one left answers every
/// velocity above it; a note with no sound at all is left out and its keys play the nearest note that has one. `releaseMs` is how long
/// the plugin's own release took (the median, from the note-off to the last sound). Throws when no note made a sound.
public func buildKeysInstrument(_ keys: SampledKeys, setup: KeysSetup, name: String, madeWith: String?, id: String, created: String,
                                sampleRate: Double) throws -> (instrument: TGIInstrument, audio: [String: Data], warnings: [String]) {
    let velocities = layerVelocities(setup.layerCount)
    let sounding = keys.notes.filter { $0.layers.contains { $0 != nil } }
    let captured = sounding.flatMap { $0.layers.compactMap { $0 } }
    guard let common = captured.map(\.start).min() else {
        throw TGIError("The plugin made no sound for any note. Check the range and the MIDI channel.")
    }
    var audio: [String: Data] = [:]
    var tooLoud = 0
    var zones: [TGIZone] = []
    let mapped = keyZones(roots: sounding.map(\.note))
    for (recorded, zone) in zip(sounding, mapped) {
        var layers: [TGILayer] = []
        for (velocity, note) in zip(velocities, recorded.layers) {
            guard let note else { continue }
            // Silence before the hit, to start it where the earliest one starts.
            var hit = note.hit
            let lead = [Float](repeating: 0, count: note.start - common)
            hit.left = lead + hit.left
            hit.right = hit.right.map { lead + $0 }
            let name = keyHitName(note: recorded.note, layer: layers.count)
            audio[name] = try encodeAppleLossless(hit, sampleRate: sampleRate)
            if hit.peak > 1 { tooLoud += 1 }
            layers.append(TGILayer(velocity: velocity, top: velocity, hits: [name]))
        }
        layers[layers.count - 1].top = 127
        zones.append(TGIZone(root: zone.root, topKey: zone.topKey, layers: layers))
    }
    let releases = captured.filter(\.released).map { Double($0.lastSound - keys.holdFrames) / sampleRate * 1000 }.sorted()
    let releaseMs = releases.isEmpty ? DEFAULT_RELEASE_MS : min(5000, max(10, releases[releases.count / 2]))
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let instrument = TGIInstrument(id: id, name: trimmed.isEmpty ? "Instrument" : trimmed, kind: .keys, created: created,
                                   madeWith: madeWith, zones: zones, releaseMs: releaseMs.rounded(),
                                   holdFrames: max(0, keys.holdFrames - common))
    try validateTGI(instrument)
    var warnings = keys.warnings
    if tooLoud > 0 {
        warnings.append("\(tooLoud) \(tooLoud == 1 ? "note is" : "notes are") louder than full scale and clipped in the file. Turn the plugin's output down and sample again.")
    }
    return (instrument, audio, warnings)
}
