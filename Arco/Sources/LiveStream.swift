// The stream Roon plays: one long WAV (24-bit stereo, declared at three hours) that grows on disk while the music plays.
// Every request — the first, a second one, a Range request after a pause — gets exactly the bytes it asks for, as far as
// they exist, and the rest as they arrive.
//
// The gate keeps Roon's distance constant. While the music plays everything is written, silence between tracks included.
// When the Music app pauses, the stream writes on until it sees a buffer of real silence, then waits; it resumes at the
// first sample that is not silent. A pause therefore leaves no silence in the stream, and nothing is lost or repeated —
// whoever resumes (Arco, Roon's button, the Music app itself).
import Foundation
import Network

final class LiveStream: @unchecked Sendable {
    /// A connection reading the stream, with its own position in the data.
    final class Reader {
        let connection: NWConnection
        var offset: Int            // bytes of data (after the WAV header) already sent
        var busy = false
        init(connection: NWConnection, offset: Int) { self.connection = connection; self.offset = offset }
    }

    enum Gate { case writing, waitForSilence, waitForSound }

    let number: Int
    /// Unique per run and per stream (/stream/<run>-<n>.wav): Roon caches by URL, and a cached failure for an address
    /// that came back must not be handed to a new stream.
    let path: String
    private static let run = String(UInt32.random(in: 0...UInt32.max), radix: 36)
    let rate: Double
    let declaredFrames: Int
    private let file: URL
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var written = 0
    private var readers: [Reader] = []
    private var gate: Gate = .waitForSound      // a new stream begins with the first sound
    private let lock = NSLock()
    static let bytesPerFrame = 6

    init(number: Int, rate: Double, directory: URL, hours: Double = 3) {
        self.number = number; self.rate = rate
        path = "/stream/\(Self.run)-\(number).wav"
        declaredFrames = Int(rate * 3600 * hours)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("stream-\(number).pcm")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        writer = try? FileHandle(forWritingTo: file)
        reader = try? FileHandle(forReadingFrom: file)
    }

    var framesWritten: Int { lock.lock(); defer { lock.unlock() }; return written }
    /// Where the stream is, in milliseconds of audio — the same clock as Roon's seek position in it.
    var positionMs: Int { Int(Double(framesWritten) / rate * 1000) }
    var isFull: Bool { framesWritten >= declaredFrames }

    /// The Music app paused: write on until real silence, then wait for sound.
    func pauseWriting() { lock.lock(); if gate == .writing { gate = .waitForSilence }; lock.unlock() }

    /// From the capture thread.
    func write(_ pcm: Data, frames: Int, firstSound: Int?) {
        lock.lock(); defer { lock.unlock() }
        var data = pcm, count = frames
        switch gate {
        case .writing:
            break
        case .waitForSilence:
            if firstSound == nil { gate = .waitForSound; Log.note("stream \(number): silence — waiting for sound at \(written) frames"); return }
        case .waitForSound:
            guard let first = firstSound else { return }
            gate = .writing
            Log.note("stream \(number): sound — writing from \(written) frames")
            data = pcm.subdata(in: (first * Self.bytesPerFrame)..<pcm.count)
            count = frames - first
        }
        let room = declaredFrames - written
        guard room > 0, count > 0 else { return }
        if count > room { data = data.prefix(room * Self.bytesPerFrame); count = room }
        try? writer?.write(contentsOf: data)
        written += count
        for r in readers { pump(r) }
    }

    // MARK: - Serving

    /// A GET (or HEAD) for the stream, optionally from a byte on (Range).
    func serve(_ connection: NWConnection, range: String?, headOnly: Bool) {
        lock.lock(); defer { lock.unlock() }
        let total = 44 + declaredFrames * Self.bytesPerFrame
        var from = 0
        if let range, let match = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression) {
            from = min(total, Int(range[match].filter(\.isNumber)) ?? 0)
        }
        var http = from > 0
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(total - 1)/\(total)\r\nContent-Length: \(total - from)\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\n"
        http += "Content-Type: audio/wav\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var head = Data(http.utf8)
        if headOnly { connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() }); return }
        if from < 44 { head.append(Self.wavHeader(rate: rate, frames: declaredFrames).dropFirst(from)) }
        let r = Reader(connection: connection, offset: max(0, from - 44))
        // A new request from the same address replaces the older ones from there: a renderer that reconnects every few
        // seconds during a long pause must not pile up readers (Basso, 6 Oct 2026: 4 449 of them stopped its server).
        let host = Self.host(connection)
        for old in readers where host != nil && Self.host(old.connection) == host { old.connection.cancel() }
        readers.removeAll { host != nil && Self.host($0.connection) == host }
        readers.append(r)
        while readers.count > 8 { readers.removeFirst().connection.cancel() }
        r.busy = true
        connection.stateUpdateHandler = { [weak self, weak r] state in
            guard let self, let r else { return }
            switch state {
            case .failed, .cancelled: self.lock.lock(); self.readers.removeAll { $0 === r }; self.lock.unlock()
            default: break
            }
        }
        connection.send(content: head, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            r.busy = false
            self.pump(r)
        })
    }

    /// Under the lock: one chunk (at most 256 KB) from the file to the reader; at the declared end, close.
    private func pump(_ r: Reader) {
        guard !r.busy else { return }
        let declaredBytes = declaredFrames * Self.bytesPerFrame
        if r.offset >= declaredBytes { r.connection.cancel(); return }
        let available = written * Self.bytesPerFrame
        guard r.offset < available, let reader else { return }
        let count = min(262_144, available - r.offset)
        try? reader.seek(toOffset: UInt64(r.offset))
        guard let data = try? reader.read(upToCount: count), !data.isEmpty else { return }
        r.busy = true
        r.offset += data.count
        r.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            r.busy = false
            if error == nil { self.pump(r) }
        })
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        for r in readers { r.connection.cancel() }
        readers = []
        try? writer?.close(); try? reader?.close()
        writer = nil; reader = nil
        try? FileManager.default.removeItem(at: file)
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
