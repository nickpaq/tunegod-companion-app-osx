// The Make instrument window's state: the plugin that is loaded, the sixteen pads' setup, the sampling in progress and its result.
import AppKit
import os
import SwiftUI
import TuneGodSamplerKit
import UniformTypeIdentifiers

/// What sampling made, ready to hear and to send.
struct MadeInstrument {
    var instrument: TGIInstrument
    var audio: [String: Data]
    var warnings: [String]
    /// The size of the .tgi, and of its audio once the phone has decoded it.
    var fileBytes: Int
    var decodedBytes: Int
    /// The plugin's kit it was sampled from, when the plugin names it.
    var kit: String?
    /// Where the .tgi was written, or nil when it could not be (`saveProblem` says why).
    var savedTo: URL?
    var saveProblem: String?
}

/// Where the chosen folder for made instruments is remembered (its path); unset: the Desktop.
private let FOLDER_KEY = "maker.folder"

private func desktopFolder() -> URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
}

/// iCloud Drive on this Mac, or nil when it is not set up.
private func iCloudDrive() -> URL? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// The folder in iCloud Drive that made instruments go to, where the phone's Files app shows them.
func iCloudInstrumentsFolder() -> URL? {
    iCloudDrive()?.appendingPathComponent("TuneGod Instruments", isDirectory: true)
}

/// The folder a made instrument is written into: the one the user chose, or the Desktop, where it is at hand for AirDrop.
func madeInstrumentsFolder() -> URL {
    UserDefaults.standard.string(forKey: FOLDER_KEY).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktopFolder()
}

/// Where `folder` is, in words for the window: "on the Desktop", "in iCloud Drive", "in Kits".
func placeName(_ folder: URL) -> String {
    let path = folder.standardizedFileURL.path
    if path == desktopFolder().standardizedFileURL.path { return "on the Desktop" }
    if let cloud = iCloudDrive(), path.hasPrefix(cloud.standardizedFileURL.path) {
        return path == iCloudInstrumentsFolder()?.standardizedFileURL.path ? "in iCloud Drive" : "in iCloud Drive, \(folder.lastPathComponent)"
    }
    return "in \(folder.lastPathComponent)"
}

/// Whether `url` is in iCloud Drive.
func isInICloud(_ url: URL) -> Bool {
    guard let cloud = iCloudDrive() else { return false }
    return url.standardizedFileURL.path.hasPrefix(cloud.standardizedFileURL.path + "/")
}

/// Gives back the Mac's copy of a file in iCloud Drive once iCloud has all of it: the file stays in iCloud (and in the folder, to
/// be downloaded when opened) and takes no room on this Mac. False while it is still being uploaded, or when it cannot be done.
func freeLocalCopy(_ url: URL) -> Bool {
    // A new URL each time: a URL remembers the answers it was given.
    let fresh = URL(fileURLWithPath: url.path)
    guard (try? fresh.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == true else { return false }
    return (try? FileManager.default.evictUbiquitousItem(at: fresh)) != nil
}

/// After the plugin has changed kit, how long it is given to load the kit's sounds before it is sampled.
let KIT_LOAD_SECONDS = 5.0
/// A run of Make every kit never makes more than this.
let MOST_KITS = 1000

/// A file in `folder` for an instrument called `name` that replaces nothing: "Name.tgi", or "Name 2.tgi" and so on when taken.
func freeInstrumentFile(_ name: String, in folder: URL) -> URL {
    let first = instrumentFileName(name)
    let base = String(first.dropLast(TGI_EXTENSION.count + 1))
    var url = folder.appendingPathComponent(first)
    var number = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(base) \(number).\(TGI_EXTENSION)")
        number += 1
    }
    return url
}

/// The plugin that was last chosen, to open with next time.
private let LAST_PLUGIN_KEY = "maker.plugin"

/// Above this much decoded audio the window warns. A first guess: what a large instrument costs the phone is not measured yet.
let PHONE_MEMORY_WARNING_BYTES = 150 * 1024 * 1024

@MainActor @Observable
final class MakerModel {
    enum Phase: Equatable {
        case setup
        case sampling(done: Int, total: Int, label: String)
    }

    private(set) var plugins: [PluginInfo] = []
    var pluginID: String? {
        didSet { if pluginID != oldValue { loadPlugin() } }
    }
    private(set) var host: PluginHost?
    private(set) var loading = false
    /// Something the user must read: a plugin that would not load, sampling that failed, a file that could not be written.
    var problem: String?

    /// The pads' setup. A loaded plugin's is kept for the next time that plugin is used (`savePadSetup`).
    var setup = KitSetup.standardDrums() {
        didSet {
            guard setup != oldValue, let host, setupIsFor == host.info.id else { return }
            try? savePadSetup(setup, for: host.info)
        }
    }
    /// The plugin whose saved setup `setup` is.
    private var setupIsFor: String?
    /// The kit or preset chosen in the plugin's own window, as the plugin names it; nil when it does not say.
    private(set) var kit: String?
    /// The instrument's name when the user has typed one; empty while it follows the kit.
    private var typedName = ""
    var selectedPad = 12
    /// The next note played on a MIDI keyboard becomes the selected pad's note.
    var learning = false
    var realTime = false
    private(set) var phase = Phase.setup
    private(set) var made: MadeInstrument?
    /// Whether the pads play the finished instrument (as the phone will) or the plugin.
    var hearInstrument = false
    var velocity = 127.0
    /// The instrument's name: the plugin's kit, until the user types another.
    var name: String {
        get { typedName.isEmpty ? followedName : typedName }
        set { typedName = newValue.trimmingCharacters(in: .whitespaces) == followedName ? "" : newValue }
    }
    private var followedName: String { kit ?? plugin?.name ?? "" }
    /// Pads that are sounding, for the grid to light.
    private(set) var lit = Set<Int>()

    private var live: LiveOutput?
    private var player: InstrumentPlayer?
    private var midi: MIDIInput?
    private let pluginWindow = PluginWindow()
    private var kitWatch: Task<Void, Never>?
    /// Where a click in the plugin's window goes to its next kit (points from the top left of the plugin's view), shown once by
    /// the user and kept for the plugin. Make every kit repeats it.
    private(set) var nextKitClick: CGPoint?
    /// The next click in the plugin's window is being waited for, to be kept as `nextKitClick`.
    private(set) var learningNextKit = false
    /// Make every kit is running: how many it has made and how many it found already made.
    private(set) var batch: (made: Int, skipped: Int)?
    /// What the last run of Make every kit did, for the window.
    private(set) var batchSummary: String?
    /// Instruments written in iCloud Drive whose copy on this Mac is still to be given back, once iCloud has them (`freeUploaded`).
    private var toFree: [URL] = []
    private var freeing: Task<Void, Never>?
    /// How many instruments in iCloud Drive still take room on this Mac, waiting for iCloud to have them.
    var waitingForICloud: Int { toFree.count }
    /// Told when the sampling in progress has ended (Make every kit waits on it).
    private var sampleEnded: CheckedContinuation<Void, Never>?
    /// The folder made instruments are written into (`madeInstrumentsFolder`), as the window shows it.
    private(set) var folder = madeInstrumentsFolder()
    private let cancel = OSAllocatedUnfairLock(initialState: false)

    var plugin: PluginInfo? { plugins.first { $0.id == pluginID } }
    var isSampling: Bool { phase != .setup }
    var canSample: Bool { host != nil && !isSampling && batch == nil && setup.sampleCount > 0 }
    var canMakeEveryKit: Bool { canSample && nextKitClick != nil && kit != nil }
    /// The result on show was made from the kit the plugin has now.
    var madeIsCurrent: Bool { made != nil && made?.kit == kit }

    /// Called when the window appears: the plugins on this Mac, and the MIDI keyboards.
    func start() {
        plugins = installedInstruments()
        if midi == nil {
            midi = MIDIInput { [weak self] note in
                Task { @MainActor in self?.midiNote(note) }
            }
            #if DEBUG
            applyLaunchArguments()
            #endif
            // The plugin used last time opens by itself, so the window starts at its kits.
            if pluginID == nil, let last = UserDefaults.standard.string(forKey: LAST_PLUGIN_KEY), plugins.contains(where: { $0.id == last }) {
                pluginID = last
            }
        }
    }

    #if DEBUG
    private var sampleOnceLoaded = false
    private var launchChannel: Int?

    /// For checking the window without a hand on the mouse (debug builds only): `--plugin <part of its name>` chooses a plugin,
    /// `--channel <n>` its MIDI channel, `--sample` presses Sample once it has loaded.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let channel = value("--channel").flatMap(Int.init) {
            launchChannel = min(16, max(1, channel))
            setup.channel = launchChannel ?? 1
        }
        if let wanted = value("--plugin")?.lowercased(), let plugin = plugins.first(where: { $0.title.lowercased().contains(wanted) }) {
            sampleOnceLoaded = args.contains("--sample")
            pluginID = plugin.id
        }
    }
    #endif

    // MARK: The plugin

    private func loadPlugin() {
        kitWatch?.cancel()
        kitWatch = nil
        batch = nil
        nextKitClick = nil
        learningNextKit = false
        pluginWindow.stopWatchingClick()
        live?.stop()
        live = nil
        pluginWindow.close()
        host = nil
        setupIsFor = nil
        kit = nil
        problem = nil
        guard let plugin else { return }
        UserDefaults.standard.set(plugin.id, forKey: LAST_PLUGIN_KEY)
        loading = true
        Task {
            defer { loading = false }
            do {
                let loaded = try await PluginHost.load(plugin, sampleRate: CaptureSettings().sampleRate)
                // Another plugin was chosen while this one loaded.
                guard pluginID == plugin.id else { return }
                let output = try LiveOutput(host: loaded)
                try output.start()
                host = loaded
                live = output
                // The plugin's own notes for the pads, as they were left the last time it was used.
                setup = savedPadSetup(for: plugin) ?? KitSetup.standardDrums()
                #if DEBUG
                if let launchChannel { setup.channel = launchChannel }
                #endif
                setupIsFor = plugin.id
                nextKitClick = UserDefaults.standard.string(forKey: Self.nextKitKey(plugin)).flatMap { text in
                    let parts = text.split(separator: ",").compactMap { Double($0) }
                    return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
                }
                selectedPad = min(selectedPad, TGI_PADS - 1)
                pluginWindow.show(loaded, bar: PluginWindowBar(model: self))
                watchKit(of: loaded)
                #if DEBUG
                if sampleOnceLoaded {
                    sampleOnceLoaded = false
                    if ProcessInfo.processInfo.arguments.contains("--every-kit") { makeEveryKit() } else { sample() }
                }
                #endif
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func showPluginWindow() {
        if let host { pluginWindow.show(host, bar: PluginWindowBar(model: self)) }
    }

    /// Follows the kit chosen in the plugin's window: its name is asked of the plugin about once a second, less often of a plugin
    /// that takes long to answer, and not while a sample is being taken.
    private func watchKit(of host: PluginHost) {
        kitWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.host === host else { return }
                var pause = 1.0
                if !self.isSampling {
                    let began = Date()
                    let name = host.presetName
                    pause = max(1, Date().timeIntervalSince(began) * 20)
                    if name != self.kit {
                        self.kit = name
                        // Another kit: the instrument is named after it, whatever was typed for the last one.
                        self.typedName = ""
                        // The pads play the plugin again: the result on show is another kit's.
                        self.hearInstrument = false
                        self.player?.stopAll()
                    }
                }
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    // MARK: Playing the pads

    /// A pad pressed (the mouse, a key, a MIDI keyboard): it sounds on the plugin, or on the finished instrument.
    func padDown(_ index: Int, velocity: Int? = nil) {
        guard setup.pads.indices.contains(index), let pad = setup.pads[index], !isSampling else { return }
        let v = velocity ?? Int(self.velocity.rounded())
        lit.insert(index)
        if hearInstrument, made != nil {
            player?.play(pad: index, velocity: v)
        } else {
            host?.noteOn(pad.note, velocity: v, channel: setup.channel)
        }
    }

    func padUp(_ index: Int) {
        lit.remove(index)
        guard setup.pads.indices.contains(index), let pad = setup.pads[index], !isSampling else { return }
        if !(hearInstrument && made != nil) { host?.noteOff(pad.note, channel: setup.channel) }
    }

    private func midiNote(_ note: MIDINote) {
        guard !isSampling else { return }
        if learning, note.on, setup.pads.indices.contains(selectedPad), setup.pads[selectedPad] != nil {
            setup.pads[selectedPad]?.note = note.note
            learning = false
        }
        if hearInstrument, made != nil {
            // The finished instrument has pads, not notes: the key plays the pad that was given its note.
            guard let index = setup.pads.firstIndex(where: { $0?.note == note.note }) else { return }
            if note.on { padDown(index, velocity: note.velocity) } else { padUp(index) }
        } else if note.on {
            host?.noteOn(note.note, velocity: note.velocity, channel: setup.channel)
        } else {
            host?.noteOff(note.note, channel: setup.channel)
        }
    }

    // MARK: The pads' setup

    func usePad(_ index: Int) {
        guard setup.pads.indices.contains(index), setup.pads[index] == nil else { return }
        setup.pads[index] = PadSetup(note: 60, label: "Pad \(index + 1)")
    }

    func clearPad(_ index: Int) {
        guard setup.pads.indices.contains(index) else { return }
        setup.pads[index] = nil
        for i in setup.pads.indices { setup.pads[i]?.cuts.removeAll { $0 == index } }
    }

    // MARK: Sampling

    func sample() { sample(inBatch: false) }

    private func sample(inBatch: Bool) {
        guard let host, inBatch ? (!isSampling && setup.sampleCount > 0) : canSample else {
            sampleEnded?.resume()
            sampleEnded = nil
            return
        }
        let setup = setup, realTime = realTime, cancel = cancel
        // The kit as the plugin names it at this moment, not a second ago.
        kit = host.presetName
        let name = name, madeWith = host.info.title, kitName = kit
        problem = nil
        made = nil
        player?.stopAll()
        player = nil
        hearInstrument = false
        lit = []
        cancel.withLock { $0 = false }
        phase = .sampling(done: 0, total: setup.sampleCount, label: "")
        host.allNotesOff()
        host.sampling = true
        host.offline = !realTime
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<(MadeInstrument, InstrumentPlayer), Error>
            do {
                let kit = try sampleKit(host, setup: setup, settings: CaptureSettings(), realTime: realTime, progress: { done, total, label in
                    Task { @MainActor in self?.progressed(done, total, label) }
                }, cancelled: { cancel.withLock { $0 } })
                let built = try buildInstrument(kit, setup: setup, name: name, madeWith: madeWith, id: UUID().uuidString,
                                                created: Date().formatted(Date.ISO8601FormatStyle()), sampleRate: host.sampleRate)
                let player = try InstrumentPlayer(instrument: built.instrument, audio: built.audio)
                let file = try writeTGI(built.instrument, audio: built.audio)
                var made = MadeInstrument(instrument: built.instrument, audio: built.audio, warnings: built.warnings,
                                          fileBytes: file.count, decodedBytes: player.decodedBytes, kit: kitName)
                // The instrument is written straight away, under its name, beside any earlier one of that name.
                do {
                    let url = freeInstrumentFile(built.instrument.name, in: madeInstrumentsFolder())
                    try file.write(to: url, options: .atomic)
                    made.savedTo = url
                } catch {
                    made.saveProblem = error.localizedDescription
                }
                outcome = .success((made, player))
            } catch {
                outcome = .failure(error)
            }
            await self?.finished(outcome, host: host)
        }
    }

    func cancelSampling() {
        batch = nil
        cancel.withLock { $0 = true }
    }

    // MARK: Every kit

    private static func nextKitKey(_ plugin: PluginInfo) -> String { "maker.nextKit.\(plugin.id)" }

    /// The user shows where the plugin's next-kit button is: their next click in the plugin's window is kept (and does what it
    /// does there). Called again while waiting, it stops waiting.
    func learnNextKitClick() {
        guard let host, !isSampling, batch == nil else { return }
        if learningNextKit {
            learningNextKit = false
            pluginWindow.stopWatchingClick()
            return
        }
        learningNextKit = true
        pluginWindow.show(host, bar: PluginWindowBar(model: self))
        pluginWindow.watchNextClick { [weak self] point in
            guard let self, self.learningNextKit, self.host === host else { return }
            self.learningNextKit = false
            self.nextKitClick = point
            UserDefaults.standard.set("\(point.x),\(point.y)", forKey: Self.nextKitKey(host.info))
        }
    }

    /// Makes the kit the plugin has, clicks to its next kit, and so on until the plugin has no other kit to show (the name stops
    /// changing, or one comes round again), or Cancel. A kit whose file is already in the folder is not made again, so a run that
    /// was stopped carries on where it was.
    func makeEveryKit() {
        guard let host, let click = nextKitClick, canSample else { return }
        batch = (0, 0)
        batchSummary = nil
        problem = nil
        typedName = ""
        Task {
            var seen = Set<String>()
            var madeCount = 0, skipped = 0
            var ended = "The plugin had no further kit."
            while batch != nil, self.host === host {
                guard let name = host.presetName else { ended = "The plugin stopped naming its kit."; break }
                guard seen.insert(name).inserted else { ended = "The kits came round to \(name) again."; break }
                guard seen.count <= MOST_KITS else { ended = "Stopped at \(MOST_KITS) kits."; break }
                kit = name
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(instrumentFileName(name)).path) {
                    skipped += 1
                } else {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        sampleEnded = done
                        sample(inBatch: true)
                    }
                    guard batch != nil else { ended = "Cancelled."; break }
                    guard problem == nil, made?.savedTo != nil else { ended = "Stopped at \(name)."; break }
                    madeCount += 1
                }
                batch = (madeCount, skipped)
                pluginWindow.click(at: click)
                // The plugin takes a moment to change kit; one that does not change has no further kit.
                var changed = false
                for _ in 0..<40 where !changed && batch != nil {
                    try? await Task.sleep(for: .milliseconds(200))
                    changed = host.presetName != name
                }
                guard batch != nil else { ended = "Cancelled."; break }
                guard changed else { break }
                try? await Task.sleep(for: .seconds(KIT_LOAD_SECONDS))
            }
            if batch == nil, !ended.hasPrefix("Stopped") { ended = "Cancelled." }
            batchSummary = "Every kit: \(madeCount) made\(skipped > 0 ? ", \(skipped) already there" : ""), \(placeName(folder)). \(ended)"
            #if DEBUG
            FileHandle.standardError.write(Data((batchSummary ?? "").appending("\n").utf8))
            #endif
            batch = nil
        }
    }

    // MARK: Room on this Mac

    /// An instrument written in iCloud Drive does not stay on this Mac's disk (the user, 2026-11-18): once iCloud has it, the copy
    /// here is given back. Looked at every few seconds until none is left.
    private func freeWhenUploaded(_ url: URL) {
        toFree.append(url)
        guard freeing == nil else { return }
        freeing = Task { [weak self] in
            while let self, !self.toFree.isEmpty {
                let waiting = self.toFree
                let freed = await Task.detached { waiting.filter { freeLocalCopy($0) || !FileManager.default.fileExists(atPath: $0.path) } }.value
                self.toFree.removeAll { freed.contains($0) }
                if !self.toFree.isEmpty { try? await Task.sleep(for: .seconds(5)) }
            }
            self?.freeing = nil
        }
    }

    // MARK: The folder

    private func useFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: FOLDER_KEY)
        } else {
            UserDefaults.standard.removeObject(forKey: FOLDER_KEY)
        }
        folder = madeInstrumentsFolder()
    }

    var folderIsDesktop: Bool { placeName(folder) == "on the Desktop" }
    var folderIsICloud: Bool { folder.standardizedFileURL.path == iCloudInstrumentsFolder()?.standardizedFileURL.path }
    var iCloudAvailable: Bool { iCloudInstrumentsFolder() != nil }

    func useDesktop() { useFolder(nil) }

    /// Instruments go to "TuneGod Instruments" in iCloud Drive, made if it is not there.
    func useICloud() {
        guard let url = iCloudInstrumentsFolder() else {
            problem = "iCloud Drive is not set up on this Mac."
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            useFolder(url)
        } catch {
            problem = "The folder could not be made in iCloud Drive. \(error.localizedDescription)"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Save here"
        if panel.runModal() == .OK, let url = panel.url { useFolder(url) }
    }

    private func progressed(_ done: Int, _ total: Int, _ label: String) {
        // A late report must not put a finished run back into sampling.
        if isSampling { phase = .sampling(done: done, total: total, label: label) }
    }

    private func finished(_ outcome: Result<(MadeInstrument, InstrumentPlayer), Error>, host: PluginHost) {
        host.allNotesOff()
        host.offline = false
        host.sampling = false
        phase = .setup
        defer {
            sampleEnded?.resume()
            sampleEnded = nil
        }
        switch outcome {
        case .success(let (instrument, player)):
            made = instrument
            self.player = player
            if let url = instrument.savedTo, isInICloud(url) { freeWhenUploaded(url) }
            // Between the kits of a run the pads stay the plugin's.
            hearInstrument = batch == nil
            if let saveProblem = instrument.saveProblem {
                problem = "The instrument was made but could not be written \(placeName(folder)). \(saveProblem) Use Save as\u{2026} to put it somewhere else."
            }
        case .failure(let error):
            if !(error is SamplingCancelled) { problem = error.localizedDescription }
        }
    }

    // MARK: Saving and sending

    /// The finished instrument's file, under the name it was made with.
    private func file() throws -> (name: String, data: Data) {
        guard let instrument = made?.instrument, let audio = made?.audio else { throw TGIError.damaged }
        return (instrumentFileName(instrument.name), try writeTGI(instrument, audio: audio))
    }

    func showInFinder() {
        if let url = made?.savedTo { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func save() {
        do {
            let file = try file()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            if let type = UTType(filenameExtension: TGI_EXTENSION) { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try file.data.write(to: url, options: .atomic)
        } catch {
            problem = "The instrument could not be saved. \(error.localizedDescription)"
        }
    }

    func airDrop() {
        do {
            // The file that was written is the one sent; one that was moved or never written is written again for sending.
            var url = made?.savedTo
            if url == nil || !FileManager.default.fileExists(atPath: url?.path ?? "") {
                let file = try file()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TuneGod instruments", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(file.name)
                try file.data.write(to: copy, options: .atomic)
                url = copy
            }
            guard let url else { throw TGIError.damaged }
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
                problem = "AirDrop is not available on this Mac right now. Save the instrument and send the file instead."
                return
            }
            service.perform(withItems: [url])
        } catch {
            problem = "The instrument could not be sent. \(error.localizedDescription)"
        }
    }

    /// The window is closing: nothing keeps sounding or sampling.
    func stop() {
        cancelSampling()
        host?.allNotesOff()
        player?.stopAll()
        lit = []
    }
}
