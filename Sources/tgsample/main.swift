// tgsample: the instrument maker without its window, for testing on the Mac.
//   tgsample list
//   tgsample setup "<plugin>" <map.txt>
//   tgsample make "<plugin>" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name "<name>"] [--wait s]
//   tgsample make-keys "<plugin>" <out.tgi> [--low n] [--high n] [--per-octave n] [--layers n] [--hold s] [--channel n] [--realtime] [--name "<name>"] [--wait s]
// `setup` keeps a pad setup written as text (`kitSetup(fromMap:)`) as that plugin's, for this tool and the window alike.
// `make` samples the plugin whose name contains <plugin> as it stands when it is loaded (its own first preset: the window is where
// a kit is chosen), on the plugin's saved pad setup or else the standard drum notes, names the instrument after the plugin's
// preset, and reads the file back. `--wait` gives the plugin that many seconds to load its sounds first (default 2). `make-keys` does
// the same for a keys instrument: the range, notes per octave, layers and hold as the window sets them.
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

/// Loads `plugin` and gives it `wait` seconds to load its sounds, ready to be sampled.
func loadForSampling(_ plugin: PluginInfo, wait: Double, realTime: Bool) async throws -> PluginHost {
    let host = try await PluginHost.load(plugin, sampleRate: CaptureSettings().sampleRate)
    host.sampling = true
    // A plugin loads its sounds in the background, some of it on the main thread's own time.
    let loaded = Date().addingTimeInterval(wait)
    var discard: [Float] = [], discardRight: [Float] = []
    while Date() < loaded {
        discard.removeAll(keepingCapacity: true)
        discardRight.removeAll(keepingCapacity: true)
        try host.render(frames: 512, left: &discard, right: &discardRight)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    host.offline = !realTime
    return host
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

/// The installed plugin whose name contains `wanted`.
func find(_ wanted: String) -> PluginInfo {
    guard let plugin = installedInstruments().first(where: { $0.title.lowercased().contains(wanted.lowercased()) }) else {
        fail("No instrument plugin's name contains \"\(wanted)\". `tgsample list` shows them.")
    }
    return plugin
}

switch args.first {
case "list":
    for plugin in installedInstruments() { print(plugin.title) }

case "setup":
    guard args.count == 3 else { fail("usage: tgsample setup \"<plugin>\" <map.txt>", code: 2) }
    let plugin = find(args[1])
    do {
        let setup = try kitSetup(fromMap: try String(contentsOfFile: args[2], encoding: .utf8))
        try savePadSetup(setup, for: plugin)
        print("\(plugin.title): \(setup.pads.compactMap { $0 }.count) pads kept as its setup.")
    } catch {
        fail("tgsample: \(error)")
    }
case "make":
    let channel = option("--channel").flatMap(Int.init)
    let layers = option("--layers").flatMap(Int.init)
    let alternates = option("--alternates").flatMap(Int.init)
    let named = option("--name")
    let wait = option("--wait").flatMap(Double.init) ?? 2
    let realTime = flag("--realtime")
    guard args.count == 3 else { fail("usage: tgsample make \"<plugin>\" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name s]", code: 2) }
    let plugin = find(args[1])
    do {
        let host = try await PluginHost.load(plugin, sampleRate: CaptureSettings().sampleRate)
        host.sampling = true
        // A plugin loads its sounds in the background, some of it on the main thread's own time.
        let loaded = Date().addingTimeInterval(wait)
        var discard: [Float] = [], discardRight: [Float] = []
        while Date() < loaded {
            discard.removeAll(keepingCapacity: true)
            discardRight.removeAll(keepingCapacity: true)
            try host.render(frames: 512, left: &discard, right: &discardRight)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        host.offline = !realTime
        var setup = savedPadSetup(for: plugin) ?? KitSetup.standardDrums()
        if let channel { setup.channel = channel }
        if let layers { setup.layers = layers }
        if let alternates { setup.alternates = alternates }
        let preset = host.presetName
        let began = Date()
        let kit = try sampleKit(host, setup: setup, settings: CaptureSettings(), realTime: realTime, progress: { done, total, label in
            if !label.isEmpty { FileHandle.standardError.write(Data("\r\(done + 1)/\(total) \(label)          ".utf8)) }
        }, cancelled: { false })
        FileHandle.standardError.write(Data("\n".utf8))
        let built = try buildInstrument(kit, setup: setup, name: named ?? preset ?? plugin.name, madeWith: plugin.title, id: UUID().uuidString,
                                        created: Date().formatted(Date.ISO8601FormatStyle()), sampleRate: host.sampleRate)
        let data = try writeTGI(built.instrument, audio: built.audio)
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        let back = try readTGI(data)
        let pads = (back.instrument.pads ?? []).compactMap { $0 }
        print("preset: \(preset ?? "not named by the plugin")")
        print("\(args[2]) (\(back.instrument.name)): \(pads.count) pads, \(pads.flatMap(\.layers).count) layers, \(back.audio.count) hits, \(data.count / 1024) KB, sampled in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
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
    keys.channel = option("--channel").flatMap(Int.init) ?? keys.channel
    let named = option("--name")
    let wait = option("--wait").flatMap(Double.init) ?? 2
    let realTime = flag("--realtime")
    guard args.count == 3 else { fail("usage: tgsample make-keys \"<plugin>\" <out.tgi> [--low n] [--high n] [--per-octave n] [--layers n] [--hold s] [--channel n] [--realtime] [--name s] [--wait s]", code: 2) }
    let plugin = find(args[1])
    do {
        let host = try await loadForSampling(plugin, wait: wait, realTime: realTime)
        let preset = host.presetName
        let began = Date()
        let sampled = try sampleKeys(host, setup: keys, settings: CaptureSettings(), realTime: realTime, progress: { done, total, label in
            if !label.isEmpty { FileHandle.standardError.write(Data("\r\(done + 1)/\(total) \(label)          ".utf8)) }
        }, cancelled: { false })
        FileHandle.standardError.write(Data("\n".utf8))
        let built = try buildKeysInstrument(sampled, setup: keys, name: named ?? preset ?? plugin.name, madeWith: plugin.title,
                                            id: UUID().uuidString, created: Date().formatted(Date.ISO8601FormatStyle()), sampleRate: host.sampleRate)
        let data = try writeTGI(built.instrument, audio: built.audio)
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        let back = try readTGI(data)
        let zones = back.instrument.zones ?? []
        print("preset: \(preset ?? "not named by the plugin")")
        print("\(args[2]) (\(back.instrument.name)): \(zones.count) notes, \(back.audio.count) samples, \(data.count / 1024) KB, hold \(back.instrument.holdFrames ?? 0) frames, release \(Int(back.instrument.releaseMs ?? 0)) ms, sampled in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        var below = -1
        for (zone, recorded) in zip(zones, sampled.notes.filter { $0.layers.contains { $0 != nil } }) {
            let layers = zip(zone.layers, recorded.layers.compactMap { $0 }).map { layer, note in
                String(format: "v%d peak %.3f %.2fs", layer.velocity, note.hit.peak, Double(note.hit.frames) / host.sampleRate)
            }
            print("  \(noteName(zone.root).padding(toLength: 4, withPad: " ", startingAt: 0)) plays \(noteName(below + 1))–\(noteName(zone.topKey))  \(layers.joined(separator: " | "))")
            below = zone.topKey
        }
        for warning in built.warnings { print("  ! \(warning)") }
    } catch {
        fail("tgsample: \(error)")
    }

default:
    fail("usage: tgsample list | tgsample setup \"<plugin>\" <map.txt> | tgsample make \"<plugin>\" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name s] [--wait s] | tgsample make-keys \"<plugin>\" <out.tgi> [...]", code: 2)
}
