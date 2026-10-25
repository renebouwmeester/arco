// The transition meter (0.4.0, from Basso's meter of 21 Oct 2026): for every change of track, one line in Arco's log
// that says how it went — "seamless", or what went wrong. Arco watches its own log for twenty seconds after the change
// (the signs below are its own lines), then writes the verdict. A bug report with the log then shows at a glance which
// changes were heard, and why.
//
//   transition: Folie À Deux — natural, 96 → 96 kHz — seamless
//   transition: Moon River — skip, 96 → 44.1 kHz — the clock corrected at the track's start
//   transition: California Dreamin' — natural, 44.1 → 96 kHz — seamless on Arco's side; the endpoint switches to the new rate
//
// The verdict comes twenty seconds after the change, so it says when the change was (0.5.0b5, René, 25 Oct 2026: it read as
// if the change came then, 14 s after the renderer had taken it): the Music app's moment, and the endpoint's when it says.
import Foundation

@MainActor
final class TransitionMeter {
    enum Kind: String { case start, natural, skip }

    private struct Open { let title: String; let kind: Kind; let from: Double?; let at: Date; var signs: [String] = []; var renderer: Date? }
    private var open: Open?
    private var closing: Task<Void, Never>?
    /// The rate now, for the verdict line.
    var rate: (() -> Double?)?

    /// What Arco's own log says when something is heard (a sign may be expected for a kind: a new run at a skip is not one).
    private static let signs: [(String, String)] = [
        ("once more, a new run", "Roon had an error — a new run"),
        ("frozen before run", "Roon stopped short of the change — the next run at once"),
        ("failed:", "Arco failed"),
        ("correcting, from the track's start", "the clock corrected at the track's start"),
        ("didn't play again", "the Music app stalled after a change of clock"),
        ("capture: no input for", "no sound from the Music app"),
        ("the end of the run not found again", "a resume didn't splice"),
        ("resume: Roon is", "Roon far behind on resuming"),
        ("begins the next run", "a new run at the change (another rate)"),
        // Per track (UPnP): a natural change the renderer didn't have as its next — it stops in between.
        ("not declared ahead", "the next track wasn't declared ahead — the renderer stopped in between"),
    ]

    static let pausedAtChange = "the Music app paused at the change (often a track that failed to load)"

    init() {
        Log.observer = { [weak self] line in
            Task { @MainActor in self?.heard(line) }
        }
    }

    /// A change of track: the previous one's verdict now, and a new window.
    func begin(_ title: String, kind: Kind, gepauzeerd: Bool = false) {
        close()
        // After a stop the listener starts something new (23 Oct 2026, Ropiee on a Verox: stop, ten seconds, then the next
        // track — logged as a skip that "paused at the change"). That is a start, not a skip, and its pause is the restart.
        var kind = kind
        if stopped || gepauzeerd, kind == .skip { kind = .start }   // ook een skip tijdens een pauze: de pauze was van de luisteraar
        stopped = false
        open = Open(title: title, kind: kind, from: rate?(), at: Date())
        // The pause can be written just before the change (Sky Bass: 30 ms before "next track").
        if kind != .start, let p = lastPause, Date().timeIntervalSince(p) < 1 { open?.signs.append(Self.pausedAtChange) }
        closing?.cancel()
        // Tijdens een pauze begint het venster pas bij het hervatten (hervat()): anders sloot het vóór de klok gewisseld was.
        if gepauzeerd { return }
        sluitOver20()
    }

    /// Het hervatten na een skip tijdens een pauze: nu begint het venster van twintig seconden.
    func hervat() {
        guard let o = open else { return }
        open = Open(title: o.title, kind: o.kind, from: o.from, at: Date(), signs: o.signs, renderer: o.renderer)
        sluitOver20()
    }

    private func sluitOver20() {
        closing?.cancel()
        closing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Arco stopped sending: the open window closes as it is.
    func end() { close() }

    private var lastPause: Date?
    /// The Music app stopped (not just paused) since the last change of track.
    private var stopped = false
    /// Arco's own reasons to pause the Music app (a change of clock, switching on): such a pause isn't heard as one.
    private var lastOwn: Date?

    private func heard(_ line: String) {
        if (line.hasPrefix("clock:") && line.contains(" → ")) || line.hasPrefix("session: began") || line.hasPrefix("rate: back to") { lastOwn = Date() }
        if line.hasPrefix("music: paused"), lastOwn.map({ Date().timeIntervalSince($0) > 2.5 }) ?? true { lastPause = Date() }
        if line.hasPrefix("music: stopped") { stopped = true }
        guard var o = open, !line.contains("transition:") else { return }
        // When the endpoint took the change — when it was heard: per track the renderer's own report of the new slice;
        // for Roon (a new run at another rate) its "Playing" for the run.
        if o.renderer == nil, line.contains(o.title),
           line.hasPrefix("renderer: slice") || (line.hasPrefix("play run") && line.hasSuffix("answered Playing")) { o.renderer = Date() }
        // The Music app paused at the change itself (21 Oct 2026, Sky Bass: Apple's server answered 503, "Asset failed to
        // load", and the Music app paused "for an error") — Arco passes the pause on, but the change was not seamless.
        if line.hasPrefix("music: paused"), o.kind != .start, lastPause.map({ Date().timeIntervalSince($0) < 0.5 }) == true,
           Date().timeIntervalSince(o.at) < 3, !o.signs.contains(Self.pausedAtChange) {
            o.signs.append(Self.pausedAtChange)
        }
        for (sign, what) in Self.signs where line.contains(sign) {
            // A new run belongs to a start or a skip; at a natural change it is the silence of another rate (accepted, but
            // said). A correction at a skip or a start comes before Roon plays: not heard.
            if o.kind != .natural, sign == "begins the next run" || sign == "correcting, from the track's start" { continue }
            if !o.signs.contains(what) { o.signs.append(what) }
        }
        open = o
    }

    private func close() {
        guard let o = open else { return }
        open = nil
        let khz = { (r: Double?) in r.map { MenuBarLabel.short($0) } ?? "?" }
        // Another rate is never seamless at the endpoint (a tester, 24 Oct 2026, 0.5.0b2: "still a hiccup between tracks with
        // different sample rates" — the log said "seamless"): Roon opens a new stream and the DAC switches rate, which most
        // DACs do with a short mute. The verdict speaks for Arco's side only and says so.
        let andereRate = o.from != nil && rate?() != nil && Int(o.from!) != Int(rate!()!)
        let verdict = o.signs.isEmpty
            ? (andereRate ? "seamless on Arco's side; the endpoint switches to the new rate" : "seamless")
            : o.signs.joined(separator: "; ")
        let klok = DateFormatter(); klok.dateFormat = "HH:mm:ss.SSS"
        let wanneer = o.renderer.map { "changed \(klok.string(from: o.at)), the endpoint took it at \(klok.string(from: $0))" }
            ?? "changed \(klok.string(from: o.at))"
        Log.note("transition: \(o.title) — \(o.kind.rawValue), \(khz(o.from)) → \(khz(rate?())) kHz — \(verdict) (\(wanneer))")
    }
}
