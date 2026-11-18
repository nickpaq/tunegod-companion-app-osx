// From what sampling recorded to a TuneGod instrument: the manifest (TuneGodCore's `TGIInstrument`) and each hit's audio file.
import Foundation

/// The name of a hit's audio in the file: pad, layer, alternate.
func hitName(pad: Int, layer: Int, alternate: Int) -> String {
    String(format: "p%02d-l%d-a%d.caf", pad, layer, alternate)
}

/// A pads instrument from a sampled kit. A layer that made no sound is left out and the hardest one left answers every velocity
/// above it; a pad's cuts keep only other pads that are in the instrument; a pad or an instrument without a name gets one. The
/// warnings are the kit's, then one counting the hits louder than full scale. Throws when no pad made a sound.
public func buildInstrument(_ kit: SampledKit, setup: KitSetup, name: String, madeWith: String?, id: String, created: String,
                            sampleRate: Double) throws -> (instrument: TGIInstrument, audio: [String: Data], warnings: [String]) {
    let velocities = layerVelocities(setup.layerCount)
    var pads = [TGIPad?](repeating: nil, count: TGI_PADS)
    var audio: [String: Data] = [:]
    var tooLoud = 0
    for index in 0..<TGI_PADS {
        guard index < setup.pads.count, index < kit.hits.count, let pad = setup.pads[index], let recorded = kit.hits[index] else { continue }
        var layers: [TGILayer] = []
        for (velocity, alternates) in zip(velocities, recorded) where !alternates.isEmpty {
            var names: [String] = []
            for (a, hit) in alternates.enumerated() {
                let name = hitName(pad: index, layer: layers.count, alternate: a)
                audio[name] = try encodeAppleLossless(hit, sampleRate: sampleRate)
                names.append(name)
                if hit.peak > 1 { tooLoud += 1 }
            }
            layers.append(TGILayer(velocity: velocity, top: velocity, hits: names))
        }
        guard !layers.isEmpty else { continue }
        layers[layers.count - 1].top = 127
        let label = pad.label.trimmingCharacters(in: .whitespaces)
        pads[index] = TGIPad(label: label.isEmpty ? "Pad \(index + 1)" : label, type: pad.type, layers: layers, cuts: pad.cuts)
    }
    guard pads.contains(where: { $0 != nil }) else {
        throw TGIError("The plugin made no sound for any pad. Check the pads' notes and the MIDI channel.")
    }
    for index in 0..<TGI_PADS {
        let cuts = (pads[index]?.cuts ?? []).filter { $0 != index && (0..<TGI_PADS).contains($0) && pads[$0] != nil }
        pads[index]?.cuts = cuts.isEmpty ? nil : cuts
    }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let instrument = TGIInstrument(id: id, name: trimmed.isEmpty ? "Instrument" : trimmed, kind: .pads, created: created,
                                   madeWith: madeWith, pads: pads)
    try validateTGI(instrument)
    var warnings = kit.warnings
    if tooLoud > 0 {
        warnings.append("\(tooLoud) \(tooLoud == 1 ? "hit is" : "hits are") louder than full scale and clipped in the file. Turn the plugin's output down and sample again.")
    }
    return (instrument, audio, warnings)
}

/// A file name for an instrument called `name`: the name without the characters a file name cannot have, with `.tgi`.
public func instrumentFileName(_ name: String) -> String {
    let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
    let trimmed = String(safe).trimmingCharacters(in: .whitespaces)
    return (trimmed.isEmpty ? "Instrument" : trimmed) + "." + TGI_EXTENSION
}
