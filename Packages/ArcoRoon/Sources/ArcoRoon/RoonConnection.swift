// The connection with one Roon Core (after node-roon-api/lib.js). Find the Core on the network (SOOD), open a WebSocket
// to ws://<core>:<port>/api, register with the registry (info → register, with the token from last time), and answer
// the services Roon expects from every extension: ping, status and pairing.
//
// Registering the first time waits until the user presses Enable in Roon › Settings › Extensions; until then the state
// is `.waitingForAuthorization`. The token Roon hands out is kept in the state file (same shape as node-roon-api's
// roonstate: tokens[core_id]), so the next start is recognised without a new Enable. The token never goes into a log.
//
// A broken line is retried after three seconds, with a fresh discovery (the Core may have a new address).
import Foundation

@MainActor
public final class RoonConnection: NSObject {
    public struct Extension {
        public var id, displayName, version, publisher, email: String
        public var website: String?
        public init(id: String, displayName: String, version: String, publisher: String, email: String, website: String? = nil) {
            self.id = id; self.displayName = displayName; self.version = version
            self.publisher = publisher; self.email = email; self.website = website
        }
    }

    /// The Core after registering: its name, version, and the services it offers this extension.
    public struct Core: Equatable {
        public let id: String
        public let name: String
        public let version: String
        public let services: Set<String>
    }

    public enum State: Equatable {
        /// Looking for a Core on the network.
        case searching
        /// A Core was found; registering.
        case connecting(coreName: String)
        /// Registered, waiting for Enable in Roon › Settings › Extensions.
        case waitingForAuthorization(coreName: String)
        /// Registered and paired: the services can be used.
        case paired(Core)
    }

    public private(set) var state: State = .searching { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    /// The address of the Core this connection talks to (a stream URL must be reachable from there).
    public private(set) var coreHost: String?

    let extensionInfo: Extension
    let requiredServices: [String], optionalServices: [String]
    let stateFile: URL

    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var lineNumber = 0
    private var nextRequestID = 0
    private var pending: [String: (String?, JSON?) -> Void] = [:]
    private var subscriptionKey = 0
    private var pongSeen = true
    private var heartbeat: Timer?
    private var registeredCore: Core?
    // com.roonlabs.status:1 — the line Roon shows under Settings › Extensions.
    private var statusMessage = "Starting", statusIsError = false
    private var statusSubscribers: [String] = []
    private var pairingSubscribers: [String] = []

    public init(extension info: Extension, required: [String], optional: [String] = [], stateFile: URL) {
        self.extensionInfo = info; self.requiredServices = required; self.optionalServices = optional
        self.stateFile = stateFile
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration)
    }

    public func start() { Task { await connect() } }

    // MARK: - Requests to the Core

    /// A request; the callback receives every reply (CONTINUE and COMPLETE) as (name, body), and (nil, nil) when the
    /// line goes down.
    public func request(_ name: String, _ body: JSON? = nil, _ callback: ((String?, JSON?) -> Void)? = nil) {
        guard let socket else { callback?(nil, nil); return }
        let id = String(nextRequestID); nextRequestID += 1
        pending[id] = callback ?? { _, _ in }
        socket.send(.data(MooMessage.encode(.request, name, id: id, body: body))) { _ in }
    }

    /// A request with a single reply.
    public func request(_ name: String, _ body: JSON? = nil) async -> (name: String?, body: JSON?) {
        await withCheckedContinuation { continuation in
            var first = true
            request(name, body) { n, b in if first { first = false; continuation.resume(returning: (n, b)) } }
        }
    }

    /// A subscription (subscribe_<what>): every message goes to the callback.
    public func subscribe(_ service: String, _ what: String, _ arguments: JSON = [:], _ callback: @escaping (String?, JSON?) -> Void) {
        var a = arguments
        a["subscription_key"] = subscriptionKey; subscriptionKey += 1
        request("\(service)/subscribe_\(what)", a, callback)
    }

    /// The status line in Roon's list of extensions.
    public func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message; statusIsError = isError
        for id in statusSubscribers { reply(.continue, "Changed", id: id, ["message": message, "is_error": isError]) }
    }

    // MARK: - Finding the Core and the line

    private func connect() async {
        lineNumber += 1
        let number = lineNumber
        state = .searching
        let cores = await Discovery.findCores()
        guard number == lineNumber else { return }
        let paired = savedState()["paired_core_id"] as? String
        guard let core = cores.first(where: { $0.id == paired }) ?? cores.first else {
            retry(after: 5)
            return
        }
        state = .connecting(coreName: core.name)
        coreHost = core.host
        guard let url = URL(string: "ws://\(core.host):\(core.port)/api") else { retry(after: 5); return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        socket = task
        task.resume()
        listen(task, number)
        pongSeen = true
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(number) }
        }
        // Register: first info (which Core), then register with the token that belongs to that Core.
        request("com.roonlabs.registry:1/info") { [weak self] name, body in
            guard let self, number == self.lineNumber, name != nil, let coreID = body?["core_id"] as? String else { return }
            var registration: JSON = [
                "extension_id": self.extensionInfo.id, "display_name": self.extensionInfo.displayName,
                "display_version": self.extensionInfo.version, "publisher": self.extensionInfo.publisher,
                "email": self.extensionInfo.email,
                "required_services": self.requiredServices, "optional_services": self.optionalServices,
                "provided_services": ["com.roonlabs.status:1", "com.roonlabs.pairing:1", "com.roonlabs.ping:1"],
            ]
            if let website = self.extensionInfo.website { registration["website"] = website }
            if let token = (self.savedState()["tokens"] as? [String: String])?[coreID] { registration["token"] = token }
            // Without a known token Roon only answers after Enable: say so in the menu meanwhile.
            if registration["token"] == nil { self.state = .waitingForAuthorization(coreName: core.name) }
            self.request("com.roonlabs.registry:1/register", registration) { [weak self] name, body in
                guard let self, number == self.lineNumber else { return }
                if name == "Registered", let body { self.registered(body, coreName: core.name) }
            }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask, _ number: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, number == self.lineNumber else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: data = Data()
                    }
                    guard let parsed = MooMessage.parse(data) else { self.lineDown(); return }
                    self.receive(parsed)
                    self.listen(task, number)
                case .failure:
                    self.lineDown()
                }
            }
        }
    }

    private func tick(_ number: Int) {
        guard number == lineNumber, let socket else { return }
        if !pongSeen { lineDown(); return }
        pongSeen = false
        socket.sendPing { [weak self] error in
            Task { @MainActor in if error == nil, number == self?.lineNumber { self?.pongSeen = true } }
        }
    }

    private func lineDown() {
        lineNumber += 1
        heartbeat?.invalidate(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        registeredCore = nil
        statusSubscribers = []; pairingSubscribers = []
        let waiting = pending; pending = [:]
        for (_, callback) in waiting { callback(nil, nil) }
        retry(after: 3)
    }

    private func retry(after seconds: TimeInterval) {
        state = .searching
        let number = lineNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, number == self.lineNumber else { return }
                Task { await self.connect() }
            }
        }
    }

    // MARK: - Messages from the Core

    private func receive(_ message: MooMessage) {
        if message.verb != .request {
            guard let callback = pending[message.requestID] else { lineDown(); return }
            if message.verb == .complete { pending[message.requestID] = nil }
            callback(message.name, message.body)
            return
        }
        // The services Roon asks of us.
        switch (message.service, message.name) {
        case ("com.roonlabs.ping:1", "ping"):
            reply(.complete, "Success", id: message.requestID, nil)
        case ("com.roonlabs.status:1", "subscribe_status"):
            statusSubscribers.append(message.requestID)
            reply(.continue, "Subscribed", id: message.requestID, ["message": statusMessage, "is_error": statusIsError])
        case ("com.roonlabs.status:1", "unsubscribe_status"):
            statusSubscribers.removeAll()
            reply(.complete, "Unsubscribed", id: message.requestID, nil)
        case ("com.roonlabs.status:1", "get_status"):
            reply(.complete, "Success", id: message.requestID, ["message": statusMessage, "is_error": statusIsError])
        case ("com.roonlabs.pairing:1", "subscribe_pairing"):
            pairingSubscribers.append(message.requestID)
            reply(.continue, "Subscribed", id: message.requestID, pairedCoreBody())
        case ("com.roonlabs.pairing:1", "unsubscribe_pairing"):
            pairingSubscribers.removeAll()
            reply(.complete, "Unsubscribed", id: message.requestID, nil)
        case ("com.roonlabs.pairing:1", "get_pairing"):
            reply(.complete, "Success", id: message.requestID, pairedCoreBody())
        case ("com.roonlabs.pairing:1", "pair"):
            // One Core: whoever pairs us is the Core on this line.
            if let core = registeredCore, (savedState()["paired_core_id"] as? String) != core.id {
                save { $0["paired_core_id"] = core.id }
                for id in pairingSubscribers { reply(.continue, "Changed", id: id, ["paired_core_id": core.id]) }
                state = .paired(core)
            }
        default:
            reply(.complete, "InvalidRequest", id: message.requestID,
                  ["error": "unknown request name (\(message.service)) : \(message.name)"])
        }
    }

    private func pairedCoreBody() -> JSON {
        if let id = savedState()["paired_core_id"] as? String { return ["paired_core_id": id] }
        return [:]
    }

    private func reply(_ verb: MooMessage.Verb, _ name: String, id: String, _ body: JSON?) {
        socket?.send(.data(MooMessage.encode(verb, name, id: id, body: body))) { _ in }
    }

    private func registered(_ body: JSON, coreName: String) {
        guard let id = body["core_id"] as? String else { return }
        let core = Core(id: id, name: body["display_name"] as? String ?? coreName,
                        version: body["display_version"] as? String ?? "",
                        services: Set(body["provided_services"] as? [String] ?? []))
        registeredCore = core
        save { s in
            var tokens = s["tokens"] as? [String: String] ?? [:]
            if let token = body["token"] as? String { tokens[id] = token }
            s["tokens"] = tokens
            if s["paired_core_id"] == nil { s["paired_core_id"] = id }
        }
        // Paired when this is the paired Core (as in node-roon-api: another Core waits for a pair request).
        if (savedState()["paired_core_id"] as? String) == id {
            for p in pairingSubscribers { reply(.continue, "Changed", id: p, ["paired_core_id": id]) }
            state = .paired(core)
        } else {
            state = .waitingForAuthorization(coreName: core.name)
        }
    }

    // MARK: - The state file (roonstate)

    private func savedState() -> JSON {
        guard let data = try? Data(contentsOf: stateFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return [:] }
        return json["roonstate"] as? JSON ?? [:]
    }

    private func save(_ change: (inout JSON) -> Void) {
        var whole: JSON = [:]
        if let data = try? Data(contentsOf: stateFile), let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON { whole = json }
        var s = whole["roonstate"] as? JSON ?? [:]
        change(&s)
        whole["roonstate"] = s
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: whole, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
