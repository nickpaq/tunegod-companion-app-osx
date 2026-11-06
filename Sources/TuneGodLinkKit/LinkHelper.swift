// The helper's engine: watches the cable once a second, opens the link to the first device whose TuneGod is listening, bridges the link's
// MIDI to the virtual "TuneGod" ports, and (until the driver exists) can play a test tone on the phone. The menu-bar app and `tglink`
// both run it.
#if os(macOS)
import Foundation

public final class LinkHelper: @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        /// Any device on the USB cable.
        case usb
        /// A TCP address: the phone simulator on this Mac, for testing.
        case direct(host: String, port: UInt16)
    }

    public struct State: Sendable, Equatable {
        public var devices: [USBMuxDevice] = []
        /// The device (UDID, or the address) the link is open to.
        public var connectedTo: String?
        public var stats: LinkMacSession.Stats?
        /// Why nothing is connected, in plain words.
        public var waiting: String = "Starting…"
        public var midiPorts = false
        public init() {}
    }

    public let target: Target
    public var onChange: (@Sendable (State) -> Void)?
    /// The phone's mic block (link reader thread).
    public var onAudioUp: (@Sendable (LinkAudio, LinkConfig) -> Void)?
    /// Audio for the phone instead of the test tone (link reader thread). The driver's output ring will plug in here.
    public var downSource: (@Sendable (_ sampleTime: UInt64, _ frames: Int, _ channels: Int) -> [Float])?

    private let appVersion: String
    private let lock = NSLock()
    private var _state = State()
    private var session: LinkMacSession?
    private var midi: LinkMIDIPorts?
    private var running = false
    private var _toneOn = false
    private let tone = ToneGenerator()

    public init(target: Target = .usb, appVersion: String, midiPorts: Bool = true) {
        self.target = target
        self.appVersion = appVersion
        if midiPorts, let ports = try? LinkMIDIPorts() {
            midi = ports
            _state.midiPorts = true
        }
    }

    public var state: State {
        lock.withLock {
            var s = _state
            s.stats = session?.stats
            return s
        }
    }

    public var toneOn: Bool {
        get { lock.withLock { _toneOn } }
        set { lock.withLock { _toneOn = newValue } }
    }

    public func start() {
        let first = lock.withLock { () -> Bool in
            defer { running = true }
            return !running
        }
        guard first else { return }
        midi?.onFromApps = { [weak self] bytes, ticks in
            self?.lock.withLock { self?.session }?.sendMIDI(bytes, hostTicks: ticks)
        }
        let watcher = Thread { [self] in watch() }
        watcher.name = "TuneGod Link watcher"
        watcher.start()
    }

    public func stop() {
        let s = lock.withLock { () -> LinkMacSession? in
            running = false
            defer { session = nil }
            return session
        }
        s?.stop()
    }

    // MARK: Watching

    private func watch() {
        while lock.withLock({ running }) {
            if lock.withLock({ session == nil }) { tryConnect() }
            onChange?(state)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func tryConnect() {
        switch target {
        case .direct(let host, let port):
            do {
                open(try LinkSocket.connectTCP(host: host, port: port), name: "\(host):\(port)")
            } catch {
                setWaiting("Nothing listening at \(host):\(port)")
            }
        case .usb:
            let devices: [USBMuxDevice]
            do {
                devices = try USBMux.devices()
            } catch {
                setWaiting("The Mac's device service is not answering: \(error)")
                return
            }
            lock.withLock { _state.devices = devices }
            guard !devices.isEmpty else {
                setWaiting("Connect the iPhone with a USB cable")
                return
            }
            var refused = false
            for device in devices {
                guard let (result, socket) = try? USBMux.connect(deviceID: device.id, port: LinkProtocol.port) else { continue }
                if result == .connected, let socket {
                    open(socket, name: device.serial)
                    return
                }
                if result == .refused { refused = true }
            }
            setWaiting(refused ? "Open TuneGod on the iPhone and turn on Mac Link" : "Waiting for the iPhone")
        }
    }

    private func open(_ socket: LinkSocket, name: String) {
        let s = LinkMacSession(socket: socket, appVersion: appVersion)
        s.downSource = { [weak self] t, frames, channels in
            guard let self else { return [Float](repeating: 0, count: frames * channels) }
            if let custom = self.downSource { return custom(t, frames, channels) }
            if self.toneOn { return self.tone.render(frames: frames, channels: channels) }
            return [Float](repeating: 0, count: frames * channels)
        }
        s.onAudioUp = { [weak self] audio, config in self?.onAudioUp?(audio, config) }
        s.onMIDI = { [weak self] bytes, ticks in self?.midi?.send(bytes, hostTicks: ticks) }
        s.onClosed = { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.session = nil
                self._state.connectedTo = nil
                self._state.waiting = error.map { "Link ended: \($0)" } ?? "Link ended"
            }
            self.onChange?(self.state)
        }
        lock.withLock {
            session = s
            _state.connectedTo = name
            _state.waiting = ""
        }
        s.start()
    }

    private func setWaiting(_ text: String) {
        lock.withLock {
            _state.connectedTo = nil
            _state.waiting = text
        }
    }
}
#endif
