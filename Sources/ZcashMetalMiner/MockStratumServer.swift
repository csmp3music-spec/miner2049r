import Foundation
import Network

@MainActor
final class MockStratumServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var endpoint = "stratum+tcp://127.0.0.1:33333"
    @Published private(set) var logs: [String] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "zcash-metal-miner.mock-stratum")

    func start() {
        stop()
        do {
            let listener = try NWListener(using: .tcp, on: 33333)
            listener.newConnectionHandler = { [weak self] connection in
                let session = MockStratumSession(connection: connection) { line in
                    Task { @MainActor in
                        self?.append(line)
                    }
                }
                session.start(on: self?.queue ?? DispatchQueue.global())
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.append("Mock Stratum listening on 127.0.0.1:33333.")
                    case .failed(let error):
                        self?.append("Mock server failed: \(error.localizedDescription)")
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            append("Could not start mock server: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func append(_ line: String) {
        logs.append(line)
        if logs.count > 80 {
            logs.removeFirst(logs.count - 80)
        }
    }
}

private final class MockStratumSession {
    private let connection: NWConnection
    private let log: (String) -> Void
    private var buffer = Data()

    init(connection: NWConnection, log: @escaping (String) -> Void) {
        self.connection = connection
        self.log = log
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("Client connected.")
                self?.receive()
            case .cancelled:
                self?.log("Client disconnected.")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.drainLines()
            }
            if !isComplete {
                self.receive()
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8), !text.isEmpty else {
                continue
            }
            log("Client: \(text)")
            handle(text)
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let id = object["id"] as? Int else {
            return
        }

        switch method {
        case "mining.subscribe":
            send(["id": id, "result": ["mock-session", "abcdef1234567890"], "error": NSNull()])
            send(["id": NSNull(), "method": "mining.set_difficulty", "params": [0.001]])
            send([
                "id": NSNull(),
                "method": "mining.set_target",
                "params": [String(repeating: "f", count: 64)]
            ])
        case "mining.authorize":
            send(["id": id, "result": true, "error": NSNull()])
            send([
                "id": NSNull(),
                "method": "mining.notify",
                "params": [
                    "mock-job-1",
                    "04000000",
                    "0000000000000000000000000000000000000000000000000000000000000000",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                    "1d00ffff",
                    "ffff001d",
                    true
                ]
            ])
        case "mining.submit":
            send(["id": id, "result": true, "error": NSNull()])
        default:
            send(["id": id, "result": NSNull(), "error": ["unknown method \(method)"]])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        var line = data
        line.append(0x0a)
        connection.send(content: line, completion: .contentProcessed { _ in })
        if let text = String(data: data, encoding: .utf8) {
            log("Server: \(text)")
        }
    }
}
