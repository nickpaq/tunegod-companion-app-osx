// A plugin's pad setup, kept between runs: which of its notes falls on which pad is the plugin's own layout, set once and used for
// every kit of that plugin. One small file a plugin, in the user's Application Support folder; also a setup written as text.
import Foundation


/// Where the pad setups are kept on this Mac.
public func padSetupFolder() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return support.appendingPathComponent("TuneGod Companion/Pad setups", isDirectory: true)
}

private func padSetupFile(_ plugin: PluginInfo, in folder: URL) -> URL {
    folder.appendingPathComponent("\(plugin.id).json")
}

/// The setup saved for `plugin`, or nil when none was, or when it cannot be read as sixteen pads.
public func savedPadSetup(for plugin: PluginInfo, in folder: URL = padSetupFolder()) -> KitSetup? {
    guard let data = try? Data(contentsOf: padSetupFile(plugin, in: folder)),
          let setup = try? JSONDecoder().decode(KitSetup.self, from: data), setup.pads.count == TGI_PADS else { return nil }
    return setup
}

public func savePadSetup(_ setup: KitSetup, for plugin: PluginInfo, in folder: URL = padSetupFolder()) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(setup).write(to: padSetupFile(plugin, in: folder), options: .atomic)
}

/// A pad setup written as text, one pad a line: `<pad 0-15> <note> <type or -> <label…>`, then optional lines
/// `cut <pad> <a pad it silences>…`. Lines that start with `#` are notes. Pads without a line are empty.
public func kitSetup(fromMap text: String) throws -> KitSetup {
    var pads = [PadSetup?](repeating: nil, count: TGI_PADS)
    var cuts: [(Int, [Int])] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first, !first.hasPrefix("#") else { continue }
        if first == "cut" {
            let numbers = words.dropFirst().compactMap { Int($0) }
            guard numbers.count >= 2, numbers.count == words.count - 1, numbers.allSatisfy({ (0..<TGI_PADS).contains($0) }) else {
                throw PluginError("A cut line names a pad and the pads it silences, each 0 to \(TGI_PADS - 1): \(line)")
            }
            cuts.append((numbers[0], Array(numbers.dropFirst())))
            continue
        }
        guard words.count >= 4, let pad = Int(words[0]), (0..<TGI_PADS).contains(pad), let note = Int(words[1]), (0...127).contains(note) else {
            throw PluginError("A pad line is a pad (0 to \(TGI_PADS - 1)), a note (0 to 127), a type or -, and a label: \(line)")
        }
        pads[pad] = PadSetup(note: note, label: words.dropFirst(3).joined(separator: " "), type: words[2] == "-" ? nil : words[2])
    }
    for (pad, silenced) in cuts {
        guard pads[pad] != nil else { throw PluginError("A cut line names pad \(pad), which has no line of its own.") }
        pads[pad]?.cuts += silenced.filter { $0 != pad }
    }
    guard pads.contains(where: { $0 != nil }) else { throw PluginError("The setup has no pad.") }
    return KitSetup(pads: pads)
}
