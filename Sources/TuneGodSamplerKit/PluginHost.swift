// Hosting the plugin: an Audio Unit instrument loaded in this process and pulled by hand, a block at a time. No audio engine owns
// it, so the same unit is pulled by the sampler (as fast as it renders, or at the speed of real time) and by the speaker (so the
// user hears what they play), never by both at once.
import AudioToolbox
import AVFoundation
import Foundation
import os

/// An Audio Unit instrument installed on this Mac.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var maker: String
    public var type: OSType
    public var subtype: OSType
    public var manufacturer: OSType

    public var id: String { "\(type)-\(subtype)-\(manufacturer)" }
    /// The maker and the name, as the list shows them.
    public var title: String { maker.isEmpty ? name : "\(maker): \(name)" }
    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

/// Every Audio Unit instrument on this Mac, by maker then name.
public func installedInstruments() -> [PluginInfo] {
    let any = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: 0, componentManufacturer: 0,
                                        componentFlags: 0, componentFlagsMask: 0)
    var seen = Set<String>()
    return AVAudioUnitComponentManager.shared().components(matching: any).map { c in
        let d = c.audioComponentDescription
        // The system gives the name as "Maker: Name"; the maker is shown apart.
        let prefix = c.manufacturerName + ": "
        let name = c.name.hasPrefix(prefix) ? String(c.name.dropFirst(prefix.count)) : c.name
        return PluginInfo(name: name, maker: c.manufacturerName, type: d.componentType, subtype: d.componentSubType,
                          manufacturer: d.componentManufacturer)
    }
    .filter { seen.insert($0.id).inserted }
    .sorted { ($0.maker.lowercased(), $0.name.lowercased()) < ($1.maker.lowercased(), $1.name.lowercased()) }
}

/// A plugin that could not be loaded or played, with the message the user is shown.
public struct PluginError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// One loaded plugin. Its first output is what is heard and recorded, in stereo (a plugin with one channel is copied to both).
public final class PluginHost: NoteRendering, @unchecked Sendable {
    /// The most frames asked of the plugin at once.
    public static let maxFrames = 4096

    public let info: PluginInfo
    public let unit: AUAudioUnit
    public let sampleRate: Double

    private let renderBlock: AURenderBlock
    private let midiBlock: AUScheduleMIDIEventBlock?
    private let channels: Int
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let scratch: [UnsafeMutablePointer<Float>]
    private let lock = OSAllocatedUnfairLock()
    private var sampleTime = 0.0
    private var samplerOwnsIt = false

    /// Loads `info`. Throws `PluginError` when it cannot be loaded or has no output this host can use.
    public static func load(_ info: PluginInfo, sampleRate: Double) async throws -> PluginHost {
        let unit: AUAudioUnit
        do {
            unit = try await AUAudioUnit.instantiate(with: info.description, options: [])
        } catch {
            throw PluginError("\(info.name) could not be loaded.")
        }
        return try PluginHost(info: info, unit: unit, sampleRate: sampleRate)
    }

    init(info: PluginInfo, unit: AUAudioUnit, sampleRate: Double) throws {
        self.info = info
        self.unit = unit
        self.sampleRate = sampleRate
        guard unit.outputBusses.count > 0 else { throw PluginError("\(info.name) has no audio output.") }
        // Stereo, or one channel for a plugin that has no more.
        var granted = 0
        for count in [2, 1] {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(count)),
                  (try? unit.outputBusses[0].setFormat(format)) != nil else { continue }
            granted = count
            break
        }
        guard granted > 0 else { throw PluginError("\(info.name) does not play at \(Int(sampleRate)) Hz.") }
        channels = granted
        unit.maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
        do {
            try unit.allocateRenderResources()
        } catch {
            throw PluginError("\(info.name) could not be started.")
        }
        renderBlock = unit.renderBlock
        midiBlock = unit.scheduleMIDIEventBlock
        buffers = AudioBufferList.allocate(maximumBuffers: granted)
        scratch = (0..<granted).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames) }
    }

    deinit {
        unit.deallocateRenderResources()
        scratch.forEach { $0.deallocate() }
        free(buffers.unsafeMutablePointer)
    }

    /// True while a sample is being taken: the speaker gets nothing, so every frame the plugin plays goes to the sampler.
    public var sampling: Bool {
        get { lock.withLock { samplerOwnsIt } }
        set { lock.withLock { samplerOwnsIt = newValue } }
    }

    /// Tells the plugin it is being rendered faster than real time, so one that streams its sounds from disk loads them as it goes.
    public var offline: Bool {
        get { unit.isRenderingOffline }
        set { unit.isRenderingOffline = newValue }
    }

    // MARK: Notes

    private func send(_ status: UInt8, _ data1: Int, _ data2: Int, channel: Int) {
        let bytes: [UInt8] = [status | UInt8(min(15, max(0, channel - 1))), UInt8(min(127, max(0, data1))), UInt8(min(127, max(0, data2)))]
        bytes.withUnsafeBufferPointer { midiBlock?(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!) }
    }

    public func noteOn(_ note: Int, velocity: Int, channel: Int) { send(0x90, note, max(1, velocity), channel: channel) }
    public func noteOff(_ note: Int, channel: Int) { send(0x80, note, 0, channel: channel) }

    /// Lets every key go and stops what is sounding, on every channel.
    public func allNotesOff() {
        for channel in 1...16 {
            send(0xB0, 123, 0, channel: channel)
            send(0xB0, 120, 0, channel: channel)
        }
    }

    // MARK: Audio

    /// The plugin's next `frames` frames into `scratch`. The lock is held.
    private func pull(_ frames: Int) throws {
        for (i, pointer) in scratch.enumerated() {
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(pointer))
        }
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = sampleTime
        stamp.mHostTime = mach_absolute_time()
        stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        let status = renderBlock(&flags, &stamp, AUAudioFrameCount(frames), 0, buffers.unsafeMutablePointer, nil)
        guard status == noErr else { throw PluginError("\(info.name) stopped playing (error \(status)).") }
        sampleTime += Double(frames)
        // A plugin may hand back its own memory instead of filling ours.
        for (i, pointer) in scratch.enumerated() {
            if let data = buffers[i].mData, data != UnsafeMutableRawPointer(pointer) {
                pointer.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
            }
        }
    }

    public func render(frames: Int, left: inout [Float], right: inout [Float]) throws {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, Self.maxFrames)
            try lock.withLockUnchecked {
                try pull(count)
                left.append(contentsOf: UnsafeBufferPointer(start: scratch[0], count: count))
                right.append(contentsOf: UnsafeBufferPointer(start: scratch[channels - 1], count: count))
            }
            remaining -= count
        }
    }

    /// For the speaker, on the audio thread: the plugin's next `frames` frames. False, with nothing written, while a sample is being
    /// taken (or the sampler is mid-block), when `frames` is more than `maxFrames`, and when the plugin fails.
    public func liveRender(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        guard frames <= Self.maxFrames else { return false }
        return lock.withLockIfAvailableUnchecked {
            guard !samplerOwnsIt, (try? pull(frames)) != nil else { return false }
            left.update(from: scratch[0], count: frames)
            right.update(from: scratch[channels - 1], count: frames)
            return true
        } ?? false
    }
}
