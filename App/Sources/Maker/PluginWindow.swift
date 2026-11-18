// The plugin's own window, where the user chooses the kit or preset to sample. A plugin without a view of its own gets the
// system's list of its parameters.
import AppKit
import CoreAudioKit
import TuneGodSamplerKit

@MainActor
final class PluginWindow {
    private var window: NSWindow?
    private var shownFor: String?

    func show(_ host: PluginHost) {
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
