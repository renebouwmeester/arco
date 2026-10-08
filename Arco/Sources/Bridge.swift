// The bridge: the Music app → the Arco output → its loopback → a slice per track → Roon's audio input on the chosen zone.
//
// On: the system output becomes Arco (the previous one is remembered, also across a crash), the loopback is read, and as
// soon as Music plays a session begins on the zone. The current track becomes the first slice, in Roon's play slot.
//
// Runs (see SliceStore): tracks at the same rate run on in one stream, gapless; each track's title, artist, album and
// cover go to Roon (update_track_info) when Roon's own position reaches it. Roon plays a few seconds behind:
// - A natural transition (the current track within two seconds of its end): the run simply goes on; a mark.
// - A skip (next, previous, another track or album, or more than two seconds left): a new run, into the play slot at once.
// - A change of rate (the Music app sets the device to each track's own rate, with Lossless on): the run is frozen where
//   the rate changed, and the new run goes into the play slot just as Roon reaches that point — nothing of the old run
//   is lost, and the seam falls where Music itself paused to change the clock.
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
    /// The run Roon plays; where it is in it (from its Time events, about once a second) and since when.
    private var roonSlice = 0
    private var roonTimeAt = Date.distantPast
    /// Track starts inside runs, for Roon's track information when Roon gets there: (run, ms, info).
    private var marks: [(number: Int, ms: Int, info: JSON)] = []
    /// Until when Roon's pause / play events are our own doing.
    private var ownUntil = Date.distantPast
    /// The clock per track (0.3.0): the Music app never changes the rate itself — Arco does (see TrackClock).
    private let clock = TrackClock()
    /// The Music app's own log of the formats it sets up (0.3.3, see FormatLog) — first source of a track's rate.
    private let formats = FormatLog()
    private var lastChangeAt: Date?
    private var lastClockChange: (id: String, at: Date)?
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
        formats.onLossless = { [weak self] at, rate in self?.lateLossless(at: at, rate: rate) }
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
    /// A session in Roon, playing or paused: the menu bar shows the rate then.
    var isSending: Bool {
        switch phase {
        case .starting, .playing, .paused: return true
        default: return false
        }
    }
    /// Spotify as a source: in the code, off unless asked for (René, 8 Oct: Arco is Apple Music in Roon; Spotify goes to
    /// Roon by way of a Spotify Connect endpoint). `defaults write nl.renebouwmeester.arco SpotifySource -bool true`.
    static var spotifyEnabled: Bool { UserDefaults.standard.bool(forKey: "SpotifySource") }

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
        music.refresh()
        if Self.spotifyEnabled {
            spotify.refresh()
            source = spotify.state == .playing && music.state != .playing ? spotify : music
            if source !== spotify, spotify.state == .playing { spotify.pause() }
        } else {
            source = music
        }
        // The format log first: switching the output makes the Music app set up a new queue, and that line names the rate of
        // the track that plays (see FormatLog).
        formats.start()
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
        // The rate: Spotify plays 44.1; for the Music app it follows each track once the session runs (TrackClock).
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
        formats.stop()
        lastChangeAt = nil
        if let rateWatch, let arcoDevice { AudioDevices.stopWatchingSampleRate(of: arcoDevice, rateWatch) }
        rateWatch = nil
        heartbeat?.invalidate(); heartbeat = nil
        pendingPause?.cancel(); pendingPause = nil
        roonPositionMs = 0
        roonSlice = 0
        marks = []
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
        // ?v=: Roon keeps a source's icon by its URL — bump it when the icon changes
        guard await s.begin(displayName: "Arco", iconURL: "http://\(address):\(server.port)/icon.png?v=2") else {
            return fail("Roon didn't start a session on this zone")
        }
        session = s
        Log.note("session: began on the zone; slices at http://\(address):\(server.port)")
        // The first run: the current track, from where the source is now.
        guard let track = source.track else { return }
        let left = max(1000, track.durationMs - Int(source.position() * 1000))
        store.startTrack(.init(info: makeInfo(track), durationMs: left), newRun: true)
        followClock(track, kind: .start)
        // No sound within five seconds: say so instead of waiting for nothing.
        try? await Task.sleep(for: .seconds(5))
        if session === s, phase == .starting, store.status == nil {
            fail("No sound reaches Arco — is \(source.name) playing, to the output Arco?")
        }
    }

    /// A run began (its first sound arrived): into Roon's play slot — at once (the start, a skip), or just as Roon reaches
    /// the point where the run before it was frozen (a change of rate).
    private func sliceStarted(_ slice: SliceStore.Slice) {
        guard let s = session, let address else { return }
        let url = "http://\(address):\(server.port)\(slice.path)"
        Task { @MainActor in
            // Follows a run Roon never got (cut 0.2 s into a start, when the rate changed at once): nothing to wait for.
            if let follows = slice.follows, self.roonSlice == follows.number {
                // Wait until Roon is a quarter of a second before the point of the change (at most the time it still has
                // to play there, plus some slack).
                let deadline = Date().addingTimeInterval(Double(max(0, follows.atMs - self.roonPositionNow())) / 1000 + 15)
                while Date() < deadline, self.session === s, self.roonSlice == follows.number,
                      self.roonPositionNow() < follows.atMs - 250 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                Log.note("run \(slice.number): Roon at \(self.roonPositionNow()) ms of run \(follows.number) (frozen at \(follows.atMs))")
                // And the new run's own supply: the seam in Roon is then as long as Music's own pause to change the clock.
                await self.waitForSupply()
            } else {
                // The first run of a session: four seconds at one rate first (at most six) — the Music app starts at the
                // device's old rate and switches to the track's own 0.2–5.5 s later (7 Oct 21:53: four); a switch before
                // Roon has the header is converted in place. A skip within a session keeps its half second (7 Oct 22:12, on
                // the Ellipse: four seconds more after every "next" was too slow); a change of rate after it is caught by
                // freezing the run, as between two tracks.
                let settle = self.roonSlice == 0 ? 4.0 : 0.5
                for _ in 0..<60 where self.store?.isSettled(slice, seconds: settle) != true { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard self.session === s else { return }
            // Replaced in the meantime (a skip right after): the newer run goes to Roon, not this one.
            guard self.store?.isCurrent(slice) == true else { Log.note("run \(slice.number) superseded before it reached Roon"); return }
            // The run before it (frozen, or cut) goes now: its waiting downloader in Roon would hold the zone's bandwidth.
            self.store?.forget(before: slice.number)
            self.ownUntil = Date().addingTimeInterval(3)
            var answer = await s.play(track: String(slice.number), url: url, info: slice.info)
            Log.note("play run \(slice.number) (\(Self.lines(slice.info)?.title ?? "?")): Roon answered \(answer)")
            if answer == "Timeout", self.session === s, self.store?.isCurrent(slice) == true {
                let fresh = url + "?n=\(Int(Date().timeIntervalSince1970 * 1000))"
                answer = await s.play(track: String(slice.number), url: fresh, info: slice.info)
                Log.note("play run \(slice.number) again: Roon answered \(answer)")
            }
            guard self.session === s else { return }
            if answer == "Playing" || answer == "Unpaused" {
                self.roonSlice = slice.number
                self.nowPlaying = Self.lines(slice.info)
                self.roonPositionMs = 0; self.roonTimeAt = Date()
                self.marks.removeAll { $0.number < slice.number }
                if self.phase == .starting { self.phase = .playing; self.startHeartbeat() }
            } else if self.phase == .starting {
                self.fail("Roon: \(answer)")
            }
        }
    }

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
            guard let n = Int(track), n >= roonSlice else { return }
            if n > roonSlice { roonSlice = n; roonPositionMs = 0; roonTimeAt = Date() }
        case .time(let track, let ms):
            guard let n = Int(track), n >= roonSlice else { return }
            roonSlice = n
            roonPositionMs = ms; roonTimeAt = Date()
            // Roon reached the start of the next track in its run: now it shows it.
            while let i = marks.firstIndex(where: { $0.number == n && $0.ms <= ms + 300 }) {
                let mark = marks.remove(at: i)
                nowPlaying = Self.lines(mark.info)
                Log.note("roon reached \(mark.ms) ms of run \(n): track information → \(Self.lines(mark.info)?.title ?? "?")")
                Task { await session?.updateInfo(track: track, info: mark.info) }
            }
        case .ended:
            // A run only ends at three hours, and is followed by then (frozen); nothing to do.
            break
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
            guard Int(track) == roonSlice, Int(track) == store?.status?.number, phase != .starting else { return }
            // Once more first (7 Oct 22:15: the Ellipse on wifi stopped with an error and Arco switched off): a new run
            // from where the source is. A second error within half a minute switches off.
            if Date().timeIntervalSince(lastRetry) > 30, let t = source.track, let store {
                lastRetry = Date()
                let left = max(1000, t.durationMs - Int(source.position() * 1000))
                Log.note("roon: \(reason) — once more, a new run")
                store.startTrack(.init(info: makeInfo(t), durationMs: left), newRun: true)
                return
            }
            fail("Roon: \(reason)")
        case .cleared:
            // A slice replaced by a new play (a skip, a cut at a change of rate): Roon confirms it took it out.
            break
        case .control(let control):
            if control.contains("next") { source.next() }
            else if control.contains("prev") {
                // "Previous" a few seconds into a track starts it over: the Music app reports no new track, so nothing
                // would change in the run and Roon would play the restart only after its lag (7 Oct 22:17). Without a new
                // track within half a second, the current one begins a new run from its start.
                let before = source.track?.id
                source.previous()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, let store = self.store, let t = self.source.track, t.id == before,
                          self.phase == .playing || self.phase == .paused else { return }
                    Log.note("previous: \(t.title) starts over — a new run")
                    store.startTrack(.init(info: self.makeInfo(t), durationMs: t.durationMs), newRun: true)
                }
            }
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
        if s === spotify, !Self.spotifyEnabled { return }
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
                // Within eight seconds of its end: the natural next track, going on in the run. Further from it: a skip.
                // Eight, not two: what is left of the first track of a session is estimated from Music's position at the
                // start, and that was 6 s off (21:27:53, "The End"). Taking a natural transition for a skip would drop the
                // run, and Roon would lose the end of the track; a skip in the last seconds is merely heard a little later.
                let left = store.remainingInTrack ?? 0
                let natural = left < 8
                let info = makeInfo(track)
                // No length in Music's notification (a streamed track, 7 Oct 22:06: the Aria counted as one second, and
                // the next "next" looked like a natural end): ask Music once more when it has loaded the track.
                if track.durationMs <= 0 { refreshLength(of: track.id) }
                if state == .playing { followClock(track, kind: natural ? .natural : .skip) }
                if let mark = store.startTrack(.init(info: info, durationMs: track.durationMs), newRun: !natural) {
                    marks.append((mark.number, mark.ms, info))
                    Log.note("next track: \(track.title) — goes on in run \(mark.number) at \(mark.ms) ms (\(String(format: "%.1f", left)) s were left)")
                } else {
                    Log.note("next track: \(track.title) — \(natural ? "begins the next run" : "a skip, a new run at once") (\(String(format: "%.1f", left)) s were left)")
                }
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
                    // In tenths of all that is held back (17:05:36: with 1.2 s held, ten steps of 0.04 s never got past what
                    // Roon had read once the pause's tail was cut — Roon kept the KEF playing, and play gave no sound).
                    for _ in 0..<10 where self.phase == .paused {
                        self.store?.release(seconds: SliceStore.holdBackSeconds / 10)
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
            } else if state == .playing {
                pendingPause?.cancel(); pendingPause = nil
                // Roon far behind the stream on resuming (12:52:48: 110 s — the Music app played on through a pause it
                // never made, its AppleScript timed out): no use catching up; a new run from where Music is, as at a skip.
                if phase == .paused, let status = store?.status, roonSlice == status.number,
                   status.writtenMs - roonPositionMs > 20_000, let track {
                    let left = max(1000, track.durationMs - Int(s.position() * 1000))
                    Log.note("resume: Roon is \((status.writtenMs - roonPositionMs) / 1000) s behind — a new run from where the Music app is")
                    store?.startTrack(.init(info: makeInfo(track), durationMs: left), newRun: true)
                }
                // The splice (0.3.2, see Splice): the Music app a little back, the run's end found again in the new sound.
                // Not near the start of a track (back would be another track), and not for Spotify.
                if phase == .paused { formats.quiet(for: 2.5) }   // a resume: a queue set up now is about this track
                if phase == .paused, s === music, let store, store.status.map({ roonSlice == $0.number }) == true {
                    let at = s.position()
                    if at >= 2.5 {
                        store.prepareSplice(back: 1.2)
                        music.seek(to: at - 1.2)
                        Log.note(String(format: "resume: the Music app 1.2 s back (at %.1f s) — a splice", at))
                    }
                }
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

    // MARK: - The clock per track (0.3.0, see TrackClock)

    /// A new track of the Music app: its own rate, and the Arco device set to it.
    private func followClock(_ track: SourceTrack, kind: FormatLog.Change) {
        guard TrackClock.enabled, source === music, let arco = arcoDevice else { return }
        let change = Date(), previous = lastChangeAt
        lastChangeAt = change
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = { self.source === self.music && self.music.track?.id == track.id && self.isOn }
            // First the Music app's own log (0.3.3); AppleScript once beside it, or on its own when the log has nothing.
            var read: (rate: Int, how: String)?
            let now = Int(AudioDevices.sampleRate(of: arco) ?? 0)
            let fromLog = await self.formats.rate(kind, change: change, previous: previous, current: now)
            if let fromLog {
                read = fromLog
                if let s = self.music.sampleRate(), s > 0, Int(s) != fromLog.rate {
                    Log.note("clock: \(track.title) — the log says \(fromLog.rate) Hz, AppleScript \(Int(s)) Hz: the log it is")
                }
            } else {
                read = await self.clock.readRate(of: track, music: self.music, stillCurrent: current)
            }
            guard current(), let read else {
                if current() { Log.note("clock: \(track.title) — the Music app names no rate; Arco stays at \(Int(AudioDevices.sampleRate(of: arco) ?? 0)) Hz") }
                return
            }
            self.clock.remember(read.rate, for: track)
            await self.setClock(read.rate, for: track, how: read.how, fromStart: true)
            // From the log, the rate is what the decoder set up: no second opinion from AppleScript (on macOS 15 it would
            // "correct" it to 44.1).
            if fromLog != nil { return }
            // One more reading five seconds later: a late correction from the Music app.
            try? await Task.sleep(for: .seconds(5))
            guard current(), let r = self.music.sampleRate(), r > 0 else { return }
            // Always in the log (0.3.1): a tester's "96 kHz" track stayed at 44.1 — what the Music app says later settles it.
            Log.note("clock: \(track.title) — five seconds in, the Music app says \(Int(r)) Hz")
            guard Int(r) != read.rate else { return }
            self.clock.remember(Int(r), for: track)
            await self.setClock(Int(r), for: track, how: "the Music app, five seconds in", fromStart: false)
        }
    }

    /// A lossless line that came after the clock was chosen (0.3.4): the Music app started the track in AAC and set up the
    /// real format later. Up to 20 s after the change of track, set the clock after all, and remember the track's rate.
    private func lateLossless(at: Date, rate: Int) {
        guard TrackClock.enabled, isOn, source === music, let change = lastChangeAt, at >= change,
              at.timeIntervalSince(change) < 20, let track = music.track, let arco = arcoDevice else { return }
        clock.remember(rate, for: track)
        guard music.state == .playing, AudioDevices.bestRate(Double(rate), of: arco) != AudioDevices.sampleRate(of: arco) else { return }
        Log.note("clock: \(track.title) — the Music app's log now says \(rate) Hz (it started otherwise): correcting")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.setClock(rate, for: track, how: "the Music app's log, late", fromStart: self.music.position() < 3)
        }
    }

    /// Basso's way for a change of clock: pause the Music app, set the rate, back to the start of the track if it only
    /// just began, play. The pause doesn't reach Roon (a change of rate within 0.2 s of it: "Music changes the clock").
    private func setClock(_ rate: Int, for track: SourceTrack, how: String, fromStart: Bool) async {
        guard let arco = arcoDevice, let now = AudioDevices.sampleRate(of: arco) else { return }
        let target = AudioDevices.bestRate(Double(rate), of: arco)
        if target != Double(rate) {
            Log.note("clock: \(rate) Hz isn't offered by the Arco device (\(AudioDevices.availableRates(of: arco).map { String(Int($0)) }.joined(separator: ", "))) — \(Int(target)) instead")
        }
        guard target != now else { Log.note("clock: \(track.title) — \(rate) Hz (\(how)), Arco is there already"); return }
        // Never two changes for one track within two seconds: a reading that keeps changing mustn't make Music stumble.
        if let last = lastClockChange, last.id == track.id, Date().timeIntervalSince(last.at) < 2 { return }
        lastClockChange = (track.id, Date())
        let back = fromStart && music.position() < 3
        let playing = music.state == .playing
        Log.note("clock: \(track.title) — \(rate) Hz (\(how)): Arco \(Int(now)) → \(Int(target)) Hz\(back ? ", from the start" : "")")
        ownUntil = Date().addingTimeInterval(3)
        formats.quiet(for: 2.5)   // the queue the Music app sets up again now is about this track (see FormatLog)
        // Before the pause, which can take the Music app two seconds (17:08:39): from now on Roon gets nothing past the
        // track's start.
        if back { store?.restartTrackAtNewRate() }
        if playing { music.pause() }
        AudioDevices.setSampleRate(target, of: arco)
        try? await Task.sleep(for: .milliseconds(250))
        if back { music.seekToStart() }
        guard playing else { return }
        music.play()
        // Does it play? (8 Oct 16:42, Wildwood Flower after autoplay: the Music app carried out the pause a second late and
        // swallowed the play right behind it — it stood paused at 0.36 s and Roon got a run without music.) Basso's way:
        // look, and press play again — up to three times.
        for attempt in 1...3 {
            try? await Task.sleep(for: .milliseconds(800))
            guard isOn, source === music, music.track?.id == track.id else { return }
            if music.isPlayingNow() { return }
            Log.note("clock: the Music app didn't play again — play (\(attempt))")
            music.play()
        }
    }

    /// Roon's supply: how far the stream is ahead of Roon. Roon plays a few seconds behind, and those seconds are what
    /// keeps it fed; at the edge of the stream it starves (it counts on, without sound).
    private static let supplyMs = 5000
    private var rateChangedAt = Date.distantPast
    /// The last time a Roon error got a second try.
    private var lastRetry = Date.distantPast

    /// Waits (at most eight seconds) until the stream is `supplyMs` ahead of where Roon is in the current run.
    private func waitForSupply() async {
        let until = Date().addingTimeInterval(8)
        while Date() < until, let status = store?.status {
            let roonAt = roonSlice == status.number ? roonPositionMs : 0
            if status.writtenMs - roonAt >= Self.supplyMs - 300 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

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
            if let track = s.track { store?.startTrack(.init(info: makeInfo(track), durationMs: track.durationMs), newRun: true) }
            if phase == .paused { roonControl("play"); phase = .playing }
        default:
            break
        }
    }

    /// The real length of the track that plays now, from the source a moment later.
    private func refreshLength(of id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.source.track?.id == id else { return }
            self.source.refresh()
            guard let t = self.source.track, t.id == id, t.durationMs > 0 else { return }
            let left = t.durationMs - Int(self.source.position() * 1000)
            self.store?.setRemaining(ms: left)
            Log.note("length: \(t.title) — \(t.durationMs / 1000) s, \(left / 1000) s left")
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
