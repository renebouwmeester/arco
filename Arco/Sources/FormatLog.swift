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
//
// 0.3.5 (10 Oct 2026, see docs/QUEUE.md): the Music app also writes the NEXT track to its log when the current one begins —
// its item and title ("ITMPAVItemCount INIT … (177582::177595) Title"), which item is next and its album ("isInContiguousAlbum
// … Next song: contentIdentifier=177582::177595 … storeAdamID=…"), and its length ("loadedTimeRanges 15.00 of 245.38").
// A lossless line that comes after the next track was named is that track's rate (not one at the rate that plays, not in a track's first seconds).
import Foundation

@MainActor
final class FormatLog {
    /// The next track, as the Music app names it (0.3.5). `rate`: from a lossless line after it was named; nil — the same.
    struct Next: Equatable {
        let item: String
        let title: String?
        let album: String
        var lengthMs: Int?
        var rate: Int?
        let at: Date
        /// When its rate was taken (a pause's line can be undone, see forget(recent:)).
        var rateAt: Date?
    }
    private(set) var next: Next?
    /// Called when the next track, its length or its rate becomes known.
    var onNext: ((Next) -> Void)?
    /// The rate the device runs at now (the bridge): a line at that rate is never the next track's — at the same rate the
    /// Music app loads the next track without a line (9 Oct) — but the current track's own queue set up again: a pause, a
    /// seek, a resume (17:52:42 and 17:53:03, La Source at 88.2 before Folie À Deux at 96).
    var deviceRate: (() -> Int)?
    private var titles: [String: String] = [:]
    private var lengths: [String: Int] = [:]
    /// How the Music app went to its current item (0.3.5): "setTargetContentItemID:<item> source:NaturalTransition" for a
    /// track that simply followed, "Redirect"/other for a jump (a skip, a play) — its own word, no estimate of time left.
    private var target: (item: String, natural: Bool, at: Date)?
    private struct Entry { let at: Date; let rate: Int; let format: String }
    private var entries: [Entry] = []
    private var process: Process?
    private var buffer = Data()
    /// Not usable on this Mac (not an administrator, or the `log` command failed): AppleScript only.
    private(set) var unavailable = false
    /// The log has given a line since it started: it works here, and silence means "the same format".
    private(set) var seenAny = false
    private static let lossless: Set<String> = ["qlac", "alac", "lpcm"]

    // MARK: The label (0.4.0)
    // The Music app gives each track it loads a label ("I/ICW") and names it with the track's title ("MP->AV Asset Log
    // Mapping: … (175085::175098) Dignity (Alternate Version) -> <AVPlayerItem: …> I/ICW"). Each audio track it sets up for
    // that label comes with the rate as its time scale, and a priming duration that tells the codec: AAC has its fixed
    // 2112 frames ("audio track 2 priming duration {2112/44100=0.048}"), lossless none ("{0/44100}"). Measured with Basso
    // on 21 Oct 2026 (Knives Out: tracks 2–4 AAC, track 5 ALAC 24-bit). So a line that names the track, its rate and
    // whether it is lossless — no window guessing. 2 ms after it: "mediaFormatinfo … sdFormatID = alac … sdBitDepth = 24 bit,
    // asbdSampleRate = 96.0 kHz" — the bit depth, for every track (the decoder's "from 24-bit source" only comes with a new
    // audio queue).
    struct Label: Equatable { let label: String; let title: String; let rate: Int; let track: Int; var bits: Int?; let at: Date }
    private var labelTitles: [String: String] = [:]
    private var labels: [String: Label] = [:]          // by title: the lossless label, the latest
    private var aacSeen: [String: Int] = [:]
    /// A lossless label arrived or changed (a track loaded ahead, or the one that plays switching to a better track).
    var onLabel: ((Label) -> Void)?

    /// The lossless label of the track with this title, if the Music app gave one.
    func label(for title: String) -> Label? { labels[title] }

    /// Waits up to `seconds` for the lossless label of this track.
    func waitForLabel(_ title: String, seconds: TimeInterval) async -> Label? {
        let until = Date().addingTimeInterval(seconds)
        while true {
            if let l = labels[title] { return l }
            if Date() >= until { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    /// Each lossless line (outside a quiet moment): for a late correction (Bridge).
    var onLossless: ((Date, Int) -> Void)?
    /// Moments after which lines are about the track that already plays (a resume, Arco's own change of clock).
    private var quietUntil = Date.distantPast

    func start() {
        guard process == nil, !unavailable else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate",
                       #"process == "Music" AND (eventMessage CONTAINS "Creating AudioQueue with format" OR eventMessage CONTAINS "ITMPAVItemCount INIT" OR eventMessage CONTAINS "isInContiguousAlbum" OR eventMessage CONTAINS "loadedTimeRanges" OR eventMessage CONTAINS "setTargetContentItemID" OR eventMessage CONTAINS "Asset Log Mapping" OR eventMessage CONTAINS "fmtDescChangeNote" OR eventMessage CONTAINS "mediaFormatinfo")"#]
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
        next = nil; titles = [:]; lengths = [:]
        labelTitles = [:]; labels = [:]; aacSeen = [:]
    }

    /// Lines from now on (for `seconds`) are about the track that already plays.
    func quiet(for seconds: Double) { quietUntil = max(quietUntil, Date().addingTimeInterval(seconds)) }

    /// The Music app paused: the lines of the last `seconds` were its queue set up again for the track that plays (it
    /// writes one just before it says it paused) — never the next track's.
    func forget(recent seconds: Double) {
        let since = Date().addingTimeInterval(-seconds)
        entries.removeAll { $0.at > since }
        // The pause's line, taken for the next track's rate: undone (it is the track that plays).
        if var n = next, let at = n.rateAt, at > since {
            n.rate = nil; n.rateAt = nil; next = n
            Log.note("next: \(n.title ?? n.item) — the line after it was the pause's, not its rate")
        }
    }

    /// 0.3.5: the Music app named this track as the next one — its rate as named then (nil: the same as before).
    func named(_ title: String) -> Next? {
        guard let n = next, n.title == title else { return nil }
        return n
    }

    /// 0.3.5: a lossless line at `at` is the next track's (loaded ahead) when the next track was named before it, isn't
    /// the one that plays, and the line isn't in the first seconds of the current track (its own).
    func isNextTracks(at: Date, playing title: String?) -> Bool {
        guard let n = next, at > n.at, let t = n.title, at.timeIntervalSince(target?.at ?? .distantPast) > Self.ownLines,
              n.rate != nil else { return false }
        return t != title
    }

    /// The first seconds of a track (after a skip or a start the Music app sets up its own lossless queue then).
    static let ownLines: TimeInterval = 5

    /// 0.3.5: how the Music app went to this track, if its log said so in the last few seconds — true: it followed
    /// naturally; false: a jump. Nil: the log didn't say (the estimate of time left decides).
    func transition(to title: String) -> Bool? {
        // The item's title may be unknown (the Music app set up its items before Arco listened, 17:49:51): then the moment
        // alone — a change within three seconds of the log's word is that change.
        guard let t = target, Date().timeIntervalSince(t.at) < 3 else { return nil }
        if let known = titles[t.item], known != title { return nil }
        return t.natural
    }

    /// 0.3.5: a track's length as the Music app loaded it.
    func length(of title: String) -> Int? {
        guard let item = titles.first(where: { $0.value == title })?.key else { return nil }
        return lengths[item]
    }

    /// The answer for "no line: the same format" — the bridge allows a late correction only briefly then.
    static let sameHow = "no new format in the Music app's log — the same as before"

    /// How long a skip or a start waits for its lossless line.
    static let wait: TimeInterval = 3

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String else { continue }
            if nextLine(message) { continue }
            if labelLine(message) { continue }
            guard let r = message.range(of: #"sampleRate:(\d+)"#, options: .regularExpression),
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
            // A line after the next track was named, of another rate than its last: that track's rate (0.3.5) — not in the
            // first seconds after a change of track (17:47:17, Helsinki after a skip: its own lossless line came 3 s after
            // the next one was named).
            if var n = next, now > n.at, n.rate != rate, now.timeIntervalSince(target?.at ?? .distantPast) > Self.ownLines,
               rate != deviceRate?() {
                n.rate = rate; n.rateAt = now; next = n
                Log.note("next: \(n.title ?? n.item) — \(rate) Hz (\(format), the line after it was named)")
                onNext?(n)
            }
            onLossless?(now, rate)
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
            Log.note("format log: the Music app set up \(format) at \(rate) Hz")
        }
    }

    /// The label lines (0.4.0, see Label). True when the message was one of them.
    private func labelLine(_ m: String) -> Bool {
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let x = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)) else { return nil }
            return (1..<x.numberOfRanges).compactMap { Range(x.range(at: $0), in: m).map { String(m[$0]) } }
        }
        if m.contains("Asset Log Mapping") {
            if let g = groups(#"\([\d+]+::\d+\) (.*) -> <AVPlayerItem: 0x[0-9a-f]+> (I/[A-Za-z0-9]+)"#), g.count == 2 {
                labelTitles[g[1]] = g[0]
                if labelTitles.count > 400 { labelTitles.removeAll(); labels.removeAll(); aacSeen.removeAll() }
            }
            return true
        }
        if m.contains("fmtDescChangeNote") {
            guard let g = groups(#"\|(I/[A-Za-z0-9]+)\.\d+>: audio track (\d+) priming duration \{(-?\d+)/(\d+)="#), g.count == 4,
                  let title = labelTitles[g[0]], let track = Int(g[1]), let priming = Int(g[2]), let rate = Int(g[3]), rate >= 8_000 else { return true }
            if priming != 0 {
                if labels[title] == nil, aacSeen[g[0]] != track {
                    aacSeen[g[0]] = track
                    Log.note("label: \(title) — track \(track) is AAC at \(rate) Hz (doesn't count)")
                }
                return true
            }
            let old = labels[title]
            guard old?.rate != rate || old?.label != g[0] else { return true }
            let l = Label(label: g[0], title: title, rate: rate, track: track, bits: nil, at: Date())
            labels[title] = l
            Log.note("label: \(title) — \(rate) Hz, lossless (\(g[0]), track \(track))\(old.map { ", was \($0.rate)" } ?? "")")
            onLabel?(l)
            return true
        }
        if m.contains("mediaFormatinfo") {
            guard let b = groups(#"sdBitDepth = (\d+) bit"#)?.first.flatMap({ Int($0) }),
                  let khz = groups(#"asbdSampleRate = ([\d.]+) kHz"#)?.first.flatMap({ Double($0) }) else { return true }
            let rate = Int((khz * 1000).rounded())
            guard var l = labels.values.filter({ $0.rate == rate && Date().timeIntervalSince($0.at) < 3 }).max(by: { $0.at < $1.at }),
                  l.bits != b else { return true }
            l.bits = b
            labels[l.title] = l
            Log.note("label: \(l.title) — \(b)-bit")
            onLabel?(l)
            return true
        }
        return false
    }

    /// The lines about the next track (0.3.5). True when the message was one of them.
    private func nextLine(_ m: String) -> Bool {
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let x = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)) else { return nil }
            return (1..<x.numberOfRanges).compactMap { Range(x.range(at: $0), in: m).map { String(m[$0]) } }
        }
        // An item id; a Play Next one carries a plus (177604+177691::177693).
        let id = #"[\d+]+::\d+"#
        if m.contains("ITMPAVItemCount INIT") {
            if let g = groups(#"\((\#(id))\) (.*)'\s*$"#), g.count == 2, g[1] != "(null)" {
                titles[g[0]] = g[1]
                if titles.count > 400 { titles.removeAll() }
            }
            return true
        }
        if m.contains("loadedTimeRanges") {
            if let g = groups(#"\((\#(id))\) .*? loadedTimeRanges [\d.]+ of ([\d.]+)"#), g.count == 2, let s = Double(g[1]), s > 0 {
                let ms = Int(s * 1000)
                if lengths[g[0]] == nil {
                    lengths[g[0]] = ms
                    if var n = next, n.item == g[0], n.lengthMs == nil {
                        n.lengthMs = ms; next = n
                        Log.note("next: \(n.title ?? n.item) — \(ms / 1000) s long")
                        onNext?(n)
                    }
                }
            }
            return true
        }
        if m.contains("setTargetContentItemID") {
            if let g = groups(#"setTargetContentItemID:(?:PLACEHOLDER=)?(\#(id)) source:(\w+)"#), g.count == 2 {
                target = (g[0], g[1] == "NaturalTransition", Date())
            }
            return true
        }
        if m.contains("isInContiguousAlbum") {
            guard let g = groups(#"Next song: contentIdentifier=(\#(id)).*?storeAdamID=(\d+)"#), g.count == 2 else { return true }
            if next?.item == g[0] { return true }
            let n = Next(item: g[0], title: titles[g[0]], album: g[1], lengthMs: lengths[g[0]], rate: nil, at: Date())
            next = n
            Log.note("next: the Music app names \(n.title ?? n.item) (album \(n.album))\(n.lengthMs.map { ", \($0 / 1000) s" } ?? "")")
            onNext?(n)
            return true
        }
        return false
    }

    enum Change { case start, natural, skip }

    /// The rate for a change of track at `change` (see the top of this file). `current`: the device's rate now, for "the
    /// same format". Nil: the log can't say (AppleScript then).
    func rate(_ kind: Change, change: Date, previous: Date?, current: Int) async -> (rate: Int, how: String)? {
        guard !unavailable, process != nil else { return nil }
        let same = (current, Self.sameHow)
        switch kind {
        case .start:
            if let e = entries.last { return (e.rate, "the Music app's log, \(e.format)") }
            let until = change.addingTimeInterval(Self.wait)
            while Date() < until, entries.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            return entries.last.map { ($0.rate, "the Music app's log, \($0.format)") }
        case .natural:
            // Not the lines of the previous track's own first seconds (9 Oct, The Theory of Everything: the start's own
            // line was taken as the next track's, loaded ahead — right by chance, both at 96).
            let since = (previous ?? .distantPast).addingTimeInterval(Self.wait)
            if let e = entries.last(where: { $0.at <= change && $0.at > since }) {
                return (e.rate, "the Music app's log, \(e.format) loaded ahead")
            }
            return seenAny ? same : nil
        case .skip:
            let until = change.addingTimeInterval(Self.wait)
            while Date() < until {
                // From 1 s before: the line can come before Arco sees the skip (9 Oct, End Of Summer: 0.4 s before — with
                // 0.3 s it was missed, Arco waited 3 s and took AppleScript). A pause's line is forgotten (forget(recent:)).
                if let e = entries.first(where: { $0.at > change.addingTimeInterval(-1) }) {
                    return (e.rate, "the Music app's log, \(e.format)")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil   // not "the same": a skipped-to track can start in AAC and get its lossless queue only later
        }
    }
}
