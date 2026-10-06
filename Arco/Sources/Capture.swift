// Reading the Arco device's input: the loopback of what the Music app plays to its output, sample for sample. Delivered
// as 24-bit little-endian stereo (the format of the stream to Roon), in buffers of 4096 frames.
//
// The scale is 2^23: Core Audio turns a 24-bit sample into a float by dividing by exactly 2^23, so multiplying by 2^23
// gives the original integer back. (×8 388 607 would move the loudest samples by one step.)
import AVFoundation
import AudioToolbox
import CoreAudio

final class Capture {
    private var engine: AVAudioEngine?
    private var device: AudioDeviceID = 0
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastBuffer = Date()
    private let bufferLock = NSLock()
    /// Called on the audio thread with 24-bit stereo PCM, its frame count, and the first frame that is not silent (nil
    /// for a silent buffer) — where the music resumes after a pause.
    var onAudio: ((Data, Int, Int?) -> Void)?
    private(set) var rate: Double = 0

    /// Starts reading the device's input. Returns nil, or what went wrong.
    func start(device: AudioDeviceID) -> String? {
        stop()
        buffers = 0; soundSeen = false
        self.device = device
        if let error = startEngine() { return error }
        // The engine stops, silently, when the device's configuration changes — and that happens as soon as the Music app
        // starts playing to Arco (6 Oct 2026, 20:18:48: the stream stopped growing at 4.9 s and Roon waited for a block
        // that never came). Start it again; and if buffers stop for a second anyway, the watchdog does the same.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let engine = note.object as? AVAudioEngine, engine === self.engine else { return }
            Log.note("capture: the device's configuration changed — starting again")
            _ = self.startEngine()
        }
        markBuffer()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.engine != nil else { return }
            self.bufferLock.lock(); let silentFor = Date().timeIntervalSince(self.lastBuffer); self.bufferLock.unlock()
            if silentFor > 1.5 {
                Log.note("capture: no buffers for \(String(format: "%.1f", silentFor)) s — starting again")
                self.markBuffer()
                _ = self.startEngine()
            }
        }
        return nil
    }

    private func markBuffer() { bufferLock.lock(); lastBuffer = Date(); bufferLock.unlock() }

    private func startEngine() -> String? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let e = AVAudioEngine()
        let input = e.inputNode
        var id = self.device
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { return "could not select the Arco input" }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount >= 2 else { return "the Arco input has no usable format" }
        rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        do { try e.start() } catch { return "could not start reading: \(error.localizedDescription)" }
        engine = e
        return nil
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    var isRunning: Bool { engine?.isRunning == true }

    private var buffers = 0
    private var soundSeen = false

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, let onAudio else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        buffers += 1
        markBuffer()
        if buffers == 1 { Log.note("capture: first buffer, \(frames) frames at \(Int(buffer.format.sampleRate)) Hz") }
        let left = channels[0], right = channels[buffer.format.channelCount > 1 ? 1 : 0]
        var firstSound: Int? = nil
        var pcm = Data(count: frames * 6)
        pcm.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            @inline(__always) func put(_ sample: Float, _ frame: Int) {
                let v = Int32(max(-8_388_608, min(8_388_607, (Double(sample) * 8_388_608).rounded())))
                if v != 0, firstSound == nil { firstSound = frame }
                p[i] = UInt8(truncatingIfNeeded: v); p[i + 1] = UInt8(truncatingIfNeeded: v >> 8); p[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                i += 3
            }
            for f in 0..<frames { put(left[f], f); put(right[f], f) }
        }
        if firstSound != nil, !soundSeen { soundSeen = true; Log.note("capture: first sound after \(buffers) buffers") }
        if buffers == 200, !soundSeen { Log.note("capture: 200 buffers and only silence — is anything playing to Arco?") }
        onAudio(pcm, frames, firstSound)
    }
}
