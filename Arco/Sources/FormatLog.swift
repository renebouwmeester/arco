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
// - a skip: the first line within 1.2 s after it; none — the same format;
// - the start of a session: the last line since Arco was switched on (the Music app sets up a queue for the new output).
// "None means the same" only once the log has shown it works on this Mac (a line seen); until then, AppleScript.
// Lines in the seconds after a resume or after Arco's own change of clock are about the track that already plays.
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
            if now < quietUntil { continue }
            entries.append(Entry(at: now, rate: rate, format: format))
            seenAny = true
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
            try? await Task.sleep(for: .milliseconds(1500))
            return entries.last.map { ($0.rate, "the Music app's log, \($0.format)") }
        case .natural:
            if let e = entries.last(where: { $0.at <= change && $0.at > (previous ?? .distantPast) }) {
                return (e.rate, "the Music app's log, \(e.format) loaded ahead")
            }
            return seenAny ? same : nil
        case .skip:
            let until = change.addingTimeInterval(1.2)
            while Date() < until {
                if let e = entries.first(where: { $0.at > change.addingTimeInterval(-0.3) }) {
                    return (e.rate, "the Music app's log, \(e.format)")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return seenAny ? same : nil
        }
    }
}
