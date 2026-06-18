import Foundation
import Network

struct StratumJob: Identifiable {
    let id: String
    let rawParams: [Any]
    let receivedAt: Date
    let zcash: ZcashStratumJob?
    let target: String?
}

struct StratumConfiguration: Equatable {
    static let miningDutchLegacyLowDifficultyPassword = "d=0.001"
    static let miningDutchLowDifficultyPassword = "d=0.000000001"
    static let miningDutchDefaultUsername = "atarian"
    static let easiestShareTarget = String(repeating: "f", count: 64)

    var poolURL: String = "stratum+tcp://europe.mining-dutch.nl:6663"
    var username: String = StratumConfiguration.miningDutchDefaultUsername
    var password: String = StratumConfiguration.miningDutchLowDifficultyPassword
    var mode: StratumMode = .zcashZip301

    var endpoint: (host: String, port: UInt16, usesTLS: Bool)? {
        let trimmed = poolURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "stratum+tcp://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let host = components.host,
              let port = components.port,
              (1...65535).contains(port) else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "stratum+tcp"
        guard ["stratum+tcp", "stratum", "tcp", "stratum+ssl", "stratum+tls", "ssl", "tls"].contains(scheme) else {
            return nil
        }
        let usesTLS = ["stratum+ssl", "stratum+tls", "ssl", "tls"].contains(scheme)
        return (host, UInt16(port), usesTLS)
    }

    var validationMessage: String {
        if endpoint == nil {
            return "Use stratum+tcp://host:port or stratum+ssl://host:port."
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a pool user, wallet.worker, or pool account name."
        }
        return "Pool configuration is ready."
    }

    var suggestedDifficulty: Double? {
        let fields = password.split(separator: ",")
        for field in fields {
            let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("d=") else { continue }
            return Double(trimmed.dropFirst(2))
        }
        return poolURL.contains("mining-dutch.nl") ? 0.000000001 : nil
    }

    var suggestedTarget: String? {
        guard mode == .zcashZip301 else {
            return nil
        }
        return suggestedDifficulty != nil ? Self.easiestShareTarget : nil
    }
}

@MainActor
final class StratumController: ObservableObject {
    @Published var configuration = StratumConfiguration()
    @Published private(set) var isConnected = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var difficulty: Double?
    @Published private(set) var target: String?
    @Published private(set) var latestJob: StratumJob?
    @Published private(set) var latestZcashJob: ZcashStratumJob?
    @Published private(set) var activeJobIDs = Set<String>()
    @Published private(set) var latestJobSequence = UInt64(0)
    @Published private(set) var workEpoch = UInt64(0)
    @Published private(set) var sessionID: String?
    @Published private(set) var nonce1: String?
    @Published private(set) var acceptedShares = 0
    @Published private(set) var rejectedShares = 0
    @Published private(set) var lastSubmitResult = "No pool submissions yet."
    @Published private(set) var logs: [String] = ["Stratum client idle."]

    private var client: StratumClient?
    private var activeJobOrder: [String] = []

    func connect() {
        disconnect()
        guard let endpoint = configuration.endpoint else {
            appendLog("Invalid pool URL. Use stratum+tcp://host:port or stratum+ssl://host:port.")
            return
        }
        guard !configuration.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("Worker/user is required before connecting.")
            return
        }

        isConnected = false
        isAuthorized = false
        difficulty = nil
        target = nil
        latestJob = nil
        latestZcashJob = nil
        activeJobIDs.removeAll(keepingCapacity: true)
        activeJobOrder.removeAll(keepingCapacity: true)
        latestJobSequence = 0
        workEpoch &+= 1
        sessionID = nil
        nonce1 = nil
        lastSubmitResult = "No pool submissions yet."

        let client = StratumClient(configuration: configuration, endpoint: endpoint)
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        self.client = client
        appendLog("Connecting to \(endpoint.host):\(endpoint.port) using \(endpoint.usesTLS ? "TLS" : "TCP")...")
        client.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        isConnected = false
        isAuthorized = false
        nonce1 = nil
        activeJobIDs.removeAll(keepingCapacity: true)
        activeJobOrder.removeAll(keepingCapacity: true)
        workEpoch &+= 1
    }

    @discardableResult
    func submit(jobID: String, time: String, nonce2: String, solution: String) -> Bool {
        guard let client else {
            appendLog("Cannot submit share for job \(jobID); no Stratum client is active.")
            return false
        }
        guard isConnected else {
            appendLog("Cannot submit share for job \(jobID); pool is not connected.")
            return false
        }
        guard isAuthorized else {
            appendLog("Cannot submit share for job \(jobID); worker is not authorized.")
            return false
        }

        appendLog(
            "Submitting share job=\(jobID), nonce2=\(nonce2.prefix(16))..., solution=\(solution.count / 2) bytes."
        )
        client.submit(worker: configuration.username, jobID: jobID, time: time, nonce2: nonce2, solution: solution)
        return true
    }

    @discardableResult
    func submit(_ submission: ZcashSubmission) -> Bool {
        submit(
            jobID: submission.jobID,
            time: submission.time,
            nonce2: submission.nonce2,
            solution: submission.solution
        )
    }

    private func handle(_ event: StratumEvent) {
        switch event {
        case .connected:
            isConnected = true
            appendLog("TCP connected. Sent mining.subscribe.")
        case .disconnected(let reason):
            isConnected = false
            isAuthorized = false
            activeJobIDs.removeAll(keepingCapacity: true)
            activeJobOrder.removeAll(keepingCapacity: true)
            workEpoch &+= 1
            appendLog("Disconnected: \(reason)")
        case .subscribed(let nonce1, let sessionID):
            self.nonce1 = nonce1
            self.sessionID = sessionID
            appendLog("Subscribed. nonce1=\(nonce1), session=\(sessionID ?? "none"). Sent mining.authorize.")
        case .authorized(let accepted):
            isAuthorized = accepted
            appendLog(accepted ? "Worker authorized." : "Worker authorization rejected.")
        case .difficulty(let value):
            difficulty = value
            appendLog("Pool difficulty set to \(value).")
        case .target(let value):
            target = value
            appendLog("Pool target updated for next job: \(value.prefix(32))...")
        case .job(let job):
            let jobTarget = target
            if job.zcash?.cleanJobs == true {
                activeJobIDs.removeAll(keepingCapacity: true)
                activeJobOrder.removeAll(keepingCapacity: true)
                workEpoch &+= 1
            }
            latestJobSequence &+= 1
            let sequence = latestJobSequence
            let jobWithTarget = StratumJob(
                id: job.id,
                rawParams: job.rawParams,
                receivedAt: job.receivedAt,
                zcash: job.zcash,
                target: jobTarget
            )
            latestJob = jobWithTarget
            latestZcashJob = jobWithTarget.zcash
            if job.zcash != nil {
                rememberActiveJob(id: job.id)
                let cleanLabel = job.zcash?.cleanJobs == true ? "clean" : "incremental"
                appendLog("Received \(cleanLabel) Zcash job #\(sequence) \(job.id) with valid ZIP-301 fields and target \(jobTarget?.prefix(12) ?? "none")...")
            } else {
                appendLog("Received job \(job.id) with \(job.rawParams.count) params.")
            }
        case .submitResult(let accepted, let message):
            if accepted {
                acceptedShares += 1
            } else {
                rejectedShares += 1
            }
            lastSubmitResult = "\(accepted ? "accepted" : "rejected"): \(message)"
            appendLog("Submit \(accepted ? "accepted" : "rejected"): \(message)")
        case .reconnectRequested(let host, let port, let waitSeconds):
            handleReconnectRequest(host: host, port: port, waitSeconds: waitSeconds)
        case .message(let value):
            appendLog(value)
        case .error(let value):
            appendLog("Error: \(value)")
        }
    }

    private func handleReconnectRequest(host: String?, port: UInt16?, waitSeconds: Int) {
        let current = configuration.endpoint
        let nextHost = host?.isEmpty == false ? host : current?.host
        let nextPort = port ?? current?.port
        if let nextHost, let nextPort {
            let scheme = current?.usesTLS == true ? "stratum+ssl" : "stratum+tcp"
            configuration.poolURL = "\(scheme)://\(nextHost):\(nextPort)"
        }

        appendLog("Pool requested reconnect\(waitSeconds > 0 ? " in \(waitSeconds)s" : "").")
        client?.disconnect()
        client = nil
        isConnected = false
        isAuthorized = false
        nonce1 = nil
        activeJobIDs.removeAll(keepingCapacity: true)
        activeJobOrder.removeAll(keepingCapacity: true)
        workEpoch &+= 1

        Task { [weak self] in
            if waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
            }
            await MainActor.run {
                self?.connect()
            }
        }
    }

    private func rememberActiveJob(id: String) {
        if !activeJobIDs.contains(id) {
            activeJobOrder.append(id)
        }
        activeJobIDs.insert(id)
        while activeJobOrder.count > 32 {
            let removed = activeJobOrder.removeFirst()
            activeJobIDs.remove(removed)
        }
    }

    private func appendLog(_ message: String) {
        let stamp = DateFormatter.stratumStamp.string(from: Date())
        logs.append("[\(stamp)] \(message)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }
}

enum StratumEvent {
    case connected
    case disconnected(String)
    case subscribed(nonce1: String, sessionID: String?)
    case authorized(Bool)
    case difficulty(Double)
    case target(String)
    case job(StratumJob)
    case submitResult(accepted: Bool, message: String)
    case reconnectRequested(host: String?, port: UInt16?, waitSeconds: Int)
    case message(String)
    case error(String)
}

final class StratumClient {
    var onEvent: ((StratumEvent) -> Void)?

    private let configuration: StratumConfiguration
    private let endpoint: (host: String, port: UInt16, usesTLS: Bool)
    private let queue = DispatchQueue(label: "zcash-metal-miner.stratum")
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 1
    private var pendingMethods: [Int: String] = [:]
    private var pendingSubmitDetails: [Int: String] = [:]

    init(configuration: StratumConfiguration, endpoint: (host: String, port: UInt16, usesTLS: Bool)) {
        self.configuration = configuration
        self.endpoint = endpoint
    }

    func connect() {
        let parameters: NWParameters = endpoint.usesTLS ? .tls : .tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: parameters
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:
                self.emit(.message("Connection setup started."))
            case .preparing:
                self.emit(.message("Resolving \(self.endpoint.host) and opening \(self.endpoint.usesTLS ? "TLS" : "TCP") socket..."))
            case .waiting(let error):
                self.emit(.message("Connection waiting: \(error.localizedDescription)"))
            case .ready:
                self.emit(.connected)
                self.receive()
                self.subscribe()
            case .failed(let error):
                self.emit(.disconnected(error.localizedDescription))
            case .cancelled:
                self.emit(.disconnected("Connection cancelled."))
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingMethods.removeAll(keepingCapacity: false)
            self.pendingSubmitDetails.removeAll(keepingCapacity: false)
            self.buffer.removeAll(keepingCapacity: false)
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func submit(worker: String, jobID: String, time: String, nonce2: String, solution: String) {
        queue.async { [weak self] in
            self?.send(method: "mining.submit", params: [worker, jobID, time, nonce2, solution])
        }
    }

    private func subscribe() {
        switch configuration.mode {
        case .zcashZip301:
            send(
                method: "mining.subscribe",
                params: [AppBrand.userAgent, NSNull(), endpoint.host, Int(endpoint.port)]
            )
        case .jsonRpcGeneric:
            send(method: "mining.subscribe", params: [AppBrand.userAgent])
        }
    }

    private func authorize() {
        send(method: "mining.authorize", params: [configuration.username, configuration.password])
    }

    private func suggestWorkIfNeeded() {
        guard let difficulty = configuration.suggestedDifficulty else {
            if let target = configuration.suggestedTarget {
                send(method: "mining.suggest_target", params: [target])
            }
            return
        }
        send(method: "mining.suggest_difficulty", params: [difficulty])
        if let target = configuration.suggestedTarget {
            send(method: "mining.suggest_target", params: [target])
        }
    }

    private func send(method: String, params: [Any]) {
        guard let connection else {
            emit(.error("Cannot send \(method); not connected."))
            return
        }
        let id = nextID
        nextID += 1
        pendingMethods[id] = method
        if method == "mining.submit" {
            pendingSubmitDetails[id] = Self.describeSubmit(params)
        }

        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            var line = data
            line.append(0x0a)
            connection.send(content: line, completion: .contentProcessed { [weak self] error in
                guard let self, let error else {
                    return
                }
                self.queue.async {
                    self.pendingMethods.removeValue(forKey: id)
                    self.pendingSubmitDetails.removeValue(forKey: id)
                    self.emit(.error("Send failed for \(method): \(error.localizedDescription)"))
                }
            })
        } catch {
            pendingMethods.removeValue(forKey: id)
            pendingSubmitDetails.removeValue(forKey: id)
            emit(.error("Could not encode \(method): \(error.localizedDescription)"))
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if let error {
                self.emit(.disconnected(error.localizedDescription))
                return
            }
            if isComplete {
                self.emit(.disconnected("Server closed the connection."))
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handleLine(Data(line))
        }
    }

    private func handleLine(_ data: Data) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                emit(.error("Received non-object JSON message."))
                return
            }

            if let method = object["method"] as? String {
                handleNotification(method: method, params: object["params"])
                return
            }

            guard let id = object["id"] as? Int else {
                emit(.message("Received response without id."))
                return
            }
            let method = pendingMethods.removeValue(forKey: id) ?? "unknown"
            let submitDetails = pendingSubmitDetails.removeValue(forKey: id)
            handleResponse(method: method, object: object, submitDetails: submitDetails)
        } catch {
            emit(.error("JSON parse failed: \(error.localizedDescription)"))
        }
    }

    private func handleResponse(method: String, object: [String: Any], submitDetails: String?) {
        let submitContext = submitDetails.map { " (\($0))" } ?? ""
        if let errorObject = object["error"], !(errorObject is NSNull) {
            let message = "\(method)\(submitContext) returned \(Self.describeStratumError(errorObject))"
            if method == "mining.submit" {
                emit(.submitResult(accepted: false, message: message))
            } else {
                if method == "mining.authorize" {
                    emit(.authorized(false))
                }
                emit(.error(message))
            }
            return
        }

        switch method {
        case "mining.subscribe":
            if let result = object["result"] as? [Any] {
                let parsed = parseSubscribeResult(result)
                if parsed.nonce1.isEmpty {
                    emit(.error("mining.subscribe did not return a usable nonce1."))
                } else {
                    emit(.subscribed(nonce1: parsed.nonce1, sessionID: parsed.sessionID))
                    suggestWorkIfNeeded()
                    authorize()
                }
            } else {
                emit(.error("mining.subscribe returned an unexpected result."))
            }
        case "mining.authorize":
            emit(.authorized((object["result"] as? Bool) == true))
        case "mining.submit":
            let accepted = (object["result"] as? Bool) == true
            emit(.submitResult(
                accepted: accepted,
                message: accepted
                    ? "pool accepted share\(submitContext)"
                    : "pool rejected share\(submitContext); response \(Self.describe(object))"
            ))
        case "mining.suggest_difficulty", "mining.suggest_target":
            emit(.message("Pool difficulty suggestion acknowledged: \(object)"))
        default:
            emit(.message("\(method) response: \(object)"))
        }
    }

    private func handleNotification(method: String, params: Any?) {
        switch method {
        case "mining.set_difficulty":
            if let values = params as? [Any], let value = values.first as? Double {
                emit(.difficulty(value))
            } else if let values = params as? [Any], let value = values.first as? Int {
                emit(.difficulty(Double(value)))
            }
        case "mining.set_target":
            if let values = params as? [Any], let value = values.first as? String {
                emit(.target(value))
            }
        case "mining.notify":
            if let values = params as? [Any], let id = values.first as? String {
                let zcashJob: ZcashStratumJob?
                do {
                    zcashJob = try ZcashStratumJob(params: values)
                } catch {
                    zcashJob = nil
                    emit(.error("Ignored invalid Zcash job \(id): \(error.localizedDescription)"))
                }
                emit(.job(StratumJob(id: id, rawParams: values, receivedAt: Date(), zcash: zcashJob, target: nil)))
            } else {
                emit(.message("Received mining.notify with unexpected params."))
            }
        case "client.reconnect":
            if let values = params as? [Any] {
                let host = values.first as? String
                let port = values.count > 1 ? Self.uint16(values[1]) : nil
                let wait = values.count > 2 ? Self.int(values[2]) ?? 0 : 0
                emit(.reconnectRequested(host: host, port: port, waitSeconds: max(0, wait)))
            } else {
                emit(.reconnectRequested(host: nil, port: nil, waitSeconds: 0))
            }
        default:
            emit(.message("Notification \(method): \(params ?? [])"))
        }
    }

    static func parseSubscribeResult(_ result: [Any], mode: StratumMode) -> (nonce1: String, sessionID: String?) {
        if mode == .zcashZip301,
           result.count >= 2,
           result[0] is NSNull,
           let nonce1 = result[1] as? String {
            return (nonce1, nil)
        }

        if mode == .zcashZip301,
           result.count >= 2,
           let sessionID = result[0] as? String,
           let nonce1 = result[1] as? String {
            return (nonce1, sessionID)
        }

        if result.count >= 2, let nonce1 = result[0] as? String {
            return (nonce1, result[1] as? String)
        }

        if result.count >= 3, let nonce1 = result[1] as? String {
            return (nonce1, nil)
        }

        return ("", nil)
    }

    private func parseSubscribeResult(_ result: [Any]) -> (nonce1: String, sessionID: String?) {
        Self.parseSubscribeResult(result, mode: configuration.mode)
    }

    private func emit(_ event: StratumEvent) {
        onEvent?(event)
    }

    private static func describeSubmit(_ params: [Any]) -> String {
        guard params.count >= 5 else {
            return "malformed submit"
        }
        let worker = params[0] as? String ?? "unknown-worker"
        let jobID = params[1] as? String ?? "unknown-job"
        let time = params[2] as? String ?? "unknown-time"
        let nonce2 = params[3] as? String ?? "unknown-nonce2"
        let solution = params[4] as? String ?? ""
        return "worker=\(worker), job=\(jobID), time=\(time), nonce2=\(nonce2.prefix(16))..., solution=\(solution.count / 2) bytes"
    }

    private static func describeStratumError(_ value: Any) -> String {
        guard let fields = value as? [Any],
              let first = fields.first,
              let code = int(first) else {
            return describe(value)
        }
        let message = fields.count > 1 ? String(describing: fields[1]) : "no message"
        let label: String
        switch code {
        case 20:
            label = "other/unknown"
        case 21:
            label = "stale job"
        case 22:
            label = "duplicate share"
        case 23:
            label = "low difficulty share"
        case 24:
            label = "unauthorized worker"
        case 25:
            label = "not subscribed"
        default:
            label = "pool error"
        }
        return "\(label) (\(code)): \(message)"
    }

    private static func describe(_ value: Any) -> String {
        if let array = value as? [Any] {
            return array.map { describe($0) }.joined(separator: " | ")
        }
        if let dictionary = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if value is NSNull {
            return "null"
        }
        return "\(value)"
    }

    private static func int(_ value: Any) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func uint16(_ value: Any) -> UInt16? {
        guard let int = int(value), (1...65535).contains(int) else {
            return nil
        }
        return UInt16(int)
    }
}

private extension DateFormatter {
    static let stratumStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
