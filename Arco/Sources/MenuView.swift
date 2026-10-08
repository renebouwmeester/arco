// The menu: where Arco stands with Roon, the zones to play to (with what plays there), and the volume of the chosen one.
// Everything here works with the Roon app closed — a laptop on your lap, Music open, Roon somewhere else in the house.
import SwiftUI
import ArcoRoon

struct MenuView: View {
    @ObservedObject var model: ArcoModel
    @ObservedObject var bridge: Bridge
    @ObservedObject var setup: SetupCheck

    init(model: ArcoModel) {
        self.model = model
        self.bridge = model.bridge
        self.setup = model.setup
    }

    private var isPaired: Bool { if case .paired = model.connectionState { return true }; return false }
    /// Enabled in Roon before, and connecting again — after a start or an update (0.3.1, René: "Het rijtje goed te keuren
    /// is nu weg – lijkt zichzelf te hebben hersteld?"): the menu says it connects instead of showing the checklist, whose
    /// "Enabled in Roon" stood open for those seconds. Only if Roon really waits for Enable does the checklist return.
    private var reconnecting: Bool {
        if case .waitingForAuthorization = model.connectionState { return false }
        return !isPaired && model.connection.wasPaired
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arco").font(.headline)
                Text(Self.version).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            // The checklist while something is missing — also while Roon isn't connected (its last item).
            if !(setup.macReady && (isPaired || reconnecting)) {
                SetupList(setup: setup, connection: model.connectionState)
            } else if reconnecting {
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
            if isPaired {
                if !setup.macReady { Divider() }
                content
            }
            Divider()
            HStack {
                LoginItemToggle()
                Spacer()
                if model.updater.available {
                    Button("Check for Updates…") { model.updater.checkForUpdates() }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Uninstall Arco…") { Uninstaller.run(bridge: bridge) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                // The log in Finder, selected — ~/Library is hidden, and a bug report wants the file (René, 8 Oct).
                Button("Show Log") { Log.reveal() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
                Button("Quit Arco") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
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
        switch model.connectionState {
        case .searching: return "Looking for Roon…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .waitingForAuthorization(let name): return "Waiting for \(name)"
        case .paired(let core): return "Connected to \(core.name)"
        }
    }

    /// The switch and the zones, once Roon is connected (before that the checklist says what is missing).
    @ViewBuilder private var content: some View {
        switch model.connectionState {
        case .searching, .connecting, .waitingForAuthorization:
            EmptyView()
        case .paired:
            sending
            Divider()
            if model.zones.isEmpty {
                Text("Roon has no zones right now").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Play to").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.zones) { zone in
                        // Arco's zone shows what Arco sends (Roon's own line for an audio-input session lags behind).
                        let own = zone.id == model.selectedZoneID && bridge.isOn ? bridge.nowPlaying : nil
                        ZoneRow(zone: zone, selected: zone.id == model.selectedZoneID, arcoPlays: own) { model.select(zone) }
                        if zone.id == model.selectedZoneID, zone.volume != nil {
                            VolumeRow(zone: zone, model: model)
                                .padding(.leading, 26).padding(.bottom, 4)
                        }
                    }
                }
            }
        }
    }
}

extension MenuView {
    /// The switch: the Music app to the chosen zone, or back to this Mac.
    @ViewBuilder var sending: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { bridge.isOn }, set: { model.setSending($0) })) {
                Text("Send to Roon").font(.body.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(!Bridge.driverInstalled || (model.selectedZone == nil && !bridge.isOn))
            Text(sendingLine)
                .font(.caption)
                .foregroundStyle(isFailure ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// " · 96 kHz", " · 44.1 kHz" — the rate Roon receives, changing with the track.
    private var rateSuffix: String {
        guard let rate = bridge.rate, rate > 0 else { return "" }
        let khz = rate / 1000
        return " · " + (khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)) + " kHz"
    }

    private var isFailure: Bool { if case .failed = bridge.phase { return true }; return false }

    private var sendingLine: String {
        if !Bridge.driverInstalled { return "The Arco audio driver isn't installed yet" }
        let zone = bridge.zoneName ?? model.selectedZone?.name ?? "a zone"
        switch bridge.phase {
        case .off: return model.selectedZone == nil ? "Pick a zone below first" : "Switch on to play Apple Music in Roon on this Mac"
        case .switchingOn: return "Switching to \(zone)…"
        case .waitingForMusic: return "Ready — press play in Music to start on \(zone)"
        case .starting: return "Starting on \(zone)…"
        case .playing: return "Playing on \(zone)" + rateSuffix
        case .paused: return "Paused on \(zone)" + rateSuffix
        case .failed(let message): return message
        }
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
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    .foregroundStyle(.secondary).font(.caption)
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
