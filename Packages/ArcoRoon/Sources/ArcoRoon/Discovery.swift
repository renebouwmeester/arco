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
    /// `alsoAsk`: addresses asked directly as well (the Core found last time, 0.5.2b10). `log`: one search written out — which
    /// connections it went through, and every answer that came back, also the ones Arco does not use.
    public static func findCores(seconds: TimeInterval = 2.5, alsoAsk: [String] = [],
                                 log: (@Sendable (String) -> Void)? = nil) async -> [DiscoveredCore] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: query(seconds: seconds, alsoAsk: alsoAsk, log: log))
            }
        }
    }

    static func adres(_ a: in_addr) -> String {
        var a = a; var t = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &t, socklen_t(INET_ADDRSTRLEN)) != nil ? String(cString: t) : "?"
    }

    static func query(seconds: TimeInterval, alsoAsk: [String] = [], log: (@Sendable (String) -> Void)? = nil) -> [DiscoveredCore] {
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
        // On every network connection of the Mac, as Roon itself asks (0.5.2b9, a tester with his Core in Docker on a NAS:
        // Roon.app on the same Mac found it at once, Arco never): one datagram to the group and the broadcast address went out
        // only through the Mac's DEFAULT connection — Wi-Fi, a VPN or a virtual adapter ahead of the Ethernet, and the question
        // never reached the Core. Now the multicast goes out through each interface, plus each subnet's own broadcast.
        let kaarten = ipv4Interfaces()
        for k in kaarten {
            var bron = k.address
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &bron, socklen_t(MemoryLayout<in_addr>.size))
            send(packet, on: fd, to: "239.255.90.90")
            if let b = k.broadcast { send(packet, on: fd, to: b) }
        }
        if kaarten.isEmpty { send(packet, on: fd, to: "239.255.90.90") }
        send(packet, on: fd, to: "255.255.255.255")
        // The Core found last time, asked directly (0.5.2b10, a tester whose Mac on Ethernet got no answer to the multicast
        // and the broadcast, while the Roon app — which remembers its Core — connected at once).
        for host in alsoAsk { send(packet, on: fd, to: host) }
        var poort = sockaddr_in(); var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &poort) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &plen) } }
        log?("search: through " + (kaarten.isEmpty ? "the default connection" : kaarten.map { "\($0.name) \(adres($0.address))\($0.broadcast.map { " (broadcast \($0))" } ?? "")" }
            .joined(separator: ", ")) + ", 255.255.255.255" + (alsoAsk.isEmpty ? "" : ", and directly \(alsoAsk.joined(separator: ", "))")
            + " — answers to port \(UInt16(bigEndian: poort.sin_port))")
        var antwoorden = 0

        var found: [String: DiscoveredCore] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { continue }
            let props = parseReply(buffer[0..<count])
            antwoorden += 1
            if antwoorden <= 12 {
                let wat = props == nil ? "not a SOOD reply (\(count) bytes)"
                    : props?["service_id"] == roonServiceID ? "a Roon Core: \((props?["name"] ?? nil) ?? "?")"
                    : "another service (\(((props?["service_id"] ?? nil) ?? "?").prefix(8))…)"
                log?("search: answer from \(adres(from.sin_addr)):\(UInt16(bigEndian: from.sin_port)) — \(wat)")
            }
            guard let props, props["service_id"] == roonServiceID else { continue }
            var address = from.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: text)
            let id = props["unique_id"].flatMap { $0 } ?? host
            found[id] = DiscoveredCore(id: id, name: props["name"].flatMap { $0 } ?? "Roon Core",
                                       version: props["display_version"].flatMap { $0 } ?? "",
                                       host: host, port: props["http_port"].flatMap { $0 }.flatMap(Int.init) ?? 9330)
        }
        if antwoorden == 0 { log?("search: no answer at all in \(String(format: "%.1f", seconds)) s") }
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

    /// The Mac's IPv4 connections that can carry multicast (up, running, not the loopback): their address, and their subnet's
    /// broadcast address where there is one.
    public static func ipv4Interfaces() -> [(name: String, address: in_addr, broadcast: String?)] {
        var lijst: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lijst) == 0, let eerste = lijst else { return [] }
        defer { freeifaddrs(lijst) }
        var uit: [(name: String, address: in_addr, broadcast: String?)] = []
        var gezien = Set<UInt32>()
        for p in sequence(first: eerste, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let vlag = Int32(ifa.ifa_flags)
            guard let adres = ifa.ifa_addr, adres.pointee.sa_family == sa_family_t(AF_INET),
                  vlag & IFF_UP != 0, vlag & IFF_RUNNING != 0, vlag & IFF_MULTICAST != 0, vlag & IFF_LOOPBACK == 0 else { continue }
            let a = adres.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard gezien.insert(a.s_addr).inserted else { continue }
            var broadcast: String?
            if vlag & IFF_BROADCAST != 0, let b = ifa.ifa_dstaddr {
                var ba = b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var tekst = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ba, &tekst, socklen_t(INET_ADDRSTRLEN)) != nil { broadcast = String(cString: tekst) }
            }
            uit.append((String(cString: ifa.ifa_name), a, broadcast))
        }
        return uit
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
