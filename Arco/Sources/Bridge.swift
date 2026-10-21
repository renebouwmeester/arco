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
    /// The Music app's volume while Arco sends it (0.4.0): below 100 the music isn't bit-perfect — the menu says so.
    @Published private(set) var musicVolume: Int?
    func setMusicVolumeTo100() { music.setVolume(100); musicVolume = 100; Log.note("music: volume set to 100 (bit-perfect)") }
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
    /// Roon's audio input on a zone, or a UPnP renderer (see Output).
    private var session: Output?
    private var store: SliceStore?
    private var target: Target?
    /// The output plays to a UPnP renderer (experimental, see UPnP.swift).
    var isUPnP: Bool { if case .upnp = target { return true }; return false }
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
    /// One line per change of track: how it went (0.4.0, see TransitionMeter).
    private let meter = TransitionMeter()
    private var lastChangeAt: Date?
    /// Until when a lossless line may still correct the clock of this track (9 Oct): not once its rate came from a
    /// lossless line — later lines are the next track's, loaded ahead (20:06:53: after a restart mid-track, the next
    /// track's 44.1 line was taken for a correction, and a 96 track went on at 44.1); 3 s after a natural change that
    /// had no line (Traces of a Song: 1.8 s); 20 s when AppleScript had to answer for a skip or a start (Moon River: 13 s).
    private var correctable: (trackID: String, until: Date)?
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
        formats.onLabel = { [weak self] label in self?.labelArrived(label) }
        formats.onNext = { [weak self] _ in self?.declareNext() }
        meter.rate = { [weak self] in self?.rate }
        // The Music app's volume, every fifteen seconds while Arco sends it (0.4.0).
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                let v = self.isOn && self.source === self.music ? self.music.volume() : nil
                if v != self.musicVolume {
                    if let v, v < 100 { Log.note("music: volume \(v) — not bit-perfect") }
                    self.musicVolume = v
                }
            }
        }
        formats.deviceRate = { [weak self] in Int(self?.capture.rate ?? 0) }
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
    /// A fixed rate per zone (0.3.7, René: "an optional 96 cap that makes for a smoother, continuous stream, as with
    /// Spotify"): the Arco device stays at 96 kHz for the Music app, so there's never a change of rate — no run frozen and
    /// started again, no DAC locking on to a new rate, no seam in Roon. The price: the Music app resamples whatever isn't
    /// 96 kHz. Off by default (bit-perfect, the device follows each track); remembered by zone name — Roon gives a zone a
    /// new id when it's grouped.
    static let fixedRate: Double = 96_000
    private static let fixedKey = "FixedRateZones"
    @Published private(set) var fixedZones = Set(UserDefaults.standard.stringArray(forKey: "FixedRateZones") ?? [])
    func isFixed(_ zoneName: String) -> Bool { fixedZones.contains(zoneName) }
    /// The zone Arco plays to now has the fixed rate, and the Music app is the source.
    private var fixedNow: Bool { source === music && zoneName.map(isFixed) == true }
    func setFixed(_ on: Bool, for zoneName: String) {
        if on { fixedZones.insert(zoneName) } else { fixedZones.remove(zoneName) }
        UserDefaults.standard.set(fixedZones.sorted(), forKey: Self.fixedKey)
        Log.note("rate: \(zoneName) — \(on ? "fixed at 96 kHz" : "follows each track")")
        guard isOn, zoneName == self.zoneName, source === music else { return }
        if on { holdFixedRate(why: "chosen in the menu") }
        else { Log.note("rate: the device follows the tracks again from the next one") }
    }
    /// The Arco device to 96 kHz now — the way of a change of clock (pause, set, play) when the Music app plays.
    private func holdFixedRate(why: String) {
        guard let arco = arcoDevice else { return }
        let target = AudioDevices.bestRate(Self.fixedRate, of: arco)
        guard AudioDevices.sampleRate(of: arco) != target else { return }
        Log.note("rate: back to \(Int(target)) Hz, fixed (\(why))")
        if let track = music.track, music.state == .playing {
            Task { @MainActor [weak self] in await self?.setClock(Int(target), for: track, how: "fixed", fromStart: false) }
        } else {
            AudioDevices.setSampleRate(target, of: arco)
        }
    }

    // MARK: - On and off

    func turnOn(zone: RoonZone) async { await turnOn(.roon(zone)) }
    func turnOn(renderer: UPnPRenderer) async { await turnOn(.upnp(renderer)) }

    func turnOn(_ target: Target) async {
        turnOff()
        attempt += 1
        let mine = attempt
        /// Still this attempt after an await: no turnOff (a second click) or a newer turnOn came in between.
        func current() -> Bool { attempt == mine && phase == .switchingOn }
        phase = .switchingOn
        zoneName = target.name
        if case .roon = target { guard case .paired = connection.state else { return fail("Roon is not connected") } }
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
        Log.note("on: \(isUPnPTarget(target) ? "UPnP renderer" : "zone") \(target.name)")
        guard await server.start() != nil else { return fail("Could not open the stream port") }
        guard current() else { return }
        let host: String?
        switch target {
        case .roon: host = connection.coreHost
        case .upnp(let r): host = r.host
        }
        guard let host, let address = Discovery.localAddress(toward: host) else {
            return fail(isUPnPTarget(target) ? "Can't reach \(target.name) from this Mac" : "Can't reach the Roon Core from this Mac")
        }
        self.address = address
        self.target = target
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
        else if fixedNow { AudioDevices.setSampleRate(AudioDevices.bestRate(Self.fixedRate, of: arco), of: arco) }
        Log.note("device: Arco at \(Int(AudioDevices.sampleRate(of: arco) ?? 0)) Hz; source \(source.name)\(fixedNow ? " — fixed at 96 kHz for this zone" : "")")
        let s = SliceStore(directory: directory)
        s.perTrack = isUPnPTarget(target)   // a slice per track for a UPnP renderer (see Slices.swift)
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
        connection.setStatus("Playing to \(target.name)")
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
        nextSent = 0
        marks = []
        session?.end()
        session = nil
        capture.stop()
        server.setStore(nil)
        storeHolder.set(nil)
        store?.closeAll()
        store = nil
        target = nil
        restoreOutput()
        nowPlaying = nil
        rate = nil
        meter.end()
        if phase != .off { connection.setStatus("Ready") }
        phase = .off
    }

    private func isUPnPTarget(_ t: Target) -> Bool { if case .upnp = t { return true }; return false }

    private static let microphoneHint = "Allow Arco to read its audio output: System Settings › Privacy & Security › Microphone"

    private func fail(_ message: String) {
        Log.note("failed: \(message)")
        turnOff()
        phase = .failed(message)
    }

    // MARK: - The session in Roon

    private func startSession() async {
        guard let target, let address, let store else { return }
        phase = .starting
        let s: Output
        switch target {
        case .roon(let zone): s = RoonOutput(connection: connection, zone: zone)
        case .upnp(let renderer): s = UPnPOutput(renderer: renderer)
        }
        s.onEvent = { [weak self] event in self?.roonEvent(event) }
        // ?v=: Roon keeps a source's icon by its URL — bump it when the icon changes
        guard await s.begin(displayName: "Arco", iconURL: "http://\(address):\(server.port)/icon.png?v=5") else {
            return fail(isUPnPTarget(target) ? "\(target.name) doesn't answer" : "Roon didn't start a session on this zone")
        }
        session = s
        Log.note("session: began on the zone; slices at http://\(address):\(server.port)")
        if let t = source.track { meter.begin(t.title, kind: .start) }
        // The first run: the current track, from where the source is now.
        guard let track = source.track else { return }
        let left = max(1000, track.durationMs - Int(source.position() * 1000))
        store.startTrack(.init(info: makeInfo(track), durationMs: left), newRun: true)
        if !lastInfoHadCover { lateCover(track) }   // also the first track of a session (16:08:13, after a restart)
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
                // A UPnP renderer that ran dry at the frozen point (it knows its position only to the second): at once.
                while Date() < deadline, self.session === s, self.roonSlice == follows.number,
                      self.roonPositionNow() < follows.atMs - 250, !(self.session?.isStarved ?? false) {
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
                // A UPnP renderer: its own lead (UPnP.swift — the Ellipse and the Mu-so want 3 s, plus what Arco holds back).
                let settle = s.lead ?? (self.roonSlice == 0 ? 4.0 : 0.5)
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
            // A MediaError for a run of a running session (9 Oct 20:27:10, a skip: Roon still closing the dropped run
            // refused the new one at once, and the zone stayed silent): once more, a second later.
            let retry = answer == "Timeout" || (answer == "MediaError" && self.phase != .starting)
            if retry, self.session === s, self.store?.isCurrent(slice) == true {
                if answer == "MediaError" { try? await Task.sleep(for: .seconds(1)) }
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
                self.nextSent = slice.number      // a new transport URI clears the renderer's next: set it again
                self.movedOn(to: slice.number)   // per track: and its next
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

    /// Whether the last makeInfo found a cover (0.4.0, see lateCover).
    private var lastInfoHadCover = false

    private func makeInfo(_ track: SourceTrack) -> JSON {
        var imageURL: String?
        defer { lastInfoHadCover = imageURL != nil }
        switch source.cover() {
        case .data(let data, let type)?:
            defer { lastImageURL = imageURL }
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
            if n > roonSlice { roonSlice = n; roonPositionMs = 0; roonTimeAt = Date(); movedOn(to: n) }
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
            // Per track: the renderer reached the end of a slice nothing was set after — the next one at once, if there is one.
            // (A slice that follows another one is played by sliceStarted itself, when the renderer runs dry.)
            if store?.perTrack == true, let n = Int(track), let next = store?.slice(after: n), next.written > 0, next.declared {
                playNow(next, why: "the renderer stopped at the end of slice \(n)")
                return
            }
            // Only a stop of the run being written: a UPnP renderer stops when a skip drops the run it played (21 Oct
            // 2026, the Ellipse) — that is Arco's doing, and the Music app must play on.
            guard Int(track) == store?.status?.number else { return }
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
        // 0.3.7: the Music app sometimes sets the device to the track's rate itself (8 Oct, Traces of a Song) — on a zone
        // with a fixed rate it goes back.
        if fixedNow, isOn, let arco = arcoDevice, rate != AudioDevices.bestRate(Self.fixedRate, of: arco) {
            holdFixedRate(why: "the device was changed")
        }
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
                // 0.3.5: the Music app named this track as the next one — a natural change within fifteen seconds of
                // the end too (the estimate of the first track of a session was 6 s off); further from it, it is still a
                // skip (to the next track: Roon should follow at once, not after its lag).
                let named = source === music ? formats.named(track.title) : nil
                // The Music app's own word first (setTargetContentItemID … source:NaturalTransition, 17:47:14 — after a
                // seek Arco thought 142 s were left and took it for a skip).
                let said = source === music ? formats.transition(to: track.title) : nil
                let natural = said ?? (left < 8 || (named != nil && left < 15))
                if let said, said != (left < 8) {
                    Log.note("next track: \(track.title) — the Music app says \(said ? "a natural change" : "a jump") (\(String(format: "%.1f", left)) s were left by the estimate)")
                }
                let info = makeInfo(track)
                // No length in Music's notification (a streamed track, 7 Oct 22:06: the Aria counted as one second, and
                // the next "next" looked like a natural end): the length the Music app's log gave (0.3.5), else ask
                // Music once more when it has loaded the track.
                var track = track
                if track.durationMs <= 0, let ms = formats.length(of: track.title) {
                    track = SourceTrack(id: track.id, title: track.title, artist: track.artist, album: track.album, durationMs: ms)
                    Log.note("length: \(track.title) — \(ms / 1000) s, from the Music app's log")
                }
                if track.durationMs <= 0 { refreshLength(of: track.id) }
                meter.begin(track.title, kind: natural ? .natural : .skip)
                defer { declareNext() }   // per track: the next one, now that this one is known
                if state == .playing { followClock(track, kind: natural ? .natural : .skip) }
                let coverMissing = !lastInfoHadCover
                if let mark = store.startTrack(.init(info: info, durationMs: track.durationMs), newRun: !natural) {
                    marks.append((mark.number, mark.ms, info))
                    if coverMissing { lateCover(track) }
                    Log.note("next track: \(track.title) — goes on in run \(mark.number) at \(mark.ms) ms (\(String(format: "%.1f", left)) s were left)")
                } else {
                    Log.note("next track: \(track.title) — \(natural ? "begins the next run" : "a skip, a new run at once") (\(String(format: "%.1f", left)) s were left)")
                    if coverMissing { lateCover(track) }
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
                // The line the Music app wrote for this pause (just before it) is about this track (see FormatLog).
                formats.forget(recent: 1)
                formats.quiet(for: 1)
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
                if phase == .paused, isUPnP {
                    // A UPnP renderer plays on from its own small buffer at once, and the splice writes nothing new for
                    // 2.5 s: after a pause of 15 s the Ellipse ran dry (21 Oct 2026, 19:23:36). It plays again once the
                    // splice is done, with 1.5 s more — the Music app already plays meanwhile.
                    phase = .playing
                    Task { @MainActor [weak self] in
                        for _ in 0..<60 where self?.store?.isSplicing == true { try? await Task.sleep(for: .milliseconds(100)) }
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard let self, self.phase == .playing, self.source.state == .playing else { return }
                        self.roonControl("play")
                    }
                } else if phase == .paused {
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
        if fixedNow { lastChangeAt = Date(); correctable = nil; return }   // 0.3.7: the zone's rate is fixed
        let change = Date(), previous = lastChangeAt
        lastChangeAt = change
        correctable = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = { self.source === self.music && self.music.track?.id == track.id && self.isOn }
            // First the Music app's own log (0.3.3); AppleScript once beside it, or on its own when the log has nothing.
            var read: (rate: Int, how: String)?
            let now = Int(AudioDevices.sampleRate(of: arco) ?? 0)
            // 0.3.5: named as the next track, its rate is the line after that (none: the same) — no window guessing.
            var fromLog: (rate: Int, how: String)?
            // 0.4.0: the Music app's label names this very track, its rate and that it is lossless — first of all. A natural
            // change has it long before (the next track is loaded 60–100 s ahead); a skip or a start waits for it.
            if let l = await self.formats.waitForLabel(track.title, seconds: kind == .natural ? 0 : FormatLog.wait) {
                fromLog = (l.rate, "the Music app's label \(l.label)")
            } else if kind == .natural, let n = self.formats.named(track.title) {
                fromLog = n.rate.map { ($0, "the Music app's log, the line after it was named") } ?? (now, FormatLog.sameHow)
            } else {
                fromLog = await self.formats.rate(kind, change: change, previous: previous, current: now)
            }
            if current() {
                if fromLog == nil { self.correctable = (track.id, change.addingTimeInterval(20)) }
                else if fromLog?.how == FormatLog.sameHow { self.correctable = (track.id, change.addingTimeInterval(FormatLog.wait)) }
            }
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
            // 0.4.0: never a change of clock this far into a track (Roon has started to play it): it plays on, resampled,
            // and the rate is remembered for the next time.
            self.clock.remember(Int(r), for: track)
            Log.note("clock: \(track.title) — stays at \(read.rate) Hz, plays on resampled (\(Int(r)) Hz remembered)")
        }
    }

    /// A lossless line that came after the clock was chosen (0.3.4): the Music app started the track in AAC and set up the
    /// real format later. Up to 20 s after the change of track, set the clock after all, and remember the track's rate.
    private func lateLossless(at: Date, rate: Int) {
        guard TrackClock.enabled, !fixedNow, isOn, source === music, let change = lastChangeAt, at >= change,
              let track = music.track, let arco = arcoDevice,
              let c = correctable, c.trackID == track.id, at <= c.until else { return }
        // 0.3.5: a line after the next track was named is the next track's, loaded ahead — never a correction of this one.
        if formats.isNextTracks(at: at, playing: track.title) {
            Log.note("clock: \(track.title) — a line of \(rate) Hz, but it is the next track's (named before it): no correction")
            return
        }
        clock.remember(rate, for: track)
        guard music.state == .playing, AudioDevices.bestRate(Double(rate), of: arco) != AudioDevices.sampleRate(of: arco) else { return }
        // Within 3 s of the change (9 Oct): back to the track's start — Roon plays 5–7 s behind and hasn't had it. Asked at
        // once, before the Music app may change the device itself (8 Oct, Traces of a Song: 0.65 s after its line — the
        // run was then frozen in the middle of the track, and setClock found Arco "there already").
        let early = at.timeIntervalSince(change) < FormatLog.wait && music.position() < 3
        // 0.4.0: only early — back to the track's start before Roon plays it (5–7 s behind). Later, a change of clock is
        // heard: the track plays on, resampled, and its rate is remembered (Basso's rule since 21 Oct 2026).
        guard early else {
            Log.note("clock: \(track.title) — the Music app's log now says \(rate) Hz, but the track plays: it stays, resampled (remembered)")
            return
        }
        store?.restartTrackAtNewRate()
        Log.note("clock: \(track.title) — the Music app's log now says \(rate) Hz (it started otherwise): correcting, from the track's start")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.setClock(rate, for: track, how: "the Music app's log, late", fromStart: early, evenIfThere: early)
        }
    }

    /// A lossless label arrived (0.4.0): for the track that plays, when the Music app
    /// switched it to a better track of another rate — the clock, but only in the track's first seconds (from its start,
    /// before Roon plays it). Later it plays on resampled, and the rate is remembered.
    private func labelArrived(_ l: FormatLog.Label) {
        // Per track: the declared next slice is this track — its rate from the label, as long as nobody fetched it.
        if let q = store?.queuedSlice, Self.lines(q.info)?.title == l.title, store?.retag(q, rate: Double(l.rate)) == true {
            Log.note("next: slice \(q.number) — \(l.title) now at \(l.rate) Hz (its label)")
        }
        guard isOn, source === music, let track = music.track, l.title == track.title else { return }
        guard TrackClock.enabled, !fixedNow, let arco = arcoDevice,
              AudioDevices.bestRate(Double(l.rate), of: arco) != AudioDevices.sampleRate(of: arco) else { return }
        // Within the choice of followClock (it waits for this label itself): nothing to correct yet.
        if let change = lastChangeAt, Date().timeIntervalSince(change) < FormatLog.wait + 0.5 { return }
        clock.remember(l.rate, for: track)
        guard music.state == .playing, music.position() < 3 else {
            Log.note("clock: \(track.title) — the label now says \(l.rate) Hz, but the track plays: it stays, resampled (remembered)")
            return
        }
        store?.restartTrackAtNewRate()
        Log.note("clock: \(track.title) — the label now says \(l.rate) Hz: correcting, from the track's start")
        Task { @MainActor [weak self] in await self?.setClock(l.rate, for: track, how: "the Music app's label, late", fromStart: true, evenIfThere: true) }
    }

    /// Basso's way for a change of clock: pause the Music app, set the rate, back to the start of the track if it only
    /// just began, play. The pause doesn't reach Roon (a change of rate within 0.2 s of it: "Music changes the clock").
    private func setClock(_ rate: Int, for track: SourceTrack, how: String, fromStart: Bool, evenIfThere: Bool = false) async {
        guard let arco = arcoDevice, let now = AudioDevices.sampleRate(of: arco) else { return }
        let target = AudioDevices.bestRate(Double(rate), of: arco)
        if target != Double(rate) {
            Log.note("clock: \(rate) Hz isn't offered by the Arco device (\(AudioDevices.availableRates(of: arco).map { String(Int($0)) }.joined(separator: ", "))) — \(Int(target)) instead")
        }
        // `evenIfThere`: the Music app set the device itself, but the track must still start over (see lateLossless).
        guard target != now || evenIfThere else { Log.note("clock: \(track.title) — \(rate) Hz (\(how)), Arco is there already"); return }
        // Never two changes for one track within two seconds: a reading that keeps changing mustn't make Music stumble.
        if let last = lastClockChange, last.id == track.id, Date().timeIntervalSince(last.at) < 2 { return }
        lastClockChange = (track.id, Date())
        let back = fromStart && music.position() < 3
        let playing = music.state == .playing
        Log.note("clock: \(track.title) — \(rate) Hz (\(how)): \(target == now ? "the Music app set Arco to it itself" : "Arco \(Int(now)) → \(Int(target)) Hz")\(back ? ", from the start" : "")")
        ownUntil = Date().addingTimeInterval(3)
        formats.quiet(for: 2.5)   // the queue the Music app sets up again now is about this track (see FormatLog)
        // Before the pause, which can take the Music app two seconds (17:08:39): from now on Roon gets nothing past the
        // track's start.
        if back { store?.restartTrackAtNewRate() }
        if playing { music.pause() }
        if target != now { AudioDevices.setSampleRate(target, of: arco) }
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
        } else if fixedNow, let arco = arcoDevice {
            AudioDevices.setSampleRate(AudioDevices.bestRate(Self.fixedRate, of: arco), of: arco)
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

    /// The cover a moment later (0.4.0, René: "Roon krijgt nu artwork niet mee?"): at the change of track the Music app
    /// often hasn't loaded the new track's artwork yet ("Can't get raw data of artwork 1 of current track" — streamed and
    /// autoplay tracks above all), and Roon got the title without a cover. Asked again after 1.5 s and 4 s; found, it goes
    /// into the track's mark (Roon hasn't reached it yet) or to Roon at once (Roon shows the track already).
    private func lateCover(_ track: SourceTrack) {
        Task { @MainActor [weak self] in
            for wait in [1.5, 2.5] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, self.isOn, self.source.track?.id == track.id else { return }
                let info = self.makeInfo(track)
                guard self.lastInfoHadCover else { continue }
                if let i = self.marks.firstIndex(where: { Self.lines($0.info)?.title == track.title }) {
                    self.marks[i].info = info
                    Log.note("cover: \(track.title) — found a moment later, in the track's mark")
                } else if let run = self.store?.status?.number {
                    // The run this track is written in (a skip began a new one; Roon may still be in the previous).
                    Task { await self.session?.updateInfo(track: String(run), info: info) }
                    Log.note("cover: \(track.title) — found a moment later, sent to Roon")
                }
                return
            }
            if let self, self.source.track?.id == track.id { Log.note("cover: \(track.title) — the Music app has none") }
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

    // MARK: - Per track (UPnP, see Slices.swift)

    /// The image address of the last track information (per track: the declared next one borrows it until it plays).
    private var lastImageURL: String?
    /// The slice the renderer was last given as its next.
    private var nextSent = 0

    /// The next track the Music app named: its slice, declared ahead, cut at its length from the Music app's log — and the
    /// drift of the current cut taken into it, so the cut after it falls on the track's boundary again (Basso's way).
    private func declareNext() {
        guard isUPnP, let store, store.perTrack, session != nil, source === music, let n = formats.next,
              let title = n.title, let ms = n.lengthMs, ms > 0, let playing = music.track, title != playing.title,
              store.writingTitle == playing.title else { return }
        if let q = store.queuedSlice, Self.lines(q.info)?.title == title { sendNext(); return }
        let rate = Double(formats.label(for: title)?.rate ?? n.rate ?? Int(capture.rate))
        // The slice being written ends `drift` seconds before the Music app's track does: the next one takes that much more.
        var drift = 0.0
        if playing.durationMs > 0, let left = store.writingLeft {
            drift = max(-2, min(2, (Double(playing.durationMs) / 1000 - music.position()) - left))
        }
        let frames = Int(max(1, Double(ms) / 1000 + drift) * rate)
        let info = AudioInputSession.info(title: title, artist: playing.artist, album: playing.album, imageURL: lastImageURL)
        guard let s = store.declare(.init(info: info, durationMs: ms), rate: rate, frames: frames) else { return }
        Log.note(String(format: "next: slice %d declared — %@, %d Hz, %d s, cut %+.2f s", s.number, title, Int(rate), ms / 1000, drift))
        sendNext()
    }

    /// The declared slice to the renderer as its next — once it plays the slice before it (an earlier SetNext would make it
    /// skip the one in between).
    private func sendNext() {
        guard let store, let q = store.queuedSlice ?? store.slice(after: roonSlice), q.number > nextSent, q.declared,
              store.slice(after: roonSlice)?.number == q.number, let s = session, let address else { return }
        nextSent = q.number
        let url = "http://\(address):\(server.port)\(q.path)"
        Task { @MainActor in
            let ok = await s.setNext(track: String(q.number), url: url, info: q.info)
            Log.note("next: slice \(q.number) (\(Self.lines(q.info)?.title ?? "?")) set as the renderer's next\(ok ? "" : " — refused")")
        }
    }

    /// The renderer moved on to slice `n` (per track): its title in the menu, older slices gone, the next one set.
    private func movedOn(to n: Int) {
        guard store?.perTrack == true else { return }
        nowPlaying = store?.info(of: n).flatMap { Self.lines($0) }
        store?.forget(before: n)
        Log.note("renderer: slice \(n) — \(nowPlaying?.title ?? "?")")
        declareNext()
        sendNext()
    }

    /// A slice to the renderer at once (it stopped with nothing after it).
    private func playNow(_ slice: SliceStore.Slice, why: String) {
        guard let s = session, let address else { return }
        let url = "http://\(address):\(server.port)\(slice.path)"
        Log.note("play slice \(slice.number) at once — \(why)")
        Task { @MainActor in
            let answer = await s.play(track: String(slice.number), url: url, info: slice.info)
            guard self.session === s else { return }
            if answer == "Playing" { self.roonSlice = slice.number; self.roonPositionMs = 0; self.roonTimeAt = Date(); self.nextSent = slice.number; self.movedOn(to: slice.number) }
            Log.note("play slice \(slice.number): the renderer answered \(answer)")
        }
    }

    /// Title and artist from Roon's track information.
    private static func lines(_ info: JSON) -> (title: String, artist: String)? {
        guard let two = info["two_line"] as? JSON, let title = two["line1"] as? String else { return nil }
        return (title, two["line2"] as? String ?? "")
    }

    private func roonControl(_ control: String) {
        guard let session else { return }
        ownUntil = Date().addingTimeInterval(3)
        session.control(control)
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
