// A slice per track, through Roon's own queue (7 Oct 2026). Roon plays two tracks gapless when the second one waits in
// its queue slot early: about eleven seconds before the end it opens it ("[zoneplayer] Open result (Queueing)") and on
// the end it goes on by itself (OnToNext) — Basso's Polythene Pam → Bathroom Window that morning, at 24/96 without a
// seam. Queued later (Arco 6 Oct, five seconds before the end) Roon starts it anew: a seam. The mix of runs that replaced
// the slices per track (6 Oct) answered the wrong question — it was the timing.
//
// Arco doesn't know Music's next track until Music begins it, and by then Roon — six seconds behind — is past the moment
// it opens the queue. So the next slice goes into Roon's queue as soon as Roon begins a track, before anyone knows what
// it holds: a placeholder. When Roon opens it, the answer waits until Music has begun the next track: then its length
// (Music's duration × the rate) and its rate are known, the WAV header goes out, and Roon still has seconds to fill.
//
// The music is one stream, cut at the declared lengths: what comes after one slice's last frame is the start of the next
// — nothing lost, nothing twice (Basso's TrackStroom). A change of rate between two tracks fills the rest of the slice
// with silence (Music pauses there itself to change the clock). Readers of the slice being written don't get its last
// 0.4 s yet: room to take out the tail of a pause before anyone has read it.
//
// Every request — the first, a second one, a Range request after a pause — gets exactly the bytes it asks for, as far
// as they exist, and the rest as they arrive. A new request from the same address replaces the older readers of that
// slice (a reconnecting renderer must not pile them up), at most eight.
import Foundation
import Network

final class SliceStore: @unchecked Sendable {
    struct Track {
        let info: [String: Any]       // Roon's track information (title, artist, album, cover)
        let durationMs: Int
    }

    final class Slice {
        let number: Int
        let path: String
        let file: URL
        /// nil: the next track, not announced yet (a placeholder in Roon's queue).
        var track: Track?
        /// Set by its first frame.
        var rate: Double?
        var writer: FileHandle?
        var reader: FileHandle?
        var written = 0
        var readers: [Reader] = []
        /// Requests that came before the header was known (Roon opening its queue): answered when it is.
        var waiting: [(connection: NWConnection, from: Int, headOnly: Bool)] = []
        /// Nothing more is written: complete, or dropped.
        var closed = false
        var dropped = false
        /// Roon has its header (and with it the rate and the length): from now on the rate can't change in place.
        var headerSent = false
        init(number: Int, path: String, track: Track?, directory: URL) {
            self.number = number; self.path = path; self.track = track
            file = directory.appendingPathComponent("slice-\(number).pcm")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            writer = try? FileHandle(forWritingTo: file)
            reader = try? FileHandle(forReadingFrom: file)
        }
        /// Its length in frames, once both the track and the rate are known.
        var frames: Int? {
            guard let track, let rate else { return nil }
            return max(1, Int((Double(track.durationMs) / 1000 * rate).rounded()))
        }
        var isFull: Bool { frames.map { written >= $0 } ?? false }
        /// A second at one rate (or complete): the Music app switches the device to a track's own rate 0.2–5.5 s after
        /// a start — the header waits until the rate holds.
        var settled: Bool { closed || rate.map { Double(written) >= $0 * SliceStore.settleSeconds } ?? false }
        func ms(_ frame: Int) -> Int { Int(Double(frame) / (rate ?? 44_100) * 1000) }
    }

    final class Reader {
        let connection: NWConnection
        var offset: Int
        var busy = false
        init(connection: NWConnection, offset: Int) { self.connection = connection; self.offset = offset }
    }

    enum Gate { case writing, waitForSilence, waitForSound }

    /// What a new track from the source means.
    enum Change {
        /// The natural next one: it is the content of this slice (perhaps already in Roon's queue).
        case next(Slice)
        /// A skip: a new slice, into Roon's play slot as soon as its first sound is in.
        case skip
    }

    static let bytesPerFrame = 6
    static let settleSeconds = 1.0
    /// Unique per session: Roon caches by URL, and slice 1 of a new session must never be served from slice 1 of the
    /// last one (20:56:53: Roon showed "24/48, 1:14" — the old slice — for a new one at 44.1 of 528 s).
    private let session = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    private let directory: URL
    private let lock = NSLock()
    private var slices: [Int: Slice] = [:]
    /// The slice the music goes into now.
    private var writing: Slice?
    private var counter = 0
    private var gate: Gate = .waitForSound
    /// Called (on the main queue) when a slice that must go to Roon at once (the start, a skip, a cut at a change of rate
    /// inside a track) has its first sound.
    var onSliceStarted: ((Slice) -> Void)?
    private var announceFirstSound: Slice?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - From the bridge (main)

    /// The first track, or a skip: everything before goes, and a new slice begins with the next sound.
    func start(_ t: Track) {
        lock.lock(); defer { lock.unlock() }
        for s in slices.values { drop(s) }
        let s = newSlice(track: t)
        writing = s
        announceFirstSound = s
        gate = .waitForSound
    }

    /// A new track from the source: the natural next one (within eight seconds of the end of the slice being written, or
    /// while the music already goes into a placeholder), or a skip.
    func trackChanged(_ t: Track) -> Change {
        lock.lock(); defer { lock.unlock() }
        guard let w = writing else { return .skip }
        let target: Slice
        if w.track == nil {
            target = w
        } else if let left = remainingLocked(w), left < 8 {
            target = slice(after: w)
            // A placeholder already announced (a very short track before it): treat it as a skip.
            if target.track != nil { return .skip }
        } else {
            return .skip
        }
        target.track = t
        declared(target)
        return .next(target)
    }

    /// Seconds left in the slice being written (for the log, and the natural-or-skip question).
    var remainingInTrack: Double? {
        lock.lock(); defer { lock.unlock() }
        return writing.flatMap { remainingLocked($0) }
    }

    private func remainingLocked(_ s: Slice) -> Double? {
        guard let f = s.frames, let r = s.rate else { return nil }
        return Double(f - s.written) / r
    }

    /// The slice after `number` — the placeholder for Roon's queue, made now if it doesn't exist yet. Nil when `number`
    /// is gone (a skip in the meantime).
    func slice(after number: Int) -> Slice? {
        lock.lock(); defer { lock.unlock() }
        guard let s = slices[number], !s.dropped else { return nil }
        return slice(after: s)
    }

    private func slice(after s: Slice) -> Slice {
        slices[s.number + 1] ?? newSlice(track: nil)
    }

    func slice(_ number: Int) -> Slice? {
        lock.lock(); defer { lock.unlock() }
        return slices[number].flatMap { $0.dropped ? nil : $0 }
    }

    /// Whether a slice's header can go out (its track and a settled rate).
    func isKnown(_ number: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return slices[number].map { $0.frames != nil && $0.settled } ?? false
    }

    /// The source stopped (the end of an album, a playlist): nothing comes after what was written. Placeholders go — a
    /// request waiting in one gets a closed connection, and Roon ends after the last track.
    func endOfMusic() {
        lock.lock(); defer { lock.unlock() }
        for s in slices.values where s.track == nil { drop(s) }
    }

    /// The Music app paused. Its notification comes about 0.2 s after its last note, so the tail of the slice already
    /// holds Music's fade (~70 ms) and silence (21:41:36: 0.27 s together — the hiccup Roon played a few seconds after
    /// resuming). When the tail already ends in silence, trim it now and wait for sound; otherwise write on to real
    /// silence first.
    func pauseWriting() {
        lock.lock(); defer { lock.unlock() }
        guard gate == .writing else { return }
        if let w = writing, !w.closed, w.written > 0, isSilent(w, frame: w.written - 1) {
            trimTail(w)
            gate = .waitForSound
        } else {
            gate = .waitForSilence
        }
    }

    /// Released from the held-back part after a pause (see `release`); back to nothing when the music goes on.
    private var released = 0

    /// After Roon was told to pause: a little of the held-back music, to wake Roon's reader. With Music stopped no data
    /// comes, and a reader asleep at the edge of the stream ("[prebuffer] sleeping in read — this isn't good") kept Roon
    /// from passing the pause on to the KEF until it let the KEF go five seconds later (21:46:19); after that the restart
    /// took seconds too. It is music from before the pause point, which Roon plays after resuming anyway.
    func release(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let w = writing, !w.closed, let rate = w.rate else { return }
        released += Int(seconds * rate)
        for r in w.readers { pump(w, r) }
    }

    /// The last 0.4 s of the slice being written are held back from Roon: room to take out the tail of a pause before
    /// anyone has read it. (Roon plays seconds behind anyway.)
    private static let holdBackSeconds = 0.4
    private static let fadeSeconds = 0.08

    /// Under the lock: the slice's tail of silence, and Music's fade before it, taken out — as far as it is still held
    /// back.
    private func trimTail(_ s: Slice) {
        guard let rate = s.rate else { return }
        let held = Int(Self.holdBackSeconds * rate)
        let floor = max(0, s.written - held, s.readers.map { $0.offset / Self.bytesPerFrame }.max() ?? 0)
        var end = s.written
        while end > floor, isSilent(s, frame: end - 1) { end -= 1 }
        let silence = s.written - end
        end = max(floor, end - Int(Self.fadeSeconds * rate))
        guard end < s.written else { return }
        let removed = s.written - end
        try? s.writer?.truncate(atOffset: UInt64(end * Self.bytesPerFrame))
        try? s.writer?.seekToEnd()
        s.written = end
        Log.note("slices: \(s.number) — pause: \(Int(Double(removed) / rate * 1000)) ms of fade and silence taken out (\(Int(Double(silence) / rate * 1000)) ms silence)")
    }

    /// Under the lock: whether a frame of the slice is digital silence.
    private func isSilent(_ s: Slice, frame: Int) -> Bool {
        guard let r = s.reader else { return false }
        try? r.seek(toOffset: UInt64(frame * Self.bytesPerFrame))
        guard let d = try? r.read(upToCount: Self.bytesPerFrame), d.count == Self.bytesPerFrame else { return false }
        return d.allSatisfy { $0 == 0 }
    }

    /// Where the music goes now (for the log, and whether anything is written at all).
    var status: (number: Int, writtenMs: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let w = writing, w.rate != nil else { return nil }
        return (w.number, w.ms(w.written))
    }

    /// Whether a slice is still there (not dropped by a skip).
    func isLive(_ number: Int) -> Bool { slice(number) != nil }

    /// Roon plays `number`: older slices can go.
    func forget(before number: Int) {
        lock.lock(); defer { lock.unlock() }
        for (n, s) in slices where n < number && s !== writing { remove(s) }
    }

    func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for s in slices.values { drop(s) }
        writing = nil; announceFirstSound = nil; gate = .waitForSound
    }

    // MARK: - From the capture queue

    func write(_ pcm: Data, frames: Int, firstSound: Int?, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        var data = pcm, count = frames
        switch gate {
        case .writing:
            break
        case .waitForSilence:
            if firstSound == nil {
                gate = .waitForSound
                if let w = writing, !w.closed { trimTail(w) }
                Log.note("slices: silence — waiting for sound")
                return
            }
        case .waitForSound:
            guard let first = firstSound, writing != nil else { return }
            gate = .writing
            released = 0
            Log.note("slices: sound — writing")
            data = pcm.subdata(in: (first * Self.bytesPerFrame)..<pcm.count)
            count = frames - first
        }
        while count > 0, let w = writing {
            if w.rate == nil {
                w.rate = rate
                declared(w)
                if w === announceFirstSound {
                    announceFirstSound = nil
                    let callback = onSliceStarted
                    DispatchQueue.main.async { callback?(w) }
                }
                continue
            }
            if w.rate != rate {
                rateChanged(w, to: rate)
                continue
            }
            if w.isFull {
                complete(w)
                writing = slice(after: w)
                continue
            }
            let n = w.frames.map { min(count, $0 - w.written) } ?? count
            append(data.prefix(n * Self.bytesPerFrame), frames: n, to: w)
            data = data.dropFirst(n * Self.bytesPerFrame); count -= n
        }
    }

    /// Under the lock: the music changed rate while going into `w`.
    private func rateChanged(_ w: Slice, to rate: Double) {
        let old = w.rate ?? rate
        let nearEnd = w.track != nil && (remainingLocked(w) ?? 99) < 8
        if nearEnd {
            // Between two tracks (Music pauses there to change the clock): the slice is filled with silence to its
            // declared length — Roon expects those bytes — and the next one begins at the new rate.
            let rest = (w.frames ?? w.written) - w.written
            if rest > 0 { append(Data(count: rest * Self.bytesPerFrame), frames: rest, to: w) }
            Log.note("slices: \(w.number) complete with \(Int(Double(rest) / old * 1000)) ms silence — rate \(Int(old)) → \(Int(rate))")
            complete(w)
            writing = slice(after: w)
        } else if !w.headerSent {
            // The start of a track at the device's old rate (Music switches 0.2–5.5 s after a start): Roon hasn't seen
            // this slice's header yet, so what was written is converted to the new rate and the slice goes on — the start
            // of the track stays.
            var converted = Data()
            if w.written > 0, let r = w.reader {
                try? r.seek(toOffset: 0)
                converted = Resample.pcm24((try? r.readToEnd()) ?? Data(), from: old, to: rate)
            }
            try? w.writer?.truncate(atOffset: 0); try? w.writer?.seekToEnd()
            w.written = 0; w.rate = rate
            if !converted.isEmpty { try? w.writer?.write(contentsOf: converted); w.written = converted.count / Self.bytesPerFrame }
            Log.note("slices: \(w.number) — rate \(Int(old)) → \(Int(rate)) before Roon had it: \(w.ms(w.written)) ms converted, it goes on")
        } else {
            // Inside a track whose header Roon already has: the rest of the track becomes a new slice, into Roon's play
            // slot at once. Only this slice and what follows go — not the one Roon may still be playing.
            let left = Int((remainingLocked(w) ?? 1) * 1000)
            Log.note("slices: \(w.number) cut — rate \(Int(old)) → \(Int(rate)) inside the track; \(left) ms go on in a new slice")
            let t = w.track.map { Track(info: $0.info, durationMs: max(1000, left)) }
            for x in slices.values where x.number >= w.number { drop(x) }
            let n = newSlice(track: t)
            writing = n
            announceFirstSound = n
        }
    }

    /// Under the lock: a slice whose header is now known answers the requests that waited for it. A slice that got more
    /// music than its length (its track was announced late) passes the rest on to the next one.
    private func declared(_ s: Slice) {
        guard let frames = s.frames, let rate = s.rate else { return }
        if s.written > frames {
            let next = slice(after: s)
            if let r = s.reader {
                try? r.seek(toOffset: UInt64(frames * Self.bytesPerFrame))
                if let rest = try? r.readToEnd(), !rest.isEmpty {
                    next.rate = rate
                    append(rest, frames: rest.count / Self.bytesPerFrame, to: next)
                }
            }
            try? s.writer?.truncate(atOffset: UInt64(frames * Self.bytesPerFrame)); try? s.writer?.seekToEnd()
            s.written = frames
            if writing === s { writing = next }
            Log.note("slices: \(s.number) was announced late — what came after its length went on in \(next.number)")
            complete(s)
        }
        answerWaiting(s)
    }

    /// Under the lock: requests that waited for the header get it, once the track is known and the rate holds.
    private func answerWaiting(_ s: Slice) {
        guard !s.waiting.isEmpty, let frames = s.frames, let rate = s.rate, s.settled else { return }
        let waiting = s.waiting
        s.waiting = []
        Log.note("slices: \(s.number) known (\(Int(rate)) Hz, \(s.ms(frames)) ms) — answering Roon")
        for w in waiting { respond(s, w.connection, from: w.from, headOnly: w.headOnly) }
    }

    /// Under the lock: no more music for this slice; its readers get all of it.
    private func complete(_ s: Slice) {
        s.closed = true
        answerWaiting(s)
        for r in s.readers { pump(s, r) }
    }

    private func newSlice(track: Track?) -> Slice {
        counter += 1
        let s = Slice(number: counter, path: "/stream/\(session)-\(counter).wav", track: track, directory: directory)
        slices[s.number] = s
        return s
    }

    /// Under the lock: a slice cut off (a skip, the end) is gone at once — its readers closed, the next request a 404.
    /// Left open, its readers waited for bytes that never came, and Roon's downloader for it held the zone's bandwidth:
    /// the next one never started (6 Oct 2026, 21:02:33).
    private func drop(_ s: Slice) {
        s.dropped = true
        for w in s.waiting { w.connection.cancel() }
        s.waiting = []
        remove(s)
        if writing === s { writing = nil }
    }

    private func remove(_ s: Slice) {
        s.closed = true
        for r in s.readers { r.connection.cancel() }
        s.readers = []
        try? s.writer?.close(); try? s.reader?.close()
        try? FileManager.default.removeItem(at: s.file)
        slices[s.number] = nil
    }

    private func append(_ d: Data, frames n: Int, to s: Slice) {
        try? s.writer?.write(contentsOf: d)
        s.written += n
        answerWaiting(s)
        for r in s.readers { pump(s, r) }
    }

    // MARK: - Serving

    /// A GET (or HEAD) for a slice. False when there is no such slice (the server answers 404).
    func serve(path: String, _ connection: NWConnection, range: String?, headOnly: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = slices.values.first(where: { $0.path == path }) else { return false }
        var from = 0
        if let range, let match = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression) {
            from = Int(range[match].filter(\.isNumber)) ?? 0
        }
        if s.frames == nil || !s.settled {
            // Roon opening its queue before Music began the next track (or before its rate holds): the answer waits.
            s.waiting.append((connection, from, headOnly))
            Log.note("slices: \(s.number) asked for before it is known — the answer waits")
            return true
        }
        respond(s, connection, from: from, headOnly: headOnly)
        return true
    }

    /// Under the lock: the header and the bytes from `from` on, as far as they exist, the rest as they arrive.
    private func respond(_ s: Slice, _ connection: NWConnection, from requested: Int, headOnly: Bool) {
        guard let frames = s.frames, let rate = s.rate else { return }
        let total = 44 + frames * Self.bytesPerFrame
        let from = min(total, requested)
        var http = from > 0
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(total - 1)/\(total)\r\nContent-Length: \(total - from)\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\n"
        http += "Content-Type: audio/wav\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var head = Data(http.utf8)
        if headOnly { connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() }); return }
        if from < 44 { head.append(Self.wavHeader(rate: rate, frames: frames).dropFirst(from)) }
        s.headerSent = true
        let r = Reader(connection: connection, offset: max(0, from - 44))
        let host = Self.host(connection)
        for old in s.readers where host != nil && Self.host(old.connection) == host { old.connection.cancel() }
        s.readers.removeAll { host != nil && Self.host($0.connection) == host }
        s.readers.append(r)
        while s.readers.count > 8 { s.readers.removeFirst().connection.cancel() }
        r.busy = true
        connection.stateUpdateHandler = { [weak self, weak s, weak r] state in
            guard let self, let s, let r else { return }
            switch state {
            case .failed, .cancelled: self.lock.lock(); s.readers.removeAll { $0 === r }; self.lock.unlock()
            default: break
            }
        }
        connection.send(content: head, completion: .contentProcessed { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            r.busy = false
            self.pump(s, r)
        })
    }

    /// Under the lock: one chunk (at most 256 KB) of the slice to the reader; at its end, close.
    private func pump(_ s: Slice, _ r: Reader) {
        guard !r.busy, let frames = s.frames, let rate = s.rate else { return }
        if r.offset >= frames * Self.bytesPerFrame { r.connection.cancel(); return }
        // Held back: the last 0.4 s of the slice being written (see trimTail); a complete slice gives all it has.
        let held = s.closed ? 0 : max(0, Int(Self.holdBackSeconds * rate) - released)
        let available = max(0, s.written - held) * Self.bytesPerFrame
        guard r.offset < available, let reader = s.reader else { return }
        let count = min(262_144, available - r.offset)
        try? reader.seek(toOffset: UInt64(r.offset))
        guard let data = try? reader.read(upToCount: count), !data.isEmpty else { return }
        r.busy = true
        r.offset += data.count
        r.connection.send(content: data, completion: .contentProcessed { [weak self, weak s] error in
            guard let self, let s else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            r.busy = false
            if error == nil { self.pump(s, r) }
        })
    }

    private static func host(_ connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return nil
    }

    static func wavHeader(rate: Double, frames: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataBytes = UInt32(min(frames * bytesPerFrame, Int(UInt32.max) - 36))
        var d = Data("RIFF".utf8); d.append(le32(36 + dataBytes)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(2))
        d.append(le32(UInt32(rate))); d.append(le32(UInt32(rate) * UInt32(bytesPerFrame))); d.append(le16(UInt16(bytesPerFrame))); d.append(le16(24))
        d.append(Data("data".utf8)); d.append(le32(dataBytes))
        return d
    }
}
