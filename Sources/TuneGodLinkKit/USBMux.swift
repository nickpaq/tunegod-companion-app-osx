// The Mac's device multiplexer: the system service that carries connections to iPhones and iPads over the USB cable (the same path Xcode
// uses). Requests are property lists on its Unix socket, each behind a 16-byte header (total length, version 1, type 8 = plist, tag).
// After a successful Connect the socket stops speaking plists and becomes a byte tunnel to the port on the device.
#if os(macOS)
import Foundation

public struct USBMuxDevice: Equatable, Sendable, Identifiable {
    public let id: Int
    /// The device's identifier (its UDID).
    public let serial: String
    /// "USB" over the cable; "Network" for devices paired over Wi-Fi.
    public let connectionType: String
    public let productID: Int?
}

public enum USBMux {
    public static let socketPath = "/var/run/usbmuxd"

    public enum ConnectResult: Equatable, Sendable {
        case connected
        case refused          // nothing listening on that port (TuneGod not in Mac Link mode)
        case badDevice        // device gone
        case other(Int)
    }

    /// Devices attached now. Only cable-connected ones unless `includeNetwork`.
    public static func devices(includeNetwork: Bool = false) throws -> [USBMuxDevice] {
        let sock = try LinkSocket.connectUnix(path: socketPath)
        defer { sock.close() }
        try send(sock, ["MessageType": "ListDevices"], tag: 1)
        let reply = try readMessage(sock)
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap { entry -> USBMuxDevice? in
            let props = entry["Properties"] as? [String: Any] ?? [:]
            guard let id = (entry["DeviceID"] as? Int) ?? (props["DeviceID"] as? Int) else { return nil }
            let type = props["ConnectionType"] as? String ?? "USB"
            guard includeNetwork || type == "USB" else { return nil }
            return USBMuxDevice(id: id, serial: props["SerialNumber"] as? String ?? "", connectionType: type,
                                productID: props["ProductID"] as? Int)
        }
    }

    /// Opens a tunnel to `port` on the device. On success the returned socket carries the device port's bytes.
    public static func connect(deviceID: Int, port: UInt16) throws -> (ConnectResult, LinkSocket?) {
        let sock = try LinkSocket.connectUnix(path: socketPath)
        // The port goes in network byte order, read as a host integer.
        try send(sock, ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)], tag: 2)
        let reply = try readMessage(sock)
        let number = reply["Number"] as? Int ?? -1
        switch number {
        case 0: return (.connected, sock)
        case 3:
            sock.close()
            return (.refused, nil)
        case 2:
            sock.close()
            return (.badDevice, nil)
        default:
            sock.close()
            return (.other(number), nil)
        }
    }

    // MARK: Plist messages

    private static func send(_ sock: LinkSocket, _ fields: [String: Any], tag: UInt32) throws {
        var dict = fields
        dict["ClientVersionString"] = "tunegod-link"
        dict["ProgName"] = "TuneGodLink"
        dict["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        var w = ByteWriter()
        w.u32(UInt32(16 + body.count))
        w.u32(1)
        w.u32(8)
        w.u32(tag)
        w.raw(body)
        try sock.send(w.bytes)
    }

    private static func readMessage(_ sock: LinkSocket) throws -> [String: Any] {
        let header = try sock.readExactly(16)
        var r = ByteReader(header[...])
        let length = Int(try r.u32())
        guard length >= 16, length < 1 << 24 else { throw LinkError.usbmux("bad reply from the device service") }
        let body = try sock.readExactly(length - 16)
        let plist = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil)
        guard let dict = plist as? [String: Any] else { throw LinkError.usbmux("bad reply from the device service") }
        return dict
    }
}
#endif
