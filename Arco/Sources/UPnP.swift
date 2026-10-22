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
    /// Where its description is (for the log line of what it can, see capabilities).
    let location: URL

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
        // Not yet (René, 21 Oct 2026: "de exoten maar even wegfilteren"): Sonos (48 kHz at most, groups), HQPlayer (no
        // SetNext — it wants the runs) and televisions. Measured first, then let in.
        let maker = tag("manufacturer", in: xml) ?? ""
        if ["Sonos", "Signalyst", "Samsung", "LG Electronics", "Sony"].contains(where: { maker.localizedCaseInsensitiveContains($0) }) { return nil }
        let base = tag("URLBase", in: xml).flatMap(URL.init(string:)) ?? location
        for block in xml.components(separatedBy: "<service>").dropFirst() {
            guard let type = tag("serviceType", in: block), type.contains(":service:AVTransport:"),
                  let control = tag("controlURL", in: block), let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
            return UPnPRenderer(id: udn, name: name.replacingOccurrences(of: "&amp;", with: "&"), host: host, avTransport: url,
                                avTransportType: type, location: location)
        }
        return nil
    }

    /// What it can, in one line for the log (21 Oct 2026 — for testers far away, a Linn Klimax DSM first): its maker, whether
    /// its AVTransport offers SetNext, whether it takes WAV and FLAC, and whether it speaks OpenHome too.
    func capabilities() async -> String {
        func get(_ url: URL) async -> String? {
            var r = URLRequest(url: url); r.timeoutInterval = 3
            return (try? await URLSession.shared.data(for: r)).map { String(decoding: $0.0, as: UTF8.self) }
        }
        guard let xml = await get(location) else { return "no description" }
        let maker = Self.value("manufacturer", in: xml) ?? "?", model = Self.value("modelName", in: xml) ?? "?"
        let base = Self.value("URLBase", in: xml).flatMap(URL.init(string:)) ?? location
        var setNext = "?", sink = "", openHome = xml.contains("av-openhome-org") ? "yes" : "no"
        for block in xml.components(separatedBy: "<service>").dropFirst() {
            guard let type = Self.value("serviceType", in: block) else { continue }
            if type.contains(":service:AVTransport:"), let scpd = Self.value("SCPDURL", in: block),
               let url = URL(string: scpd, relativeTo: base), let text = await get(url.absoluteURL) {
                setNext = text.contains("SetNextAVTransportURI") ? "yes" : "no"
            }
            if type.contains(":service:ConnectionManager:"), let control = Self.value("controlURL", in: block),
               let url = URL(string: control, relativeTo: base) {
                let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                    + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:GetProtocolInfo xmlns:u=\"\(type)\"/></s:Body></s:Envelope>"
                var r = URLRequest(url: url.absoluteURL); r.timeoutInterval = 3; r.httpMethod = "POST"
                r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
                r.setValue("\"\(type)#GetProtocolInfo\"", forHTTPHeaderField: "SOAPAction")
                r.httpBody = Data(body.utf8)
                if let (d, _) = try? await URLSession.shared.data(for: r) {
                    let info = (Self.value("Sink", in: String(decoding: d, as: UTF8.self)) ?? "").lowercased()
                    sink = ", WAV \(info.contains("audio/wav") || info.contains("audio/x-wav") || info.contains("audio/wave") ? "yes" : "no")"
                        + ", FLAC \(info.contains("flac") ? "yes" : "no")"
                }
            }
            if type.contains("av-openhome-org") { openHome = "yes" }
        }
        return "\(maker) \(model) — SetNext \(setNext)\(sink), OpenHome \(openHome)"
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
    private var seen: [String: (renderer: UPnPRenderer, at: Date)] = [:]
    /// Renderers whose capabilities are in the log already (once per start of Arco).
    private var described = Set<String>()
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "UPnP") }

    init() {
        guard Self.enabled else { return }
        Task { @MainActor [weak self] in
            while let self {
                // A renderer stays ten minutes after it last answered: the Mu-so doesn't answer every search (Basso, 20 Sept;
                // here 21 Oct 20:22 — it vanished from the menu after one round).
                for r in await UPnPRenderer.find() {
                    if self.seen[r.id] == nil, !self.described.contains(r.id) {
                        self.described.insert(r.id)
                        Task { Log.note("upnp: \(r.name) — \(await r.capabilities())") }
                    }
                    self.seen[r.id] = (r, Date())
                }
                self.seen = self.seen.filter { Date().timeIntervalSince($0.value.at) < 600 }
                let found = self.seen.values.map(\.renderer).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    /// Out of music: between two streams, or stopped at the end of a slice nothing followed (per track).
    var isStarved: Bool { ["TRANSITIONING", "STOPPED", "NO_MEDIA_PRESENT"].contains(lastState) }
    /// The renderer let go of the stream (22 Oct 2026: the KEF went to standby 5 s into a pause, then answered 404 and
    /// "STOPPED" — and a Play the next morning had nothing to play): stopped, or no answer three times in a row.
    var lostStream: Bool { failures >= 3 || ["STOPPED", "NO_MEDIA_PRESENT"].contains(lastState) }
    private var failures = 0
    /// Which track each URL is (per track the renderer moves on to the next by itself; its TrackURI says where it is).
    private var tracks: [String: String] = [:]

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
        tracks[url] = track
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

    func setNext(track: String, url: String, info: JSON) async -> Bool {
        tracks[url] = track
        let meta = Self.didl(url: url, info: info)
        return await renderer.avt("SetNextAVTransportURI", "<NextURI>\(UPnPRenderer.escape(url))</NextURI><NextURIMetaData>\(UPnPRenderer.escape(meta))</NextURIMetaData>") != nil
    }

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
                guard let self, var track = self.track else { return }
                let info = await self.renderer.avt("GetTransportInfo")
                self.failures = info == nil ? self.failures + 1 : 0
                let state = UPnPRenderer.value("CurrentTransportState", in: info) ?? ""
                guard !Task.isCancelled, self.track == track else { return }
                if state == "PLAYING", let position = await self.renderer.avt("GetPositionInfo"), let rel = UPnPRenderer.value("RelTime", in: position) {
                    // Moved on to the next track by itself (SetNext, per track): from now on that one.
                    if let uri = UPnPRenderer.value("TrackURI", in: position)?.replacingOccurrences(of: "&amp;", with: "&"),
                       let t = self.tracks[uri], t != track {
                        track = t; self.track = t
                        self.onEvent?(.playing(track: t))
                    }
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
