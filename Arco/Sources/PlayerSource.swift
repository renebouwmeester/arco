// A source: an app on this Mac that plays to the Arco output — the Music app or Spotify. The bridge follows one of them
// at a time (the one that plays), the same way for both: what plays, its state, its cover, and its buttons.
import Foundation

enum SourceState: String { case playing, paused, stopped }

struct SourceTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let durationMs: Int

    /// One identity for a track, the same from AppleScript and from the app's notification (their own ids differ in form,
    /// and a streamed track may come without one).
    static func identity(_ title: String, _ artist: String, _ album: String) -> String {
        [title, artist, album].joined(separator: "\u{1F}")
    }
}

/// A cover: image data Arco serves itself (the Music app), or a URL Roon can fetch (Spotify).
enum SourceCover {
    case data(Data, type: String)
    case url(String)
}

@MainActor
protocol PlayerSource: AnyObject {
    /// "Music", "Spotify".
    var name: String { get }
    var state: SourceState { get }
    var track: SourceTrack? { get }
    /// (new state, track, whether the track changed)
    var onChange: ((SourceState, SourceTrack?, Bool) -> Void)? { get set }
    /// The rate the Arco device should have for this source; nil when the source sets it itself (the Music app does, per
    /// track, with Lossless on).
    var preferredRate: Double? { get }
    /// The current state, asked once (later the app's notifications keep it current).
    func refresh()
    /// Where the source is in the current track, in seconds.
    func position() -> Double
    func cover() -> SourceCover?
    func play()
    func pause()
    func next()
    func previous()
}

enum AppleScript {
    /// Every script within a time limit: an app that doesn't answer its Apple Events (6 Oct 2026, 21:53: the Music app
    /// answered nobody, not even Terminal) must not hang Arco — the default limit is two minutes, on the main thread.
    @discardableResult
    static func run(_ source: String, seconds: Int = 3) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = "with timeout of \(seconds) seconds\n\(source)\nend timeout"
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.note("applescript: \(error[NSAppleScript.errorMessage] ?? error)") }
        return error == nil ? result : nil
    }
}
