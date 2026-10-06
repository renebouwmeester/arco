// The bridge: the Music app → the Arco output → its loopback → a slice per track → Roon's audio input on the chosen zone.
//
// On: the system output becomes Arco (the previous one is remembered, also across a crash), the loopback is read, and as
// soon as Music plays a session begins on the zone. The current track becomes the first slice, in Roon's play slot.
//
// A slice per track (milestone 4): every track is a WAV of its own length, with its own title, artist, album and cover,
// so Roon shows the real length and the real track. Roon plays a few seconds behind, which gives Arco those seconds to
// get the next track ready:
// - A natural transition (the current slice is at, or within two seconds of, its end): the next track's slice goes into
//   Roon's queue slot. When Roon reports the current one ended, the queued one goes into the play slot — on RAAT and
//   Squeeze Roon does not take it from the queue itself, and this does not repeat anything (Basso, 5 Oct 2026).
// - A skip (next, previous, another track or album, or more than two seconds left): the new slice goes into the play
//   slot at once.
// - The rate: with Lossless on, the Music app sets the Arco device to each track's own rate. A slice begins with its
//   track's first sound, by which time the rate is settled, so each slice carries its own rate (see SliceStore).
//
// Pause and resume work both ways: Music paused → the slices wait for sound at once, and Roon pauses when it lasts 0.6 s;
// Roon's pause or play button → Music. Events that Arco caused itself are ignored for a few seconds. Roon's next and
// previous go to Music.
//
// Off, quit, or the zone taken over in Roon: the session ends and the previous output comes back.
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
    private var store: SliceStore?
    private var zoneID: String?
    private var address: String?
    /// The slice Roon plays, and the one waiting in its queue slot.
    private var roonSlice = 0
    private var queued: SliceStore.Slice?
    /// Until when Roon's pause / play events are our own doing.
    private var ownUntil = Date.distantPast
    private var coverNumber = 0
    private static let coverRun = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    private var pendingPause: Task<Void, Never>?
    private var termSource: DispatchSourceSignal?
    private var roonPositionMs = 0
    private var rateWatch: AudioObjectPropertyListenerBlock?
    private var arcoDevice: AudioDeviceID?
    private var heartbeat: Timer?
    private static let previousOutputKey = "PreviousOutputUID"
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arco", isDirectory: true)

    init(connection: RoonConnection) {
        self.connection = connection
        try? FileManager.default.removeItem(at: directory)   // leftovers of an earlier run
        music.onChange = { [weak self] state, track, changed in self?.musicChanged(state, track, changed) }
        let holder = storeHolder, capture = capture
        capture.onAudio = { pcm, frames, firstSound in holder.write(pcm, frames, firstSound, rate: capture.rate) }
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
        restoreOutput()   // Arco quit unexpectedly with the output on Arco: give the Mac its own back
    }

    /// On while it sends or is about to; after a failure the switch is off again (the message stays).
    var isOn: Bool {
        switch phase {
        case .off, .failed: return false
        default: return true
        }
    }
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
        guard let host = connection.coreHost, let address = Discovery.localAddress(toward: host) else {
            return fail("Can't reach the Roon Core from this Mac")
        }
        self.address = address
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
        // No rate is forced: with Lossless on, the Music app sets the device to each track's own rate.
        Log.note("device: Arco at \(Int(AudioDevices.sampleRate(of: arco) ?? 0)) Hz")
        let s = SliceStore(directory: directory)
        s.onSliceStarted = { [weak self] slice in self?.sliceStarted(slice) }
        store = s
        storeHolder.set(s)
        server.setStore(s)
        if let error = capture.start(device: arco) { return fail(error) }
        Log.note("capture: reading the Arco input at \(Int(capture.rate)) Hz")
        rateWatch = AudioDevices.watchSampleRate(of: arco) { [weak self] rate in
            MainActor.assumeIsolated { self?.deviceRateChanged(rate) }
        }
        arcoDevice = arco
        phase = .waitingForMusic
        connection.setStatus("Playing to \(zone.name)")
        // Music starts again on Arco; its "playing" begins the session.
        if wasPlaying { music.play() }
    }

    func turnOff() {
        if let rateWatch, let arcoDevice { AudioDevices.stopWatchingSampleRate(of: arcoDevice, rateWatch) }
        rateWatch = nil
        heartbeat?.invalidate(); heartbeat = nil
        pendingPause?.cancel(); pendingPause = nil
        roonPositionMs = 0
        roonSlice = 0
        queued = nil
        session?.end()
        session = nil
        capture.stop()
        server.setStore(nil)
        storeHolder.set(nil)
        store?.closeAll()
        store = nil
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
        guard let zoneID, let address, let store else { return }
        phase = .starting
        let s = AudioInputSession(connection: connection, zoneID: zoneID)
        s.onEvent = { [weak self] event in self?.roonEvent(event) }
        guard await s.begin(displayName: "Arco", iconURL: "http://\(address):\(server.port)/icon.png") else {
            return fail("Roon didn't start a session on this zone")
        }
        session = s
        Log.note("session: began on the zone; slices at http://\(address):\(server.port)")
        // The first slice: the current track, from where Music is now.
        guard let track = music.track else { return }
        let left = max(1000, track.durationMs - Int(music.position() * 1000))
        store.announce(.init(info: makeInfo(track), durationMs: left, immediate: true))
        // No sound within five seconds: say so instead of waiting for nothing.
        try? await Task.sleep(for: .seconds(5))
        if session === s, phase == .starting, store.status == nil {
            fail("No sound reaches Arco. Is the Music app playing, to the output Arco?")
        }
    }

    /// A slice began (its track's first sound arrived): into Roon — at once, or queued behind the current one.
    private func sliceStarted(_ slice: SliceStore.Slice) {
        guard let s = session, let address else { return }
        let url = "http://\(address):\(server.port)\(slice.path)"
        if slice.immediate {
            queued = nil
            Task { @MainActor in
                // A little of the music first, so Roon's first read finds something.
                for _ in 0..<30 where (self.store?.status?.writtenMs ?? 0) < 500 { try? await Task.sleep(for: .milliseconds(100)) }
                guard self.session === s else { return }
                // Replaced in the meantime (a change of rate right after a skip): the newer slice goes to Roon, not this one.
                guard self.store?.isCurrent(slice) == true else { Log.note("slice \(slice.number) superseded before it reached Roon"); return }
                self.ownUntil = Date().addingTimeInterval(3)
                var answer = await s.play(track: String(slice.number), url: url, info: slice.info)
                Log.note("play slice \(slice.number): Roon answered \(answer)")
                if answer == "Timeout", self.session === s, self.store?.isCurrent(slice) == true {
                    let fresh = url + "?n=\(Int(Date().timeIntervalSince1970 * 1000))"
                    answer = await s.play(track: String(slice.number), url: fresh, info: slice.info)
                    Log.note("play slice \(slice.number) again: Roon answered \(answer)")
                }
                guard self.session === s else { return }
                if answer == "Playing" || answer == "Unpaused" {
                    self.roonSlice = slice.number
                    if self.phase == .starting { self.phase = .playing; self.startHeartbeat() }
                } else if self.phase == .starting {
                    self.fail("Roon: \(answer)")
                }
            }
        } else {
            queued = slice
            Task { @MainActor in
                let answer = await s.play(track: String(slice.number), url: url, info: slice.info, slot: "queue")
                Log.note("queue slice \(slice.number): Roon answered \(answer)")
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.store?.status else { return }
                Log.note("slice \(status.number): \(status.writtenMs) of \(status.lengthMs) ms written; Roon in slice \(self.roonSlice) at \(self.roonPositionMs) ms")
            }
        }
    }

    private func makeInfo(_ track: MusicWatcher.Track) -> JSON {
        var imageURL: String?
        if let cover = music.artwork(), let address {
            // Unique per run, like the slices: Roon caches images by URL, and "c1" of the last run showed the wrong cover.
            coverNumber += 1
            let key = "\(Self.coverRun)-\(coverNumber).\(cover.type == "image/png" ? "png" : "jpg")"
            server.addCover(cover.data, type: cover.type, key: key)
            imageURL = "http://\(address):\(server.port)/cover/\(key)"
        }
        return AudioInputSession.info(title: track.title, artist: track.artist, album: track.album, imageURL: imageURL)
    }

    private func roonEvent(_ event: AudioInputSession.Event) {
        let own = Date() < ownUntil
        if case .time = event {} else { Log.note("roon: \(event)\(own ? " (ours)" : "")") }
        // Events of a slice Roon left behind (an end, an error after a skip) don't count.
        func current(_ track: String) -> Bool { Int(track) ?? 0 >= roonSlice }
        switch event {
        case .playing(let track):
            guard let n = Int(track), n >= roonSlice else { return }
            roonSlice = n
            if queued?.number == n { queued = nil }
            store?.forget(before: n)
        case .time(let track, let ms):
            guard let n = Int(track), n >= roonSlice else { return }
            if n > roonSlice { roonSlice = n; if queued?.number == n { queued = nil }; store?.forget(before: n) }
            roonPositionMs = ms
        case .ended(let track):
            guard Int(track) == roonSlice else { return }
            // The end of a slice: the queued one into the play slot (Roon doesn't take it from the queue itself), with a
            // fresh URL — a long-waiting queued slice can have a failed pre-fetch in Roon's cache (Basso, 5 Oct 2026).
            if let next = queued, let s = session, let address {
                queued = nil
                let url = "http://\(address):\(server.port)\(next.path)?n=\(Int(Date().timeIntervalSince1970 * 1000))"
                Task { @MainActor in
                    let answer = await s.play(track: String(next.number), url: url, info: next.info)
                    Log.note("slice \(next.number) into the play slot at the end of \(track): Roon answered \(answer)")
                }
            }
        case .paused(let track):
            guard current(track) else { return }
            if !own { ownUntil = Date().addingTimeInterval(3); music.pause() }
            phase = .paused
        case .unpaused(let track):
            guard current(track) else { return }
            if !own { ownUntil = Date().addingTimeInterval(3); music.play() }
            phase = .playing
        case .stopped(let track):
            // Roon stops a zone five seconds into a pause; a stop while playing is the user's.
            guard current(track) else { return }
            if phase == .playing, !own { ownUntil = Date().addingTimeInterval(3); music.pause() }
        case .failed(let track, let reason):
            // Only an error of the slice being written counts: a slice dropped at a skip answers a 404 to Roon's last
            // fetches, and Roon may report that as a MediaError before the new slice's play arrives.
            guard Int(track) == roonSlice, Int(track) == store?.status?.number, phase != .starting else { return }
            fail("Roon: \(reason)")
        case .cleared:
            // A slice replaced by a new play (a skip, a cut at a change of rate): Roon confirms it took it out.
            break
        case .control(let control):
            if control.contains("next") { music.next() } else if control.contains("prev") { music.previous() }
        case .sessionEnded:
            // Someone played something else on the zone: give the Mac its output back.
            turnOff()
        }
    }

    /// The device changed rate. The slices follow by themselves (a slice gets the rate its first sound arrives at); the
    /// capture only needs to know, to label what it reads.
    private func deviceRateChanged(_ rate: Double) {
        guard rate != capture.rate else { return }
        Log.note("device: Arco changed to \(Int(rate)) Hz (was \(Int(capture.rate)))")
        capture.rate = rate
    }

    // MARK: - The Music app

    private func musicChanged(_ state: MusicWatcher.State, _ track: MusicWatcher.Track?, _ changed: Bool) {
        Log.note("music: \(state.rawValue)\(changed ? " — \(track?.title ?? "-")" : "")")
        switch phase {
        case .waitingForMusic:
            if state == .playing { Task { await startSession() } }
        case .playing, .paused, .starting:
            if changed, let track, let store {
                // Within two seconds of its end: the natural next track, queued. Further from it: a skip, at once.
                let left = store.remainingSeconds ?? 0
                let natural = left < 2
                Log.note("next track: \(track.title) — \(natural ? "queued" : "at once") (\(String(format: "%.1f", left)) s left in the slice)")
                store.announce(.init(info: makeInfo(track), durationMs: track.durationMs, immediate: !natural))
            }
            if state != .playing, phase == .playing {
                // The slices close at once — whatever silence Music leaves is not written. Roon only hears of a pause
                // that lasts: Music also pauses itself for a moment when its output or rate changes.
                store?.pauseWriting()
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

    /// The store the capture thread writes to — the audio thread never touches the bridge itself.
    private let storeHolder = StoreHolder()
    final class StoreHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var store: SliceStore?
        func set(_ s: SliceStore?) { lock.lock(); store = s; lock.unlock() }
        func write(_ pcm: Data, _ frames: Int, _ firstSound: Int?, rate: Double) {
            lock.lock(); let s = store; lock.unlock()
            s?.write(pcm, frames: frames, firstSound: firstSound, rate: rate)
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
}
