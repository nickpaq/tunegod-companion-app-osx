// tgsample: the instrument maker without its window, for testing on the Mac.
//   tgsample list
//   tgsample make "<plugin>" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name "<name>"]
//   tgsample make-keys "<plugin>" <out.tgi> [--low n] [--high n] [--per-octave n] [--layers n] [--hold s] [--channel n] [--realtime] [--name "<name>"]
// `make` samples the standard drum notes of the plugin whose name contains <plugin>, as the plugin stands when it is loaded (its
// own first preset: the window is where a kit is chosen), and reads the file back. `make-keys` samples it as a keys instrument.
import Foundation
import TuneGodSamplerKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

/// The value after `flag`, taken out of `args`.
func option(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

switch args.first {
case "list":
    for plugin in installedInstruments() { print(plugin.title) }

case "make":
    let channel = option("--channel").flatMap(Int.init) ?? 1
    let layers = option("--layers").flatMap(Int.init) ?? 4
    let alternates = option("--alternates").flatMap(Int.init) ?? 1
    let named = option("--name")
    let realTime = flag("--realtime")
    guard args.count == 3 else { fail("usage: tgsample make \"<plugin>\" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name s]", code: 2) }
    let wanted = args[1].lowercased()
    guard let plugin = installedInstruments().first(where: { $0.title.lowercased().contains(wanted) }) else {
        fail("No instrument plugin's name contains \"\(args[1])\". `tgsample list` shows them.")
    }
    do {
        let host = try await PluginHost.load(plugin, sampleRate: CaptureSettings().sampleRate)
        host.sampling = true
        host.offline = !realTime
        var setup = KitSetup.standardDrums()
        setup.channel = channel
        setup.layers = layers
        setup.alternates = alternates
        let began = Date()
        let kit = try sampleKit(host, setup: setup, settings: CaptureSettings(), realTime: realTime, progress: { done, total, label in
            if !label.isEmpty { FileHandle.standardError.write(Data("\r\(done + 1)/\(total) \(label)          ".utf8)) }
        }, cancelled: { false })
        FileHandle.standardError.write(Data("\n".utf8))
        let built = try buildInstrument(kit, setup: setup, name: named ?? plugin.name, madeWith: plugin.title, id: UUID().uuidString,
                                        created: Date().formatted(Date.ISO8601FormatStyle()), sampleRate: host.sampleRate)
        let data = try writeTGI(built.instrument, audio: built.audio)
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        let back = try readTGI(data)
        let pads = (back.instrument.pads ?? []).compactMap { $0 }
        print("\(args[2]): \(pads.count) pads, \(pads.flatMap(\.layers).count) layers, \(back.audio.count) hits, \(data.count / 1024) KB, sampled in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        for (index, pad) in (back.instrument.pads ?? []).enumerated() {
            guard let pad, let recorded = kit.hits[index] else { continue }
            let layers = zip(pad.layers, recorded.filter { !$0.isEmpty }).map { layer, hits in
                String(format: "v%d peak %.3f %.2fs%@", layer.velocity, hits[0].peak, Double(hits[0].frames) / host.sampleRate, hits[0].channels == 1 ? " mono" : "")
            }
            print(String(format: "  %2d %@  %@", index, pad.label.padding(toLength: 11, withPad: " ", startingAt: 0), layers.joined(separator: " | ")))
        }
        for warning in built.warnings { print("  ! \(warning)") }
    } catch {
        fail("tgsample: \(error)")
    }

case "make-keys":
    var keys = KeysSetup()
    keys.lowest = option("--low").flatMap(Int.init) ?? keys.lowest
    keys.highest = option("--high").flatMap(Int.init) ?? keys.highest
    keys.notesPerOctave = option("--per-octave").flatMap(Int.init) ?? keys.notesPerOctave
    keys.layers = option("--layers").flatMap(Int.init) ?? keys.layers
    keys.holdSeconds = option("--hold").flatMap(Double.init) ?? keys.holdSeconds
    keys.channel = option("--channel").flatMap(Int.init) ?? 1
    let named = option("--name")
    let realTime = flag("--realtime")
    guard args.count == 3 else { fail("usage: tgsample make-keys \"<plugin>\" <out.tgi> [--low n] [--high n] [--per-octave n] [--layers n] [--hold s] [--channel n] [--realtime] [--name s]", code: 2) }
    let wanted = args[1].lowercased()
    guard let plugin = installedInstruments().first(where: { $0.title.lowercased().contains(wanted) }) else {
        fail("No instrument plugin's name contains \"\(args[1])\". `tgsample list` shows them.")
    }
    do {
        let host = try await PluginHost.load(plugin, sampleRate: CaptureSettings().sampleRate)
        host.sampling = true
        host.offline = !realTime
        let began = Date()
        let sampled = try sampleKeys(host, setup: keys, settings: CaptureSettings(), realTime: realTime, progress: { done, total, label in
            if !label.isEmpty { FileHandle.standardError.write(Data("\r\(done + 1)/\(total) \(label)          ".utf8)) }
        }, cancelled: { false })
        FileHandle.standardError.write(Data("\n".utf8))
        let built = try buildKeysInstrument(sampled, setup: keys, name: named ?? plugin.name, madeWith: plugin.title, id: UUID().uuidString,
                                            created: Date().formatted(Date.ISO8601FormatStyle()), sampleRate: host.sampleRate)
        let data = try writeTGI(built.instrument, audio: built.audio)
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        let back = try readTGI(data)
        let zones = back.instrument.zones ?? []
        print("\(args[2]): \(zones.count) notes, \(back.audio.count) samples, \(data.count / 1024) KB, hold \(back.instrument.holdFrames ?? 0) frames, release \(Int(back.instrument.releaseMs ?? 0)) ms, sampled in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        var below = -1
        for zone in zones {
            let layers = zone.layers.map { "v\($0.velocity)" }.joined(separator: " ")
            print("  \(noteName(zone.root)) plays \(noteName(below + 1))–\(noteName(zone.topKey))  \(layers)")
            below = zone.topKey
        }
        for warning in built.warnings { print("  ! \(warning)") }
    } catch {
        fail("tgsample: \(error)")
    }

default:
    fail("usage: tgsample list | tgsample make \"<plugin>\" <out.tgi> [...] | tgsample make-keys \"<plugin>\" <out.tgi> [...]", code: 2)
}
