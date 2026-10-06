// The menu: where Arco stands with Roon, the zones to play to (with what plays there), and the volume of the chosen one.
// Everything here works with the Roon app closed — a laptop on your lap, Music open, Roon somewhere else in the house.
import SwiftUI
import ArcoRoon

struct MenuView: View {
    @ObservedObject var model: ArcoModel
    @ObservedObject var bridge: Bridge

    init(model: ArcoModel) {
        self.model = model
        self.bridge = model.bridge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arco").font(.headline)
                Spacer()
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            content
            Divider()
            HStack {
                Spacer()
                Button("Quit Arco") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var statusLine: String {
        switch model.connectionState {
        case .searching: return "Looking for Roon…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .waitingForAuthorization(let name): return "Waiting for \(name)"
        case .paired(let core): return "Connected to \(core.name)"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.connectionState {
        case .searching, .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for a Roon Core on your network.").font(.callout).foregroundStyle(.secondary)
            }
        case .waitingForAuthorization(let name):
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Arco in Roon").font(.callout.weight(.semibold))
                Text("In Roon on any device, open Settings › Extensions and press Enable next to Arco. (\(name))")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paired:
            sending
            Divider()
            if model.zones.isEmpty {
                Text("Roon has no zones right now.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Play to").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.zones) { zone in
                        ZoneRow(zone: zone, selected: zone.id == model.selectedZoneID) { model.select(zone) }
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

    private var isFailure: Bool { if case .failed = bridge.phase { return true }; return false }

    private var sendingLine: String {
        if !Bridge.driverInstalled { return "The Arco audio driver isn't installed yet." }
        let zone = bridge.zoneName ?? model.selectedZone?.name ?? "a zone"
        switch bridge.phase {
        case .off: return model.selectedZone == nil ? "Pick a zone below first." : "Music and Spotify play on this Mac. Switch on to play them on \(zone)."
        case .waitingForMusic: return "Ready — press play in Music or Spotify to start on \(zone)."
        case .starting: return "Starting on \(zone)…"
        case .playing: return "Playing on \(zone)."
        case .paused: return "Paused on \(zone)."
        case .failed(let message): return message
        }
    }
}

private struct ZoneRow: View {
    let zone: RoonZone
    let selected: Bool
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
        let what = [zone.nowPlayingTitle, zone.nowPlayingSubtitle].compactMap { $0 }.joined(separator: " · ")
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
