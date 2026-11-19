// Playing a finished pads instrument on the Mac, to check it before it is sent. Which recording a note plays, and how loud, is
// decided by TuneGodCore's own rules (`tgiLayerIndex`, `tgiNextHit`, `tgiLayerGain`), the ones the phone uses.
import AVFoundation
import Foundation

public final class InstrumentPlayer {
    /// What a note at `velocity` plays on `pad`: the layer, which of its alternates (`last` remembers each layer's, and is brought up
    /// to date), and the gain: the note's own (velocity / 127) times the layer's.
    public static func choice(pad: TGIPad, velocity: Int, last: inout [Int: Int]) -> (layer: Int, hit: Int, gain: Double) {
        let v = min(127, max(1, velocity))
        let layer = tgiLayerIndex(tops: pad.layers.map(\.top), velocity: v)
        let hit = tgiNextHit(count: pad.layers[layer].hits.count, last: last[layer])
        last[layer] = hit
        return (layer, hit, Double(v) / 127 * tgiLayerGain(layerVelocity: pad.layers[layer].velocity))
    }

    public let instrument: TGIInstrument
    /// Not private: the tests render it by hand instead of through the Mac's output.
    let engine = AVAudioEngine()
    let format: AVAudioFormat
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    /// The voices, used in turn; each remembers the pad it last played, so a cut can stop it, and when (`played` counts the notes).
    private var voices: [(node: AVAudioPlayerNode, pad: Int, order: Int)] = []
    private var nextVoice = 0
    private var played = 0
    private var lastHit: [Int: [Int: Int]] = [:]

    /// Decodes every hit `instrument` names from `audio`. Throws `TGIError.damaged` when one is missing or cannot be read.
    public init(instrument: TGIInstrument, audio: [String: Data]) throws {
        self.instrument = instrument
        var rate = 48_000.0
        var decoded: [String: (left: [Float], right: [Float]?)] = [:]
        for name in instrument.hitNames {
            guard let data = audio[name], let hit = try? decodeAudio(data) else { throw TGIError.damaged }
            decoded[name] = (hit.left, hit.right)
            rate = hit.sampleRate
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw TGIError.damaged }
        self.format = format
        for (name, hit) in decoded {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hit.left.count)),
                  let channels = buffer.floatChannelData else { throw TGIError.damaged }
            buffer.frameLength = AVAudioFrameCount(hit.left.count)
            hit.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: hit.left.count) }
            (hit.right ?? hit.left).withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: hit.left.count) }
            buffers[name] = buffer
        }
    }

    public var hitCount: Int { buffers.count }
    /// The decoded audio's size in memory (two channels of 32-bit samples).
    public var decodedBytes: Int { buffers.values.reduce(0) { $0 + Int($1.frameLength) * 2 * MemoryLayout<Float>.size } }

    private func startIfNeeded() -> Bool {
        if voices.isEmpty {
            for _ in 0..<24 {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                voices.append((node, -1, 0))
            }
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    /// Plays `pad` (0…15) at `velocity`, as the phone would: hits overlap, except that the pad's `cuts` are silenced and a pad
    /// sounds at most `TGI_PAD_VOICES` times at once, the oldest giving way.
    public func play(pad index: Int, velocity: Int) {
        guard let pads = instrument.pads, pads.indices.contains(index), let pad = pads[index], !pad.layers.isEmpty, startIfNeeded() else { return }
        var last = lastHit[index] ?? [:]
        let choice = Self.choice(pad: pad, velocity: velocity, last: &last)
        lastHit[index] = last
        guard let buffer = buffers[pad.layers[choice.layer].hits[choice.hit]] else { return }
        for i in voices.indices where (pad.cuts ?? []).contains(voices[i].pad) {
            voices[i].node.stop()
            voices[i].pad = -1
        }
        let mine = voices.indices.filter { voices[$0].pad == index }.sorted { voices[$0].order < voices[$1].order }
        if mine.count >= TGI_PAD_VOICES {
            for i in mine.prefix(mine.count - TGI_PAD_VOICES + 1) {
                voices[i].node.stop()
                voices[i].pad = -1
            }
        }
        played += 1
        let voice = nextVoice
        nextVoice = (nextVoice + 1) % voices.count
        voices[voice].pad = index
        voices[voice].order = played
        let node = voices[voice].node
        node.stop()
        node.volume = Float(choice.gain)
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.play()
    }

    public func stopAll() {
        for i in voices.indices {
            voices[i].node.stop()
            voices[i].pad = -1
        }
        engine.stop()
    }
}
