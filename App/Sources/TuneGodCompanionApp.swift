// TuneGod Companion: a menu-bar app that keeps the link to the iPhone open over the USB cable. For now it carries MIDI (the "TuneGod" ports)
// and a test tone; the audio device for Ableton comes with the driver.
import SwiftUI
import TuneGodLinkKit

@main
struct TuneGodCompanionApp: App {
    @State private var link = LinkController()

    var body: some Scene {
        MenuBarExtra {
            LinkMenu(link: link)
        } label: {
            Image(systemName: link.connected ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor @Observable
final class LinkController {
    private(set) var state = LinkHelper.State()
    var toneOn = false {
        didSet { helper.toneOn = toneOn }
    }
    var connected: Bool { state.connectedTo != nil }
    private let helper: LinkHelper

    init() {
        // `--simulator` connects to `tglink phone-sim` on this Mac instead of the cable.
        let target: LinkHelper.Target = ProcessInfo.processInfo.arguments.contains("--simulator")
            ? .direct(host: "127.0.0.1", port: LinkProtocol.port) : .usb
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        helper = LinkHelper(target: target, appVersion: "companion \(version)")
        helper.onChange = { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
        helper.start()
    }
}

struct LinkMenu: View {
    let link: LinkController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TuneGod Companion").font(.headline)
            if let to = link.state.connectedTo, let s = link.state.stats {
                Label("Connected to \(s.phoneVersion ?? "TuneGod")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(to).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("To the phone", ms(s.downLatencyMs))
                    row("From the phone", ms(s.upLatencyMs))
                    row("Round trip", ms(s.roundTripMs, digits: 2))
                    row("Dropouts", "\(s.phoneStatus?.underruns ?? 0)")
                    row("Sample rate", s.config.map { "\($0.sampleRate) Hz" } ?? "–")
                    row("Buffer", s.config.map { "\($0.ioBufferFrames) frames" } ?? "–")
                    row("MIDI", "\(s.midiUp) in · \(s.midiDown) out")
                }
                .font(.callout.monospacedDigit())
                Toggle("Test tone on the phone", isOn: Binding(get: { link.toneOn }, set: { link.toneOn = $0 }))
            } else {
                Label(link.state.waiting, systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Label(link.state.midiPorts ? "MIDI port \u{201C}TuneGod\u{201D} is ready" : "MIDI ports unavailable",
                  systemImage: "pianokeys")
                .font(.callout)
            Label("Audio device: coming with the driver", systemImage: "speaker.wave.2")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func ms(_ v: Double?, digits: Int = 1) -> String {
        v.map { String(format: "%.\(digits)f ms", $0) } ?? "–"
    }
}
