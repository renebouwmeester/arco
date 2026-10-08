// The clock per track (0.3.0, 8 Oct 2026). A first tester, on macOS 15: "Arco is set to 48 kHz and its sample rate is
// kept regardless the played track's sample rate." The Music app never sets the output's rate itself, on any macOS —
// it plays at whatever the device is set to and resamples the rest. On the developer's Macs another tool of his
// (Basso) switched the rate, which is why 0.1 and 0.2 seemed to follow each track. Now Arco does it, the way Basso does:
//
// - At each new track, ask the Music app for the track's own rate (AppleScript: sample rate of current track). It
//   names it only after a moment, so read again every quarter second, for up to three seconds.
// - Right after a change the Music app sometimes still gives a low reading (44.1 or 48) for a hi-res track. A low
//   reading is trusted only once the three seconds are over — unless nothing says the track is hi-res: Arco remembers
//   the rate of every track and the highest rate of every album it has seen.
// - Only a rate the Arco device offers; the nearest one below otherwise (and never a change that can't be made, so it
//   can't loop).
// - The change itself: pause the Music app, set the rate, back to the start of the track if it only just began, play.
//   The run in Roon is cut (or frozen) where the track began, so its start isn't heard twice (see SliceStore).
// - Five seconds later one more reading: a late correction from the Music app changes the rate in the middle of the
//   track (pause, set, play — without going back).
//
// `defaults write nl.renebouwmeester.arco ClockPerTrack -bool false` leaves the rate to Audio MIDI Setup.
import Foundation

@MainActor
final class TrackClock {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "ClockPerTrack") as? Bool ?? true }

    private static let memoryKey = "RateMemory"
    private static let albumKey = "AlbumRateMemory"
    private var trackRates: [String: Int]
    private var albumRates: [String: Int]

    init() {
        trackRates = UserDefaults.standard.dictionary(forKey: Self.memoryKey) as? [String: Int] ?? [:]
        albumRates = UserDefaults.standard.dictionary(forKey: Self.albumKey) as? [String: Int] ?? [:]
    }

    static func albumID(_ t: SourceTrack) -> String { [t.artist, t.album].joined(separator: "\u{1F}") }

    /// What memory says about this track: its own rate, or else the highest of its album.
    func remembered(_ t: SourceTrack) -> Int? { trackRates[t.id] ?? albumRates[Self.albumID(t)] }

    func remember(_ rate: Int, for t: SourceTrack) {
        trackRates[t.id] = rate
        let album = Self.albumID(t)
        albumRates[album] = max(albumRates[album] ?? 0, rate)
        // Bounded: a few thousand tracks is plenty to know the albums one plays.
        if trackRates.count > 4000 { trackRates = Dictionary(uniqueKeysWithValues: trackRates.prefix(3000).map { ($0.key, $0.value) }) }
        if albumRates.count > 2000 { albumRates = Dictionary(uniqueKeysWithValues: albumRates.prefix(1500).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(trackRates, forKey: Self.memoryKey)
        UserDefaults.standard.set(albumRates, forKey: Self.albumKey)
    }

    /// The track's own rate, read from the Music app (see the top of this file). `stillCurrent` stops the reading when
    /// another track plays by then. Nil: the Music app didn't say, and memory doesn't know.
    func readRate(of t: SourceTrack, music: MusicWatcher, stillCurrent: () -> Bool) async -> (rate: Int, how: String)? {
        let started = Date()
        let hiRes = (remembered(t) ?? 0) > 48_000
        var last = 0
        // Every reading into the log (0.3.1): which the Music app gave, and when.
        var readings: [String] = []
        defer { Log.note("clock: \(t.title) — readings \(readings.joined(separator: ", "))\(remembered(t).map { "; remembered \($0)" } ?? "")") }
        while Date().timeIntervalSince(started) < 3 {
            guard stillCurrent() else { return nil }
            let r = music.sampleRate()
            readings.append(String(format: "%@ at %.2f s", r.map { String(Int($0)) } ?? "none", Date().timeIntervalSince(started)))
            if let r, r > 0 {
                last = Int(r)
                if last > 48_000 || !hiRes { return (last, "the Music app") }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard stillCurrent() else { return nil }
        // Still low after three seconds: the track's own memory wins (it was seen higher before); an album's doesn't (an
        // album can mix rates) — the reading five seconds later catches a late correction.
        if last > 0 {
            if let mine = trackRates[t.id], mine > last { return (mine, "remembered for this track; the Music app said \(last)") }
            return (last, "the Music app")
        }
        return remembered(t).map { ($0, "remembered") }
    }
}
