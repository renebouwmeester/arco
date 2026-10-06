// The bridge: the Music app → the Arco output → its loopback → one growing stream → Roon's audio input on the chosen zone.
//
// On: the system output becomes Arco (the previous one is remembered, also across a crash), the loopback is read, and as
// soon as Music plays a session begins on the zone and the stream goes into its play slot, with the current track's
// title, artist, album and cover.
//
// A new track in Music is marked at the stream's position; Roon plays a few seconds behind, so the new track information
// goes to Roon when Roon's own position (its Time events, in the same stream) reaches that mark — not when Music starts it.
//
// Pause and resume work both ways: Music paused → Roon pauses (and the stream waits for sound); Roon's pause or play
// button → Music. Events that Arco caused itself are ignored for a few seconds. Roon's next and previous go to Music.
//
// Off, quit, or the zone taken over in Roon: the session ends and the previous output comes back.
//
// Milestone 2: the Arco output runs at a fixed 44.1 kHz. A clock per track comes later.
import AppKit
import ArcoRoon
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class Bridge: ObservableObject {
    enum Phase: Equatable {
        case off
        case waitingForMusic
        case starting
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var zoneName: String?

    private let connection: RoonConnection
    private let server = StreamServer()
    private let capture = Capture()
    private let music = MusicWatcher()
    private var session: AudioInputSession?
    private var stream: LiveStream?
    private var streamNumber = 0
    private var zoneID: String?
    /// Track starts in the stream that Roon has not reached yet.
    private var marks: [(ms: Int, info: JSON)] = []
    /// Until when Roon's pause / play events are our own doing.
    private var ownUntil = Date.distantPast
    private static let previousOutputKey = "PreviousOutputUID"
    private static let fixedRate = 44_100.0
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arco", isDirectory: true)

    init(connection: RoonConnection) {
        self.connection = connection
        try? FileManager.default.removeItem(at: directory)   // leftovers of an earlier run
        music.onChange = { [weak self] state, track, changed in self?.musicChanged(state, track, changed) }
        let holder = streamHolder
        capture.onAudio = { pcm, frames, firstSound in holder.write(pcm, frames, firstSound) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.turnOff() }
        }
        // A plain kill (SIGTERM — an update, a restart) skips willTerminate: end the session in Roon and give the Mac its
        // output back anyway, then quit. (Without this Roon kept fetching the old address for minutes.)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.turnOff() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        }
        term.resume()
        termSource = term
        restoreOutputAfterCrash()
    }

    /// On while it sends or is about to; after a failure the switch is off again (the message stays).
    var isOn: Bool {
        switch phase {
        case .off, .failed: return false
        default: return true
        }
    }
    private var coverNumber = 0
    private var pendingPause: Task<Void, Never>?
    private var termSource: DispatchSourceSignal?
    private var roonPositionMs = 0
    private var heartbeat: Timer?
    static var driverInstalled: Bool { AudioDevices.arco != nil }

    // MARK: - On and off

    func turnOn(zone: RoonZone) async {
        turnOff()
        zoneName = zone.name
        guard case .paired = connection.state else { return fail("Roon is not connected") }
        guard let arco = AudioDevices.arco else { return fail("Install the Arco audio driver first") }
        // Reading an audio input needs the microphone permission — also for Arco's own loopback. Without it macOS
        // delivers silence, without an error.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return fail(Self.microphoneHint) }
        default:
            return fail(Self.microphoneHint)
        }
        Log.note("on: zone \(zone.name)")
        guard await server.start() != nil else { return fail("Could not open the stream port") }
        zoneID = zone.id
        // Basso's lesson for a change of output or clock: pause, change, resume. Switching the output under a playing
        // Music app makes it stumble (20:27:58: paused and on again 42 ms later — a hiccup in the music itself).
        music.refresh()
        let wasPlaying = music.state == .playing
        if wasPlaying { music.pause(); try? await Task.sleep(for: .milliseconds(300)) }
        if let current = AudioDevices.defaultOutput, current != arco, let uid = AudioDevices.uid(of: current) {
            UserDefaults.standard.set(uid, forKey: Self.previousOutputKey)
        }
        AudioDevices.setDefaultOutput(arco)
        // The rate after the switch: macOS gives a device that becomes the default output its remembered format (Arco
        // stayed at 48 kHz although 44.1 was asked before the switch — and Music resampled to it).
        AudioDevices.setSampleRate(Self.fixedRate, of: arco)
        for _ in 0..<20 where AudioDevices.sampleRate(of: arco) != Self.fixedRate { try? await Task.sleep(for: .milliseconds(50)) }
        Log.note("device: Arco at \(Int(AudioDevices.sampleRate(of: arco) ?? 0)) Hz (asked \(Int(Self.fixedRate)))")
        if let error = capture.start(device: arco) { return fail(error) }
        Log.note("capture: reading the Arco input at \(Int(capture.rate)) Hz")
        phase = .waitingForMusic
        connection.setStatus("Playing to \(zone.name)")
        // Music starts again on Arco; its "playing" begins the session.
        if wasPlaying { music.play() }
    }

    func turnOff() {
        heartbeat?.invalidate(); heartbeat = nil
        roonPositionMs = 0
        session?.end()
        session = nil
        capture.stop()
        server.setStream(nil)
        streamHolder.set(nil)
        stream?.close()
        stream = nil
        marks = []
        zoneID = nil
        restoreOutput()
        if phase != .off { connection.setStatus("Ready") }
        phase = .off
    }

    private static let microphoneHint = "Allow Arco to read its audio output: System Settings › Privacy & Security › Microphone."

    private func fail(_ message: String) {
        Log.note("failed: \(message)")
        turnOff()
        phase = .failed(message)
    }

    // MARK: - The session in Roon

    private func startSession() async {
        guard let zoneID, let host = connection.coreHost, let address = Discovery.localAddress(toward: host) else {
            return fail("Can't reach the Roon Core from this Mac")
        }
        phase = .starting
        let s = AudioInputSession(connection: connection, zoneID: zoneID)
        s.onEvent = { [weak self] event in self?.roonEvent(event) }
        guard await s.begin(displayName: "Arco", iconURL: "http://\(address):\(server.port)/icon.png") else {
            return fail("Roon didn't start a session on this zone")
        }
        Log.note("session: began on the zone; stream at http://\(address):\(server.port)")
        session = s
        streamNumber += 1
        let live = LiveStream(number: streamNumber, rate: capture.rate, directory: directory)
        stream = live
        streamHolder.set(live)
        server.setStream(live)
        marks = []
        // A little of the music first, so Roon's first read finds something.
        for _ in 0..<50 where live.positionMs < 500 { try? await Task.sleep(for: .milliseconds(100)) }
        Log.note("stream \(streamNumber): \(live.positionMs) ms of music before the play request")
        if live.positionMs == 0 {
            return fail("No sound reaches Arco. Is the Music app playing, to the output Arco?")
        }
        let info = makeInfo(music.track, address: address)
        ownUntil = Date().addingTimeInterval(3)
        let answer = await s.play(track: String(streamNumber), url: "http://\(address):\(server.port)\(live.path)", info: info)
        guard session === s else { return }
        Log.note("play: Roon answered \(answer)")
        if answer == "Playing" || answer == "Unpaused" {
            phase = .playing
            heartbeat?.invalidate()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let live = self.stream else { return }
                    Log.note("stream \(live.number): \(live.positionMs) ms written, Roon at \(self.roonPositionMs) ms")
                }
            }
        } else { fail("Roon: \(answer)") }
    }

    private func makeInfo(_ track: MusicWatcher.Track?, address: String? = nil) -> JSON {
        guard let track else { return AudioInputSession.info(title: "Arco", artist: "", album: "", imageURL: nil) }
        var imageURL: String?
        let host = address ?? connection.coreHost.flatMap(Discovery.localAddress(toward:))
        if let cover = music.artwork(), let host {
            coverNumber += 1
            let key = "c\(coverNumber).\(cover.type == "image/png" ? "png" : "jpg")"
            server.addCover(cover.data, type: cover.type, key: key)
            imageURL = "http://\(host):\(server.port)/cover/\(key)"
        }
        return AudioInputSession.info(title: track.title, artist: track.artist, album: track.album, imageURL: imageURL)
    }

    private func roonEvent(_ event: AudioInputSession.Event) {
        let own = Date() < ownUntil
        if case .time = event {} else { Log.note("roon: \(event)\(own ? " (ours)" : "")") }
        switch event {
        case .time(_, let ms):
            roonPositionMs = ms
            // Roon reached the start of the next track in the stream: now it shows it.
            while let first = marks.first, ms >= first.ms - 300 {
                marks.removeFirst()
                Log.note("roon reached \(first.ms) ms: track information updated")
                let info = first.info
                Task { await session?.updateInfo(track: String(streamNumber), info: info) }
            }
        case .paused:
            if !own { ownUntil = Date().addingTimeInterval(3); music.pause() }
            phase = .paused
        case .unpaused:
            if !own { ownUntil = Date().addingTimeInterval(3); music.play() }
            phase = .playing
        case .stopped:
            // Roon stops a zone five seconds into a pause; a stop while playing is the user's.
            if phase == .playing, !own { ownUntil = Date().addingTimeInterval(3); music.pause() }
        case .control(let control):
            if control.contains("next") { music.next() } else if control.contains("prev") { music.previous() }
        case .ended:
            fail("The stream reached its end (three hours) — turn Arco on again")
        case .failed(_, let reason):
            fail("Roon: \(reason)")
        case .sessionEnded:
            // Someone played something else on the zone: give the Mac its output back.
            turnOff()
        case .playing:
            break
        }
    }

    // MARK: - The Music app

    private func musicChanged(_ state: MusicWatcher.State, _ track: MusicWatcher.Track?, _ changed: Bool) {
        Log.note("music: \(state.rawValue)\(changed ? " — \(track?.title ?? "-")" : "") at stream \(stream?.positionMs ?? -1) ms")
        switch phase {
        case .waitingForMusic:
            if state == .playing { Task { await startSession() } }
        case .playing, .paused, .starting:
            if changed, let track, let live = stream {
                marks.append((live.positionMs, makeInfo(track)))
            }
            if state != .playing, phase == .playing {
                // The stream closes at once — whatever silence Music leaves is not written (20:31:59: Music paused itself
                // for 0.22 s, seven seconds after the start, and that gap went into the stream). Roon only hears of a
                // pause that lasts: Music also pauses itself for a moment when its output changes (20:18:49: 0.14 s).
                stream?.pauseWriting()
                pendingPause?.cancel()
                pendingPause = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self, !Task.isCancelled, self.music.state != .playing, self.phase == .playing else { return }
                    self.roonControl("pause")
                    self.phase = .paused
                }
            } else if state == .playing {
                pendingPause?.cancel(); pendingPause = nil
                if phase == .paused {
                    roonControl("play")
                    phase = .playing
                }
            }
        default:
            break
        }
    }

    private func roonControl(_ control: String) {
        guard let zoneID else { return }
        ownUntil = Date().addingTimeInterval(3)
        connection.request("\(transportService)/control", ["zone_or_output_id": zoneID, "control": control])
    }

    // MARK: - The audio thread

    /// The stream the capture thread writes to — the audio thread never touches the bridge itself.
    private let streamHolder = StreamHolder()
    final class StreamHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var stream: LiveStream?
        func set(_ s: LiveStream?) { lock.lock(); stream = s; lock.unlock() }
        func write(_ pcm: Data, _ frames: Int, _ firstSound: Int?) {
            lock.lock(); let s = stream; lock.unlock()
            s?.write(pcm, frames: frames, firstSound: firstSound)
        }
    }

    // MARK: - The system output

    private func restoreOutput() {
        guard let arco = AudioDevices.arco, AudioDevices.defaultOutput == arco else { return }
        let remembered = UserDefaults.standard.string(forKey: Self.previousOutputKey).flatMap(AudioDevices.device(uid:))
        if let back = remembered ?? AudioDevices.builtInOutput {
            AudioDevices.setDefaultOutput(back)
            Log.note("output: back to \(AudioDevices.uid(of: back) ?? "?")\(remembered == nil ? " (the Mac's own — no previous output known)" : "")")
        }
    }

    /// Arco is the output but the bridge is off (Arco quit unexpectedly): the Mac's own output back.
    private func restoreOutputAfterCrash() { restoreOutput() }
}
