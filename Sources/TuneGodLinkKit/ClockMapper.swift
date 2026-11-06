// The phone's audio hardware is the only clock (docs/link-protocol.md, "Clock"). The Mac sees it through the arrival times of the phone's
// AUDIO_UP packets; a second-order delay-locked loop smooths those into a steady mapping between the phone's sample timeline and Mac host
// time, so the driver can run at exactly the phone's rate and MIDI can be stamped on either side.
import Foundation

public struct ClockMapper: Sendable {
    public let sampleRate: Double
    public let bandwidth: Double
    private var b = 0.0
    private var c = 0.0
    // Host seconds at the start of the current and the next packet, and the smoothed period.
    private var t0 = 0.0
    private var t1 = 0.0
    private var e2 = 0.0
    // Phone frames at those two points.
    private var s0: UInt64 = 0
    private var s1: UInt64 = 0
    /// Smoothed (frame, host) points about every half second, the last 10 s: the rate is measured across them, which averages the
    /// arrival jitter away far better than one packet's period can.
    private var anchors: [(sample: UInt64, host: Double)] = []
    public private(set) var locked = false
    /// Times the loop was restarted because the phone's frames jumped (a gap, or a new START).
    public private(set) var resets = 0

    public init(sampleRate: Double, bandwidth: Double = 1.0) {
        self.sampleRate = sampleRate
        self.bandwidth = bandwidth
    }

    public mutating func reset() {
        locked = false
        anchors.removeAll()
    }

    /// One packet of `frames` frames starting at phone frame `sampleTime` arrived at `host` (seconds).
    public mutating func update(sampleTime: UInt64, frames: Int, host: Double) {
        let period = Double(frames) / sampleRate
        if !locked || sampleTime != s1 {
            if locked { resets += 1 }
            let omega = 2 * Double.pi * bandwidth * period
            b = 2.0.squareRoot() * omega
            c = omega * omega
            e2 = period
            t0 = host
            t1 = host + period
            s0 = sampleTime
            s1 = sampleTime + UInt64(frames)
            locked = true
            anchors.removeAll()
            return
        }
        let e = host - t1
        t0 = t1
        t1 += b * e + e2
        e2 += c * e
        s0 = s1
        s1 += UInt64(frames)
        if anchors.isEmpty || Double(s1 - anchors[anchors.count - 1].sample) >= sampleRate / 2 {
            anchors.append((s1, t1))
            if anchors.count > 21 { anchors.removeFirst() }
        }
    }

    /// Smoothed phone frames per host second.
    public var rate: Double {
        guard locked else { return sampleRate }
        if anchors.count >= 3, let first = anchors.first, let last = anchors.last, last.host > first.host {
            return Double(last.sample - first.sample) / (last.host - first.host)
        }
        return e2 > 0 ? Double(s1 - s0) / e2 : sampleRate
    }

    /// The host time (seconds) phone frame `sample` corresponds to.
    public func hostTime(forSample sample: UInt64) -> Double? {
        guard locked else { return nil }
        return t0 + (Double(sample) - Double(s0)) / rate
    }

    /// The phone frame at host time `host` (seconds).
    public func sampleTime(atHost host: Double) -> UInt64? {
        guard locked else { return nil }
        let s = Double(s0) + (host - t0) * rate
        return s <= 0 ? 0 : UInt64(s)
    }

    /// The newest phone frame the loop has seen (end of the last packet).
    public var latestSample: UInt64 { s1 }
}

/// Mac (and iPhone) host clock: mach ticks and seconds.
public enum HostClock {
    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    public static func ticks() -> UInt64 { mach_absolute_time() }
    public static func now() -> Double { seconds(ticks: ticks()) }
    public static func nanos() -> UInt64 { ticks() * UInt64(timebase.numer) / UInt64(timebase.denom) }
    public static func seconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    public static func ticks(seconds: Double) -> UInt64 {
        seconds <= 0 ? 0 : UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }
}

/// Real-time scheduling for threads that carry audio (what Core Audio's own IO threads use): `period` between wake-ups, `computation`
/// of work in each. Without it a busy Mac can hold such a thread back by milliseconds.
public enum RealtimeThread {
    @discardableResult
    public static func promote(period: Double, computation: Double) -> Bool {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(HostClock.ticks(seconds: period)),
            computation: UInt32(HostClock.ticks(seconds: computation)),
            constraint: UInt32(HostClock.ticks(seconds: period)),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return rc == KERN_SUCCESS
    }
}
