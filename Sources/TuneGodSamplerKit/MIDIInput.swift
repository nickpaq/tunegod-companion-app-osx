// Notes from every MIDI keyboard and controller connected to the Mac, also ones plugged in later: to play the plugin, and to
// give a pad its note by playing it.
import CoreMIDI
import Foundation

public struct MIDINote: Equatable, Sendable {
    public var note: Int
    public var velocity: Int
    /// A key going down; false for one let go (a note-on at velocity 0 is one let go).
    public var on: Bool
}

/// The note in one word of MIDI as the system delivers it (a MIDI 1.0 channel message); nil for anything else.
public func midiNote(word: UInt32) -> MIDINote? {
    guard word >> 28 == 0x2 else { return nil }
    let status = (word >> 16) & 0xF0, note = Int((word >> 8) & 0x7F), velocity = Int(word & 0x7F)
    switch status {
    case 0x90: return MIDINote(note: note, velocity: velocity, on: velocity > 0)
    case 0x80: return MIDINote(note: note, velocity: 0, on: false)
    default: return nil
    }
}

public final class MIDIInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()

    /// `onNote` is called on a MIDI thread, as each note arrives.
    public init(onNote: @escaping @Sendable (MIDINote) -> Void) {
        MIDIClientCreateWithBlock("TuneGod instrument maker" as CFString, &client) { [weak self] _ in
            // The MIDI setup changed (something was plugged in or taken out).
            DispatchQueue.main.async { self?.connectSources() }
        }
        MIDIInputPortCreateWithProtocol(client, "Notes" as CFString, ._1_0, &port) { list, _ in
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for i in 0..<min(count, words.count) {
                        if let note = midiNote(word: words[i]) { onNote(note) }
                    }
                }
            }
        }
        connectSources()
    }

    deinit {
        MIDIClientDispose(client)
    }

    private func connectSources() {
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if source != 0, connected.insert(source).inserted { MIDIPortConnectSource(port, source, nil) }
        }
    }
}
