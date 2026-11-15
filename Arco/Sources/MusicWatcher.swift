// The Music app, from the outside: what plays (its distributed notification, com.apple.Music.playerInfo, arrives at every
// change), the cover of the current track, and the buttons Roon passes on (play, pause, next, previous) — by AppleScript.
// Arco never launches Music by itself: when it is not running, there is nothing to watch.
import AppKit
import Foundation

@MainActor
final class MusicWatcher: PlayerSource {
    let name = "Music"
    private(set) var state: SourceState = .stopped
    private(set) var track: SourceTrack?
    var onChange: ((SourceState, SourceTrack?, Bool) -> Void)?
    /// None: the rate follows each track (TrackClock) — the Music app itself never changes it.
    let preferredRate: Double? = nil
    private var observer: NSObjectProtocol?
    /// When the current track began, minus its pauses (1.0, 15 Nov 2026 — the code review: repeat-one, or the same song twice in
    /// a row, has the same identity, so the second play was dropped as "nothing changed" — per track, the renderer went silent).
    private var startedAt: Date?, pausedSince: Date?, pausedTotal: TimeInterval = 0

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.received(info) }
        }
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func refresh() {
        // Not running = stopped. But a script that times out or fails is NOT "stopped" (1.0, 15 Nov 2026 — the code review): it
        // paused Roon while the app played on, called mid-session (refreshLength, clockPauseWatch) — exactly when the app is
        // slow to answer. Then we keep what we had and report nothing.
        guard Self.isRunning else { update(.stopped, nil); return }
        guard let reply = AppleScript.run("""
            tell application "Music"
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string)
            end tell
            """)?.stringValue else { Log.note("\(name): no answer to the state question — keeping what we had"); return }
        let lines = reply.components(separatedBy: "\n")
        let state = SourceState(rawValue: lines[0]) ?? .stopped
        guard state != .stopped, lines.count >= 5 else { update(state, nil); return }
        let seconds = Double(lines[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        update(state, SourceTrack(id: SourceTrack.identity(lines[1], lines[2], lines[3]), title: lines[1], artist: lines[2],
                                  album: lines[3], durationMs: Int(seconds * 1000)))
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
        let t = SourceTrack(id: SourceTrack.identity(title, artist, album), title: title, artist: artist, album: album,
                            durationMs: (info["Total Time"] as? NSNumber)?.intValue ?? 0)
        // The same track, playing, announced again when its last play was (nearly) through and the needle is at the start:
        // a new play of it, not a repeat of the notification.
        if state == .playing, self.state == .playing, t.id == track?.id, t.durationMs > 0, let start = startedAt,
           Date().timeIntervalSince(start) - pausedTotal >= Double(t.durationMs) / 1000 - 3, position() < 10 {
            Log.note("Music: \(t.title) begins again (repeat or the same song twice)")
            startedAt = Date(); pausedTotal = 0; pausedSince = nil
            track = t
            onChange?(state, t, true)
            return
        }
        update(state, t)
    }

    private func update(_ state: SourceState, _ track: SourceTrack?) {
        let changed = track?.id != self.track?.id
        guard changed || state != self.state else { return }
        if changed { startedAt = track == nil ? nil : Date(); pausedTotal = 0; pausedSince = state == .paused ? Date() : nil }
        else if state == .paused, self.state == .playing { pausedSince = Date() }
        else if state == .playing, let p = pausedSince { pausedTotal += Date().timeIntervalSince(p); pausedSince = nil }
        self.state = state
        self.track = track
        onChange?(state, track, changed)
    }

    func position() -> Double {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Music" to get player position"#)?.stringValue else { return 0 }
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// The cover of the current track, as the Music app has it (JPEG or PNG) — Arco serves it to Roon.
    func cover() -> SourceCover? {
        guard Self.isRunning, let reply = AppleScript.run(#"tell application "Music" to get raw data of artwork 1 of current track"#) else { return nil }
        let data = reply.data
        guard data.count > 8 else { return nil }
        return .data(data, type: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg")
    }

    /// The current track's own sample rate, as the Music app names it (0 or nothing until it knows).
    func sampleRate() -> Double? {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Music" to get sample rate of current track"#)?.stringValue else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// The Music app's own volume (0.4.0): only at 100 does it play bit-exact (measured on macOS 27 with Basso's set of test
    /// files, 15 Oct 2026: 100.00% at 100; below it every sample is scaled).
    func volume() -> Int? {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Music" to get sound volume"#)?.stringValue else { return nil }
        return Int(text)
    }
    func setVolume(_ v: Int) { AppleScript.run("tell application \"Music\" to set sound volume to \(v)") }

    /// The player state asked directly (the notification can come a second late).
    func isPlayingNow() -> Bool {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Music" to get player state as string"#)?.stringValue else { return false }
        return text == "playing"
    }

    func seek(to seconds: Double) {
        AppleScript.run("tell application \"Music\" to set player position to \(String(format: "%.3f", max(0, seconds)))")
    }

    func seekToStart() { AppleScript.run(#"tell application "Music" to set player position to 0"#) }

    func play() { AppleScript.run(#"tell application "Music" to play"#) }
    func pause() { AppleScript.run(#"tell application "Music" to pause"#) }
    func next() { AppleScript.run(#"tell application "Music" to next track"#) }
    func previous() { AppleScript.run(#"tell application "Music" to previous track"#) }
}
