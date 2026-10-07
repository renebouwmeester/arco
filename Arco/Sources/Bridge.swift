// The bridge: the Music app → the Arco output → its loopback → a slice per track → Roon's audio input on the chosen zone.
//
// On: the system output becomes Arco (the previous one is remembered, also across a crash), the loopback is read, and as
// soon as Music plays a session begins on the zone. The current track becomes the first slice, in Roon's play slot.
//
// Through Roon's own queue (see SliceStore): as soon as Roon begins a slice, the next one goes into its queue slot — a
// placeholder until Music begins the next track, then that track with its own length, rate, title, artist, album and
// cover. Roon goes on to it by itself, gapless. Roon plays a few seconds behind:
// - A natural transition (the current track within eight seconds of its end): the next track fills the queued slice.
// - A skip (next, previous, another track or album, or more seconds left): a new slice, into the play slot at once.
// - Roon ends a slice without going on (it opened its queue too late): the next one into the play slot then.
//
// Pause and resume work both ways: Music paused → the slices wait for sound at once, and Roon pauses 0.2 s later;
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
        /// Between the click and "ready": pausing the source, switching the output, starting the capture (1–2 s). The
        /// switch shows on at once — before, it stayed off that long and invited a second click (22:52, three tries).
        case switchingOn
        case waitingForMusic
        case starting
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    private var attempt = 0
    @Published private(set) var zoneName: String?
    /// The rate of the Arco device while sending: what Music set for this track (with Lossless on), 44.1 kHz for Spotify.
    @Published private(set) var rate: Double?
    /// What Roon plays from Arco now — set when Roon starts a run or reaches the next track in it. The menu shows this for
    /// Arco's zone: Roon's own "now playing" of an audio-input session lags behind (Apple's title stayed long after
    /// Spotify had taken over).
    @Published private(set) var nowPlaying: (title: String, artist: String)?

    private let connection: RoonConnection
    private let server = StreamServer()
    private let capture = Capture()
    private let music = MusicWatcher()
    private let spotify = SpotifyWatcher()
    /// The source Arco follows: the app that plays (one voice — when the other one starts, it becomes the source and the
    /// first one is paused).
    private var source: PlayerSource
    private var session: AudioInputSession?
    private var store: SliceStore?
    private var zoneID: String?
    private var address: String?
    /// The slice Roon plays; where it is in it (from its Time events, about once a second) and since when.
    private var roonSlice = 0
    private var roonTimeAt = Date.distantPast
    /// The slice in Roon's queue slot, and the information it was queued with.
    private var queued: Int?
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
        source = music
        try? FileManager.default.removeItem(at: directory)   // leftovers of an earlier run
        for s in [music, spotify] as [PlayerSource] {
            s.onChange = { [weak self, weak s] state, track, changed in
                guard let self, let s else { return }
                self.sourceChanged(s, state, track, changed)
            }
        }
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
        attempt += 1
        let mine = attempt
        /// Still this attempt after an await: no turnOff (a second click) or a newer turnOn came in between.
        func current() -> Bool { attempt == mine && phase == .switchingOn }
        phase = .switchingOn
        zoneName = zone.name
        guard case .paired = connection.state else { return fail("Roon is not connected") }
        guard let arco = AudioDevices.arco else { return fail("Install the Arco audio driver first") }
        // Reading an audio input needs the microphone permission — also for Arco's own loopback. Without it macOS
        // delivers silence, without an error.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return fail(Self.microphoneHint) }
            guard current() else { return }
        default:
            return fail(Self.microphoneHint)
        }
        Log.note("on: zone \(zone.name)")
        guard await server.start() != nil else { return fail("Could not open the stream port") }
        guard current() else { return }
        guard let host = connection.coreHost, let address = Discovery.localAddress(toward: host) else {
            return fail("Can't reach the Roon Core from this Mac")
        }
        self.address = address
        zoneID = zone.id
        // The source: the app that plays now (Music when neither does).
        music.refresh(); spotify.refresh()
        source = spotify.state == .playing && music.state != .playing ? spotify : music
        if source !== spotify, spotify.state == .playing { spotify.pause() }
        // Basso's lesson for a change of output or clock: pause, change, resume. Switching the output under a playing
        // Music app makes it stumble (20:27:58: paused and on again 42 ms later — a hiccup in the music itself).
        let wasPlaying = source.state == .playing
        if wasPlaying {
            source.pause()
            try? await Task.sleep(for: .milliseconds(300))
            guard current() else { return }
        }
        if let current = AudioDevices.defaultOutput, current != arco, let uid = AudioDevices.uid(of: current) {
            UserDefaults.standard.set(uid, forKey: Self.previousOutputKey)
        }
        AudioDevices.setDefaultOutput(arco)
        // The rate: the Music app sets the device to each track's own rate itself (with Lossless on); Spotify plays 44.1.
        if let rate = source.preferredRate { AudioDevices.setSampleRate(rate, of: arco) }
        Log.note("device: Arco at \(Int(AudioDevices.sampleRate(of: arco) ?? 0)) Hz; source \(source.name)")
        let s = SliceStore(directory: directory)
        s.onSliceStarted = { [weak self] slice in self?.sliceStarted(slice) }
        store = s
        storeHolder.set(s)
        server.setStore(s)
        if let error = capture.start(device: arco) { return fail(error) }
        Log.note("capture: reading the Arco input at \(Int(capture.rate)) Hz")
        rate = capture.rate
        rateWatch = AudioDevices.watchSampleRate(of: arco) { [weak self] rate in
            MainActor.assumeIsolated { self?.deviceRateChanged(rate) }
        }
        arcoDevice = arco
        phase = .waitingForMusic
        connection.setStatus("Playing to \(zone.name)")
        // The source starts again on Arco; its "playing" begins the session.
        if wasPlaying { source.play() }
    }

    func turnOff() {
        attempt += 1   // an attempt to turn on that is still under way stops at its next step
        if let rateWatch, let arcoDevice { AudioDevices.stopWatchingSampleRate(of: arcoDevice, rateWatch) }
        rateWatch = nil
        heartbeat?.invalidate(); heartbeat = nil
        pendingPause?.cancel(); pendingPause = nil
        roonPositionMs = 0
        roonSlice = 0
        queued = nil
        queuedTrackKnown = []
        session?.end()
        session = nil
        capture.stop()
        server.setStore(nil)
        storeHolder.set(nil)
        store?.closeAll()
        store = nil
        zoneID = nil
        restoreOutput()
        nowPlaying = nil
        rate = nil
        if phase != .off { connection.setStatus("Ready") }
        phase = .off
    }

    private static let microphoneHint = "Allow Arco to read its audio output: System Settings › Privacy & Security › Microphone"

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
        // The first slice: the current track, from where the source is now.
        guard let track = source.track else { return }
        let left = max(1000, track.durationMs - Int(source.position() * 1000))
        store.start(.init(info: makeInfo(track), durationMs: left))
        // No sound within five seconds: say so instead of waiting for nothing.
        try? await Task.sleep(for: .seconds(5))
        if session === s, phase == .starting, store.status == nil {
            fail("No sound reaches Arco — is \(source.name) playing, to the output Arco?")
        }
    }

    /// A slice for the play slot began (its first sound arrived — the start, a skip, a cut): into Roon at once, with a
    /// little of the music first so Roon's first read finds something.
    private func sliceStarted(_ slice: SliceStore.Slice) {
        guard let s = session, let address else { return }
        let url = "http://\(address):\(server.port)\(slice.path)"
        Task { @MainActor in
            for _ in 0..<30 where (self.store?.status?.writtenMs ?? 0) < 500 { try? await Task.sleep(for: .milliseconds(100)) }
            guard self.session === s else { return }
            // Replaced in the meantime (a skip right after): the newer slice goes to Roon, not this one.
            guard self.store?.isLive(slice.number) == true else { Log.note("slice \(slice.number) superseded before it reached Roon"); return }
            // The slices before it go now: a waiting downloader in Roon would hold the zone's bandwidth.
            self.store?.forget(before: slice.number)
            self.queued = nil
            self.ownUntil = Date().addingTimeInterval(3)
            var answer = await s.play(track: String(slice.number), url: url, info: slice.track?.info ?? [:])
            Log.note("play slice \(slice.number): Roon answered \(answer)")
            if answer == "Timeout", self.session === s, self.store?.isLive(slice.number) == true {
                answer = await s.play(track: String(slice.number), url: Self.fresh(url), info: slice.track?.info ?? [:])
                Log.note("play slice \(slice.number) again: Roon answered \(answer)")
            }
            guard self.session === s else { return }
            if answer == "Playing" || answer == "Unpaused" {
                self.roonBegan(slice.number)
                if self.phase == .starting { self.phase = .playing; self.startHeartbeat() }
            } else if self.phase == .starting {
                self.fail("Roon: \(answer)")
            }
        }
    }

    /// Roon plays slice `n` now: show it, let the older ones go, and put the next one in Roon's queue — at once, so Roon
    /// can open it in time (about eleven seconds before the end) and go on to it by itself.
    private func roonBegan(_ n: Int) {
        guard n >= roonSlice else { return }
        let fresh = n != roonSlice
        roonSlice = n
        roonPositionMs = 0; roonTimeAt = Date()
        if queued == n { queued = nil }
        guard let slice = store?.slice(n) else { return }
        if let info = slice.track?.info {
            nowPlaying = Self.lines(info)
            // Queued as a placeholder: Roon shows what it was queued with until told otherwise.
            if fresh, !queuedWithTrackFor(n) { Task { await session?.updateInfo(track: String(n), info: info) } }
        }
        store?.forget(before: n)
        queueNext(after: n)
    }

    private var queuedTrackKnown: Set<Int> = []
    private func queuedWithTrackFor(_ n: Int) -> Bool { queuedTrackKnown.contains(n) }

    /// The slice after `n` into Roon's queue slot (once).
    private func queueNext(after n: Int) {
        guard let s = session, let address, let next = store?.slice(after: n), queued != next.number else { return }
        queued = next.number
        let url = "http://\(address):\(server.port)\(next.path)"
        // Not known yet: Roon gets the current track's information for now; the real one follows as soon as Music begins
        // the next track (update_track_info), and again when Roon gets there.
        let info = next.track?.info ?? store?.slice(n)?.track?.info ?? [:]
        if next.track != nil { queuedTrackKnown.insert(next.number) }
        Task { @MainActor in
            let answer = await s.play(track: String(next.number), url: url, info: info, slot: "queue")
            Log.note("queue slice \(next.number)\(next.track == nil ? " (not known yet)" : ""): Roon answered \(answer)")
        }
    }

    /// Roon ended slice `n`. Normally it already went on to the queued one by itself (its "Playing" comes with the
    /// end); if not — it opened its queue too late — the next slice goes into the play slot now, with a fresh address
    /// (Roon's cache may hold a failed early fetch of it).
    private func roonEnded(_ n: Int) {
        guard n == roonSlice, let s = session, let address else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard self.session === s, self.roonSlice == n, let next = self.store?.slice(n + 1), self.store?.isKnown(next.number) == true
            else { return }
            Log.note("roon: slice \(n) ended without going on — slice \(next.number) into the play slot")
            self.ownUntil = Date().addingTimeInterval(3)
            let url = Self.fresh("http://\(address):\(self.server.port)\(next.path)")
            let answer = await s.play(track: String(next.number), url: url, info: next.track?.info ?? [:])
            Log.note("play slice \(next.number): Roon answered \(answer)")
            if answer == "Playing" || answer == "Unpaused" { self.roonBegan(next.number) }
        }
    }

    private static func fresh(_ url: String) -> String { url + "?n=\(Int(Date().timeIntervalSince1970 * 1000))" }

    /// Where Roon is in its run now: its last Time event, plus the time since (while it plays).
    private func roonPositionNow() -> Int {
        guard phase == .playing else { return roonPositionMs }
        return roonPositionMs + Int(Date().timeIntervalSince(roonTimeAt) * 1000)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.store?.status else { return }
                Log.note("run \(status.number): \(status.writtenMs) ms written; Roon in run \(self.roonSlice) at \(self.roonPositionMs) ms")
            }
        }
    }

    private func makeInfo(_ track: SourceTrack) -> JSON {
        var imageURL: String?
        switch source.cover() {
        case .data(let data, let type)?:
            // Served by Arco, under an address unique per run: Roon caches images by URL ("c1" of a last run showed the
            // wrong cover).
            if let address {
                coverNumber += 1
                let key = "\(Self.coverRun)-\(coverNumber).\(type == "image/png" ? "png" : "jpg")"
                server.addCover(data, type: type, key: key)
                imageURL = "http://\(address):\(server.port)/cover/\(key)"
            }
        case .url(let url)?:
            imageURL = url          // Spotify's own image address: Roon fetches it itself
        case nil:
            break
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
            // Roon went on to the queued slice by itself (OnToNext), or began one it was given.
            guard let n = Int(track), n >= roonSlice else { return }
            if n > roonSlice { Log.note("roon: on to slice \(n)") }
            roonBegan(n)
        case .time(let track, let ms):
            guard let n = Int(track), n >= roonSlice else { return }
            if n > roonSlice { roonBegan(n) }
            roonPositionMs = ms; roonTimeAt = Date()
        case .ended(let track):
            if let n = Int(track) { roonEnded(n) }
        case .paused(let track):
            guard current(track) else { return }
            if !own { ownUntil = Date().addingTimeInterval(3); source.pause() }
            phase = .paused
        case .unpaused(let track):
            guard current(track) else { return }
            if !own { ownUntil = Date().addingTimeInterval(3); source.play() }
            phase = .playing
        case .stopped(let track):
            // Roon stops a zone five seconds into a pause; a stop while playing is the user's.
            guard current(track) else { return }
            if phase == .playing, !own { ownUntil = Date().addingTimeInterval(3); source.pause() }
        case .failed(let track, let reason):
            // Only an error of the slice being written counts: a slice dropped at a skip answers a 404 to Roon's last
            // fetches, and Roon may report that as a MediaError before the new slice's play arrives.
            guard let n = Int(track), n == roonSlice, store?.isLive(n) == true, phase != .starting else { return }
            fail("Roon: \(reason)")
        case .cleared:
            // A slice replaced by a new play (a skip, a cut at a change of rate): Roon confirms it took it out.
            break
        case .control(let control):
            if control.contains("next") { source.next() } else if control.contains("prev") { source.previous() }
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
        self.rate = rate
        rateChangedAt = Date()
    }

    // MARK: - The sources (Music, Spotify)

    private func sourceChanged(_ s: PlayerSource, _ state: SourceState, _ track: SourceTrack?, _ changed: Bool) {
        Log.note("\(s.name.lowercased()): \(state.rawValue)\(changed ? " — \(track?.title ?? "-")" : "")\(s === source ? "" : " (not the source)")")
        guard phase != .switchingOn else { return }   // turnOn chooses the source itself, and pauses it on purpose
        if s !== source {
            // The other app starts playing: it becomes the source (one voice), the first one pauses, and a new run begins
            // at once — like a skip. Its pausing and stopping otherwise don't matter.
            guard state == .playing, phase != .off else { return }
            switchSource(to: s)
            return
        }
        switch phase {
        case .waitingForMusic:
            if state == .playing { Task { await startSession() } }
        case .playing, .paused, .starting:
            if changed, let track, let store {
                // Within eight seconds of the end of the slice being written: the natural next track — it fills the
                // queued slice. Further from it: a skip. Eight, not two: what is left of the first track of a session is
                // estimated from Music's position at the start, and that was 6 s off (21:27:53, "The End").
                let left = store.remainingInTrack
                let info = makeInfo(track)
                let leftText = left.map { String(format: "%.1f s left", $0) } ?? "in the next slice"
                switch store.trackChanged(.init(info: info, durationMs: track.durationMs)) {
                case .next(let slice):
                    Log.note("next track: \(track.title) — slice \(slice.number) (\(leftText))")
                    if queued == slice.number, !queuedTrackKnown.contains(slice.number) {
                        queuedTrackKnown.insert(slice.number)
                        Task { [weak self] in
                            let answer = await self?.session?.updateInfo(track: String(slice.number), info: info)
                            Log.note("queued slice \(slice.number): information sent — Roon answered \(answer ?? "-")")
                        }
                    }
                case .skip:
                    Log.note("next track: \(track.title) — a skip, a new slice at once (\(leftText))")
                    queued = nil
                    store.start(.init(info: info, durationMs: track.durationMs))
                }
            }
            if state == .stopped, phase == .playing {
                // The end of an album or a playlist: Roon plays out what it has, nothing comes after it.
                store?.endOfMusic()
                Log.note("source stopped — Roon plays out what it has")
                return
            }
            if state != .playing, phase == .playing {
                // The run closes at once — whatever silence Music leaves is not written. Roon pauses 0.2 s later, unless
                // Music plays again by then or the rate changes around it: then it was Music changing the clock (~1.2 s;
                // the rate change comes just before its pause, or at most 0.12 s after — 21:34:58), which must not reach
                // Roon. Not longer: paused 0.6 s late (21:36:43), Roon paused its player but left the KEF playing until it
                // released it five seconds later — and the restart then took five seconds; paused at once, the KEF paused
                // at once and resumed quickly (21:26:30, 21:34:26) — as with Qobuz.
                store?.pauseWriting()
                pendingPause?.cancel()
                pendingPause = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, !Task.isCancelled, self.source.state != .playing, self.phase == .playing else { return }
                    if Date().timeIntervalSince(self.rateChangedAt) < 2 {
                        Log.note("pause: Music changes the clock — Roon plays on")
                        return
                    }
                    self.roonControl("pause")
                    self.phase = .paused
                    // Keep Roon's reader awake while it passes the pause on, a little music at a time — all of the held-back
                    // part, as Roon's own "Paused" comes also when the KEF was not paused (21:46:19) and says nothing.
                    for _ in 0..<10 where self.phase == .paused {
                        self.store?.release(seconds: 0.04)
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
            } else if state == .playing {
                pendingPause?.cancel(); pendingPause = nil
                if phase == .paused {
                    // Roon goes on at once (after a short pause it doesn't even re-open RAAT). Holding Music back until Roon
                    // played (c579c99) got in the way — during a change of clock above all.
                    roonControl("play")
                    phase = .playing
                }
            }
        default:
            break
        }
    }

    private var rateChangedAt = Date.distantPast

    /// Another app plays: it becomes the source. The first one pauses (Arco's own doing), the device gets the new source's
    /// rate, and its track begins a new run at once.
    private func switchSource(to s: PlayerSource) {
        let old = source
        source = s
        Log.note("source: \(old.name) → \(s.name)")
        if old.state == .playing { ownUntil = Date().addingTimeInterval(3); old.pause() }
        if let rate = s.preferredRate, let arco = arcoDevice, AudioDevices.sampleRate(of: arco) != rate {
            AudioDevices.setSampleRate(rate, of: arco)
        }
        switch phase {
        case .waitingForMusic:
            Task { await startSession() }
        case .playing, .paused, .starting:
            if let track = s.track { queued = nil; store?.start(.init(info: makeInfo(track), durationMs: track.durationMs)) }
            if phase == .paused { roonControl("play"); phase = .playing }
        default:
            break
        }
    }

    /// Title and artist from Roon's track information.
    private static func lines(_ info: JSON) -> (title: String, artist: String)? {
        guard let two = info["two_line"] as? JSON, let title = two["line1"] as? String else { return nil }
        return (title, two["line2"] as? String ?? "")
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
