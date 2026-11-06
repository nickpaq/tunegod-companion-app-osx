// tglink: the companion's engine from the command line, for testing the link.
//   tglink devices                      list the devices on the USB cable
//   tglink connect [--direct HOST:PORT] [--tone] [--seconds N]
//                                       open the link (the cable, or a TCP address), print its numbers once a second
//   tglink phone-sim [--port N] [--midi]
//                                       play the phone's part on this Mac
//   tglink device-test [--seconds N]    play a tone into "TuneGod iPhone" and measure its input
import Foundation
import TuneGodLinkKit

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fmt(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }

switch args.first {
case "devices":
    do {
        let devices = try USBMux.devices(includeNetwork: args.contains("--all"))
        if devices.isEmpty { print("No devices on the cable.") }
        for d in devices { print("\(d.id)\t\(d.connectionType)\t\(d.serial)\tproduct \(d.productID.map(String.init) ?? "?")") }
    } catch {
        print("error: \(error)")
        exit(1)
    }

case "connect":
    var target = LinkHelper.Target.usb
    if let direct = value("--direct") {
        let parts = direct.split(separator: ":")
        target = .direct(host: String(parts.first ?? "127.0.0.1"),
                         port: parts.count > 1 ? UInt16(parts[1]) ?? LinkProtocol.port : LinkProtocol.port)
    }
    let helper = LinkHelper(target: target, appVersion: "tglink")
    helper.toneOn = args.contains("--tone")
    let seconds = value("--seconds").flatMap(Double.init)
    let started = Date()
    helper.onChange = { state in
        guard let s = state.stats, state.connectedTo != nil else {
            print("waiting: \(state.waiting)")
            return
        }
        let c = s.config
        let status = s.phoneStatus
        print("""
            \(state.connectedTo!) phone \(s.phoneVersion ?? "?") \
            \(c.map { "\($0.sampleRate) Hz \($0.framesPerPacket)f io \($0.ioBufferFrames)f" } ?? "no config") \
            | up \(s.packetsUp) down \(s.packetsDown) \
            | rtt \(fmt(s.roundTripMs, 2)) ms lead \(s.downLeadFrames)f \
            | down ≈\(fmt(s.downLatencyMs)) ms up ≈\(fmt(s.upLatencyMs)) ms \
            | rate \(fmt(s.measuredRate, 2)) resets \(s.clockResets) \
            | phone underruns \(status?.underruns ?? 0) late \(status?.latePackets ?? 0) buffered \(status?.bufferedFrames ?? 0)f \
            | midi up \(s.midiUp) down \(s.midiDown) | driver \(state.driverConnected ? "on" : "off")
            """)
    }
    helper.onAudioUp = nil
    helper.start()
    while seconds.map({ Date().timeIntervalSince(started) < $0 }) ?? true { Thread.sleep(forTimeInterval: 0.25) }
    helper.stop()
    Thread.sleep(forTimeInterval: 0.2)

case "device-test":
    exit(DeviceTest.run(seconds: value("--seconds").flatMap(Double.init) ?? 6))

case "phone-sim":
    let port = value("--port").flatMap(UInt16.init) ?? LinkProtocol.port
    let sim = LinkPhoneSimulator(port: port)
    sim.sendMIDINotes = args.contains("--midi")
    sim.onLog = { print($0) }
    sim.onReport = { r in
        print("sim: packets \(r.packets) rate \(String(format: "%.1f", r.effectiveRate)) received rms \(String(format: "%.3f", r.receivedRMS)) underruns \(r.underruns) late \(r.late) "
            + "buffered \(r.bufferedFrames)f midi in \(r.midiReceived)")
    }
    do {
        try sim.run()
    } catch {
        print("error: \(error)")
        exit(1)
    }

default:
    print("""
        usage:
          tglink devices [--all]
          tglink connect [--direct HOST:PORT] [--tone] [--seconds N]
          tglink phone-sim [--port N] [--midi]
          tglink device-test [--seconds N]
        """)
}
