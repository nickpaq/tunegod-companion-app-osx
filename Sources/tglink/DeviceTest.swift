// `tglink device-test`: plays a 440 Hz tone into the "TuneGod iPhone" device and measures what comes back on its input, once a second,
// so the driver can be checked end to end (with the phone, or the phone simulator and `tglink connect --direct`).
import CoreAudio
import Foundation
import TuneGodLinkKit

enum DeviceTest {
    static let uid = "TuneGodLink:iPhone"

    static func findDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), q,
                                       &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    static func run(seconds: Double) -> Int32 {
        guard let device = findDevice() else {
            print("No \"TuneGod iPhone\" device: is the driver installed? (scripts/install-driver.sh)")
            return 1
        }
        print("found TuneGod iPhone (device \(device))")
        final class Meter: @unchecked Sendable {
            let lock = NSLock()
            var phase = 0.0
            var sum = 0.0
            var count = 0
            var cycles = 0
            var lastInputTime = 0.0
            var gaps = 0
        }
        let meter = Meter()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, output, _ in
            meter.lock.withLock {
                meter.cycles += 1
                let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                for buffer in inList {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(buffer.mDataByteSize) / 4
                    for i in 0..<n { meter.sum += Double(data[i] * data[i]) }
                    meter.count += n
                }
                let t = inputTime.pointee.mSampleTime
                if meter.lastInputTime > 0, let first = inList.first {
                    let frames = Double(Int(first.mDataByteSize) / 4 / max(1, Int(first.mNumberChannels)))
                    if abs(t - meter.lastInputTime - frames) > 0.5 { meter.gaps += 1 }
                }
                meter.lastInputTime = t
                let outList = UnsafeMutableAudioBufferListPointer(output)
                for buffer in outList {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = Int(buffer.mNumberChannels)
                    let frames = Int(buffer.mDataByteSize) / 4 / max(1, channels)
                    var phase = meter.phase
                    for f in 0..<frames {
                        let v = Float(sin(phase)) * 0.2
                        for c in 0..<channels { data[f * channels + c] = v }
                        phase += 2 * Double.pi * 440 / 48000
                    }
                    meter.phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
                }
            }
        }
        guard status == noErr, let procID else {
            print("could not open the device (\(status))")
            return 1
        }
        AudioDeviceStart(device, procID)
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            Thread.sleep(forTimeInterval: 1)
            let line: String = meter.lock.withLock {
                let rms = meter.count > 0 ? (meter.sum / Double(meter.count)).squareRoot() : 0
                defer {
                    meter.sum = 0
                    meter.count = 0
                }
                return String(format: "device: cycles %d input rms %.3f timeline gaps %d", meter.cycles, rms, meter.gaps)
            }
            print(line)
        }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        return 0
    }
}
