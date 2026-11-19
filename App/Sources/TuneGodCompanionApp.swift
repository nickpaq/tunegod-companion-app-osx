// TuneGod Companion: a menu-bar app that keeps the link to the iPhone open over the USB cable and carries it to the "TuneGod iPhone" audio
// device (the driver) and the "TuneGod" MIDI ports. Its menu also opens Make instrument (App/Sources/Maker), which samples a plugin
// into a TuneGod instrument for the phone. Opened from the Dock, Launchpad or Finder it is the instrument maker: the window opens, and
// the app is in the Dock while the window is open (in the menu bar only once it is closed).
import SwiftUI
import TuneGodLinkKit

/// The Make instrument window's scene.
let MAKER_WINDOW = "maker"

extension Notification.Name {
    /// The app's icon was clicked in the Dock or Launchpad while it runs: Make instrument opens (or comes to the front).
    static let openMaker = Notification.Name("app.tunegod.companion.openMaker")
}

final class CompanionDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMaker, object: nil)
        return false
    }
}

/// The menu bar's icon. It is always there, so it is what opens Make instrument when the Dock asks.
struct MenuBarIcon: View {
    let connected: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "iphone")
            .onReceive(NotificationCenter.default.publisher(for: .openMaker)) { _ in
                openWindow(id: MAKER_WINDOW)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

@main
struct TuneGodCompanionApp: App {
    @State private var link = LinkController()
    @State private var maker = MakerModel()
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            LinkMenu(link: link)
        } label: {
            MenuBarIcon(connected: link.connected)
        }
        .menuBarExtraStyle(.window)

        Window("Make instrument", id: MAKER_WINDOW) {
            MakerWindow(model: maker)
                // In the Dock (and the app switcher) while the window is open, with the app's icon; back to the menu bar after.
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .onDisappear { NSApplication.shared.setActivationPolicy(.accessory) }
        }
        .windowResizability(.contentSize)
        // Opening the app (the Dock, Launchpad, Finder) opens the instrument maker; the link runs in the menu bar either way.
        .defaultLaunchBehavior(.presented)
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
    @Environment(\.openWindow) private var openWindow

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
            Label(link.state.driverConnected ? "Audio device \u{201C}TuneGod iPhone\u{201D} is ready"
                  : link.state.driverPortBusy ? "Another copy of the companion is running"
                  : "Audio driver not installed", systemImage: "speaker.wave.2")
                .font(.callout)
                .foregroundStyle(link.state.driverConnected ? .primary : .secondary)
            Divider()
            Button("Make instrument\u{2026}") {
                openWindow(id: MAKER_WINDOW)
                // A menu-bar app is not in front by itself.
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
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
