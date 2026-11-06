// The Mac's virtual MIDI ports named "TuneGod": a source that apps such as Ableton read (TuneGod's pads, sequencer and beat repeats) and a
// destination they write to (sent on to the phone). CoreMIDI carries Universal MIDI Packets; the link carries MIDI 1.0 bytes (MIDIUMP).
#if os(macOS)
import CoreMIDI
import Foundation

public final class LinkMIDIPorts: @unchecked Sendable {
    /// MIDI apps sent to the "TuneGod" destination: the bytes and their host time in ticks (0 = now). CoreMIDI's thread.
    public var onFromApps: (@Sendable ([UInt8], UInt64) -> Void)?

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    public init(name: String = "TuneGod") throws {
        var status = MIDIClientCreateWithBlock("TuneGod Link" as CFString, &client, nil)
        guard status == noErr else { throw LinkError.usbmux("MIDI client could not be created (\(status))") }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else { throw LinkError.usbmux("MIDI source could not be created (\(status))") }
        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { throw LinkError.usbmux("MIDI destination could not be created (\(status))") }
        // A stable identity so MIDI apps remember their settings for the port between launches.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x5447_4C31)  // "TGL1"
        MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, 0x5447_4C32)  // "TGL2"
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIEndpointDispose(destination)
        MIDIClientDispose(client)
    }

    /// Bytes from the phone out of the "TuneGod" source at `hostTicks` (0 = now).
    public func send(_ bytes: [UInt8], hostTicks: UInt64) {
        let messages = MIDIUMP.messages(fromBytes: bytes)
        // One list per message (a message is at most two words, far under a list's room), so a list never overflows.
        for words in messages {
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            _ = words.withUnsafeBufferPointer {
                MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, hostTicks, $0.count, $0.baseAddress!)
            }
            MIDIReceivedEventList(source, &list)
        }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        guard let onFromApps else { return }
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12
        for packet in list.unsafeSequence() {
            let count = min(64, Int(packet.pointee.wordCount))
            let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
            var words: [UInt32] = []
            words.reserveCapacity(count)
            for i in 0..<count { words.append(base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
            let bytes = MIDIUMP.bytes(fromWords: words)
            if !bytes.isEmpty { onFromApps(bytes, packet.pointee.timeStamp) }
        }
    }
}
#endif
