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
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string)
            end tell
            """)?.stringValue else { update(.stopped, nil); return }
        let lines = reply.components(separatedBy: "\n")
        let state = SourceState(rawValue: lines[0]) ?? .stopped
        guard state != .stopped, lines.count >= 5 else { update(state, nil); return }
        update(state, SourceTrack(id: SourceTrack.identity(lines[1], lines[2], lines[3]), title: lines[1], artist: lines[2],
                                  album: lines[3], durationMs: Int(lines[4]) ?? 0))
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
                                  durationMs: (info["Duration"] as? NSNumber)?.intValue ?? 0))
    }

    private func update(_ state: SourceState, _ track: SourceTrack?) {
        let changed = track?.id != self.track?.id
        guard changed || state != self.state else { return }
        self.state = state
        self.track = track
        onChange?(state, track, changed)
    }

    func position() -> Double {
        guard Self.isRunning, let text = AppleScript.run(#"tell application "Spotify" to get player position"#)?.stringValue else { return 0 }
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
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
