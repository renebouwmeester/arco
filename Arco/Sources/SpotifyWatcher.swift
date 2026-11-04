// Spotify, from the outside: its distributed notification (com.spotify.client.PlaybackStateChanged) at every change, its
// AppleScript for the rest. Its cover comes as a URL (artwork url), which Roon fetches itself — no key, nothing to serve.
// Spotify doesn't set the output's rate; it plays at 44.1 kHz, so that is what the Arco device gets when Spotify plays.
// Arco never launches Spotify by itself.
import AppKit
import Foundation

@MainActor
final class SpotifyWatcher: PlayerSource {
    let name = "Spotify"
    private(set) var state: SourceState = .stopped
    private(set) var track: SourceTrack?
    var onChange: ((SourceState, SourceTrack?, Bool) -> Void)?
    let preferredRate: Double? = 44_100
    private var observer: NSObjectProtocol?
    /// Spotify on repeat-one plays the same track again without a new id, so `update` sees no change and the bridge never
    /// starts a new track (per-track mode then fills its slice and the renderer stops). Near the track's end we check the
    /// position: if it wrapped back to the start, the same track plays again and counts as a new one.
    private var repeatCheck: Timer?
    private var checkFrom: (position: Double, at: Date)?
    /// This track played again at least once (repeat-one, most likely): the bridge declares it ahead as its own next.
    private(set) var looped = false

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.received(info) }
        }
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func refresh() {
        guard Self.isRunning, let reply = AppleScript.run("""
            tell application "Spotify"
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string) & linefeed & (id of t)
            end tell
            """)?.stringValue else { update(.stopped, nil); return }
        let lines = reply.components(separatedBy: "\n")
        let state = SourceState(rawValue: lines[0]) ?? .stopped
        guard state != .stopped, lines.count >= 5 else { update(state, nil); return }
        update(state, SourceTrack(id: Self.id(lines.count > 5 ? lines[5] : nil, lines[1], lines[2], lines[3]), title: lines[1],
                                  artist: lines[2], album: lines[3], durationMs: Int(lines[4]) ?? 0))
    }

    /// A track is Spotify's own id (spotify:track:…), not its title: Spotify doesn't always spell a title alike (4 Nov 2026:
    /// the same track as "地元愛▽満タン" and as "地元愛♡満タン" — its pause was taken for a skip, and the slice dropped).
    private static func id(_ spotifyID: String?, _ title: String, _ artist: String, _ album: String) -> String {
        if let spotifyID, !spotifyID.isEmpty { return spotifyID }
        return SourceTrack.identity(title, artist, album)
    }

    private func received(_ info: [AnyHashable: Any]) {
        let state: SourceState
        switch info["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        default: state = .stopped
        }
        guard state != .stopped, let title = info["Name"] as? String else { update(state, state == .stopped ? nil : track); return }
        let artist = info["Artist"] as? String ?? "", album = info["Album"] as? String ?? ""
        update(state, SourceTrack(id: Self.id(info["Track ID"] as? String, title, artist, album), title: title, artist: artist,
                                  album: album, durationMs: (info["Duration"] as? NSNumber)?.intValue ?? 0))
    }

    private func update(_ state: SourceState, _ track: SourceTrack?) {
        let changed = track?.id != self.track?.id
        guard changed || state != self.state else { return }
        self.state = state
        self.track = track
        if changed { looped = false }
        onChange?(state, track, changed)
        watchForRepeat()
    }

    private func watchForRepeat() {
        repeatCheck?.invalidate(); repeatCheck = nil; checkFrom = nil
        guard Bridge.spotifyEnabled, state == .playing, let track, track.durationMs > 0 else { return }
        let at = position()
        let wait = max(1, Double(track.durationMs) / 1000 - at + 1.5)
        checkFrom = (at, Date())
        repeatCheck = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRepeat() }
        }
    }

    private func checkRepeat() {
        guard state == .playing, let track, track.durationMs > 0, let from = checkFrom else { return }
        let now = position()
        let expected = from.position + Date().timeIntervalSince(from.at) - Double(track.durationMs) / 1000
        if expected > 0, abs(now - expected) < 3 {
            Log.note(String(format: "spotify: %@ plays again (repeat) — at %.1f s", track.title, now))
            looped = true
            onChange?(state, track, true)
        }
        watchForRepeat()
    }

    func position() -> Double {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Spotify" to get player position"#)?.stringValue else { return 0 }
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Spotify's repeat is on — one or all, its AppleScript doesn't say which.
    var repeating: Bool {
        Self.isRunning && AppleScript.run(#"tell application "Spotify" to get repeating"#)?.booleanValue == true
    }

    func cover() -> SourceCover? {
        guard Self.isRunning, let url = AppleScript.run(#"tell application "Spotify" to get artwork url of current track"#)?.stringValue,
              url.hasPrefix("http") else { return nil }
        return .url(url)
    }

    func play() { AppleScript.run(#"tell application "Spotify" to play"#) }
    func pause() { AppleScript.run(#"tell application "Spotify" to pause"#) }
    func next() { AppleScript.run(#"tell application "Spotify" to next track"#) }
    func previous() { AppleScript.run(#"tell application "Spotify" to previous track"#) }
}
