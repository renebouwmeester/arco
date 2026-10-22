// The menu: where Arco stands with Roon, the zones to play to (with what plays there), and the volume of the chosen one.
// Everything here works with the Roon app closed — a laptop on your lap, Music open, Roon somewhere else in the house.
import SwiftUI
import ArcoRoon

struct MenuView: View {
    @ObservedObject var model: ArcoModel
    @ObservedObject var bridge: Bridge
    @ObservedObject var setup: SetupCheck
    @ObservedObject var finder: UPnPFinder

    init(model: ArcoModel) {
        self.model = model
        self.bridge = model.bridge
        self.setup = model.setup
        self.finder = model.finder
    }

    private var isPaired: Bool { if case .paired = model.connectionState { return true }; return false }
    /// A Roon zone is (or would be) the target: nothing else chosen.
    private var roonNeeded: Bool { model.roonOn && model.selectedRenderer == nil && model.selectedLocal == nil }
    private var macOK: Bool { model.selectedLocal != nil ? setup.musicReady : setup.macReady }
    /// Enabled in Roon before, and connecting again — after a start or an update (0.3.1, René: "Het rijtje goed te keuren
    /// is nu weg – lijkt zichzelf te hebben hersteld?"): the menu says it connects instead of showing the checklist, whose
    /// "Enabled in Roon" stood open for those seconds. Only if Roon really waits for Enable does the checklist return.
    /// The checklist while something is missing — also while Roon isn't connected, when a Roon zone is the target.
    private var showsChecklist: Bool { !(macOK && (!roonNeeded || isPaired || reconnecting)) }
    private var reconnecting: Bool {
        if case .waitingForAuthorization = model.connectionState { return false }
        return model.roonOn && !isPaired && model.connection.wasPaired
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The version on the right (22 Oct 2026, René: "moeten versienummer en de grote switch nu ook niet rechts
            // lijnen?"); Roon's status lives in the Roon section now.
            HStack(alignment: .firstTextBaseline) {
                Text("Arco").font(.headline)
                Spacer()
                Text(Self.version).font(.callout).foregroundStyle(.tertiary)
            }
            Divider()
            // The checklist while something is missing — also while Roon isn't connected (its last item).
            // Roon is only needed for a Roon zone (21 Oct 2026, René): with UPnP or This Mac chosen it's optional, and This
            // Mac needs no driver and no microphone either.
            if showsChecklist {
                SetupList(setup: setup, connection: model.connectionState, roonOptional: !roonNeeded, localOnly: model.selectedLocal != nil,
                          roonShown: model.roonOn)
            } else if reconnecting, roonNeeded {
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
            // Still no Roon after 30 s: what to check (only when a Roon zone is the target).
            if roonNeeded, model.searchTooLong {
                Text("Can't find Roon — is the Core on this network? Also check System Settings › Privacy & Security › Local Network")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            // The switch and the targets — always: each kind of target has its own switch there.
            // A line only under something (the checklist, the reconnecting line, the hint) — not a second one under the top.
            if showsChecklist || (reconnecting && roonNeeded) || (roonNeeded && model.searchTooLong) { Divider() }
            content
            Divider()
            // The bottom as in a macOS menu (22 Oct 2026, René: "onderin is het een beetje een chaos geworden"): the two
            // settings as rows with a switch, like the headers above; then the actions, each a row of its own.
            VStack(alignment: .leading, spacing: 6) {
                LoginItemToggle()
                RateInMenuBarToggle()
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if model.updater.available {
                    MenuActionRow(title: "Check for Updates…") { model.updater.checkForUpdates() }
                }
                // The log in Finder, selected — ~/Library is hidden, and a bug report wants the file (René, 8 Oct).
                MenuActionRow(title: "Show Log") { Log.reveal() }
                MenuActionRow(title: "Uninstall Arco…") { Uninstaller.run(bridge: bridge) }
                MenuActionRow(title: "Quit Arco", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { setup.refresh() }
    }

    /// "0.1.3" — which Arco this is, for a bug report and after an update.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private var statusLine: String {
        guard model.roonOn else { return "" }
        switch model.connectionState {
        case .searching: return "Looking for Roon…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .waitingForAuthorization(let name): return "Waiting for \(name)"
        case .paired(let core): return "Connected to \(core.name)"
        }
    }

    /// The switch and the zones, once Roon is connected (before that the checklist says what is missing).
    @ViewBuilder private var content: some View {
        sending
        Divider()
        // Three kinds of target, each with its own switch (22 Oct 2026, René): Local, Roon, UPnP. Off, a section is only
        // its header.
        // Local: this Mac's outputs, the clock per track for a DAC (see Bridge.isLocal).
        header("Local", symbol: "laptopcomputer", on: model.localOn) { model.setLocal($0) }
        if model.localOn {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AudioDevices.outputs) { out in
                    let selected = "local:" + out.id == model.selectedZoneID
                    RendererRow(name: out.name, selected: selected, line: selected && bridge.isOn ? playingLine : nil) {
                        model.select(out)
                    }
                }
            }
        }
        header("Roon", symbol: "music.note.house.fill", on: model.roonOn) { model.setRoon($0) }
        // Where Arco stands with Roon (it was the line at the top, 22 Oct 2026): connected — or, with another target chosen,
        // looking or connecting (for a Roon zone the checklist says that already).
        if model.roonOn, isPaired || !roonNeeded {
            Text(statusLine).font(.callout).foregroundStyle(.secondary)
        }
        if model.roonOn, isPaired {
            if model.zones.isEmpty {
                Text("Roon has no zones right now").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.zones) { zone in
                        // Arco's zone shows what Arco sends (Roon's own line for an audio-input session lags behind).
                        let own = zone.id == model.selectedZoneID && bridge.isOn ? bridge.nowPlaying : nil
                        ZoneRow(zone: zone, selected: zone.id == model.selectedZoneID, arcoPlays: own) { model.select(zone) }
                        if zone.id == model.selectedZoneID, zone.volume != nil {
                            VolumeRow(zone: zone, model: model)
                                .padding(.leading, 26).padding(.bottom, 4)
                        }
                        if zone.id == model.selectedZoneID {
                            RateRow(zone: zone, bridge: bridge)
                                .padding(.leading, 26).padding(.bottom, 4)
                        }
                    }
                }
            }
        }
        // UPnP renderers (see UPnP.swift).
        header("UPnP", symbol: "network", on: model.upnpOn) { model.setUPnP($0) }
        if model.upnpOn {
            if finder.renderers.isEmpty {
                Text("Looking for renderers…").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finder.renderers) { r in
                        let selected = "upnp:" + r.id == model.selectedZoneID
                        RendererRow(name: r.name, selected: selected, line: selected && bridge.isOn ? playingLine : nil) {
                            model.select(r)
                        }
                    }
                }
            }
        }
    }
}

extension MenuView {
    /// A section's header (22 Oct 2026, René: the bare captions were "hele iele kopjes"): as in macOS's own Wi-Fi and
    /// Bluetooth menus — a symbol in a circle, blue when the section is on, then its name, and its switch on the right.
    func header(_ title: String, symbol: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.white : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
            Text(title).font(.body.weight(.semibold))
            Spacer()
            Toggle(title, isOn: Binding(get: { on }, set: set))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    /// "Title · Artist" of what Arco sends, under the chosen renderer or output.
    var playingLine: String? { bridge.nowPlaying.map { [$0.title, $0.artist].filter { !$0.isEmpty }.joined(separator: " · ") } }

    /// The switch: the Music app to the chosen zone, or back to this Mac.
    @ViewBuilder var sending: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The switch on the right, like those of Local, Roon and UPnP below (22 Oct 2026).
            HStack {
                Text("Enable").font(.body.weight(.medium))
                Spacer()
                Toggle("Enable", isOn: Binding(get: { bridge.isOn }, set: { model.setSending($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    // This Mac needs no Arco driver: the Music app plays to the DAC itself.
                    .disabled((!Bridge.driverInstalled && model.selectedLocal == nil) || (model.selectedName == nil && !bridge.isOn))
            }
            Text(sendingLine)
                .font(.callout)
                .foregroundStyle(isFailure ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 0.4.0: the Music app below volume 100 scales every sample — bit-perfect only at 100.
            if bridge.isOn, let v = bridge.musicVolume, v < 100 {
                HStack(spacing: 6) {
                    Text("Music volume \(v) — not bit-perfect").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Set to 100") { bridge.setMusicVolumeTo100() }
                        .buttonStyle(.borderless).font(.callout)
                }
            }
        }
    }

    /// " · 96 kHz", " · 44.1 kHz" — the rate Roon receives, changing with the track; " · 96 kHz, fixed" on a zone with
    /// a fixed rate (0.3.7).
    private var rateSuffix: String {
        guard let rate = bridge.rate, rate > 0 else { return "" }
        let khz = rate / 1000
        let fixed = bridge.zoneName.map(bridge.isFixed) == true
        // With the bit depth when the Music app's label gave it (René, 21 Oct 2026: "aardigheidje") — the menu bar stays compact.
        let bits = bridge.bits.map { "\($0)-bit/" } ?? ""
        return " · " + bits + (khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)) + " kHz" + (fixed ? ", fixed" : "")
    }

    /// " (Roon)", " (Local)", " (UPnP)" — where the music goes (René, 21 Oct 2026).
    private var kindSuffix: String { bridge.targetKind.map { " (\($0))" } ?? "" }

    private var isFailure: Bool { if case .failed = bridge.phase { return true }; return false }

    private var sendingLine: String {
        if !Bridge.driverInstalled, model.selectedLocal == nil { return "The Arco audio driver isn't installed yet" }
        let zone = bridge.zoneName ?? model.selectedName ?? "a zone"
        switch bridge.phase {
        case .off: return model.selectedName.map { "Switch on to play Apple Music to \($0)" } ?? "Pick a zone below first"
        case .switchingOn: return "Switching to \(zone)…"
        case .waitingForMusic: return "Ready — press play in Music to start on \(zone)"
        case .starting: return "Starting on \(zone)…"
        case .playing: return "Playing on \(zone)" + kindSuffix + rateSuffix
        case .paused: return "Paused on \(zone)" + kindSuffix + rateSuffix
        case .failed(let message): return message
        }
    }
}

/// A UPnP renderer in the list: like a zone row, with what Arco sends to it.
private struct RendererRow: View {
    let name: String
    let selected: Bool
    let line: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body)
                    if let line, !line.isEmpty { Text("▶︎ " + line).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ZoneRow: View {
    let zone: RoonZone
    let selected: Bool
    var arcoPlays: (title: String, artist: String)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(zone.name).font(.body)
                    if let line = playingLine {
                        Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// What plays there, so a busy zone is recognisable before you take it over.
    private var playingLine: String? {
        let what = arcoPlays.map { [$0.title, $0.artist].filter { !$0.isEmpty }.joined(separator: " · ") }
            ?? [zone.nowPlayingTitle, zone.nowPlayingSubtitle].compactMap { $0 }.joined(separator: " · ")
        switch zone.state {
        case "playing": return what.isEmpty ? "Playing" : "▶︎ " + what
        case "paused": return what.isEmpty ? "Paused" : "Paused · " + what
        case "loading": return "Loading…"
        default: return nil
        }
    }
}

/// The rate for the chosen zone (0.3.7): follow each track (bit-perfect), or a fixed 96 kHz (no change of rate, ever).
private struct RateRow: View {
    let zone: RoonZone
    @ObservedObject var bridge: Bridge

    var body: some View {
        Picker(selection: Binding(get: { bridge.isFixed(zone.name) }, set: { bridge.setFixed($0, for: zone.name) })) {
            Text("Follow Each Track (Bit-Perfect)").tag(false)
            Text("Fixed 96 kHz (No Rate Switches)").tag(true)
        } label: {
            Image(systemName: "waveform").foregroundStyle(.secondary).font(.callout)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.callout)
        .fixedSize()
    }
}

private struct VolumeRow: View {
    let zone: RoonZone
    @ObservedObject var model: ArcoModel
    @State private var value: Double = 0
    @State private var dragging = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        if let volume = zone.volume {
            HStack(spacing: 8) {
                Image(systemName: volume.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(.secondary).font(.callout)
                if volume.type == "incremental" {
                    Button { model.stepVolume(zone, up: false) } label: { Image(systemName: "minus") }
                    Button { model.stepVolume(zone, up: true) } label: { Image(systemName: "plus") }
                    Spacer()
                } else {
                    // No `step:` — on macOS that draws a row of tick marks under the slider, which at 0–100 reads as a
                    // stray line. The value is rounded to Roon's step when it is sent.
                    Slider(value: $value, in: volume.min...max(volume.max, volume.min + 1)) { editing in
                        dragging = editing
                    }
                    .controlSize(.small)
                    Text(label(volume)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .onAppear { value = volume.value }
            .onChange(of: volume.value) { _, new in if !dragging { value = new } }
            .onChange(of: value) { _, new in
                let step = volume.step > 0 ? volume.step : 1
                let rounded = (new / step).rounded() * step
                guard rounded != volume.value else { return }
                // Not a request per pixel while dragging: the last value after a short pause.
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    if !Task.isCancelled { model.setVolume(zone, to: rounded) }
                }
            }
        }
    }

    private func label(_ volume: RoonZone.Volume) -> String {
        let step = volume.step > 0 ? volume.step : 1
        let shown = (value / step).rounded() * step
        return volume.type == "db" ? String(format: "%.0f dB", shown) : String(format: "%.0f", shown)
    }
}

/// A setting in the menu: its name, and a switch on the right (as the headers Local, Roon and UPnP).
struct SettingRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

/// An action in the menu, a row of its own as in a macOS menu: the whole width answers, and it lights up under the pointer.
struct MenuActionRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
    }
}
