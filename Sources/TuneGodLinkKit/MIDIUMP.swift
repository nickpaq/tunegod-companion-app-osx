// MIDI 1.0 bytes (what the link carries) to and from Universal MIDI Packet words (what CoreMIDI's event lists carry), group 0.
// Channel voice messages are type 2, system common and real-time type 1, SysEx type 3 (7-bit data, six bytes per packet).
import Foundation

public enum MIDIUMP {
    /// Data bytes that follow a status byte; nil for status bytes carrying no complete message here (SysEx start/end, undefined).
    static func dataLength(_ status: UInt8) -> Int? {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF: return 2
        case 0xC0...0xDF: return 1
        case 0xF1, 0xF3: return 1
        case 0xF2: return 2
        case 0xF6, 0xF8...0xFF: return 0
        default: return nil
        }
    }

    /// Complete messages in `bytes` (running status allowed) as UMP words, one array per message.
    public static func messages(fromBytes bytes: [UInt8]) -> [[UInt32]] {
        var out: [[UInt32]] = []
        var running: UInt8?
        var sysex: [UInt8]?
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0xF8 {
                out.append([0x1000_0000 | UInt32(b) << 16])
                i += 1
                continue
            }
            if sysex != nil {
                if b < 0x80 {
                    sysex!.append(b)
                    i += 1
                    continue
                }
                out.append(contentsOf: sysexPackets(sysex!))
                sysex = nil
                if b == 0xF7 {
                    i += 1
                    continue
                }
            }
            if b == 0xF0 {
                sysex = []
                running = nil
                i += 1
                continue
            }
            let status: UInt8
            let dataStart: Int
            if b >= 0x80 {
                status = b
                dataStart = i + 1
                running = b < 0xF0 ? b : nil
            } else {
                guard let r = running else {
                    i += 1
                    continue
                }
                status = r
                dataStart = i
            }
            guard let n = dataLength(status) else {
                i = dataStart
                continue
            }
            // Data bytes, letting real-time bytes (clock) pass between them; another status byte abandons the message.
            var data: [UInt32] = []
            var j = dataStart
            while data.count < n, j < bytes.count {
                let d = bytes[j]
                if d >= 0xF8 {
                    out.append([0x1000_0000 | UInt32(d) << 16])
                } else if d >= 0x80 {
                    break
                } else {
                    data.append(UInt32(d))
                }
                j += 1
            }
            guard data.count == n else {
                if j >= bytes.count { break }
                i = j
                continue
            }
            let d1 = n >= 1 ? data[0] : 0
            let d2 = n >= 2 ? data[1] : 0
            let type: UInt32 = status < 0xF0 ? 0x2 : 0x1
            out.append([type << 28 | UInt32(status) << 16 | d1 << 8 | d2])
            i = j
        }
        return out
    }

    private static func sysexPackets(_ data: [UInt8]) -> [[UInt32]] {
        var chunks: [ArraySlice<UInt8>] = []
        var k = 0
        repeat {
            chunks.append(data[k..<min(k + 6, data.count)])
            k += 6
        } while k < data.count
        return chunks.enumerated().map { index, chunk in
            let st: UInt32 = chunks.count == 1 ? 0 : index == 0 ? 1 : index == chunks.count - 1 ? 3 : 2
            var b = [UInt32](repeating: 0, count: 6)
            for (j, v) in chunk.enumerated() { b[j] = UInt32(v) }
            let w0 = 0x3000_0000 | st << 20 | UInt32(chunk.count) << 16 | b[0] << 8 | b[1]
            let w1 = b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5]
            return [w0, w1]
        }
    }

    /// Words of a UMP stream as MIDI 1.0 bytes (types 1, 2 and 3; other types are skipped by their size).
    public static func bytes(fromWords words: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let mt = w >> 28
            let size: Int
            switch mt {
            case 0x0, 0x1, 0x2, 0x6, 0x7: size = 1
            case 0x3, 0x4, 0x8, 0x9, 0xA: size = 2
            case 0xB, 0xC: size = 3
            default: size = 4
            }
            switch mt {
            case 0x1, 0x2:
                let status = UInt8((w >> 16) & 0xFF)
                if let n = dataLength(status) {
                    out.append(status)
                    if n >= 1 { out.append(UInt8((w >> 8) & 0x7F)) }
                    if n >= 2 { out.append(UInt8(w & 0x7F)) }
                }
            case 0x3 where i + 1 < words.count:
                let w1 = words[i + 1]
                let st = (w >> 20) & 0xF
                let count = min(6, Int((w >> 16) & 0xF))
                let data: [UInt8] = [UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F), UInt8((w1 >> 24) & 0x7F),
                                     UInt8((w1 >> 16) & 0x7F), UInt8((w1 >> 8) & 0x7F), UInt8(w1 & 0x7F)]
                if st == 0 || st == 1 { out.append(0xF0) }
                out.append(contentsOf: data.prefix(count))
                if st == 0 || st == 3 { out.append(0xF7) }
            default:
                break
            }
            i += size
        }
        return out
    }
}
