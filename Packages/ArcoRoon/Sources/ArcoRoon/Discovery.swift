// SOOD — how a Roon extension finds a Core (after node-roon-api/sood.js). One UDP datagram to the multicast group
// 239.255.90.90:9003 and to the broadcast address, asking for Roon's service id; every Core answers the sender directly
// with its name, version and ports. The Core's address is where the answer came from.
//
// Datagram: "SOOD", version 2, type 'Q' (query) or 'R' (reply), then properties: one byte name length, the name, two
// bytes (big-endian) value length, the value — 0xFFFF for a value that is null.
import Foundation
import Darwin

public struct DiscoveredCore: Sendable, Equatable, Identifiable {
    public let id: String          // the Core's unique id
    public let name: String        // "Dylan"
    public let version: String     // "2.73 (build 1697) earlyaccess"
    public let host: String        // IPv4 address
    public let port: Int           // the extension API (http_port, normally 9330)
}

public enum Discovery {
    static let roonServiceID = "00720724-5143-4a9b-abac-0e50cba674bb"
    static let port: UInt16 = 9003

    /// Asks the network which Roon Cores there are, and collects the answers for `seconds`.
    public static func findCores(seconds: TimeInterval = 2.5) async -> [DiscoveredCore] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: query(seconds: seconds))
            }
        }
    }

    static func query(seconds: TimeInterval) -> [DiscoveredCore] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let packet = makeQuery()
        for target in ["239.255.90.90", "255.255.255.255"] { send(packet, on: fd, to: target) }

        var found: [String: DiscoveredCore] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0, let props = parseReply(buffer[0..<count]), props["service_id"] == roonServiceID else { continue }
            var address = from.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: text)
            let id = props["unique_id"].flatMap { $0 } ?? host
            found[id] = DiscoveredCore(id: id, name: props["name"].flatMap { $0 } ?? "Roon Core",
                                       version: props["display_version"].flatMap { $0 } ?? "",
                                       host: host, port: props["http_port"].flatMap { $0 }.flatMap(Int.init) ?? 9330)
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// This Mac's address on the network that reaches `host` — the address the Core can fetch a stream from. (A UDP
    /// "connect" sends nothing; it only picks the route.)
    public static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9330).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }

    static func makeQuery() -> [UInt8] {
        var packet = Array("SOOD".utf8) + [2, UInt8(ascii: "Q")]
        func property(_ name: String, _ value: String) {
            let n = Array(name.utf8), v = Array(value.utf8)
            packet += [UInt8(n.count)] + n + [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
        }
        property("query_service_id", roonServiceID)
        property("_tid", UUID().uuidString.lowercased())
        return packet
    }

    static func parseReply(_ data: ArraySlice<UInt8>) -> [String: String?]? {
        let bytes = Array(data)
        guard bytes.count >= 6, Array(bytes[0..<4]) == Array("SOOD".utf8), bytes[4] == 2, bytes[5] == UInt8(ascii: "R") else { return nil }
        var props: [String: String?] = [:]
        var i = 6
        while i < bytes.count {
            let nameLength = Int(bytes[i]); i += 1
            guard i + nameLength + 2 <= bytes.count else { return nil }
            let name = String(decoding: bytes[i..<(i + nameLength)], as: UTF8.self); i += nameLength
            let valueLength = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
            if valueLength == 0xFFFF { props[name] = .some(nil); continue }
            guard i + valueLength <= bytes.count else { return nil }
            props[name] = String(decoding: bytes[i..<(i + valueLength)], as: UTF8.self); i += valueLength
        }
        return props
    }

    static func send(_ packet: [UInt8], on fd: Int32, to host: String) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
