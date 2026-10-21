// Where the runs go: Roon's audio input on a zone, or a UPnP renderer (experimental, see UPnP.swift). The bridge talks
// to both the same way — begin, play a run's URL, new track information, pause and play, end — and hears back Roon's
// events (UPnP's are made to look the same).
import ArcoRoon
import Foundation

@MainActor
protocol Output: AnyObject {
    var onEvent: ((AudioInputSession.Event) -> Void)? { get set }
    /// How many seconds of a run must be written before the output plays it (nil: the bridge's own rule).
    var lead: Double? { get }
    var name: String { get }
    /// The output ran out of music (a UPnP renderer in TRANSITIONING): at a frozen run, the next one can go at once.
    var isStarved: Bool { get }
    func begin(displayName: String, iconURL: String?) async -> Bool
    func play(track: String, url: String, info: JSON) async -> String
    func updateInfo(track: String, info: JSON) async
    func control(_ control: String)
    func end()
}

/// What the bridge plays to.
enum Target: Equatable {
    case roon(RoonZone)
    case upnp(UPnPRenderer)

    var name: String {
        switch self {
        case .roon(let z): return z.name
        case .upnp(let r): return r.name
        }
    }
}

/// Roon's audio input on a zone.
@MainActor
final class RoonOutput: Output {
    private let session: AudioInputSession
    private let connection: RoonConnection
    let name: String
    let lead: Double? = nil
    let isStarved = false
    var onEvent: ((AudioInputSession.Event) -> Void)? {
        get { session.onEvent }
        set { session.onEvent = newValue }
    }

    init(connection: RoonConnection, zone: RoonZone) {
        self.connection = connection
        session = AudioInputSession(connection: connection, zoneID: zone.id)
        name = zone.name
    }

    func begin(displayName: String, iconURL: String?) async -> Bool { await session.begin(displayName: displayName, iconURL: iconURL) }
    func play(track: String, url: String, info: JSON) async -> String { await session.play(track: track, url: url, info: info) }
    func updateInfo(track: String, info: JSON) async { await session.updateInfo(track: track, info: info) }
    func control(_ control: String) {
        connection.request("\(transportService)/control", ["zone_or_output_id": session.zoneID, "control": control])
    }
    func end() { session.end() }
}
