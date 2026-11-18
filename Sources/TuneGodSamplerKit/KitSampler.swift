// Sampling a whole pads instrument: every pad, at every layer's velocity, as many times as it has alternates.
import Foundation

/// What sampling a kit recorded.
public struct SampledKit: Sendable {
    /// Sixteen pads; nil for an empty pad and for one that made no sound. A pad is its layers from soft to hard, a layer its
    /// alternates; a layer that made no sound is empty.
    public var hits: [[[CapturedHit]]?]
    /// What the user should know about the result, ready to show.
    public var warnings: [String]

    public init(hits: [[[CapturedHit]]?], warnings: [String]) {
        self.hits = hits
        self.warnings = warnings
    }
}

/// Plays and records `setup` on `plugin`, pad by pad. `progress` is told how many hits are done of how many and which pad is being
/// played; `cancelled` is asked between blocks, and answering true ends it with `SamplingCancelled`.
public func sampleKit(_ plugin: NoteRendering, setup: KitSetup, settings: CaptureSettings, realTime: Bool,
                      progress: (Int, Int, String) -> Void, cancelled: () -> Bool) throws -> SampledKit {
    let velocities = layerVelocities(setup.layerCount)
    let total = setup.sampleCount
    var done = 0
    var hits = [[[CapturedHit]]?](repeating: nil, count: TGI_PADS)
    var silent: [String] = [], cutShort: [String] = []
    for (index, pad) in setup.pads.prefix(TGI_PADS).enumerated() {
        guard let pad else { continue }
        var layers: [[CapturedHit]] = []
        for velocity in velocities {
            var alternates: [CapturedHit] = []
            for _ in 0..<setup.alternateCount {
                progress(done, total, pad.label)
                if let hit = try captureHit(plugin, note: pad.note, velocity: velocity, channel: setup.channel, settings: settings,
                                            realTime: realTime, cancelled: cancelled) {
                    alternates.append(hit)
                }
                done += 1
            }
            layers.append(alternates)
        }
        if layers.allSatisfy(\.isEmpty) {
            silent.append(pad.label)
        } else {
            hits[index] = layers
            if layers.contains(where: { $0.contains(where: \.cutShort) }) { cutShort.append(pad.label) }
        }
    }
    progress(total, total, "")
    var warnings: [String] = []
    if !silent.isEmpty {
        warnings.append("The plugin made no sound for \(silent.joined(separator: ", ")). \(silent.count == 1 ? "That pad is" : "Those pads are") left empty.")
    }
    if !cutShort.isEmpty {
        let seconds = settings.maxSeconds.formatted(.number.precision(.fractionLength(0...1)))
        warnings.append("Still sounding after \(seconds) seconds and faded out there: \(cutShort.joined(separator: ", ")).")
    }
    return SampledKit(hits: hits, warnings: warnings)
}
