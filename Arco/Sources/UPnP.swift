// UPnP renderers as a second kind of output (21 Oct 2026, René: "zullen we in onze Arco UPnP achter een schakelaar
// bouwen met de bevindingen van nu?") — experimental, behind a switch:
//
//   defaults write nl.renebouwmeester.arco UPnP -bool true
//
// The runs are the same as Roon's (see SliceStore): WAV files that grow while the music plays, served with Range. A
// renderer plays a run's URL (SetAVTransportURI + Play); tracks at one rate go on in it, gapless, without SetNext. What
// Basso's seam tests on 21 Oct taught (KEF LS60, Meridian Ellipse, Naim Mu-so 2): all three wait patiently for a file that
// is still growing, but the Ellipse and the Mu-so need at least 3 s of lead (the KEF 1 s) — so a renderer starts a run only
// when 4.5 s are written (3 s, plus the 1.2 s Arco holds back). And wifi on both sides (Mac and renderer) gave dropouts at
// 96 kHz; a wired renderer was clean from a Mac on wifi.
//
// Not yet: a title per track (UPnP has no update_track_info — the renderer shows the run's first track), the renderer's
// own volume, its next and previous buttons.
import ArcoRoon
import Foundation

/// A UPnP MediaRenderer on the network.
struct UPnPRenderer: Identifiable, Equatable, Sendable {
    let id: String            // its UDN
    let name: String
    let host: String
    let avTransport: URL
    let avTransportType: String

    /// Which renderers there are: an SSDP search (2.5 s), then each one's description.
    static func find() async -> [UPnPRenderer] {
        let locations = await withCheckedContinuation { (c: CheckedContinuation<[URL], Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: search(seconds: 2.5)) }
        }
        var found: [String: UPnPRenderer] = [:]
        await withTaskGroup(of: UPnPRenderer?.self) { group in
            for l in locations { group.addTask { await describe(l) } }
            for await r in group { if let r { found[r.id] = r } }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func search(seconds: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let query = Array(("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
                           + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n").utf8)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var locations = Set<URL>()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let url = URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)) { locations.insert(url) }
            }
        }
        return Array(locations)
    }

    private static func describe(_ location: URL) async -> UPnPRenderer? {
        var request = URLRequest(url: location); request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request), let host = location.host else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        func tag(_ t: String, in s: String) -> String? {
            guard let r = s.range(of: "<\(t)>"), let e = s.range(of: "</\(t)>", range: r.upperBound..<s.endIndex) else { return nil }
            return String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let udn = tag("UDN", in: xml), let name = tag("friendlyName", in: xml) else { return nil }
        let base = tag("URLBase", in: xml).flatMap(URL.init(string:)) ?? location
        for block in xml.components(separatedBy: "<service>").dropFirst() {
            guard let type = tag("serviceType", in: block), type.contains(":service:AVTransport:"),
                  let control = tag("controlURL", in: block), let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
            return UPnPRenderer(id: udn, name: name.replacingOccurrences(of: "&amp;", with: "&"), host: host, avTransport: url, avTransportType: type)
        }
        return nil
    }

    /// An AVTransport action; the answer's body, or nil (logged).
    func avt(_ action: String, _ args: String = "") async -> String? {
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(avTransportType)\">"
            + "<InstanceID>0</InstanceID>\(args)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: avTransport); request.timeoutInterval = 5
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(avTransportType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            Log.note("upnp: \(name) — \(action) got no answer"); return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = text.range(of: "<errorDescription>").map { r in String(text[r.upperBound...].prefix(while: { $0 != "<" })) } ?? ""
            Log.note("upnp: \(name) — \(action) answered \(code)\(detail.isEmpty ? "" : " (\(detail))")"); return nil
        }
        return text
    }

    static func value(_ tag: String, in s: String?) -> String? {
        guard let s, let r = s.range(of: "<\(tag)>"), let e = s.range(of: "</\(tag)>", range: r.upperBound..<s.endIndex) else { return nil }
        return String(s[r.upperBound..<e.lowerBound])
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The renderers in the menu, while the switch is on: searched at the start and every minute.
@MainActor
final class UPnPFinder: ObservableObject {
    @Published private(set) var renderers: [UPnPRenderer] = []
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "UPnP") }

    init() {
        guard Self.enabled else { return }
        Task { @MainActor [weak self] in
            while let self {
                let found = await UPnPRenderer.find()
                if found != self.renderers {
                    Log.note("upnp: \(found.count) renderer\(found.count == 1 ? "" : "s") — \(found.map(\.name).joined(separator: ", "))")
                    self.renderers = found
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// A session on a UPnP renderer: what the bridge needs of an output (see Output), by SOAP. The renderer's state and
/// position are read every second and reported as Roon's events would be.
@MainActor
final class UPnPOutput: Output {
    let renderer: UPnPRenderer
    var onEvent: ((AudioInputSession.Event) -> Void)?
    /// A renderer starts a run only with this much written (see the top of this file).
    let lead: Double? = 4.5
    var name: String { renderer.name }
    private var track: String?
    private var poller: Task<Void, Never>?
    private var lastState = ""
    var isStarved: Bool { lastState == "TRANSITIONING" }

    init(renderer: UPnPRenderer) { self.renderer = renderer }

    func begin(displayName: String, iconURL: String?) async -> Bool {
        guard let answer = await renderer.avt("GetTransportInfo") else { return false }
        Log.note("upnp: \(renderer.name) answers (\(UPnPRenderer.value("CurrentTransportState", in: answer) ?? "?"))")
        return true
    }

    func play(track: String, url: String, info: JSON) async -> String {
        let meta = Self.didl(url: url, info: info)
        guard await renderer.avt("SetAVTransportURI", "<CurrentURI>\(UPnPRenderer.escape(url))</CurrentURI><CurrentURIMetaData>\(UPnPRenderer.escape(meta))</CurrentURIMetaData>") != nil else { return "MediaError" }
        // Play, again every quarter second for up to three: a renderer still between two streams refuses it at first
        // (the Ellipse, 19:26:09: "Transition not available").
        var played = false
        for _ in 0..<12 {
            if await renderer.avt("Play", "<Speed>1</Speed>") != nil { played = true; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard played else { return "MediaError" }
        self.track = track
        lastState = ""
        // Playing once the renderer says so (it fetches and buffers first).
        for _ in 0..<40 {
            let state = UPnPRenderer.value("CurrentTransportState", in: await renderer.avt("GetTransportInfo"))
            if state == "PLAYING" { lastState = "PLAYING"; startPolling(); return "Playing" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        startPolling()
        return "Timeout"
    }

    /// UPnP has no new track information for what plays: the renderer keeps showing the run's first track.
    func updateInfo(track: String, info: JSON) async {}

    func control(_ control: String) {
        Task { @MainActor in
            switch control {
            case "pause": _ = await renderer.avt("Pause")
            case "play": _ = await renderer.avt("Play", "<Speed>1</Speed>")
            default: break
            }
        }
    }

    func end() {
        poller?.cancel(); poller = nil
        let r = renderer
        Task { _ = await r.avt("Stop") }
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let track = self.track else { return }
                let state = UPnPRenderer.value("CurrentTransportState", in: await self.renderer.avt("GetTransportInfo")) ?? ""
                guard !Task.isCancelled, self.track == track else { return }
                if state == "PLAYING", let rel = UPnPRenderer.value("RelTime", in: await self.renderer.avt("GetPositionInfo")) {
                    self.onEvent?(.time(track: track, positionMs: Self.ms(rel)))
                }
                if state != self.lastState, !state.isEmpty {
                    let was = self.lastState
                    self.lastState = state
                    Log.note("upnp: \(self.renderer.name) — \(state)")
                    switch (was, state) {
                    case ("PLAYING", "PAUSED_PLAYBACK"): self.onEvent?(.paused(track: track))
                    case ("PAUSED_PLAYBACK", "PLAYING"): self.onEvent?(.unpaused(track: track))
                    case ("PLAYING", "STOPPED"), ("PAUSED_PLAYBACK", "STOPPED"): self.onEvent?(.stopped(track: track))
                    default: break
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// "0:01:23" or "0:01:23.456" → ms.
    static func ms(_ rel: String) -> Int {
        let parts = rel.split(separator: ":").map { Double($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        return Int((parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000)
    }

    /// The renderer's metadata: title, artist, album and cover from Roon's track information.
    static func didl(url: String, info: JSON) -> String {
        let three = info["three_line"] as? JSON
        let title = UPnPRenderer.escape(three?["line1"] as? String ?? "Arco")
        let artist = UPnPRenderer.escape(three?["line2"] as? String ?? "")
        let album = UPnPRenderer.escape(three?["line3"] as? String ?? "")
        let art = (info["image_url"] as? String).map { "<upnp:albumArtURI>\(UPnPRenderer.escape($0))</upnp:albumArtURI>" } ?? ""
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"arco\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(title)</dc:title><dc:creator>\(artist)</dc:creator><upnp:artist>\(artist)</upnp:artist>"
            + "<upnp:album>\(album)</upnp:album>\(art)<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res protocolInfo=\"http-get:*:audio/wav:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\">\(UPnPRenderer.escape(url))</res>"
            + "</item></DIDL-Lite>"
    }
}
