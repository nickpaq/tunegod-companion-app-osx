// The name of the kit or preset a plugin has loaded. A plugin's presets are its own: most give a host no list of them, but the
// state a plugin hands over for saving says which one is chosen, so an instrument can carry that name.
import AudioToolbox
import Foundation

/// The entries of a saved state that hold the chosen preset's name, as their last path component reads in lower case; the first
/// is trusted most.
private let PRESET_NAME_KEYS = ["currentpresetname", "presetname", "currentprogramname", "programname", "patchname"]

/// A name found in a state, and how much its entry is trusted (0 is most).
private struct FoundName {
    var rank: Int
    var name: String
}

/// A name worth showing: one line, not empty, not long.
private func usableName(_ text: String) -> String? {
    let name = text.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
    return name
}

/// How much `key` is trusted to name the preset; nil when it does not name it.
private func presetKeyRank(_ key: String) -> Int? {
    let last = key.split(whereSeparator: { "/.:".contains($0) }).last.map { $0.lowercased() } ?? ""
    return PRESET_NAME_KEYS.firstIndex(of: last)
}

/// The better of two finds: the more trusted entry, and of two alike the earlier.
private func better(_ a: FoundName?, _ b: FoundName?) -> FoundName? {
    guard let a else { return b }
    guard let b else { return a }
    return b.rank < a.rank ? b : a
}

/// The preset's name in one block of a plugin's state, read two ways: as text entries that each end in a zero byte, a key followed
/// by its value, and as `key="value"`.
private func foundName(in data: Data) -> FoundName? {
    var best: FoundName?
    func offer(_ key: String, _ value: String) {
        guard let rank = presetKeyRank(key), let name = usableName(value) else { return }
        best = better(best, FoundName(rank: rank, name: name))
    }
    let parts = data.split(separator: 0, omittingEmptySubsequences: false)
    for index in parts.indices.dropLast() {
        // A key is short; the audio and tables in a state are not read as text.
        guard (1...200).contains(parts[index].count), parts[index + 1].count <= 400,
              let key = String(bytes: parts[index], encoding: .utf8), presetKeyRank(key) != nil,
              let value = String(bytes: parts[index + 1], encoding: .utf8) else { continue }
        offer(key, value)
    }
    if let text = String(data: data, encoding: .utf8),
       let pattern = try? NSRegularExpression(pattern: "([A-Za-z0-9_./:]+)\\s*=\\s*\"([^\"\\n]{1,120})\"") {
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            offer(String(text[key]), String(text[value]))
        }
    }
    return best
}

/// The preset's name in a plugin's whole saved state (what a host stores in a project): the most trusted entry anywhere in it.
/// Nil when the state does not name its preset.
public func presetName(inState state: [String: Any]) -> String? {
    var best: FoundName?
    func look(_ value: Any, key: String) {
        if let data = value as? Data {
            best = better(best, foundName(in: data))
        } else if let text = value as? String {
            if let rank = presetKeyRank(key), let name = usableName(text) { best = better(best, FoundName(rank: rank, name: name)) }
        } else if let inner = value as? [String: Any] {
            for key in inner.keys.sorted() { look(inner[key] as Any, key: key) }
        }
    }
    for key in state.keys.sorted() { look(state[key] as Any, key: key) }
    return best?.name
}

extension PluginHost {
    /// The name of the kit or preset the plugin has loaded, or nil when the plugin does not say. A preset of the plugin's that the
    /// system knows by number is named by the system; any other is looked for in the plugin's state. That asks the plugin for its
    /// whole state on the caller's thread: call it from the main thread, as a host does when it saves.
    public var presetName: String? { presetName(in: unit.fullState) }

    /// The same, from a state already asked for (`unit.fullState`), so one asking serves the name and the keeping of the state.
    public func presetName(in state: [String: Any]?) -> String? {
        if let preset = unit.currentPreset, preset.number >= 0, let name = usableName(preset.name) { return name }
        return state.flatMap { TuneGodSamplerKit.presetName(inState: $0) }
    }
}

// MARK: The plugin as it was left

/// Where a plugin's state is kept between runs: the kit that was chosen and everything set in the plugin's own window.
public func pluginStateFolder() -> URL {
    padSetupFolder().deletingLastPathComponent().appendingPathComponent("Plugin states", isDirectory: true)
}

/// A plugin's state as a file's bytes; nil when it holds something a file cannot.
public func pluginStateData(_ state: [String: Any]) -> Data? {
    guard PropertyListSerialization.propertyList(state, isValidFor: .binary) else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
}

extension PluginHost {
    private func stateFile(in folder: URL) -> URL { folder.appendingPathComponent("\(info.id).plist") }

    /// Keeps `data` (`pluginStateData`) as this plugin's state.
    public func keepState(_ data: Data, in folder: URL = pluginStateFolder()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: stateFile(in: folder), options: .atomic)
    }

    /// Puts the plugin back as it was last kept. False when nothing was kept or it cannot be read. Call from the main thread.
    @discardableResult
    public func restoreKeptState(in folder: URL = pluginStateFolder()) -> Bool {
        guard let data = try? Data(contentsOf: stateFile(in: folder)),
              let state = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        unit.fullState = state
        return true
    }
}
