// The mix (6 Oct 2026, René: "bouw de mengvorm maar"): tracks at the same rate run on in one stream — gapless, as
// Abbey Road's second side needs — and a new stream only begins where it must: at the start, at a skip, and where the
// Music app changes the rate (it pauses there itself anyway). Roon's audio input can't do both gapless and a length per
// track: every new play is a new start of Roon's stream to the endpoint (a seam of about half a second, measured from
// Polythene Pam to Bathroom Window), and a track's length comes only from the WAV. So a run shows its own time in Roon,
// and each track's title, artist, album and cover arrive when Roon reaches that track (update_track_info).
//
// A run is a WAV (24-bit stereo, declared at three hours at its rate) growing on disk while the music plays.
// - A natural next track (the current one within two seconds of its end) simply goes on in the run; the bridge marks
//   where, and updates Roon's track information when Roon gets there.
// - A skip (or the first track): the current run is dropped at once and a new one begins with the next sound.
// - A change of rate: the run is frozen where the rate changed — not dropped: Roon plays a few seconds behind and must
//   still hear the end of what was written — and a new run begins with the first sound at the new rate. The bridge puts
//   it in Roon's play slot just as Roon reaches the point of the change.
// - Three hours at one rate: the same as a change of rate, with the current track going on in the next run.
// - A new run begins with its first sound, by which time the device's rate is settled.
// - The gate keeps the distance to Roon constant: at a pause of the Music app nothing is written until the first real
//   sound — no silence of a pause in the music, nothing lost or repeated.
//
// Every request — the first, a second one, a Range request after a pause — gets exactly the bytes it asks for, as far
// as they exist, and the rest as they arrive. A new request from the same address replaces the older readers of that
// run (a reconnecting renderer must not pile them up), at most eight.
import Foundation
import Network

final class SliceStore: @unchecked Sendable {
    struct Track {
        let info: [String: Any]       // Roon's track information (title, artist, album, cover)
        let durationMs: Int
    }

    /// A run: one stream of consecutive tracks at one rate.
    final class Slice {
        let number: Int
        let path: String
        /// Set by its first sound; converted in place if the Music app switches the rate before Roon has the header.
        var rate: Double
        var frames: Int
        /// Roon has the header (rate, length): from now on a change of rate means a new run.
        var headerSent = false
        /// Where the current rate began (a frame of this run): the run goes to Roon once the rate has held a while.
        var rateSince = 0
        /// The track it begins with.
        let info: [String: Any]
        /// Set when this run follows another one at a change of rate: that run's number and where it was frozen (ms).
        /// The bridge plays this run when Roon gets there; without it, at once.
        let follows: (number: Int, atMs: Int)?
        let file: URL
        var writer: FileHandle?
        var reader: FileHandle?
        var written = 0
        var readers: [Reader] = []
        var closed = false            // no more writing (frozen at a change of rate, or dropped)
        init(number: Int, path: String, rate: Double, frames: Int, info: [String: Any], follows: (Int, Int)?, directory: URL) {
            self.number = number; self.path = path; self.rate = rate; self.frames = max(1, frames)
            self.info = info; self.follows = follows
            file = directory.appendingPathComponent("run-\(number).pcm")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            writer = try? FileHandle(forWritingTo: file)
            reader = try? FileHandle(forReadingFrom: file)
        }
        var isFull: Bool { written >= frames }
        /// The rate has held `seconds` (the Music app switches the device to a track's own rate 0.2–5.5 s after a start;
        /// 7 Oct 21:53: four seconds).
        func settled(_ seconds: Double) -> Bool { Double(written - rateSince) >= seconds * rate }
        var bytes: Int { frames * SliceStore.bytesPerFrame }
        func ms(_ frame: Int) -> Int { Int(Double(frame) / rate * 1000) }
    }

    final class Reader {
        let connection: NWConnection
        var offset: Int
        var busy = false
        init(connection: NWConnection, offset: Int) { self.connection = connection; self.offset = offset }
    }

    enum Gate { case writing, waitForSilence, waitForSound }

    static let bytesPerFrame = 6
    private static let runHours = 3.0
    /// Unique per session: Roon caches by URL, and run 1 of a new session must never be served from run 1 of the last
    /// one (20:56:53: Roon showed "24/48, 1:14" — the old slice — for a new one at 44.1 of 528 s).
    private let session = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    private let directory: URL
    private let lock = NSLock()
    private var slices: [Int: Slice] = [:]
    private var current: Slice?
    /// The track playing now, and the frame of the current run where it began.
    private var track: Track?
    private var trackStart = 0
    /// A new run, beginning with the next sound: its first track, and what it follows (at a change of rate).
    private var pendingRun: (track: Track, follows: (Int, Int)?)?
    private var overflow = Data()
    private var overflowRate: Double = 0
    private var gate: Gate = .waitForSound
    private var counter = 0
    /// Called (on the main queue) when a run begins: the bridge plays it in Roon — at once, or when Roon reaches the point
    /// where the run before it was frozen.
    var onSliceStarted: ((Slice) -> Void)?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - From the bridge (main)

    /// How many frames a run can hold at `rate`: three hours, or as long as a WAV can be (its length is a 32-bit field —
    /// about an hour at 192 kHz).
    static func capacity(_ rate: Double) -> Int {
        min(Int(runHours * 3600 * rate), (Int(UInt32.max) - 36) / bytesPerFrame)
    }

    /// Whether the run's rate has held `seconds` (see Slice.settled).
    func isSettled(_ s: Slice, seconds: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return s.settled(seconds) }

    /// A new track. `newRun`: a skip or the first track — a new run with the next sound. Otherwise it goes on in the
    /// current run, and the answer is where (run number, ms) — for the bridge to update Roon's track information there.
    @discardableResult
    func startTrack(_ t: Track, newRun: Bool) -> (number: Int, ms: Int)? {
        lock.lock(); defer { lock.unlock() }
        track = t
        if !newRun, let c = current, !c.closed {
            // Room for this track in the run? If not (an hour at 192 kHz), the next run begins here, between two tracks —
            // the way a change of rate does — instead of in the middle of a track when the run is full.
            let needed = Int(Double(t.durationMs) / 1000 * c.rate) + Int(5 * c.rate)
            if c.frames - c.written >= needed {
                trackStart = c.written
                return (c.number, c.ms(c.written))
            }
            c.closed = true
            current = nil
            pendingRun = (t, (c.number, c.ms(c.written)))
            Log.note("runs: \(c.number) frozen at \(c.ms(c.written)) ms — the next track doesn't fit in it")
            return nil
        }
        if newRun, let c = current { drop(c); current = nil; overflow = Data() }
        // A skip begins a run of its own, at once. Otherwise a run is about to begin (right after a change of rate): it
        // begins with this track, still following the frozen one.
        pendingRun = (t, newRun ? nil : pendingRun?.follows)
        if current == nil, !overflow.isEmpty { begin(rate: overflowRate) }
        return nil
    }

    /// The current track's real length came late (the Music app's notification of a streamed track can come without it):
    /// what is left of it, from the source's own duration and position.
    func setRemaining(ms: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let c = current, let t = track else { return }
        let done = Int(Double(c.written - trackStart) / c.rate * 1000)
        track = Track(info: t.info, durationMs: done + max(0, ms))
    }

    /// How much of the current track is left in the run, in seconds (a natural end is near when this is small).
    var remainingInTrack: Double? {
        lock.lock(); defer { lock.unlock() }
        return remainingInTrackLocked()
    }

    private func remainingInTrackLocked() -> Double? {
        guard let c = current, let t = track else { return nil }
        let end = trackStart + Int(Double(t.durationMs) / 1000 * c.rate)
        return Double(end - c.written) / c.rate
    }

    /// The Music app paused. Its notification comes about 0.2 s after its last note, so the tail of the run already holds
    /// Music's fade (~70 ms) and silence (21:41:36: 0.27 s together — the hiccup Roon played a few seconds after resuming).
    /// When the tail already ends in silence, trim it now and wait for sound; otherwise write on to real silence first.
    func pauseWriting() {
        lock.lock(); defer { lock.unlock() }
        guard gate == .writing else { return }
        if let c = current, !c.closed, c.written > 0, isSilent(c, frame: c.written - 1) {
            trimTail(c)
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
        guard let c = current, !c.closed else { return }
        released += Int(seconds * c.rate)
        for r in c.readers { pump(c, r) }
    }

    /// The last 0.4 s of a run are held back from Roon: room to take out the tail of a pause before anyone has read it.
    /// (Roon plays seconds behind anyway.)
    private static let holdBackSeconds = 0.4
    private static let fadeSeconds = 0.08
    private static let keepSeconds = 0.12

    /// Under the lock: the run's tail of silence, and Music's fade before it, taken out — as far as it is still held back.
    private func trimTail(_ c: Slice) {
        let held = Int(Self.holdBackSeconds * c.rate)
        let floor = max(0, c.written - held, c.readers.map { $0.offset / Self.bytesPerFrame }.max() ?? 0)
        var end = c.written
        while end > floor, isSilent(c, frame: end - 1) { end -= 1 }
        let silence = c.written - end
        end = max(floor, end - Int(Self.fadeSeconds * c.rate))
        // A little silence stays above what Roon has read: the drip after Roon's pause needs bytes to wake its reader
        // (7 Oct 22:08: the whole held-back part was silence and went — nothing to drip, and the KEF played on until Roon
        // let it go five seconds later). It costs 0.12 s of silence when the music goes on.
        end = max(end, min(c.written, floor + Int(Self.keepSeconds * c.rate)))
        guard end < c.written else { return }
        let removed = c.written - end
        try? c.writer?.truncate(atOffset: UInt64(end * Self.bytesPerFrame))
        try? c.writer?.seekToEnd()
        c.written = end
        Log.note("runs: \(c.number) — pause: \(Int(Double(removed) / c.rate * 1000)) ms of fade and silence taken out (\(Int(Double(silence) / c.rate * 1000)) ms silence)")
    }

    /// Under the lock: whether a frame of the run is digital silence.
    private func isSilent(_ c: Slice, frame: Int) -> Bool {
        guard let r = c.reader else { return false }
        try? r.seek(toOffset: UInt64(frame * Self.bytesPerFrame))
        guard let d = try? r.read(upToCount: Self.bytesPerFrame), d.count == Self.bytesPerFrame else { return false }
        return d.allSatisfy { $0 == 0 }
    }

    /// Where the current run is (for the log).
    var status: (number: Int, writtenMs: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return (c.number, c.ms(c.written))
    }

    /// Whether a run is still the one being written (a superseded one must not go to Roon any more).
    func isCurrent(_ s: Slice) -> Bool { lock.lock(); defer { lock.unlock() }; return current === s }

    /// Roon plays `number`: older runs can go.
    func forget(before number: Int) {
        lock.lock(); defer { lock.unlock() }
        for (n, s) in slices where n < number && s !== current { remove(s) }
    }

    func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for s in slices.values { remove(s) }
        current = nil; pendingRun = nil; track = nil; overflow = Data(); gate = .waitForSound
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
                if let c = current, !c.closed { trimTail(c) }
                Log.note("runs: silence — waiting for sound")
                return
            }
        case .waitForSound:
            guard let first = firstSound else { return }
            gate = .writing
            released = 0
            Log.note("runs: sound — writing")
            data = pcm.subdata(in: (first * Self.bytesPerFrame)..<pcm.count)
            count = frames - first
        }
        while count > 0 {
            if let c = current, !c.closed {
                if c.rate != rate, !c.headerSent {
                    // The start of a track at the device's old rate: Roon hasn't seen this run's header, so what was
                    // written is converted to the new rate and the run goes on — the start of the track stays.
                    let old = c.rate
                    var converted = Data()
                    if c.written > 0, let r = c.reader {
                        try? r.seek(toOffset: 0)
                        converted = Resample.pcm24((try? r.readToEnd()) ?? Data(), from: old, to: rate)
                    }
                    try? c.writer?.truncate(atOffset: 0); try? c.writer?.seekToEnd()
                    if !converted.isEmpty { try? c.writer?.write(contentsOf: converted) }
                    trackStart = Int(Double(trackStart) * rate / old)
                    c.rate = rate
                    c.written = converted.count / Self.bytesPerFrame
                    c.rateSince = c.written
                    c.frames = Self.capacity(rate)
                    Log.note("runs: \(c.number) — rate \(Int(old)) → \(Int(rate)) before Roon had it: \(c.ms(c.written)) ms converted, it goes on")
                    continue
                }
                if c.rate != rate || c.isFull {
                    // A change of rate (or three hours at one rate): freeze the run where it is — Roon still plays its
                    // end — and go on in a new run at the new rate, with the track that plays now.
                    c.closed = true
                    current = nil
                    let left = max(1000, Int((remainingInTrackLocked() ?? 0) * 1000))
                    if let t = track { pendingRun = (Track(info: t.info, durationMs: left), (c.number, c.ms(c.written))) }
                    Log.note("runs: \(c.number) frozen at \(c.ms(c.written)) ms (\(c.rate != rate ? "rate \(Int(c.rate)) → \(Int(rate))" : "three hours"))")
                    continue
                }
                let n = min(count, c.frames - c.written)
                append(data.prefix(n * Self.bytesPerFrame), frames: n, to: c)
                data = data.dropFirst(n * Self.bytesPerFrame); count -= n
                continue
            }
            if pendingRun != nil {
                if overflowRate != rate { overflow = Data() }
                overflowRate = rate
                begin(rate: rate)
                continue
            }
            // No run to write to yet (the first track isn't announced): keep the music, up to half a minute.
            if overflowRate != rate { overflow = Data(); overflowRate = rate }
            overflow.append(data.prefix(count * Self.bytesPerFrame))
            let cap = Int(rate) * 30 * Self.bytesPerFrame
            if overflow.count > cap { overflow = overflow.suffix(cap) }
            count = 0
        }
    }

    /// Under the lock: the pending run begins, starting with what waited in the overflow.
    private func begin(rate: Double) {
        guard let p = pendingRun else { return }
        pendingRun = nil
        counter += 1
        // As long as a WAV can be: its length is a 32-bit field. Three hours fit at 44.1 and 48 kHz; at 96 kHz they would
        // be 6.2 GB — the header overflowed and Arco crashed (21:32:25). So about two hours at 96, one at 192; a full run
        // simply goes on in the next one.
        let s = Slice(number: counter, path: "/stream/\(session)-\(counter).wav", rate: rate,
                      frames: Self.capacity(rate), info: p.track.info, follows: p.follows, directory: directory)
        slices[s.number] = s
        current = s
        track = p.track
        trackStart = 0
        if overflowRate == rate, !overflow.isEmpty {
            let n = min(overflow.count / Self.bytesPerFrame, s.frames)
            append(overflow.prefix(n * Self.bytesPerFrame), frames: n, to: s)
        }
        overflow = Data()
        Log.note("runs: \(s.number) begins at \(Int(rate)) Hz\(p.follows.map { " — follows run \($0.0) at \($0.1) ms" } ?? " (now)")")
        let callback = onSliceStarted
        DispatchQueue.main.async { callback?(s) }
    }

    /// Under the lock: a run cut off at a skip is gone at once — its readers closed, the next request a 404. Left open,
    /// its readers waited for bytes that never came, and Roon's downloader for it held the zone's bandwidth: the next one
    /// never started (6 Oct 2026, 21:02:33).
    private func drop(_ s: Slice) {
        remove(s)
        Log.note("runs: \(s.number) dropped (a skip)")
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
        for r in s.readers { pump(s, r) }
    }

    // MARK: - Serving

    /// A GET (or HEAD) for a slice. False when there is no such slice (the server answers 404).
    func serve(path: String, _ connection: NWConnection, range: String?, headOnly: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = slices.values.first(where: { $0.path == path }) else { return false }
        let total = 44 + s.bytes
        var from = 0
        if let range, let match = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression) {
            from = min(total, Int(range[match].filter(\.isNumber)) ?? 0)
        }
        var http = from > 0
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(total - 1)/\(total)\r\nContent-Length: \(total - from)\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\n"
        http += "Content-Type: audio/wav\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var head = Data(http.utf8)
        if headOnly { connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() }); return true }
        if from < 44 { head.append(Self.wavHeader(rate: s.rate, frames: s.frames).dropFirst(from)) }
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
        return true
    }

    /// Under the lock: one chunk (at most 256 KB) of the slice to the reader; at its end, close.
    private func pump(_ s: Slice, _ r: Reader) {
        guard !r.busy else { return }
        if r.offset >= s.bytes { r.connection.cancel(); return }
        // Held back: the last 0.4 s of an open run (see trimTail); a frozen run gives all it has.
        let held = s.closed ? 0 : max(0, Int(Self.holdBackSeconds * s.rate) - released)
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
        let dataBytes = UInt32(frames * bytesPerFrame)
        var d = Data("RIFF".utf8); d.append(le32(36 + dataBytes)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(2))
        d.append(le32(UInt32(rate))); d.append(le32(UInt32(rate) * UInt32(bytesPerFrame))); d.append(le16(UInt16(bytesPerFrame))); d.append(le16(24))
        d.append(Data("data".utf8)); d.append(le32(dataBytes))
        return d
    }
}
