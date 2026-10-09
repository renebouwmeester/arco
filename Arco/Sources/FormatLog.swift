// What the Music app actually plays, from the system log (0.3.3, 8 Oct 2026). A tester on macOS 15: the Music app's
// AppleScript gave 44100 Hz for a 96 kHz track (on macOS 27 it gives the right rate) — the author of LosslessSwitcher
// warns that it only holds for local files. But each time the Music app sets up a track for playback it writes the
// format to the system log, at default level:
//
//   subaq_buildCAAudioQueue: … Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:96000
//
// The tester's Mac wrote exactly that, with the right rates. Arco follows it with `log stream`, filtered to that one
// line of the Music app, while it sends to Roon. (Since macOS 15 the log API itself is closed to other apps; the `log`
// command isn't. It needs an administrator account — without one, AppleScript remains.)
//
// The line names no track, only a moment, and the Music app loads the next track well ahead for gapless playback (17:28:58
// for a track that began at 17:30:47). And it writes one only when it sets up a new queue — a new format (or a skip): a next
// track at the same rate goes on in the same queue, without a line (18:12:08, 100 Lovers after a 96 kHz track). So:
// - a natural change of track: the last format loaded since the previous change; none — the same format as before;
// - a skip: the first lossless line within 2.5 s after it; none — AppleScript (not "the same": see below);
// - the start of a session: the last line since Arco was switched on (the Music app sets up a queue for the new output).
// "None means the same" only once the log has shown it works on this Mac (a line seen); until then, AppleScript.
//
// 0.3.4 (8 Oct 2026, Basso's evening on the KEF): the Music app can start a streamed track in AAC — 'qaac', 1024 frames
// per packet, 48 kHz for a hi-res master — and set up the real format about two seconds later ('qlac', 4096 frames, 96 kHz).
// A clock set on that AAC line was wrong, and the Music app then stayed at 48. So only lossless lines count ('qlac', 'alac',
// 'lpcm'); a skip or a start waits up to 2.5 s for one; and a lossless line that comes later anyway (up to 20 s after the
// change) corrects the clock (Bridge).
// After a skip, no line is not "the same format" (8 Oct, Moon River after a 96 kHz track): the Music app started it in AAC
// and set up 44.1 lossless only 13 s later; "the same" kept 96 over AppleScript's right 44.1, and the late line cut the
// stream. So a skip without a line asks AppleScript; the late lossless line still corrects it.
// Lines in the seconds after a resume or after Arco's own change of clock are about the track that already plays.
//
// The measurement of 9 Oct (Arco 0.3.3 on Gaylord, a meter beside it, René playing the scenarios) settled the rest:
// - a natural change at the same rate: no line (autoplay too); at another rate: the lossless line 60–100 s ahead;
// - a skip or a start: the lossless line from 0.05 s before to 0.9 s after (once, 8 Oct, Moon River: AAC first and
//   lossless 13 s later); AppleScript names the rate of the queue that plays — the AAC one in the first ~0.8 s;
// - a pause: the Music app sets up its queue again AT the pause, 0.15 s before it says it paused — a line of the track
//   that plays, which must never count as the next track's, loaded ahead (see forget(recent:)).
// So a skip or a start waits up to 3 s; a pause forgets the lines of the last second; and a lossless line of another
// rate within 3 s of a change (8 Oct, Traces of a Song: no line ahead, one 1.8 s after) still cuts at the track's
// start (Bridge) — Roon plays 5–7 s behind and hasn't had it yet.
import Foundation

@MainActor
final class FormatLog {
    private struct Entry { let at: Date; let rate: Int; let format: String }
    private var entries: [Entry] = []
    private var process: Process?
    private var buffer = Data()
    /// Not usable on this Mac (not an administrator, or the `log` command failed): AppleScript only.
    private(set) var unavailable = false
    /// The log has given a line since it started: it works here, and silence means "the same format".
    private(set) var seenAny = false
    private static let lossless: Set<String> = ["qlac", "alac", "lpcm"]
    /// Each lossless line (outside a quiet moment): for a late correction (Bridge).
    var onLossless: ((Date, Int) -> Void)?
    /// Moments after which lines are about the track that already plays (a resume, Arco's own change of clock).
    private var quietUntil = Date.distantPast

    func start() {
        guard process == nil, !unavailable else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate",
                       #"process == "Music" AND eventMessage CONTAINS "Creating AudioQueue with format""#]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.received(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let text = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in
                Log.note("format log: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))")
                if text.lowercased().contains("admin") { self?.unavailable = true }
            }
        }
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.process = nil } }
        do {
            try p.run()
            process = p
            Log.note("format log: following the Music app's audio formats")
        } catch {
            unavailable = true
            Log.note("format log: can't run the log command (\(error.localizedDescription)) — AppleScript only")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        entries = []
        seenAny = false
    }

    /// Lines from now on (for `seconds`) are about the track that already plays.
    func quiet(for seconds: Double) { quietUntil = max(quietUntil, Date().addingTimeInterval(seconds)) }

    /// The Music app paused: the lines of the last `seconds` were its queue set up again for the track that plays (it
    /// writes one just before it says it paused) — never the next track's.
    func forget(recent seconds: Double) {
        let since = Date().addingTimeInterval(-seconds)
        entries.removeAll { $0.at > since }
    }

    /// How long a skip or a start waits for its lossless line.
    static let wait: TimeInterval = 3

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String,
                  let r = message.range(of: #"sampleRate:(\d+)"#, options: .regularExpression),
                  let rate = Int(message[r].filter(\.isNumber)) else { continue }
            var format = "?"
            if let f = message.range(of: #"format:'[^']+'"#, options: .regularExpression) {
                format = String(message[f].dropFirst(8).dropLast())
            }
            let now = Date()
            guard Self.lossless.contains(format) else {
                Log.note("format log: the Music app set up \(format) at \(rate) Hz — not lossless (a quick start), doesn't count")
                continue
            }
            if now < quietUntil { continue }
            entries.append(Entry(at: now, rate: rate, format: format))
            seenAny = true
            onLossless?(now, rate)
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
            Log.note("format log: the Music app set up \(format) at \(rate) Hz")
        }
    }

    enum Change { case start, natural, skip }

    /// The rate for a change of track at `change` (see the top of this file). `current`: the device's rate now, for "the
    /// same format". Nil: the log can't say (AppleScript then).
    func rate(_ kind: Change, change: Date, previous: Date?, current: Int) async -> (rate: Int, how: String)? {
        guard !unavailable, process != nil else { return nil }
        let same = (current, "no new format in the Music app's log — the same as before")
        switch kind {
        case .start:
            if let e = entries.last { return (e.rate, "the Music app's log, \(e.format)") }
            let until = change.addingTimeInterval(Self.wait)
            while Date() < until, entries.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            return entries.last.map { ($0.rate, "the Music app's log, \($0.format)") }
        case .natural:
            if let e = entries.last(where: { $0.at <= change && $0.at > (previous ?? .distantPast) }) {
                return (e.rate, "the Music app's log, \(e.format) loaded ahead")
            }
            return seenAny ? same : nil
        case .skip:
            let until = change.addingTimeInterval(Self.wait)
            while Date() < until {
                if let e = entries.first(where: { $0.at > change.addingTimeInterval(-0.3) }) {
                    return (e.rate, "the Music app's log, \(e.format)")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil   // not "the same": a skipped-to track can start in AAC and get its lossless queue only later
        }
    }
}
