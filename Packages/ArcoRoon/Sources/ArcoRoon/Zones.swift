// Roon's zones (com.roonlabs.transport:2): a subscription keeps the list current — added, changed, removed, and the
// seek position every second — and a zone's volume can be set on its first output.
import Foundation

public let transportService = "com.roonlabs.transport:2"

public struct RoonZone: Identifiable, Equatable {
    public struct Volume: Equatable {
        public let outputID: String
        public let value: Double
        public let min: Double
        public let max: Double
        public let step: Double
        public let isMuted: Bool
        /// "number", "db", "incremental" — the last has no value to set, only up and down.
        public let type: String
    }

    public let id: String
    public let name: String
    /// "playing", "paused", "loading", "stopped".
    public let state: String
    /// What plays, as Roon shows it on two lines ("Title", "Artist").
    public let nowPlayingTitle: String?
    public let nowPlayingSubtitle: String?
    public let volume: Volume?

    init?(_ json: JSON) {
        guard let id = json["zone_id"] as? String else { return nil }
        self.id = id
        name = json["display_name"] as? String ?? "Zone"
        state = json["state"] as? String ?? "stopped"
        let twoLine = (json["now_playing"] as? JSON)?["two_line"] as? JSON
        nowPlayingTitle = (twoLine?["line1"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        nowPlayingSubtitle = (twoLine?["line2"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let output = (json["outputs"] as? [JSON])?.first, let outputID = output["output_id"] as? String,
           let v = output["volume"] as? JSON {
            volume = Volume(outputID: outputID, value: v["value"] as? Double ?? 0, min: v["min"] as? Double ?? 0,
                            max: v["max"] as? Double ?? 100, step: v["step"] as? Double ?? 1,
                            isMuted: v["is_muted"] as? Bool ?? false, type: v["type"] as? String ?? "number")
        } else {
            volume = nil
        }
    }
}

@MainActor
public final class ZoneTracker {
    public private(set) var zones: [RoonZone] = [] { didSet { if zones != oldValue { onChange?(zones) } } }
    public var onChange: (([RoonZone]) -> Void)?
    private var raw: [String: JSON] = [:]
    private var order: [String] = []
    private weak var connection: RoonConnection?

    public init() {}

    /// Starts the subscription on a freshly paired connection.
    public func start(on connection: RoonConnection) {
        self.connection = connection
        raw = [:]; order = []; zones = []
        connection.subscribe(transportService, "zones") { [weak self] name, body in
            self?.handle(name, body)
        }
    }

    public func stop() { raw = [:]; order = []; zones = []; connection = nil }

    /// Sets the volume of the zone's first output (absolute, within the zone's own range).
    public func setVolume(_ zone: RoonZone, to value: Double) {
        guard let volume = zone.volume, volume.type != "incremental" else { return }
        let clamped = Swift.min(volume.max, Swift.max(volume.min, value))
        connection?.request("\(transportService)/change_volume",
                            ["output_id": volume.outputID, "how": "absolute", "value": clamped])
    }

    /// One step up or down — also for zones whose volume is only incremental.
    public func stepVolume(_ zone: RoonZone, up: Bool) {
        guard let volume = zone.volume else { return }
        connection?.request("\(transportService)/change_volume",
                            ["output_id": volume.outputID, "how": "relative_step", "value": up ? 1 : -1])
    }

    private func handle(_ name: String?, _ body: JSON?) {
        guard let body else { return }
        func put(_ zone: JSON) {
            guard let id = zone["zone_id"] as? String else { return }
            if raw[id] == nil { order.append(id) }
            raw[id] = zone
        }
        switch name {
        case "Subscribed":
            raw = [:]; order = []
            for zone in body["zones"] as? [JSON] ?? [] { put(zone) }
        case "Changed":
            for zone in body["zones_added"] as? [JSON] ?? [] { put(zone) }
            for zone in body["zones_changed"] as? [JSON] ?? [] { put(zone) }
            for id in body["zones_removed"] as? [String] ?? [] { raw[id] = nil; order.removeAll { $0 == id } }
        default:
            return
        }
        zones = order.compactMap { raw[$0].flatMap(RoonZone.init) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
