// The plugin's own window, where the user browses and hears the plugin's kits. A plugin without a view of its own gets the
// system's list of its parameters. The window's title bar carries the maker's bar (`PluginWindowBar`): the chosen kit's name and
// Make instrument, so a kit is browsed, heard and made without leaving this window.
import AppKit
import ApplicationServices
import CoreAudioKit
import SwiftUI
import TuneGodSamplerKit

@MainActor
final class PluginWindow {
    private var window: NSWindow?
    private var shownFor: String?
    /// The plugin's own view and its controller, kept while the window shows them, and the watch on the view's size.
    private var controller: NSViewController?
    private var pluginView: NSView?
    private var sizeWatch: NSObjectProtocol?

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
                let window: NSWindow
                if let controller {
                    // The plugin's view keeps the size the plugin gives it, at the top left of a plain view, and the window follows
                    // it: a plugin that changes its own size (a scale setting, a panel that opens) is never cut off by the window.
                    let view = controller.view
                    let size = view.frame.size.width > 1 ? view.frame.size : controller.preferredContentSize
                    let holder = TopLeftView(frame: NSRect(origin: .zero, size: size))
                    view.autoresizingMask = []
                    view.frame = NSRect(origin: .zero, size: size)
                    holder.addSubview(view)
                    window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                                      backing: .buffered, defer: false)
                    window.contentView = holder
                    window.center()
                    view.postsFrameChangedNotifications = true
                    self.sizeWatch = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak window, weak view] _ in
                        MainActor.assumeIsolated {
                            guard let window, let view, view.frame.size.width > 1, view.frame.size.height > 1 else { return }
                            if view.frame.origin != .zero { view.setFrameOrigin(.zero) }
                            guard let shown = window.contentView?.frame.size,
                                  abs(shown.width - view.frame.width) > 0.5 || abs(shown.height - view.frame.height) > 0.5 else { return }
                            // The top left corner stays where it is.
                            let top = window.frame.maxY
                            window.setContentSize(view.frame.size)
                            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
                        }
                    }
                    self.controller = controller
                    self.pluginView = view
                } else {
                    let generic = AUGenericViewController()
                    generic.auAudioUnit = unit
                    window = NSWindow(contentViewController: generic)
                    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                }
                window.title = title
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

    // MARK: Clicks in the plugin's view

    private var clickMonitor: Any?

    /// A point of the plugin's view, measured from its top left, as the window has it.
    private func windowPoint(_ point: CGPoint, in content: NSView) -> NSPoint {
        content.convert(NSPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y), to: nil)
    }

    /// Tells `found` where the next click inside the plugin's view lands (points from its top left). The click goes on to the
    /// plugin as any click does.
    func watchNextClick(_ found: @escaping (CGPoint) -> Void) {
        stopWatchingClick()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let content = self.pluginView ?? window.contentView else { return event }
            let at = content.convert(event.locationInWindow, from: nil)
            guard content.bounds.contains(at) else { return event }
            self.stopWatchingClick()
            found(CGPoint(x: at.x, y: content.isFlipped ? at.y : content.bounds.height - at.y))
            return event
        }
    }

    func stopWatchingClick() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Clicks the plugin's view at `point` (points from its top left). A plugin that draws its own controls asks the system
    /// where the pointer is, so the pointer is put there for the click and put back after. Where the user has let the companion
    /// control the Mac (Accessibility) the click is a real one; otherwise the events are handed to the window.
    func click(at point: CGPoint) {
        guard let window, let content = pluginView ?? window.contentView, let screen = NSScreen.screens.first else { return }
        window.makeKeyAndOrderFront(nil)
        let location = windowPoint(point, in: content)
        let onScreen = window.convertPoint(toScreen: location)
        // The system's events measure from the top left of the first screen.
        let target = CGPoint(x: onScreen.x, y: screen.frame.height - onScreen.y)
        let was = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(target)
        defer { if let was { CGWarpMouseCursorPosition(was) } }
        if AXIsProcessTrusted() {
            let source = CGEventSource(stateID: .hidSystemState)
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(60_000)
            }
            return
        }
        usleep(40_000)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
            usleep(40_000)
        }
    }

    func close() {
        stopWatchingClick()
        if let sizeWatch { NotificationCenter.default.removeObserver(sizeWatch) }
        sizeWatch = nil
        pluginView?.removeFromSuperview()
        pluginView = nil
        controller = nil
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
            if model.learningNextKit {
                Text("Click the button that goes to the next kit").foregroundStyle(.secondary)
                Button("Cancel") { model.learnNextKitClick() }
            } else if let batch = model.batch {
                if case .sampling(let done, let total, _) = model.phase {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                        .frame(width: 80)
                }
                Text("\(model.kit ?? "") · kit \(batch.made + batch.skipped + 1)").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                Button("Stop") { model.cancelSampling() }
            } else if case .sampling(let done, let total, _) = model.phase {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .frame(width: 120)
                Text("\(done) of \(total)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { model.cancelSampling() }
            } else if model.madeIsCurrent, let made = model.made {
                Text(made.savedTo.map { "\($0.lastPathComponent) is \(placeName($0.deletingLastPathComponent()))" } ?? made.instrument.name)
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
                    .help("Samples this kit and writes it \(placeName(model.folder)) as a TuneGod instrument with the kit\u{2019}s name.")
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.trailing, 10)
        .frame(height: 28)
        .fixedSize()
    }
}

/// A plain view measured from its top left, so the plugin's view sits in that corner whatever its size.
private final class TopLeftView: NSView {
    override var isFlipped: Bool { true }
}
