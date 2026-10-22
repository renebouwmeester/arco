// Converting a stretch of 24-bit stereo from one rate to another — for the first moments of a track that the Music app
// played at the device's old rate before it switched to the track's own (it does that 0.2–5.5 s after a start: twelve
// times on 6 Oct). Music had already resampled those moments itself, so nothing bit-perfect is lost; converting them to
// the new rate keeps the start of the track in the slice instead of cutting it off.
import AVFoundation

enum Resample {
    static func pcm24(_ data: Data, from: Double, to: Double) -> Data {
        let frames = data.count / 6
        guard frames > 0, from != to,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 2, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = buffer(data, format: inFormat) else { return Data() }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let capacity = AVAudioFrameCount(Double(frames) * to / from) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return Data() }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return input
        }
        guard error == nil else { return Data() }
        return pcm24(output)
    }

    /// 24-bit stereo as a float buffer.
    static func buffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 6
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for c in 0..<2 {
                let channel = input.floatChannelData![c]
                for f in 0..<frames {
                    let i = f * 6 + c * 3
                    let v = Int32(bitPattern: UInt32(b[i]) << 8 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 24) >> 8
                    channel[f] = Float(v) / 8_388_608
                }
            }
        }
        return input
    }

    /// A float buffer as 24-bit stereo.
    static func pcm24(_ output: AVAudioPCMBuffer) -> Data {
        let n = Int(output.frameLength)
        var out = Data(count: n * 6)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for f in 0..<n {
                for c in 0..<2 {
                    let s = output.floatChannelData![c][f]
                    let v = Int32(max(-8_388_608, min(8_388_607, (Double(s) * 8_388_608).rounded())))
                    let i = f * 6 + c * 3
                    p[i] = UInt8(truncatingIfNeeded: v); p[i + 1] = UInt8(truncatingIfNeeded: v >> 8); p[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
            }
        }
        return out
    }
}

/// Down to what a renderer takes (22 Oct 2026: the Sonos Era plays nothing above 48 kHz — it took the URL and the Play, and
/// stopped): one converter for the whole stream, so the stretches the capture hands over join without a seam. Always by
/// a whole factor, in the rate's own family: 96 and 192 kHz to 48, 88.2 and 176.4 to 44.1.
final class Downsampler {
    let from: Double, to: Double
    private let inFormat: AVAudioFormat, outFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from: Double, to: Double) {
        guard let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 2, interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 2, interleaved: false),
              let c = AVAudioConverter(from: i, to: o) else { return nil }
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.from = from; self.to = to; inFormat = i; outFormat = o; converter = c
    }

    /// 24-bit stereo in, 24-bit stereo out at the lower rate.
    func convert(_ data: Data) -> Data {
        let frames = data.count / 6
        guard frames > 0, let input = Resample.buffer(data, format: inFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(frames) * to / from) + 4096) else { return Data() }
        var given = false
        var error: NSError?
        // No more for now — not the end: the converter keeps what it holds for the next stretch.
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return input
        }
        return error == nil ? Resample.pcm24(output) : Data()
    }
}
