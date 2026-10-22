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
    /// UPnP renderers (experimental, behind the switch — see UPnP.swift).
    let finder = UPnPFinder()
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
        roonOn = UserDefaults.standard.object(forKey: Self.roonKey) as? Bool ?? connection.wasPaired
        if roonOn { connection.start() }
        Updater.announceIfUpdated()
    }

    var selectedZone: RoonZone? { zones.first { $0.id == selectedZoneID } }
    /// A UPnP renderer chosen instead of a Roon zone: its id is kept as "upnp:<UDN>".
    var selectedRenderer: UPnPRenderer? { finder.renderers.first { "upnp:" + $0.id == selectedZoneID } }
    var selectedName: String? { selectedZone?.name ?? selectedRenderer?.name ?? selectedLocal?.name }
    /// This Mac's output chosen (experimental, see Bridge.isLocal): its id is kept as "local:<UID>".
    var selectedLocal: AudioDevices.LocalOutput? {
        guard let id = selectedZoneID, id.hasPrefix("local:") else { return nil }
        return AudioDevices.outputs.first { "local:" + $0.id == id }
    }

    func select(_ out: AudioDevices.LocalOutput) {
        let id = "local:" + out.id
        let switching = id != selectedZoneID
        selectedZoneID = id
        UserDefaults.standard.set(id, forKey: Self.zoneIDKey)
        UserDefaults.standard.set(out.name, forKey: Self.zoneNameKey)
        if switching, bridge.isOn { Task { await bridge.turnOn(local: out) } }
    }

    func select(_ renderer: UPnPRenderer) {
        let id = "upnp:" + renderer.id
        let switching = id != selectedZoneID
        selectedZoneID = id
        UserDefaults.standard.set(id, forKey: Self.zoneIDKey)
        UserDefaults.standard.set(renderer.name, forKey: Self.zoneNameKey)
        if switching, bridge.isOn { Task { await bridge.turnOn(renderer: renderer) } }
    }

    /// Roon on or off (22 Oct 2026, René: for someone without Roon "Looking for Roon…" was "een beetje naargeestig"). Off:
    /// no looking for a Core, no status line, no Roon in the checklist. Standard: on for a Mac that was ever enabled in
    /// Roon (an update changes nothing), off for a fresh install.
    @Published private(set) var roonOn = false
    private static let roonKey = "Roon"

    func setRoon(_ on: Bool) {
        guard on != roonOn else { return }
        roonOn = on
        UserDefaults.standard.set(on, forKey: Self.roonKey)
        Log.note("roon: \(on ? "on" : "off") (the switch in the menu)")
        if on { connection.start() } else {
            if bridge.isOn, !bridge.isUPnP, !bridge.isLocal { bridge.turnOff() }
            connection.stop()
            searchingSince = nil; searchTooLong = false
        }
    }

    /// Local and UPnP get a switch of their own as well (22 Oct 2026, René: "is het niet logisch om alle drie de segmenten
    /// aan/uit te maken?"). Off: not in the menu, and a target of that kind that plays is let go.
    @Published private(set) var localOn = Bridge.localEnabled
    @Published private(set) var upnpOn = UPnPFinder.enabled

    func setLocal(_ on: Bool) {
        guard on != localOn else { return }
        localOn = on
        UserDefaults.standard.set(on, forKey: "ThisMac")
        Log.note("local: \(on ? "on" : "off") (the switch in the menu)")
        if !on, bridge.isOn, bridge.isLocal { bridge.turnOff() }
    }

    func setUPnP(_ on: Bool) {
        guard on != upnpOn else { return }
        upnpOn = on
        UserDefaults.standard.set(on, forKey: "UPnP")
        Log.note("upnp: \(on ? "on" : "off") (the switch in the menu)")
        if on { finder.start() } else {
            if bridge.isOn, bridge.isUPnP { bridge.turnOff() }
            finder.stop()
        }
    }

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
        if on, let zone = selectedZone { Task { await bridge.turnOn(zone: zone) } }
        else if on, let renderer = selectedRenderer { Task { await bridge.turnOn(renderer: renderer) } }
        else if on, let out = selectedLocal { Task { await bridge.turnOn(local: out) } }
        else { bridge.turnOff() }
    }

    func setVolume(_ zone: RoonZone, to value: Double) { tracker.setVolume(zone, to: value) }
    func stepVolume(_ zone: RoonZone, up: Bool) { tracker.stepVolume(zone, up: up) }

    /// Since when Arco looks for a Roon Core without finding one (22 Oct 2026: a tester saw "Looking for Roon…" and nothing
    /// in the log said why): one line in the log after 30 s, and a hint in the menu.
    @Published private(set) var searchingSince: Date?
    private var searchNoted = false
    /// 30 s without a Core: the menu says what to check.
    @Published private(set) var searchTooLong = false

    private func connectionChanged(_ state: RoonConnection.State) {
        connectionState = state
        if case .searching = state, roonOn {
            if searchingSince == nil {
                searchingSince = Date(); searchNoted = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, let since = self.searchingSince, Date().timeIntervalSince(since) >= 29, !self.searchNoted else { return }
                    self.searchNoted = true
                    self.searchTooLong = true
                    Log.note("roon: no Roon Core answered for 30 s — not on this network (another subnet, a VPN, a guest network), or Arco may not use the local network (System Settings › Privacy & Security › Local Network)")
                }
            }
        } else {
            if let since = searchingSince, searchNoted { Log.note("roon: found after \(Int(Date().timeIntervalSince(since))) s") }
            searchingSince = nil
            searchTooLong = false
        }
        if case .paired(let core) = state { Log.note("roon: connected to \(core.name) (\(core.version))") }
        if case .paired = state {
            tracker.start(on: connection)
            connection.setStatus(selectedZone.map { "Ready — plays to \($0.name)" } ?? "Ready — pick a zone in the menu")
        } else {
            tracker.stop()
            zones = []
            if bridge.isOn, !bridge.isUPnP, !bridge.isLocal { bridge.turnOff() }
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
        if selectedZone == nil, selectedZoneID?.hasPrefix("upnp:") != true, selectedZoneID?.hasPrefix("local:") != true, let name = UserDefaults.standard.string(forKey: Self.zoneNameKey),
           let again = zones.first(where: { $0.name == name }) {
            select(again)
        }
    }
}
