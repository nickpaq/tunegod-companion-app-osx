// A hit's audio as the .tgi stores it: Apple Lossless in a CAF file, 24-bit, at the rate it was rendered. The system's own audio
// files do the coding, through a file in the temporary folder.
import AVFoundation
import Foundation

private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("tgsampler-\(UUID().uuidString).caf")
}

/// `hit` as an Apple Lossless CAF file's bytes. Samples beyond full scale are clipped by the 24-bit file.
public func encodeAppleLossless(_ hit: CapturedHit, sampleRate: Double) throws -> Data {
    let channels = AVAudioChannelCount(hit.channels)
    guard hit.frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hit.frames)),
          let data = buffer.floatChannelData else { throw TGIError("That hit could not be stored.") }
    buffer.frameLength = AVAudioFrameCount(hit.frames)
    hit.left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: hit.frames) }
    if let right = hit.right {
        right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress!, count: min(hit.frames, right.count)) }
    }
    let url = scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleLossless,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channels),
        AVEncoderBitDepthHintKey: 24,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    file.close()
    return try Data(contentsOf: url)
}

/// An audio file's bytes as samples; `right` is nil for a file with one channel.
public func decodeAudio(_ data: Data) throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
    let url = scratchFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw TGIError.damaged
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { throw TGIError.damaged }
    let frames = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: frames)) : nil
    return (left, right, format.sampleRate)
}
