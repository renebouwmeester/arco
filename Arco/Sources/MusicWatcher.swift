// The Music app, from the outside: what plays (its distributed notification, com.apple.Music.playerInfo, arrives at every
// change), the cover of the current track, and the buttons Roon passes on (play, pause, next, previous) — by AppleScript.
// Arco never launches Music by itself: when it is not running, there is nothing to watch.
import AppKit
import Foundation

@MainActor
final class MusicWatcher {
    struct Track: Equatable {
        let id: String          // the persistent id
        let title: String
        let artist: String
        let album: String
        let durationMs: Int
    }
    enum State: String { case playing, paused, stopped }

    private(set) var state: State = .stopped
    private(set) var track: Track?
    /// (new state, track, whether the track changed)
    var onChange: ((State, Track?, Bool) -> Void)?
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

    /// The current state, asked once (at start; later the notifications keep it current).
    func refresh() {
        guard Self.isRunning, let reply = Self.run("""
            tell application "Music"
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string) & linefeed & (persistent ID of t)
            end tell
            """)?.stringValue else { update(.stopped, nil); return }
        let lines = reply.components(separatedBy: "\n")
        let state = State(rawValue: lines[0]) ?? .stopped
        guard state != .stopped, lines.count >= 6 else { update(state, nil); return }
        let seconds = Double(lines[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        update(state, Track(id: Self.identity(lines[1], lines[2], lines[3]), title: lines[1], artist: lines[2], album: lines[3],
                            durationMs: Int(seconds * 1000)))
    }

    private func received(_ info: [AnyHashable: Any]) {
        let state: State
        switch info["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        default: state = .stopped
        }
        guard state != .stopped, let title = info["Name"] as? String else { update(state, state == .stopped ? nil : track); return }
        let artist = info["Artist"] as? String ?? "", album = info["Album"] as? String ?? ""
        let new = Track(id: Self.identity(title, artist, album), title: title, artist: artist, album: album,
                        durationMs: (info["Total Time"] as? NSNumber)?.intValue ?? 0)
        update(state, new)
    }

    /// One identity for a track, the same from AppleScript and from the notification (their persistent ids differ in
    /// form, and a streamed track may come without one).
    private static func identity(_ title: String, _ artist: String, _ album: String) -> String {
        [title, artist, album].joined(separator: "\u{1F}")
    }

    private func update(_ state: State, _ track: Track?) {
        let changed = track?.id != self.track?.id
        guard changed || state != self.state else { return }
        self.state = state
        self.track = track
        onChange?(state, track, changed)
    }

    // MARK: - Buttons

    func play() { _ = Self.run(#"tell application "Music" to play"#) }
    func pause() { _ = Self.run(#"tell application "Music" to pause"#) }
    func next() { _ = Self.run(#"tell application "Music" to next track"#) }
    func previous() { _ = Self.run(#"tell application "Music" to previous track"#) }

    /// The cover of the current track, as the Music app has it (JPEG or PNG).
    func artwork() -> (data: Data, type: String)? {
        guard Self.isRunning, let reply = Self.run(#"tell application "Music" to get raw data of artwork 1 of current track"#) else { return nil }
        let data = reply.data
        guard data.count > 8 else { return nil }
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return (data, png ? "image/png" : "image/jpeg")
    }

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
