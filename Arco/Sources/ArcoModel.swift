// What the menu shows: the connection with Roon, Roon's zones, and the zone Arco plays to.
import Foundation
import ArcoRoon

@MainActor
final class ArcoModel: ObservableObject {
    @Published private(set) var connectionState: RoonConnection.State = .searching
    @Published private(set) var zones: [RoonZone] = []
    @Published private(set) var selectedZoneID: String?

    let connection: RoonConnection
    let bridge: Bridge
    private var lastShown = ""
    let setup = SetupCheck()
    let updater = Updater()
    private let tracker = ZoneTracker()

    /// The chosen zone is remembered by id and by name: Roon gives a zone a new id when it is grouped or ungrouped,
    /// and the name is how the user knows it.
    private static let zoneIDKey = "SelectedZoneID", zoneNameKey = "SelectedZoneName"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arco", isDirectory: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        connection = RoonConnection(
            // With the Mac's name (René, 8 Oct): every Mac is enabled in Roon on its own, and two "Arco" lines in
            // Settings › Extensions didn't say which was which.
            extension: .init(id: "nl.renebouwmeester.arco", displayName: Self.extensionName, version: version,
                             publisher: "René Bouwmeester", email: "",
                             website: "https://github.com/renebouwmeester/arco"),
            required: [transportService, "com.roonlabs.audioinput:1"],
            stateFile: support.appendingPathComponent("roon.json"))
        bridge = Bridge(connection: connection)
        selectedZoneID = UserDefaults.standard.string(forKey: Self.zoneIDKey)
        connection.onStateChange = { [weak self] state in self?.connectionChanged(state) }
        tracker.onChange = { [weak self] zones in self?.zonesChanged(zones) }
        connection.setStatus("Starting")
        connection.start()
        Updater.announceIfUpdated()
    }

    var selectedZone: RoonZone? { zones.first { $0.id == selectedZoneID } }

    /// "Arco on William" — the name in Roon's list of extensions.
    static let extensionName = "Arco on \(Host.current().localizedName ?? "this Mac")"

    func select(_ zone: RoonZone) {
        let switching = zone.id != selectedZoneID
        selectedZoneID = zone.id
        UserDefaults.standard.set(zone.id, forKey: Self.zoneIDKey)
        UserDefaults.standard.set(zone.name, forKey: Self.zoneNameKey)
        // Sending already: the music moves to the new zone.
        if switching, bridge.isOn { Task { await bridge.turnOn(zone: zone) } }
        else if !bridge.isOn { connection.setStatus("Ready — plays to \(zone.name)") }
    }

    /// The switch in the menu: send the Music app to the chosen zone, or give the Mac its output back.
    func setSending(_ on: Bool) {
        if on, let zone = selectedZone { Task { await bridge.turnOn(zone: zone) } } else { bridge.turnOff() }
    }

    func setVolume(_ zone: RoonZone, to value: Double) { tracker.setVolume(zone, to: value) }
    func stepVolume(_ zone: RoonZone, up: Bool) { tracker.stepVolume(zone, up: up) }

    private func connectionChanged(_ state: RoonConnection.State) {
        connectionState = state
        if case .paired = state {
            tracker.start(on: connection)
            connection.setStatus(selectedZone.map { "Ready — plays to \($0.name)" } ?? "Ready — pick a zone in the menu")
        } else {
            tracker.stop()
            zones = []
            if bridge.isOn { bridge.turnOff() }
        }
    }

    private func zonesChanged(_ zones: [RoonZone]) {
        // What Roon itself shows on the chosen zone, whenever it changes while Arco sends (0.3.1): a tester's streamer
        // showed the previous track's title — the log now has Roon's side next to what Arco sent it.
        if bridge.isOn, let id = selectedZoneID, let zone = zones.first(where: { $0.id == id }) {
            let shows = [zone.nowPlayingTitle, zone.nowPlayingSubtitle].compactMap { $0 }.joined(separator: " · ")
            if shows != lastShown { lastShown = shows; Log.note("roon shows: \(shows.isEmpty ? "nothing" : shows) (\(zone.state))") }
        }
        self.zones = zones
        // The chosen zone got a new id (grouped, ungrouped, renamed output): find it back by name.
        if selectedZone == nil, let name = UserDefaults.standard.string(forKey: Self.zoneNameKey),
           let again = zones.first(where: { $0.name == name }) {
            select(again)
        }
    }
}
