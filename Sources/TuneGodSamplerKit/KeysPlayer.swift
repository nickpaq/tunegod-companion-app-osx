// Playing a finished keys instrument on the Mac, to check it before it is sent, the way the phone is to play it: the key picks the zone
// and the sample is repitched from the zone's root, the velocity picks the layer (TuneGodCore's `tgiLayerIndex`, `tgiLayerGain`).
// A key let go before `holdFrames` fades over `releaseMs`; one held to `holdFrames` or beyond plays the recorded release and ends.
import AVFoundation
import Foundation
import os

/// The sounding notes and their mixing, apart from the Mac's output so the tests can render it by hand.
final class KeysVoices: @unchecked Sendable {
    struct Voice {
        var key: Int
        var left: [Float]
        var right: [Float]
        /// Where in the sample, in its own frames, and how far to move each frame.
        var position: Double
        var rate: Double
        var gain: Double
        /// While fading after an early let-go: how much the level falls each frame.
        var fall: Double?
        var level: Double = 1
    }

    static let maxVoices = 32

    let instrument: TGIInstrument
    let sampleRate: Double
    private let zones: [TGIZone]
    private let sounds: [String: (left: [Float], right: [Float])]
    private let lock = OSAllocatedUnfairLock()
    private var voices: [Voice] = []

    init(instrument: TGIInstrument, sounds: [String: (left: [Float], right: [Float])], sampleRate: Double) {
        self.instrument = instrument
        self.sampleRate = sampleRate
        zones = instrument.zones ?? []
        self.sounds = sounds
        voices.reserveCapacity(Self.maxVoices)
    }

    /// What `key` at `velocity` plays: the zone, the layer, how fast the sample runs and the gain (the note's velocity / 127 times
    /// the layer's).
    static func choice(zones: [TGIZone], key: Int, velocity: Int) -> (zone: Int, layer: Int, rate: Double, gain: Double)? {
        guard !zones.isEmpty else { return nil }
        let v = min(127, max(1, velocity))
        let zone = keyZoneIndex(topKeys: zones.map(\.topKey), key: key)
        let layers = zones[zone].layers
        guard !layers.isEmpty else { return nil }
        let layer = tgiLayerIndex(tops: layers.map(\.top), velocity: v)
        return (zone, layer, keyRate(key: key, root: zones[zone].root),
                Double(v) / 127 * tgiLayerGain(layerVelocity: layers[layer].velocity))
    }

    var sounding: Int { lock.withLockUnchecked { voices.count } }

    func noteOn(key: Int, velocity: Int) {
        guard let c = Self.choice(zones: zones, key: key, velocity: velocity),
              let hit = zones[c.zone].layers[c.layer].hits.first, let sound = sounds[hit] else { return }
        let voice = Voice(key: key, left: sound.left, right: sound.right, position: 0, rate: c.rate, gain: c.gain)
        lock.withLockUnchecked {
            // The same key played again lets the note it was playing go first.
            for i in voices.indices where voices[i].key == key { release(&voices[i]) }
            if voices.count >= Self.maxVoices { voices.removeFirst() }
            voices.append(voice)
        }
    }

    func noteOff(key: Int) {
        lock.withLockUnchecked {
            for i in voices.indices where voices[i].key == key { release(&voices[i]) }
        }
    }

    func allOff() {
        lock.withLockUnchecked { voices.removeAll(keepingCapacity: true) }
    }

    /// A key let go: before `holdFrames` the note fades over `releaseMs`; at or after it the recorded release goes on to its end.
    private func release(_ voice: inout Voice) {
        guard voice.fall == nil, voice.position < Double(instrument.holdFrames ?? 0) else { return }
        let frames = max(1, (instrument.releaseMs ?? DEFAULT_RELEASE_MS) / 1000 * sampleRate)
        voice.fall = 1 / frames
        // Done with its key: playing the key again starts a new note beside this fading one.
        voice.key = -1
    }

    /// Mixes the next `frames` frames of every sounding note into `left` and `right` (which it first clears). False, with silence,
    /// when the notes are being changed at that moment.
    @discardableResult
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        return lock.withLockIfAvailableUnchecked {
            for v in voices.indices {
                var voice = voices[v]
                let count = voice.left.count
                for f in 0..<frames {
                    let i = Int(voice.position)
                    guard i < count, voice.level > 0 else { break }
                    // Between two frames of the sample, by straight line.
                    let t = Float(voice.position - Double(i))
                    let next = min(i + 1, count - 1)
                    let g = Float(voice.gain * voice.level)
                    left[f] += (voice.left[i] + (voice.left[next] - voice.left[i]) * t) * g
                    right[f] += (voice.right[i] + (voice.right[next] - voice.right[i]) * t) * g
                    voice.position += voice.rate
                    if let fall = voice.fall { voice.level = max(0, voice.level - fall) }
                }
                voices[v].position = voice.position
                voices[v].level = voice.level
            }
            voices.removeAll { Int($0.position) >= $0.left.count || $0.level <= 0 }
            return true
        } ?? false
    }
}

public final class KeysPlayer {
    public let instrument: TGIInstrument
    let voices: KeysVoices
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let decoded: Int

    /// Decodes every hit `instrument` names from `audio`. Throws `TGIError.damaged` when one is missing or cannot be read.
    public init(instrument: TGIInstrument, audio: [String: Data]) throws {
        self.instrument = instrument
        var rate = 48_000.0
        var sounds: [String: (left: [Float], right: [Float])] = [:]
        for name in instrument.hitNames {
            guard let data = audio[name], let hit = try? decodeAudio(data) else { throw TGIError.damaged }
            sounds[name] = (hit.left, hit.right ?? hit.left)
            rate = hit.sampleRate
        }
        decoded = sounds.values.reduce(0) { $0 + $1.left.count * 2 * MemoryLayout<Float>.size }
        let voices = KeysVoices(instrument: instrument, sounds: sounds, sampleRate: rate)
        self.voices = voices
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw TGIError.damaged }
        source = AVAudioSourceNode(format: format) { silence, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            voices.render(frames: Int(frames), left: left, right: right)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    public var hitCount: Int { instrument.hitNames.count }
    /// The decoded audio's size in memory (two channels of 32-bit samples).
    public var decodedBytes: Int { decoded }

    /// Plays `key` (0…127) at `velocity` until `keyUp`.
    public func keyDown(_ key: Int, velocity: Int) {
        if !engine.isRunning { try? engine.start() }
        voices.noteOn(key: key, velocity: velocity)
    }

    public func keyUp(_ key: Int) {
        voices.noteOff(key: key)
    }

    public func stopAll() {
        voices.allOff()
        engine.stop()
    }
}
