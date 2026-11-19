// Make instrument: one window, top to bottom. Pick the plugin (its own window opens, where its kits are browsed and heard), choose
// Pads or Keys, say once which of its notes falls on which pad (pads) or which range is sampled and how closely (keys), then Make
// instrument: it is sampled and written as a .tgi named after the kit, to listen to and AirDrop to the phone. The plugin and its pads
// are remembered, so the next time it is browse, then one button. Pads and keys go through the same steps.
import SwiftUI
import TuneGodSamplerKit

struct MakerWindow: View {
    @Bindable var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PluginRow(model: model)
            Divider()
            Picker("Instrument", selection: $model.kind) {
                Text("Pads").tag(TGIKind.pads)
                Text("Keys").tag(TGIKind.keys)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.isSampling || model.batch != nil)
            .help("Pads: a drum kit on TuneGod\u{2019}s 16 pads. Keys: a keyboard instrument, sampled across a range of notes.")
            Group {
                if model.kind == .pads {
                    HStack(alignment: .top, spacing: 18) {
                        PadGridView(model: model)
                        PadSettings(model: model)
                            .frame(width: 250, alignment: .topLeading)
                    }
                } else {
                    KeysSettings(model: model)
                }
            }
            .disabled(model.isSampling)
            AuditionRow(model: model)
                .disabled(model.isSampling)
            Divider()
            SamplingRow(model: model)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let made = model.made {
                Divider()
                ResultSection(model: model, made: made)
            }
        }
        .padding(18)
        .frame(width: 668)
        .fixedSize(horizontal: false, vertical: true)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - The plugin

private struct PluginRow: View {
    @Bindable var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Plugin", selection: $model.pluginID) {
                    Text("Choose a plugin").tag(String?.none)
                    ForEach(model.plugins) { plugin in
                        Text(plugin.title).tag(String?.some(plugin.id))
                    }
                }
                .frame(maxWidth: 360)
                Picker("MIDI channel", selection: $model.channel) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                .help("The channel the notes are sent on. Instruments with several parts keep drums on channel 10.")
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Show plugin window") { model.showPluginWindow() }
                        .disabled(model.host == nil)
                }
            }
            .disabled(model.isSampling)
            Text(model.host == nil
                 ? "Audio Unit instruments installed on this Mac. Choose the one to sample."
                 : model.kind == .pads
                    ? "Browse the kits in the plugin\u{2019}s window. Click the pads to hear what each one will record."
                    : "Browse the sounds in the plugin\u{2019}s window. Play the keyboard to hear them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - The selected pad

private struct PadSettings: View {
    @Bindable var model: MakerModel

    var body: some View {
        let index = model.selectedPad
        VStack(alignment: .leading, spacing: 10) {
            Text("Pad \(index + 1)").font(.headline)
            if model.setup.pads[index] != nil {
                let pad = Binding(get: { model.setup.pads[index] ?? PadSetup(note: 60, label: "") },
                                  set: { model.setup.pads[index] = $0 })
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Label").foregroundStyle(.secondary)
                        // Typing a drum's name sets the pad's Type with it (`PadSetup.rename`).
                        TextField("Label", text: Binding(get: { pad.wrappedValue.label }, set: { model.setup.pads[index]?.rename($0) }))
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Note").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Stepper(value: pad.note, in: 0...127) {
                                Text("\(pad.wrappedValue.note) · \(noteName(pad.wrappedValue.note))").monospacedDigit()
                            }
                            Toggle(model.learning ? "Play a key\u{2026}" : "Learn", isOn: $model.learning)
                                .toggleStyle(.button)
                                .help("Sets this pad\u{2019}s note to the next key played on a MIDI keyboard.")
                        }
                    }
                    GridRow {
                        Text("Type").foregroundStyle(.secondary)
                        Picker("Type", selection: pad.type) {
                            Text("None").tag(String?.none)
                            ForEach(padTypes, id: \.id) { Text($0.label).tag(String?.some($0.id.rawValue)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Cuts").foregroundStyle(.secondary)
                        CutsMenu(model: model, index: index)
                    }
                }
                Button("Clear pad", role: .destructive) { model.clearPad(index) }
            } else {
                Text("This pad is empty. It will be empty on the phone too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use this pad") { model.usePad(index) }
            }
        }
    }

    /// The sound Types a pad can have: TuneGod's own, without the loops.
    private var padTypes: [(id: CategoryId, label: String)] {
        CATEGORIES.filter { !$0.id.rawValue.hasSuffix("Loop") && $0.id != .other }.map { ($0.id, $0.label) }
    }
}

/// Which pads the selected pad silences when it plays (a closed hat cutting the open hat).
private struct CutsMenu: View {
    @Bindable var model: MakerModel
    let index: Int

    var body: some View {
        let cuts = model.setup.pads[index]?.cuts ?? []
        let names = cuts.compactMap { model.setup.pads[$0]?.label }
        Menu(names.isEmpty ? "Nothing" : names.joined(separator: ", ")) {
            ForEach(0..<16, id: \.self) { other in
                if other != index, let pad = model.setup.pads[other] {
                    Toggle(pad.label.isEmpty ? "Pad \(other + 1)" : pad.label, isOn: Binding(
                        get: { cuts.contains(other) },
                        set: { on in
                            if on { model.setup.pads[index]?.cuts.append(other) } else { model.setup.pads[index]?.cuts.removeAll { $0 == other } }
                        }))
                }
            }
        }
        .fixedSize()
        .help("The pads this one silences when it plays.")
    }
}

// MARK: - Hearing the pads

/// How hard a click or a key plays a pad, and, once there is a result, whether the pads play it or the plugin.
private struct AuditionRow: View {
    @Bindable var model: MakerModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Velocity")
            Slider(value: $model.velocity, in: 1...127)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Velocity")
                .help("How hard a click or a computer key plays. A MIDI keyboard plays at its own.")
            Text("\(Int(model.velocity.rounded()))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Spacer()
            if model.made != nil {
                Picker(model.kind == .pads ? "Pads play" : "Keys play", selection: $model.hearInstrument) {
                    Text("The instrument").tag(true)
                    Text("The plugin").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("The instrument is what the phone will play; the plugin is what it was sampled from.")
            }
        }
    }
}

// MARK: - Sampling

private struct SamplingRow: View {
    @Bindable var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                if model.kind == .pads {
                    Stepper("Velocity layers: \(model.setup.layerCount)", value: $model.setup.layers, in: 1...MAX_LAYERS)
                        .help("How many strengths each pad is recorded at. More layers follow the plugin more closely and make a larger instrument.")
                    Stepper("Alternates: \(model.setup.alternateCount)", value: $model.setup.alternates, in: 1...MAX_ALTERNATES)
                        .help("How many times each hit is recorded, for plugins that vary a hit each time it is played.")
                }
                Toggle("Real time", isOn: $model.realTime)
                    .help("Records at playing speed. Turn it on for a plugin that sounds wrong when recorded faster.")
            }
            .disabled(model.isSampling)
            HStack(spacing: 10) {
                Text("Name")
                TextField("Name", text: $model.name)
                    .labelsHidden()
                    .frame(width: 240)
                    .help("The instrument\u{2019}s name on the phone, and its file\u{2019}s. It follows the kit chosen in the plugin until another is typed.")
                Text(model.kit == nil ? "This plugin does not name its kit. Type the name here."
                     : "The kit chosen in the plugin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isSampling || model.host == nil)
            EveryKitRow(model: model)
            if case .sampling(let done, let total, let label) = model.phase {
                HStack(spacing: 12) {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text(label.isEmpty ? "\(done) of \(total)" : "\(min(done + 1, total)) of \(total) · \(label)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                    Button("Cancel") { model.cancelSampling() }
                }
            } else {
                HStack(spacing: 12) {
                    // The window's one prominent button is the next step: Make instrument, then AirDrop once this kit is made.
                    if model.madeIsCurrent {
                        Button("Make again") { model.sample() }
                            .disabled(!model.canSample)
                    } else {
                        Button("Make instrument") { model.sample() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canSample)
                    }
                    Text(estimate)
                        .font(.callout)
                        .foregroundStyle(tooLarge ? .orange : .secondary)
                        .help(tooLarge ? "That is a lot of the phone\u{2019}s memory. Fewer samples an octave, fewer layers or a shorter hold make it smaller." : "")
                }
            }
        }
    }

    /// How many hits will be recorded and roughly how long that takes at playing speed (about three seconds a hit; a note is held
    /// for its hold, then released, about two seconds more). Keys also say roughly how large the instrument will be on the phone.
    private var estimate: String {
        let count = model.sampleCount
        guard count > 0 else { return "No pad has a note." }
        let each = model.kind == .pads ? 3.0 : model.keys.holdLength + 2
        let seconds = Int(Double(count) * each)
        let time = seconds < 90 ? "\(seconds) seconds" : "\(Int((Double(seconds) / 60).rounded())) minutes"
        guard model.kind == .keys else { return "\(count) hits. About \(time) in real time, much less otherwise." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(model.estimatedKeysBytes), countStyle: .memory)
        return "\(count) samples, about \(size) on the phone. About \(time) in real time, much less otherwise."
    }

    private var tooLarge: Bool { model.kind == .keys && model.estimatedKeysBytes > PHONE_MEMORY_WARNING_BYTES }
}

/// Where instruments are written, and Make every kit: the plugin's kits one after another, by repeating the click the user shows.
private struct EveryKitRow: View {
    @Bindable var model: MakerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Save")
                Menu(placeName(model.folder)) {
                    Toggle("On the Desktop", isOn: Binding(get: { model.folderIsDesktop }, set: { _ in model.useDesktop() }))
                    Toggle("In iCloud Drive (TuneGod Instruments)", isOn: Binding(get: { model.folderIsICloud }, set: { _ in model.useICloud() }))
                        .disabled(!model.iCloudAvailable)
                    Divider()
                    Button("Choose a folder\u{2026}") { model.chooseFolder() }
                }
                .fixedSize()
                .help("Where a made instrument\u{2019}s file is written. A folder in iCloud Drive shows in the Files app on the phone.")
                Spacer()
                Button(model.learningNextKit ? "Click it in the plugin\u{2026}" : model.nextKitClick == nil ? "Show the next-kit button\u{2026}" : "Next-kit button set")
                    { model.learnNextKitClick() }
                    .help("Then click, in the plugin\u{2019}s window, the button that goes to its next kit. Make every kit repeats that click.")
                if model.batch == nil {
                    Button("Make every kit") { model.makeEveryKit() }
                        .disabled(!model.canMakeEveryKit)
                        .help("Makes this kit, goes to the next and makes it, until the plugin has no further kit. Kits already in the folder are passed over.")
                } else {
                    Button("Stop") { model.cancelSampling() }
                }
            }
            if model.waitingForICloud > 0 {
                Text("\(model.waitingForICloud) \(model.waitingForICloud == 1 ? "instrument is" : "instruments are") going up to iCloud. Each leaves this Mac\u{2019}s disk once it is there; keep the companion open until then.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let batch = model.batch {
                Text("Every kit: \(batch.made) made\(batch.skipped > 0 ? ", \(batch.skipped) already there" : ""). Now \(model.kit ?? "the next").")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let summary = model.batchSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.host == nil)
    }
}

// MARK: - The result

private struct ResultSection: View {
    @Bindable var model: MakerModel
    let made: MadeInstrument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(made.warnings + sizeWarning, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(made.savedTo.map { "\($0.lastPathComponent) is \(placeName($0.deletingLastPathComponent()))" } ?? made.instrument.name)
                        .font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if made.savedTo != nil {
                    Button("Show in Finder") { model.showInFinder() }
                }
                Button("Save as\u{2026}") { model.save() }
                if model.madeIsCurrent {
                    Button("AirDrop") { model.airDrop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("AirDrop") { model.airDrop() }
                }
            }
        }
    }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(made.fileBytes), countStyle: .file)
        if made.instrument.kind == .keys {
            return "\((made.instrument.zones ?? []).count) notes, \(made.audio.count) samples, \(size)"
        }
        let pads = (made.instrument.pads ?? []).compactMap { $0 }
        return "\(pads.count) pads, \(made.audio.count) hits, \(size)"
    }

    private var sizeWarning: [String] {
        guard made.decodedBytes > PHONE_MEMORY_WARNING_BYTES else { return [] }
        let size = ByteCountFormatter.string(fromByteCount: Int64(made.decodedBytes), countStyle: .memory)
        let fewer = made.instrument.kind == .keys ? "Fewer samples an octave, fewer layers or a shorter hold" : "Fewer layers or alternates"
        return ["This instrument takes about \(size) of the phone\u{2019}s memory while a project uses it. \(fewer) make it smaller."]
    }
}
