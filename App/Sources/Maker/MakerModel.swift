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
}

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

    var setup = KitSetup.standardDrums()
    var selectedPad = 12
    /// The next note played on a MIDI keyboard becomes the selected pad's note.
    var learning = false
    var realTime = false
    private(set) var phase = Phase.setup
    private(set) var made: MadeInstrument?
    /// Whether the pads play the finished instrument (as the phone will) or the plugin.
    var hearInstrument = false
    var velocity = 127.0
    var name = ""
    /// Pads that are sounding, for the grid to light.
    private(set) var lit = Set<Int>()

    private var live: LiveOutput?
    private var player: InstrumentPlayer?
    private var midi: MIDIInput?
    private let pluginWindow = PluginWindow()
    private let cancel = OSAllocatedUnfairLock(initialState: false)

    var plugin: PluginInfo? { plugins.first { $0.id == pluginID } }
    var isSampling: Bool { phase != .setup }
    var canSample: Bool { host != nil && !isSampling && setup.sampleCount > 0 }

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
        }
    }

    #if DEBUG
    private var sampleOnceLoaded = false

    /// For checking the window without a hand on the mouse (debug builds only): `--plugin <part of its name>` chooses a plugin,
    /// `--channel <n>` its MIDI channel, `--sample` presses Sample once it has loaded.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        let value = { (flag: String) in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let channel = value("--channel").flatMap(Int.init) { setup.channel = min(16, max(1, channel)) }
        if let wanted = value("--plugin")?.lowercased(), let plugin = plugins.first(where: { $0.title.lowercased().contains(wanted) }) {
            sampleOnceLoaded = args.contains("--sample")
            pluginID = plugin.id
        }
    }
    #endif

    // MARK: The plugin

    private func loadPlugin() {
        live?.stop()
        live = nil
        pluginWindow.close()
        host = nil
        problem = nil
        guard let plugin else { return }
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
                if name.isEmpty || plugins.contains(where: { $0.name == name }) { name = plugin.name }
                pluginWindow.show(loaded)
                #if DEBUG
                if sampleOnceLoaded {
                    sampleOnceLoaded = false
                    sample()
                }
                #endif
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func showPluginWindow() {
        if let host { pluginWindow.show(host) }
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

    func sample() {
        guard let host, canSample else { return }
        let setup = setup, realTime = realTime, cancel = cancel
        let name = name, madeWith = host.info.title
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
                outcome = .success((MadeInstrument(instrument: built.instrument, audio: built.audio, warnings: built.warnings,
                                                   fileBytes: file.count, decodedBytes: player.decodedBytes), player))
            } catch {
                outcome = .failure(error)
            }
            await self?.finished(outcome, host: host)
        }
    }

    func cancelSampling() {
        cancel.withLock { $0 = true }
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
        switch outcome {
        case .success(let (instrument, player)):
            made = instrument
            self.player = player
            hearInstrument = true
        case .failure(let error):
            if !(error is SamplingCancelled) { problem = error.localizedDescription }
        }
    }

    // MARK: Saving and sending

    /// The finished instrument's file, under the name it has now.
    private func file() throws -> (name: String, data: Data) {
        guard var instrument = made?.instrument, let audio = made?.audio else { throw TGIError.damaged }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        instrument.name = trimmed.isEmpty ? instrument.name : trimmed
        return (instrumentFileName(instrument.name), try writeTGI(instrument, audio: audio))
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
            let file = try file()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TuneGod instruments", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.name)
            try file.data.write(to: url, options: .atomic)
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
