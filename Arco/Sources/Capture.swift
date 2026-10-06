// Reading the Arco device's input: the loopback of what the Music app plays to its output, sample for sample. Delivered
// as 24-bit little-endian stereo (the format of the stream to Roon).
//
// A Core Audio IOProc on the device itself, not AVAudioEngine: the engine stops (silently) whenever the device's
// configuration changes — which happens the moment an app starts playing to Arco — and restarting it caused the next
// change (6 Oct 2026: a restart every 0.2 s, no buffer ever). An IOProc keeps running through such changes, and later
// through a change of sample rate per track. The IOProc only copies; the conversion and the writing happen on a queue
// of their own, so the device's cycle — the Music app's playback — never waits for Arco.
//
// The scale is 2^23: Core Audio turns a 24-bit sample into a float by dividing by exactly 2^23, so multiplying by 2^23
// gives the original integer back. (×8 388 607 would move the loudest samples by one step.)
import CoreAudio
import Foundation

final class Capture: @unchecked Sendable {
    /// Called on the capture queue with 24-bit stereo PCM, its frame count, and the first frame that is not silent (nil
    /// for a silent buffer) — where the music resumes after a pause.
    var onAudio: ((Data, Int, Int?) -> Void)?
    private(set) var rate: Double = 0

    private var device: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "arco.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var lastCallback = Date()
    private var watchdog: Timer?
    private var buffers = 0
    private var soundSeen = false

    /// Starts reading the device's input. Returns nil, or what went wrong.
    func start(device: AudioDeviceID) -> String? {
        stop()
        self.device = device
        buffers = 0; soundSeen = false
        rate = AudioDevices.sampleRate(of: device) ?? 44_100
        if let error = startProc() { return error }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.procID != nil else { return }
            self.lock.lock(); let quiet = Date().timeIntervalSince(self.lastCallback); self.lock.unlock()
            if quiet > 1.5 {
                Log.note("capture: no input for \(String(format: "%.1f", quiet)) s — starting again")
                self.stopProc()
                _ = self.startProc()
            }
        }
        return nil
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        stopProc()
    }

    var isRunning: Bool { procID != nil }

    private func startProc() -> String? {
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { [weak self] _, input, _, _, _ in
            self?.copy(input)
        }
        guard status == noErr, let id else { return "could not read the Arco input (\(status))" }
        guard AudioDeviceStart(device, id) == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            return "could not start reading the Arco input"
        }
        procID = id
        lock.lock(); lastCallback = Date(); lock.unlock()
        return nil
    }

    private func stopProc() {
        guard let id = procID else { return }
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
        procID = nil
    }

    /// On Core Audio's IO thread: copy the input (float32, interleaved stereo — the Arco format) and hand it over.
    private func copy(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        let samples = Data(bytes: data, count: Int(buffer.mDataByteSize))
        let channels = max(1, Int(buffer.mNumberChannels))
        lock.lock(); lastCallback = Date(); lock.unlock()
        queue.async { [weak self] in self?.convert(samples, channels: channels) }
    }

    private func convert(_ samples: Data, channels: Int) {
        guard let onAudio else { return }
        let frames = samples.count / (4 * channels)
        guard frames > 0 else { return }
        buffers += 1
        if buffers == 1 { Log.note("capture: first input, \(frames) frames at \(Int(rate)) Hz") }
        var firstSound: Int? = nil
        var pcm = Data(count: frames * 6)
        samples.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            pcm.withUnsafeMutableBytes { out in
                guard let p = out.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                for frame in 0..<frames {
                    for c in 0..<2 {
                        let sample = f[frame * channels + min(c, channels - 1)]
                        let v = Int32(max(-8_388_608, min(8_388_607, (Double(sample) * 8_388_608).rounded())))
                        if v != 0, firstSound == nil { firstSound = frame }
                        p[i] = UInt8(truncatingIfNeeded: v); p[i + 1] = UInt8(truncatingIfNeeded: v >> 8); p[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                        i += 3
                    }
                }
            }
        }
        if firstSound != nil, !soundSeen { soundSeen = true; Log.note("capture: first sound after \(buffers) inputs") }
        if buffers == 2000, !soundSeen { Log.note("capture: 2000 inputs and only silence — is anything playing to Arco?") }
        onAudio(pcm, frames, firstSound)
    }
}
