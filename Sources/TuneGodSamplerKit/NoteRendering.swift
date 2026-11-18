// What the sampler needs of a plugin: play a note, let it go, and hand over the next stretch of its output. `PluginHost` is the
// real one (an Audio Unit); the tests use a made-up one.
import Foundation

public protocol NoteRendering: AnyObject {
    var sampleRate: Double { get }
    /// `note` and `velocity` 0…127 (velocity at least 1), `channel` 1…16.
    func noteOn(_ note: Int, velocity: Int, channel: Int)
    func noteOff(_ note: Int, channel: Int)
    /// Appends the next `frames` frames of the plugin's output to `left` and `right`.
    func render(frames: Int, left: inout [Float], right: inout [Float]) throws
}

/// Sampling was cancelled by the user.
public struct SamplingCancelled: Error, Equatable {
    public init() {}
}
