// A slice per track: each track the Music app plays becomes its own WAV of known length (the track's duration × the
// device's rate, 24-bit stereo), growing on disk while the music plays. Roon gets each slice in its play slot or queue
// slot and shows the track's real length; at a change of rate the next slice simply has the other rate.
//
// The writer follows the music, not the notifications:
// - A slice takes exactly its declared frames. What comes after belongs to the next track: it waits in the overflow
//   until the bridge announces that track (Music's notification), then becomes the start of its slice.
// - A slice is created when the first sound of its track arrives, so it gets the rate the device has by then (the Music
//   app switches the rate during its short pause between tracks of different rates).
// - When sound arrives at another rate while a slice is still open, that slice is filled with silence to its declared
//   length (Roon expects those bytes) and the next one starts at the new rate.
// - The gate keeps the distance to Roon constant: at a pause of the Music app nothing is written until the first real
//   sound — no silence of a pause in the music, nothing lost or repeated.
//
// Every request — the first, a second one, a Range request after a pause — gets exactly the bytes it asks for, as far
// as they exist, and the rest as they arrive. A new request from the same address replaces the older readers of that
// slice (a reconnecting renderer must not pile them up), at most eight.
import Foundation
import Network

final class SliceStore: @unchecked Sendable {
    struct Announcement {
        let info: [String: Any]       // Roon's track information (title, artist, album, cover)
        let durationMs: Int
        /// Play it at once (a skip, the first track, a continuation) or queue it behind the current slice.
        let immediate: Bool
    }

    final class Slice {
        let number: Int
        let path: String
        let rate: Double
        let frames: Int
        let info: [String: Any]
        let immediate: Bool
        let file: URL
        var writer: FileHandle?
        var reader: FileHandle?
        var written = 0
        var readers: [Reader] = []
        var closed = false            // no more writing (padded to its length, or cut off by a skip)
        init(number: Int, path: String, rate: Double, frames: Int, info: [String: Any], immediate: Bool, directory: URL) {
            self.number = number; self.path = path; self.rate = rate; self.frames = max(1, frames)
            self.info = info; self.immediate = immediate
            file = directory.appendingPathComponent("slice-\(number).pcm")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            writer = try? FileHandle(forWritingTo: file)
            reader = try? FileHandle(forReadingFrom: file)
        }
        var isFull: Bool { written >= frames }
        var bytes: Int { frames * SliceStore.bytesPerFrame }
    }

    final class Reader {
        let connection: NWConnection
        var offset: Int
        var busy = false
        init(connection: NWConnection, offset: Int) { self.connection = connection; self.offset = offset }
    }

    enum Gate { case writing, waitForSilence, waitForSound }

    static let bytesPerFrame = 6
    /// Unique per session: Roon caches by URL, and slice 1 of a new session must never be served from slice 1 of the last
    /// one (20:56:53: Roon showed "24/48, 1:14" — the old slice — for a new slice at 44.1 of 528 s).
    private let session = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    private let directory: URL
    private let lock = NSLock()
    private var slices: [Int: Slice] = [:]
    private var current: Slice?
    private var pending: Announcement?
    private var overflow = Data()
    private var overflowRate: Double = 0
    private var gate: Gate = .waitForSound
    private var counter = 0
    /// Called (on the main queue) when a slice begins: the bridge plays or queues it in Roon.
    var onSliceStarted: ((Slice) -> Void)?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - From the bridge (main)

    /// The next track: its slice begins with its first sound. A skip ends the current slice at once.
    func announce(_ a: Announcement) {
        lock.lock(); defer { lock.unlock() }
        if a.immediate, let c = current {
            c.closed = true
            for r in c.readers { pump(c, r) }
            current = nil
            overflow = Data()            // whatever came after the skip point belongs to the new track
        }
        pending = a
        // The current slice is already full and the music of the next track is waiting: begin it now.
        if current == nil, !overflow.isEmpty { begin(rate: overflowRate) }
    }

    /// The Music app paused: write on to real silence, then wait for sound.
    func pauseWriting() { lock.lock(); if gate == .writing { gate = .waitForSilence }; lock.unlock() }

    /// Where the current slice is (for the log and the menu).
    var status: (number: Int, writtenMs: Int, lengthMs: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return (c.number, Int(Double(c.written) / c.rate * 1000), Int(Double(c.frames) / c.rate * 1000))
    }

    /// How much of the current slice is left, in seconds (a natural end is near when this is small).
    var remainingSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return Double(c.frames - c.written) / c.rate
    }

    /// Roon plays `number`: older slices can go.
    func forget(before number: Int) {
        lock.lock(); defer { lock.unlock() }
        for (n, s) in slices where n < number && s !== current {
            for r in s.readers { r.connection.cancel() }
            try? s.writer?.close(); try? s.reader?.close()
            try? FileManager.default.removeItem(at: s.file)
            slices[n] = nil
        }
    }

    func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for s in slices.values {
            for r in s.readers { r.connection.cancel() }
            try? s.writer?.close(); try? s.reader?.close()
            try? FileManager.default.removeItem(at: s.file)
        }
        slices = [:]; current = nil; pending = nil; overflow = Data(); gate = .waitForSound
    }

    // MARK: - From the capture queue

    func write(_ pcm: Data, frames: Int, firstSound: Int?, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        var data = pcm, count = frames
        switch gate {
        case .writing:
            break
        case .waitForSilence:
            if firstSound == nil { gate = .waitForSound; Log.note("slices: silence — waiting for sound"); return }
        case .waitForSound:
            guard let first = firstSound else { return }
            gate = .writing
            data = pcm.subdata(in: (first * Self.bytesPerFrame)..<pcm.count)
            count = frames - first
        }
        while count > 0 {
            if let c = current, !c.closed, !c.isFull {
                if c.rate != rate {
                    // The device changed rate inside an open slice. Near its end: the boundary between two tracks — fill it
                    // to its length (Roon expects those bytes); the music goes on in the next. Further from its end (the
                    // Music app settles on a track's rate a few seconds after a start): cut it, and the rest of the same
                    // track goes on at once as a slice of its own, instead of minutes of silence.
                    let remaining = Double(c.frames - c.written) / c.rate
                    if remaining < 2 || pending != nil {
                        pad(c)
                    } else {
                        c.closed = true
                        current = nil
                        pending = Announcement(info: c.info, durationMs: Int(remaining * 1000), immediate: true)
                        Log.note("slices: \(c.number) cut at a change of rate, \(Int(remaining)) s go on in the next")
                        for r in c.readers { pump(c, r) }
                    }
                    continue
                }
                let n = min(count, c.frames - c.written)
                append(data.prefix(n * Self.bytesPerFrame), frames: n, to: c)
                data = data.dropFirst(n * Self.bytesPerFrame); count -= n
                if c.isFull { c.closed = true; for r in c.readers { pump(c, r) } }
                continue
            }
            // No open slice: the music of the next track. Begin its slice if it has been announced, else keep it.
            if pending != nil {
                if overflowRate != rate { overflow = Data() }
                overflowRate = rate
                begin(rate: rate)
                continue
            }
            if overflowRate != rate { overflow = Data(); overflowRate = rate }
            overflow.append(data.prefix(count * Self.bytesPerFrame))
            let cap = Int(rate) * 30 * Self.bytesPerFrame
            if overflow.count > cap { overflow = overflow.suffix(cap) }
            count = 0
        }
    }

    /// Under the lock: the announced track gets its slice, starting with what waited in the overflow.
    private func begin(rate: Double) {
        guard let a = pending else { return }
        pending = nil
        counter += 1
        let s = Slice(number: counter, path: "/stream/\(session)-\(counter).wav", rate: rate,
                      frames: Int(Double(a.durationMs) / 1000 * rate), info: a.info, immediate: a.immediate, directory: directory)
        slices[s.number] = s
        current = s
        if overflowRate == rate, !overflow.isEmpty {
            let n = min(overflow.count / Self.bytesPerFrame, s.frames)
            append(overflow.prefix(n * Self.bytesPerFrame), frames: n, to: s)
        }
        overflow = Data()
        Log.note("slices: \(s.number) begins at \(Int(rate)) Hz, \(a.durationMs / 1000) s\(a.immediate ? " (now)" : " (queued)")")
        let callback = onSliceStarted
        DispatchQueue.main.async { callback?(s) }
    }

    private func pad(_ s: Slice) {
        let rest = s.frames - s.written
        if rest > 0 { append(Data(count: rest * Self.bytesPerFrame), frames: rest, to: s) }
        s.closed = true
        current = nil
        Log.note("slices: \(s.number) padded with \(String(format: "%.2f", Double(rest) / s.rate)) s of silence")
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
        let available = s.written * Self.bytesPerFrame
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
