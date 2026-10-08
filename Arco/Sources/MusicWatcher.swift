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
        guard Self.isRunning, let reply = AppleScript.run("""
            tell application "Music"
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string)
            end tell
            """)?.stringValue else { update(.stopped, nil); return }
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
        update(state, SourceTrack(id: SourceTrack.identity(title, artist, album), title: title, artist: artist, album: album,
                                  durationMs: (info["Total Time"] as? NSNumber)?.intValue ?? 0))
    }

    private func update(_ state: SourceState, _ track: SourceTrack?) {
        let changed = track?.id != self.track?.id
        guard changed || state != self.state else { return }
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

    /// The player state asked directly (the notification can come a second late).
    func isPlayingNow() -> Bool {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Music" to get player state as string"#)?.stringValue else { return false }
        return text == "playing"
    }

    func seekToStart() { AppleScript.run(#"tell application "Music" to set player position to 0"#) }

    func play() { AppleScript.run(#"tell application "Music" to play"#) }
    func pause() { AppleScript.run(#"tell application "Music" to pause"#) }
    func next() { AppleScript.run(#"tell application "Music" to next track"#) }
    func previous() { AppleScript.run(#"tell application "Music" to previous track"#) }
}
