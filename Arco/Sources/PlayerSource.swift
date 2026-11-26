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
    /// The rate the Arco device should have for this source; nil when it follows each track (the Music app: TrackClock).
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
    /// And not while macOS still has to ask (AR17, 19 Nov 2026): after an update (a new signature) the first Apple Event waited
    /// in macOS's automation check before it was even sent — `with timeout` only counts once it is sent — and the main thread
    /// hung: nothing was written, Roon played its buffer empty, the menu didn't open, Quit didn't work. So first a question
    /// that never waits (ask: false); without permission yet the script is skipped — the setup list asks, off the main thread.
    /// (26 Nov 2026: running the scripts on a queue of their own instead got one stuck for minutes and left Arco deaf to the
    /// Music app — NSAppleScript belongs on the thread that calls it.)
    @discardableResult
    static func run(_ source: String, seconds: Int = 3) -> NSAppleEventDescriptor? {
        if let app = targetApp(source), !mayAsk(app) { return nil }
        var error: NSDictionary?
        let script = "with timeout of \(seconds) seconds\n\(source)\nend timeout"
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.note("applescript: \(error[NSAppleScript.errorMessage] ?? error)") }
        return error == nil ? result : nil
    }

    private static func targetApp(_ source: String) -> String? {
        if source.contains("application \"Music\"") { return "com.apple.Music" }
        if source.contains("application \"Spotify\"") { return "com.spotify.client" }
        return nil
    }

    nonisolated(unsafe) private static var known: [String: (ok: Bool, at: Date)] = [:]
    nonisolated(unsafe) private static var skippedNoted = Date.distantPast
    nonisolated(unsafe) private static var busy: Set<String> = []
    private static let lock = NSLock()

    private final class PermissionAnswer: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var status: OSStatus = noErr
        func set(_ s: OSStatus) { status = s; done.signal() }
        func wait(_ seconds: Double) -> OSStatus? { done.wait(timeout: .now() + seconds) == .success ? status : nil }
    }

    /// Whether Arco may send this app Apple Events without macOS having to ask first. Waits half a second at most; remembered for 10 s.
    private static func mayAsk(_ bundleID: String) -> Bool {
        lock.lock()
        if let k = known[bundleID], Date().timeIntervalSince(k.at) < 10 { lock.unlock(); return k.ok }
        lock.unlock()
        // The check itself can wait too (26 Nov 2026, 17:10: on the main thread it never came back — the menu stayed open
        // with a beach ball): so it runs on a thread of its own and gets half a second; no answer counts as "not now".
        lock.lock()
        if busy.contains(bundleID) { let last = known[bundleID]?.ok ?? false; lock.unlock(); return last }
        busy.insert(bundleID)
        lock.unlock()
        let answer = PermissionAnswer()
        DispatchQueue.global(qos: .userInitiated).async {
            var target = AEAddressDesc()
            let made = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
            let status = made == noErr ? AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) : noErr
            if made == noErr { AEDisposeDesc(&target) }
            answer.set(status)
            lock.lock(); busy.remove(bundleID); lock.unlock()
        }
        guard let status = answer.wait(0.5) else {
            lock.lock(); known[bundleID] = (false, Date())
            let say = Date().timeIntervalSince(skippedNoted) > 30
            if say { skippedNoted = Date() }
            lock.unlock()
            if say { Log.note("applescript: the automation check for \(bundleID) doesn't answer — skipped") }
            return false
        }
        // noErr: allowed; procNotFound: the app doesn't run (the script finds that out itself, quickly)
        let ok = status == noErr || status == OSStatus(procNotFound)
        lock.lock(); known[bundleID] = (ok, Date())
        let say = !ok && Date().timeIntervalSince(skippedNoted) > 30
        if say { skippedNoted = Date() }
        lock.unlock()
        if say { Log.note("applescript: no automation permission for \(bundleID) yet (\(status)) — skipped, the setup list asks") }
        return ok
    }
}
