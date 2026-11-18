// tgsample: hosts an Audio Unit instrument, plays its notes at several velocities and writes what it gives back as a TuneGod
// instrument (.tgi, the phone repository's docs/tgi-file-format.md). The first working piece of the instrument maker: no window yet,
// so the plugin plays whatever it loads by itself.
//
//   tgsample list                                         the Audio Unit instruments on this Mac
//   tgsample probe <subtype> <maker> [--realtime]          which notes sound, how long and how loud
//   tgsample make <subtype> <maker> <map.txt> <name> <out.tgi> [--layers N] [--takes N] [--realtime]
//
// map.txt: one pad a line, "<pad 0-15> <note> <type or -> <label…>", then optional lines "cut <pad> <pad it silences>…".
import AVFoundation
import AudioToolbox
import Foundation
import TuneGodCore

let RATE = 48000.0
let BLOCK: AVAudioFrameCount = 512
/// Under this a hit has died away (about -80 dBFS), and how long it must stay under it.
let SILENCE: Float = 0.0001
let QUIET_SECONDS = 0.3
/// A hit is never recorded longer than this.
let MAX_SECONDS = 12.0
/// The key is held this long.
let HOLD_SECONDS = 0.25
/// Kept before the first sound.
let PRE_ROLL = 24

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func fourCC(_ s: String) -> OSType {
    guard s.utf8.count == 4 else { fail("\(s): a four-character code is four characters") }
    return s.utf8.reduce(0) { $0 << 8 | OSType($1) }
}

func text(_ code: OSType) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xff) }, encoding: .ascii) ?? "????"
}

/// Lets the plugin's own timers and loaders run for a while.
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

final class Host {
    let engine = AVAudioEngine()
    let unit: AVAudioUnit
    let format = AVAudioFormat(standardFormatWithSampleRate: RATE, channels: 2)!
    let buffer: AVAudioPCMBuffer
    let realtime: Bool
    private var midi: AUScheduleMIDIEventBlock?

    init(subtype: String, maker: String, realtime: Bool) {
        self.realtime = realtime
        let description = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: fourCC(subtype),
                                                    componentManufacturer: fourCC(maker), componentFlags: 0, componentFlagsMask: 0)
        var made: AVAudioUnit?
        var problem: Error?
        var done = false
        AVAudioUnit.instantiate(with: description, options: []) { unit, error in
            made = unit
            problem = error
            done = true
        }
        while !done { spin(0.05) }
        guard let made else { fail("The plugin did not load: \(problem.map { "\($0)" } ?? "not found")") }
        unit = made
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: BLOCK)!
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: BLOCK)
            engine.attach(unit)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch {
            fail("The audio engine did not start: \(error)")
        }
        midi = unit.auAudioUnit.scheduleMIDIEventBlock
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { midi?(AUEventSampleTimeImmediate, 0, bytes.count, $0.baseAddress!) }
    }

    /// One block of the plugin's output, left and right.
    func block() -> ([Float], [Float]) {
        let started = Date()
        do {
            let status = try engine.renderOffline(BLOCK, to: buffer)
            guard status == .success else { return ([Float](repeating: 0, count: Int(BLOCK)), [Float](repeating: 0, count: Int(BLOCK))) }
        } catch {
            fail("Rendering stopped: \(error)")
        }
        let n = Int(buffer.frameLength)
        let l = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        let r = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n))
        // In real time a block takes as long as it lasts, for plugins that read their samples from disk as they play.
        if realtime {
            let left = Double(n) / RATE - Date().timeIntervalSince(started)
            if left > 0 { Thread.sleep(forTimeInterval: left) }
        }
        return (l, r)
    }

    /// Renders until the output has stayed silent for `QUIET_SECONDS` (at most `seconds`).
    func settle(_ seconds: Double = 6) {
        var quiet = 0.0, total = 0.0
        while quiet < QUIET_SECONDS && total < seconds {
            let (l, r) = block()
            let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
            quiet = peak < SILENCE ? quiet + Double(l.count) / RATE : 0
            total += Double(l.count) / RATE
        }
    }

    /// One note, from the key going down until the sound has died away: left and right, trimmed to just before the first sound and
    /// just after the last. Nil when the note makes no sound.
    func hit(note: UInt8, velocity: UInt8) -> (left: [Float], right: [Float])? {
        settle()
        var left: [Float] = [], right: [Float] = []
        var quiet = 0.0, released = false
        send([0x90, note, velocity])
        while Double(left.count) / RATE < MAX_SECONDS {
            let (l, r) = block()
            left += l
            right += r
            let seconds = Double(left.count) / RATE
            if !released && seconds >= HOLD_SECONDS {
                send([0x80, note, 0])
                released = true
            }
            let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
            quiet = peak < SILENCE ? quiet + Double(l.count) / RATE : 0
            // Nothing at all in the first second: this note is not played by the plugin.
            if quiet >= 1 && left.count == Int(quiet * RATE + 0.5) { break }
            if released && quiet >= QUIET_SECONDS && seconds > HOLD_SECONDS + QUIET_SECONDS { break }
        }
        if !released { send([0x80, note, 0]) }
        let loud = { (i: Int) in abs(left[i]) >= SILENCE || abs(right[i]) >= SILENCE }
        guard let first = left.indices.first(where: loud), let last = left.indices.last(where: loud) else { return nil }
        let from = max(0, first - PRE_ROLL)
        var l = Array(left[from...last]), r = Array(right[from...last])
        // The last few milliseconds fade, so the cut end never clicks.
        let fade = min(l.count, Int(0.005 * RATE))
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            l[l.count - 1 - i] *= g
            r[r.count - 1 - i] *= g
        }
        return (l, r)
    }
}

/// Apple Lossless in a CAF, 24-bit; one channel when both carry the same.
func lossless(_ hit: (left: [Float], right: [Float])) -> Data {
    let mono = hit.left == hit.right
    let channels: AVAudioChannelCount = mono ? 1 : 2
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let pcm = AVAudioFormat(standardFormatWithSampleRate: RATE, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(hit.left.count))!
    buffer.frameLength = AVAudioFrameCount(hit.left.count)
    hit.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: hit.left.count) }
    if !mono { hit.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: hit.right.count) } }
    do {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: RATE, AVNumberOfChannelsKey: Int(channels),
                                       AVEncoderBitDepthHintKey: 24]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    } catch {
        fail("A hit could not be written: \(error)")
    }
    // The file is closed when `file` goes away, above.
    return (try? Data(contentsOf: url)) ?? Data()
}

struct MapPad {
    var pad: Int
    var note: UInt8
    var type: String?
    var label: String
}

func readMap(_ path: String) -> (pads: [MapPad], cuts: [Int: [Int]]) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("\(path) could not be read") }
    var pads: [MapPad] = []
    var cuts: [Int: [Int]] = [:]
    for line in text.split(separator: "\n") {
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first, !first.hasPrefix("#") else { continue }
        if first == "cut" {
            let numbers = words.dropFirst().compactMap { Int($0) }
            guard numbers.count >= 2 else { fail("cut needs a pad and the pads it silences: \(line)") }
            cuts[numbers[0], default: []] += numbers.dropFirst()
            continue
        }
        guard words.count >= 4, let pad = Int(words[0]), (0..<TGI_PADS).contains(pad), let note = UInt8(words[1]), note < 128 else {
            fail("Not a pad line (pad note type label): \(line)")
        }
        pads.append(MapPad(pad: pad, note: note, type: words[2] == "-" ? nil : words[2], label: words.dropFirst(3).joined(separator: " ")))
    }
    return (pads, cuts)
}

func option(_ name: String, in args: [String]) -> Int? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
}

let args = Array(CommandLine.arguments.dropFirst())
let realtime = args.contains("--realtime")

switch args.first {
case "list":
    let any = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
    for c in AVAudioUnitComponentManager.shared().components(matching: any) {
        print("\(text(c.audioComponentDescription.componentSubType)) \(text(c.audioComponentDescription.componentManufacturer))  \(c.manufacturerName): \(c.name)")
    }

case "probe":
    guard args.count >= 3 else { fail("usage: tgsample probe <subtype> <maker> [--realtime]") }
    let host = Host(subtype: args[1], maker: args[2], realtime: realtime)
    // The plugin loads its sounds in the background.
    for _ in 0..<40 { _ = host.block(); spin(0.2) }
    for note in UInt8(24)...UInt8(96) {
        guard let hit = host.hit(note: note, velocity: 110) else { continue }
        let peak = max(hit.left.map(abs).max() ?? 0, hit.right.map(abs).max() ?? 0)
        print(String(format: "note %3d  %5.2f s  peak %6.1f dB  %@", note, Double(hit.left.count) / RATE, 20 * log10(Double(peak)), hit.left == hit.right ? "mono" : "stereo"))
    }

case "make":
    guard args.count >= 6 else { fail("usage: tgsample make <subtype> <maker> <map.txt> <name> <out.tgi> [--layers N] [--takes N] [--realtime]") }
    let layers = max(1, min(8, option("--layers", in: args) ?? 4))
    let takes = max(1, min(4, option("--takes", in: args) ?? 1))
    let (map, cuts) = readMap(args[3])
    let host = Host(subtype: args[1], maker: args[2], realtime: realtime)
    for _ in 0..<40 { _ = host.block(); spin(0.2) }
    // The layers share the velocities evenly, and each is played at the top of its share.
    let tops = (1...layers).map { Int((127.0 * Double($0) / Double(layers)).rounded()) }
    var pads = [TGIPad?](repeating: nil, count: TGI_PADS)
    var audio: [String: Data] = [:]
    var seconds = 0.0
    for m in map {
        var made: [TGILayer] = []
        for top in tops {
            var names: [String] = []
            for take in 0..<takes {
                guard let hit = host.hit(note: m.note, velocity: UInt8(top)) else { continue }
                let name = String(format: "p%02d-v%03d-a%d.caf", m.pad, top, take)
                audio[name] = lossless(hit)
                names.append(name)
                seconds += Double(hit.left.count) / RATE
            }
            if !names.isEmpty { made.append(TGILayer(velocity: top, top: top, hits: names)) }
        }
        guard !made.isEmpty else { print("pad \(m.pad) (\(m.label), note \(m.note)): no sound, left empty"); continue }
        // A layer the plugin gave nothing for is answered by the next one up; the last answers to 127.
        made[made.count - 1].top = 127
        pads[m.pad] = TGIPad(label: m.label, type: m.type, layers: made, cuts: cuts[m.pad])
        print("pad \(m.pad) (\(m.label), note \(m.note)): \(made.count) layers")
    }
    guard pads.contains(where: { $0 != nil }) else { fail("Nothing sounded: no instrument was written.") }
    let component = AVAudioUnitComponentManager.shared().components(matching: host.unit.audioComponentDescription).first
    let instrument = TGIInstrument(id: UUID().uuidString, name: args[4], kind: .pads, created: Date().formatted(Date.ISO8601FormatStyle()),
                                   madeWith: component.map { "\($0.manufacturerName) \($0.name)" }, pads: pads)
    do {
        let data = try writeTGI(instrument, audio: audio)
        try data.write(to: URL(fileURLWithPath: args[5]), options: .atomic)
        print(String(format: "%@: %d hits, %.0f s of audio, %.1f MB", args[5], audio.count, seconds, Double(data.count) / 1_048_576))
    } catch {
        fail("The instrument could not be written: \(error)")
    }

default:
    fail("usage: tgsample list | probe <subtype> <maker> | make <subtype> <maker> <map.txt> <name> <out.tgi> [--layers N] [--takes N] [--realtime]")
}
