// MOO/1 — the message format of Roon's extension API (after node-roon-api/moo.js): a header of text lines, an empty
// line, and a JSON body of Content-Length bytes. Requests are "REQUEST <service>/<name>"; replies are CONTINUE (more to
// come) or COMPLETE (done), carrying the same Request-Id.
import Foundation

public typealias JSON = [String: Any]

public struct MooMessage {
    public enum Verb: String { case request = "REQUEST", `continue` = "CONTINUE", complete = "COMPLETE" }

    public let verb: Verb
    /// For a REQUEST, the service ("com.roonlabs.ping:1"); empty otherwise.
    public let service: String
    /// For a REQUEST, the method ("ping"); otherwise the name of the reply ("Success", "Changed" …).
    public let name: String
    public let requestID: String
    public let body: JSON?

    /// Reads one message; nil for a malformed one (the connection then closes, as in node-roon-api).
    public static func parse(_ data: Data) -> MooMessage? {
        let bytes = [UInt8](data)
        guard let firstEnd = bytes.firstIndex(of: 0x0A) else { return nil }
        let first = String(decoding: bytes[0..<firstEnd], as: UTF8.self)
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0].hasPrefix("MOO/"), let verb = Verb(rawValue: parts[1]) else { return nil }
        var service = "", name = parts[2]
        if verb == .request {
            guard let slash = name.firstIndex(of: "/") else { return nil }
            service = String(name[..<slash]); name = String(name[name.index(after: slash)...])
        }
        var headers: [String: String] = [:]
        var start = firstEnd + 1
        while start < bytes.count {
            guard let end = bytes[start...].firstIndex(of: 0x0A) else { return nil }
            if end == start {   // the empty line: end of the header
                guard let id = headers["Request-Id"] else { return nil }
                var body: JSON? = nil
                if let length = headers["Content-Length"].flatMap(Int.init), length > 0 {
                    guard headers["Content-Type"] == "application/json", end + 1 + length <= bytes.count else { return nil }
                    body = (try? JSONSerialization.jsonObject(with: Data(bytes[(end + 1)..<(end + 1 + length)]))) as? JSON
                    if body == nil { return nil }
                }
                return MooMessage(verb: verb, service: service, name: name, requestID: id, body: body)
            }
            let line = String(decoding: bytes[start..<end], as: UTF8.self)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            start = end + 1
        }
        return nil
    }

    /// Writes a message: "MOO/1 <VERB> <name>", the Request-Id, and for a body its length and type.
    public static func encode(_ verb: Verb, _ name: String, id: String, body: JSON?) -> Data {
        var header = "MOO/1 \(verb.rawValue) \(name)\nRequest-Id: \(id)\n"
        var json = Data()
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            json = data
            header += "Content-Length: \(data.count)\nContent-Type: application/json\n"
        }
        var out = Data((header + "\n").utf8)
        out.append(json)
        return out
    }
}
