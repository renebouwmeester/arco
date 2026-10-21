// Roon's audio input (com.roonlabs.audioinput:1, see RoonLabs/node-roon-api-audioinput): an extension begins a session
// on a zone, plays a media URL into it (type "track", in the "play" slot or the "queue" slot), and can update the track
// information of what plays. Roon fetches the URL itself; the session shows the extension's name and icon in Roon.
//
// What a play request reports, in order: Playing, then Time (seek_position_ms, about once a second), and at the end
// EndedNaturally — or Paused / Unpaused / StoppedUser from Roon's own transport, MediaError, ZoneLost or ZoneNotFound.
// The session itself reports TransportControl (Roon's next / previous buttons) and SessionEnded.
import Foundation

public let audioInputService = "com.roonlabs.audioinput:1"

@MainActor
public final class AudioInputSession {
    public enum Event: Equatable {
        case playing(track: String)
        case time(track: String, positionMs: Int)
        case paused(track: String)
        case unpaused(track: String)
        case stopped(track: String)
        case ended(track: String)
        case failed(track: String, reason: String)
        /// The track left the play slot because another one replaced it — expected after a new play, not an error.
        case cleared(track: String)
        case control(String)        // "next", "previous" …
        case sessionEnded
    }

    public let zoneID: String
    public private(set) var sessionID: String?
    public var onEvent: ((Event) -> Void)?
    private weak var connection: RoonConnection?

    public init(connection: RoonConnection, zoneID: String) {
        self.connection = connection; self.zoneID = zoneID
    }

    /// Begins the session on the zone. True when Roon answered SessionBegan.
    public func begin(displayName: String, iconURL: String?, allowsNextPrevious: Bool = true) async -> Bool {
        guard let connection else { return false }
        var body: JSON = ["zone_id": zoneID, "display_name": displayName,
                          "controls": ["is_previous_allowed": allowsNextPrevious, "is_next_allowed": allowsNextPrevious]]
        if let iconURL { body["icon_url"] = iconURL }
        return await withCheckedContinuation { continuation in
            var first = true
            connection.request("\(audioInputService)/begin_session", body) { [weak self] name, reply in
                guard let self else { return }
                if first {
                    first = false
                    if name == "SessionBegan", let id = reply?["session_id"] {
                        self.sessionID = "\(id)"
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                    return
                }
                switch name {
                case "TransportControl":
                    // {"control": "next"} — keep whatever Roon names it.
                    let control = (reply?["control"] as? String) ?? (reply.map { "\($0)" } ?? "")
                    self.onEvent?(.control(control.lowercased()))
                case "SessionEnded", nil:
                    self.sessionID = nil
                    self.onEvent?(.sessionEnded)
                default:
                    break
                }
            }
        }
    }

    /// Plays a media URL in a slot. Returns Roon's first answer ("Playing", or the error); later replies go to onEvent.
    public func play(track: String, url: String, info: JSON, slot: String = "play", seekMs: Int? = nil) async -> String {
        guard let connection, let sessionID else { return "NoSession" }
        var body: JSON = ["session_id": sessionID, "track_id": track, "type": "track", "slot": slot,
                          "media_url": url, "info": info]
        if let seekMs { body["seek_position_ms"] = seekMs }
        return await withCheckedContinuation { continuation in
            var first = true
            // Roon answers once it has fetched and started; a slow start must not hang the caller.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if first { first = false; continuation.resume(returning: "Timeout") }
            }
            connection.request("\(audioInputService)/play", body) { [weak self] name, reply in
                let name = name ?? "NoConnection"
                if first { first = false; continuation.resume(returning: name) }
                guard let self else { return }
                switch name {
                case "Playing": self.onEvent?(.playing(track: track))
                case "Time":
                    if let p = reply?["seek_position_ms"] as? NSNumber { self.onEvent?(.time(track: track, positionMs: p.intValue)) }
                case "Paused": self.onEvent?(.paused(track: track))
                case "Unpaused": self.onEvent?(.unpaused(track: track))
                case "StoppedUser": self.onEvent?(.stopped(track: track))
                case "EndedNaturally": self.onEvent?(.ended(track: track))
                case "Cleared": self.onEvent?(.cleared(track: track))
                case "MediaError", "ZoneLost", "ZoneNotFound", "NoConnection":
                    self.onEvent?(.failed(track: track, reason: name))
                default: break
                }
            }
        }
    }

    /// New track information for what plays (a continuous stream: one URL, many songs).
    @discardableResult
    public func updateInfo(track: String, info: JSON) async -> String {
        guard let connection, let sessionID else { return "NoSession" }
        let reply = await connection.request("\(audioInputService)/update_track_info",
                                             ["session_id": sessionID, "track_id": track, "info": info])
        return reply.name ?? "NoConnection"
    }

    public func end() {
        guard let connection, let sessionID else { return }
        connection.request("\(audioInputService)/end_session", ["session_id": sessionID])
        self.sessionID = nil
    }

    /// The track information Roon shows: one, two and three lines, the cover, and what the transport may do.
    public static func info(title: String, artist: String, album: String, imageURL: String?,
                            pauseAllowed: Bool = true, seekAllowed: Bool = false) -> JSON {
        var info: JSON = ["is_seek_allowed": seekAllowed, "is_pause_allowed": pauseAllowed,
                          "one_line": ["line1": title],
                          "two_line": ["line1": title, "line2": artist],
                          "three_line": ["line1": title, "line2": artist, "line3": album]]
        if let imageURL { info["image_url"] = imageURL }
        return info
    }
}
