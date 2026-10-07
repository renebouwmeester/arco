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
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)) else { return Data() }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
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
        let capacity = AVAudioFrameCount(Double(frames) * to / from) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return Data() }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return input
        }
        guard error == nil else { return Data() }
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
