// The plugin's own window, where the user browses and hears the plugin's kits. A plugin without a view of its own gets the
// system's list of its parameters. The window's title bar carries the maker's bar (`PluginWindowBar`): the chosen kit's name and
// Make instrument, so a kit is browsed, heard and made without leaving this window.
import AppKit
import CoreAudioKit
import SwiftUI
import TuneGodSamplerKit

@MainActor
final class PluginWindow {
    private var window: NSWindow?
    private var shownFor: String?

    func show(_ host: PluginHost, bar: PluginWindowBar) {
        if let window, shownFor == host.info.id {
            window.makeKeyAndOrderFront(nil)
            return
        }
        close()
        shownFor = host.info.id
        let id = host.info.id, title = host.info.name, unit = host.unit
        unit.requestViewController { controller in
            DispatchQueue.main.async { [weak self] in
                // Closed, or another plugin chosen, while the view was being made.
                guard let self, self.shownFor == id, self.window == nil else { return }
                let content: NSViewController
                if let controller {
                    content = controller
                } else {
                    let generic = AUGenericViewController()
                    generic.auAudioUnit = unit
                    content = generic
                }
                let window = NSWindow(contentViewController: content)
                window.title = title
                window.styleMask = controller == nil ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
                window.isReleasedWhenClosed = false
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .trailing
                let hosting = NSHostingView(rootView: bar)
                hosting.frame.size = hosting.fittingSize
                accessory.view = hosting
                window.addTitlebarAccessoryViewController(accessory)
                window.makeKeyAndOrderFront(nil)
                self.window = window
            }
        }
    }

    func close() {
        window?.close()
        window = nil
        shownFor = nil
    }
}

/// What the plugin's window carries in its title bar: the instrument's name (the kit chosen in the plugin) and the one button
/// that makes it, then where the file is and AirDrop.
struct PluginWindowBar: View {
    let model: MakerModel

    var body: some View {
        HStack(spacing: 8) {
            if case .sampling(let done, let total, _) = model.phase {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .frame(width: 120)
                Text("\(done) of \(total)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { model.cancelSampling() }
            } else if model.madeIsCurrent, let made = model.made {
                Text(made.savedTo.map { "\($0.lastPathComponent) is on the Desktop" } ?? made.instrument.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Make again") { model.sample() }
                    .disabled(!model.canSample)
                Button("AirDrop") { model.airDrop() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text(model.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Make instrument") { model.sample() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSample)
                    .help("Samples this kit and writes it on the Desktop as a TuneGod instrument with the kit\u{2019}s name.")
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.trailing, 10)
        .frame(height: 28)
        .fixedSize()
    }
}
