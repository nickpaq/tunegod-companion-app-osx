// The plugin on the Mac's speakers, so the user hears the kit they chose and the pads they set. The output asks the host for its
// next frames; while a sample is being taken the host gives none and the speakers are silent.
import AVFoundation
import Foundation

public final class LiveOutput {
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode

    public init(host: PluginHost) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: host.sampleRate, channels: 2) else {
            throw PluginError("The Mac's audio output could not be opened.")
        }
        source = AVAudioSourceNode(format: format) { [weak host] silence, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if host?.liveRender(frames: Int(frames), left: left, right: right) != true {
                left.update(repeating: 0, count: Int(frames))
                right.update(repeating: 0, count: Int(frames))
                silence.pointee = true
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    public func start() throws {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { throw PluginError("The Mac's audio output could not be started.") }
    }

    public func stop() {
        engine.stop()
    }
}
