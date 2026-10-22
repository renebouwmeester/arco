// OpenHome as an output (22 Oct 2026, René: "zouden we voor Linn niet eerst die OpenHome-test willen doen? Dan kan het in
// één keer goed"). Linn's own way, also spoken by Lumin, Auralic, Moon and everything with upmpdcli: the renderer keeps a
// playlist of its own and plays it gapless. So per track (see Slices.swift) is: start = DeleteAll, Insert, SeekId; the next
// track = Insert after the one that plays (UPnP AV's SetNext); where it is = the Playlist's Id and the Time service.
// First measured on the AudioPi with upmpdcli 1.9.17 (MPD to a null output).
import ArcoRoon
import Foundation

@MainActor
final class OpenHomeOutput: Output {
    let renderer: UPnPRenderer
    private let oh: UPnPRenderer.OpenHome
    var onEvent: ((AudioInputSession.Event) -> Void)?
    /// As for UPnP AV: 3 s of lead for every renderer, plus what Arco holds back.
    let lead: Double? = 4.5
    var name: String { renderer.name }
    /// OpenHome's states: Playing, Paused, Stopped, Buffering.
    var isStarved: Bool { ["Buffering", "Stopped"].contains(lastState) }
    private var lastState = ""
    /// The renderer's playlist ids and the tracks (slices) they are.
    private var tracks: [Int: String] = [:]
    private var currentID = 0
    private var track: String?
    private var poller: Task<Void, Never>?

    init(renderer: UPnPRenderer, openHome: UPnPRenderer.OpenHome) {
        self.renderer = renderer
        oh = openHome
    }

    private func playlist(_ action: String, _ args: String = "") async -> String? {
        await renderer.soap(oh.playlist, oh.playlistType, action, args)
    }

    func begin(displayName: String, iconURL: String?) async -> Bool {
        guard let answer = await playlist("TransportState") else { return false }
        Log.note("openhome: \(renderer.name) answers (\(UPnPRenderer.value("Value", in: answer) ?? "?"))")
        return true
    }

    /// A new start: the renderer's playlist emptied, this slice in it, and played.
    func play(track: String, url: String, info: JSON) async -> String {
        // The tracker first: it read the old list while it was emptied ("slice 2 — ?", 22 Oct 11:06:04).
        poller?.cancel(); poller = nil
        _ = await playlist("DeleteAll")
        tracks = [:]
        guard let id = await insert(after: 0, url: url, info: info),
              await playlist("SeekId", "<Value>\(id)</Value>") != nil else { return "MediaError" }
        tracks[id] = track
        currentID = id
        self.track = track
        lastState = ""
        for _ in 0..<40 {
            let state = UPnPRenderer.value("Value", in: await playlist("TransportState"))
            if state == "Playing" { lastState = "Playing"; startPolling(); return "Playing" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        startPolling()
        return "Timeout"
    }

    /// The next slice after the one that plays: the renderer goes on in it by itself, gapless.
    func setNext(track: String, url: String, info: JSON) async -> Bool {
        guard let id = await insert(after: currentID, url: url, info: info) else { return false }
        tracks[id] = track
        return true
    }

    private func insert(after: Int, url: String, info: JSON) async -> Int? {
        let meta = UPnPRenderer.escape(UPnPOutput.didl(url: url, info: info))
        let answer = await playlist("Insert", "<AfterId>\(after)</AfterId><Uri>\(UPnPRenderer.escape(url))</Uri><Metadata>\(meta)</Metadata>")
        return UPnPRenderer.value("NewId", in: answer).flatMap(Int.init)
    }

    /// No new track information for what plays: each slice carries its own (Insert's metadata).
    func updateInfo(track: String, info: JSON) async {}

    func control(_ control: String) {
        Task { @MainActor in
            switch control {
            case "pause": _ = await playlist("Pause")
            case "play": _ = await playlist("Play")
            default: break
            }
        }
    }

    func end() {
        poller?.cancel(); poller = nil
        let r = renderer, p = oh
        Task { _ = await r.soap(p.playlist, p.playlistType, "Stop") }
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, var track = self.track else { return }
                let state = UPnPRenderer.value("Value", in: await self.playlist("TransportState")) ?? ""
                // Moved on to the next slice by itself (its playlist): from now on that one.
                if let id = UPnPRenderer.value("Value", in: await self.playlist("Id")).flatMap(Int.init), id != self.currentID,
                   let t = self.tracks[id] {
                    self.currentID = id
                    track = t; self.track = t
                    self.onEvent?(.playing(track: t))
                }
                if state == "Playing", let time = self.oh.time,
                   let seconds = UPnPRenderer.value("Seconds", in: await self.renderer.soap(time, self.oh.timeType, "Time")).flatMap(Int.init) {
                    self.onEvent?(.time(track: track, positionMs: seconds * 1000))
                }
                if state != self.lastState, !state.isEmpty {
                    let was = self.lastState
                    self.lastState = state
                    Log.note("openhome: \(self.renderer.name) — \(state)")
                    switch (was, state) {
                    case ("Playing", "Paused"): self.onEvent?(.paused(track: track))
                    case ("Paused", "Playing"): self.onEvent?(.unpaused(track: track))
                    case ("Playing", "Stopped"), ("Paused", "Stopped"): self.onEvent?(.stopped(track: track))
                    default: break
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
