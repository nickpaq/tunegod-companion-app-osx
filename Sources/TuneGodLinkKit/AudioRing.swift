// Audio kept by phone frame: a block written for frames t..<t+n is read back by the same frame numbers, and frames never written, or
// already overwritten by newer ones, read as silence. The helper holds the driver's output this way until the phone asks for it.
import Foundation

public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    public let capacity: Int
    private let lock = NSLock()
    private var data: [Float]
    /// Frames [validFrom, writtenUpTo) hold real audio.
    private var validFrom: UInt64 = 0
    private var writtenUpTo: UInt64 = 0

    public init(channels: Int, capacity: Int = 16384) {
        self.channels = channels
        self.capacity = capacity
        data = [Float](repeating: 0, count: channels * capacity)
    }

    public func reset() {
        lock.withLock {
            validFrom = 0
            writtenUpTo = 0
        }
    }

    /// Interleaved `samples` of `channels` channels for frames starting at `sampleTime` (mono is spread to every channel; extra
    /// channels are dropped).
    public func write(sampleTime: UInt64, samples: [Float], channels inChannels: Int) {
        guard inChannels > 0 else { return }
        let frames = samples.count / inChannels
        guard frames > 0 else { return }
        lock.withLock {
            let end = sampleTime + UInt64(frames)
            // A jump back (a new timeline) or a gap wider than the ring starts the ring over.
            if sampleTime < validFrom || sampleTime > writtenUpTo + UInt64(capacity) || writtenUpTo == 0 {
                validFrom = sampleTime
                writtenUpTo = sampleTime
            } else if sampleTime > writtenUpTo {
                // A small gap: what was skipped is silence.
                for t in writtenUpTo..<sampleTime { zeroFrame(t) }
            }
            for f in 0..<frames {
                let base = Int((sampleTime + UInt64(f)) % UInt64(capacity)) * channels
                for c in 0..<channels { data[base + c] = samples[f * inChannels + min(c, inChannels - 1)] }
            }
            writtenUpTo = max(writtenUpTo, end)
            if writtenUpTo - validFrom > UInt64(capacity) { validFrom = writtenUpTo - UInt64(capacity) }
        }
    }

    /// Frames `sampleTime..<sampleTime+frames` interleaved for `channels` channels, and whether all of them were there.
    public func read(sampleTime: UInt64, frames: Int, channels outChannels: Int) -> (samples: [Float], complete: Bool) {
        var out = [Float](repeating: 0, count: frames * outChannels)
        var complete = true
        lock.withLock {
            for f in 0..<frames {
                let t = sampleTime + UInt64(f)
                guard t >= validFrom, t < writtenUpTo else {
                    complete = false
                    continue
                }
                let base = Int(t % UInt64(capacity)) * channels
                for c in 0..<outChannels { out[f * outChannels + c] = data[base + min(c, channels - 1)] }
            }
        }
        return (out, complete)
    }

    private func zeroFrame(_ t: UInt64) {
        let base = Int(t % UInt64(capacity)) * channels
        for c in 0..<channels { data[base + c] = 0 }
    }
}
