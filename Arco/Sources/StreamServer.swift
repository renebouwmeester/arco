// The HTTP side Roon talks to: the stream (/stream/<n>.wav), the covers (/cover/<key>) and Arco's icon (/icon.png).
// One request per connection, "Connection: close"; the port is whatever the system gives.
import AppKit
import Foundation
import Network

final class StreamServer: @unchecked Sendable {
    private var listener: NWListener?
    private let lock = NSLock()
    private var stream: LiveStream?
    private var covers: [String: (data: Data, type: String)] = [:]
    private var coverOrder: [String] = []
    private var icon: Data?
    private(set) var port: UInt16 = 0

    /// Starts listening; returns once the port is known (or nil after two seconds).
    func start() async -> UInt16? {
        if port != 0 { return port }
        guard let l = try? NWListener(using: .tcp, on: .any) else { return nil }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        for _ in 0..<40 {
            if let p = l.port?.rawValue, p != 0 { port = p; return p }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func setStream(_ s: LiveStream?) { lock.lock(); stream = s; lock.unlock() }

    /// Keeps a cover for Roon to fetch; the last twenty stay.
    func addCover(_ data: Data, type: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        if covers[key] == nil { coverOrder.append(key) }
        covers[key] = (data, type)
        while coverOrder.count > 20 { covers[coverOrder.removeFirst()] = nil }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || buf.count > 16_384 { connection.cancel() } else { self.receiveRequest(connection, buffer: buf) }
                return
            }
            let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { connection.cancel(); return }
            let method = String(parts[0]), path = String(parts[1].split(separator: "?").first ?? "")
            var range: String?
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].lowercased() == "range" { range = kv[1].trimmingCharacters(in: .whitespaces) }
            }
            self.route(connection, method: method, path: path, range: range)
        }
    }

    private func route(_ connection: NWConnection, method: String, path: String, range: String?) {
        let headOnly = method == "HEAD"
        if path.hasPrefix("/stream/"), let n = Int(path.dropFirst("/stream/".count).replacingOccurrences(of: ".wav", with: "")) {
            lock.lock(); let s = stream; lock.unlock()
            if let s, s.number == n { s.serve(connection, range: range, headOnly: headOnly); return }
            return respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
        }
        if path.hasPrefix("/cover/") {
            let key = String(path.dropFirst("/cover/".count))
            lock.lock(); let cover = covers[key]; lock.unlock()
            if let cover { return respond(connection, status: "200 OK", type: cover.type, body: cover.data, headOnly: headOnly) }
            return respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
        }
        if path == "/icon.png" {
            return respond(connection, status: "200 OK", type: "image/png", body: iconPNG(), headOnly: headOnly)
        }
        respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data, headOnly: Bool = false) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        if !headOnly { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Arco's own icon as a PNG, for the session in Roon.
    private func iconPNG() -> Data {
        lock.lock(); if let icon { lock.unlock(); return icon }; lock.unlock()
        let image = NSApplication.shared.applicationIconImage ?? NSImage()
        var png = Data()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) { png = data }
        lock.lock(); icon = png; lock.unlock()
        return png
    }
}
