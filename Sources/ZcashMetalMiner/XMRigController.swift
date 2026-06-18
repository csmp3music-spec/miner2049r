import Foundation

@MainActor
final class XMRigController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "XMRig idle."
    @Published private(set) var acceptedShares = 0
    @Published private(set) var rejectedShares = 0
    @Published private(set) var latestHashrate = ""
    @Published private(set) var telemetrySource = "Log parser"
    @Published private(set) var apiStatus = "XMRig API disabled."
    @Published private(set) var logs: [String] = ["XMRig backend idle."]

    private var process: Process?
    private var pipe: Pipe?
    private var apiTask: Task<Void, Never>?
    private var partialLine = ""
    private let apiHost = "127.0.0.1"
    private let apiPort = 20_490

    static func defaultExecutablePath() -> String {
        for path in [
            "/opt/homebrew/bin/xmrig",
            "/usr/local/bin/xmrig",
            "/usr/bin/xmrig"
        ] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "xmrig"
    }

    func start(
        executablePath: String,
        algorithm: String,
        poolURL: String,
        username: String,
        password: String,
        threads: Int,
        usesTLS: Bool
    ) {
        stop()

        let normalizedPool = normalizePoolURL(poolURL)
        guard !normalizedPool.isEmpty else {
            status = "XMRig pool URL is required."
            append("Invalid XMRig pool URL.")
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "XMRig user/wallet is required."
            append("Missing XMRig user/wallet.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = [
            "--algo=\(algorithm)",
            "--url=\(normalizedPool)",
            "--user=\(username)",
            "--pass=\(password.isEmpty ? "x" : password)",
            "--keepalive",
            "--no-color",
            "--print-time=2",
            "--cpu-priority=2",
            "--cpu-max-threads-hint=100",
            "--cpu-memory-pool=-1",
            "--cpu-no-yield",
            "--http-host=\(apiHost)",
            "--http-port=\(apiPort)"
        ]
        if algorithm.hasPrefix("rx/") {
            arguments.append("--randomx-mode=fast")
            arguments.append("--randomx-init=-1")
            arguments.append("--huge-pages-jit")
        }
        if usesTLS {
            arguments.append("--tls")
        }
        if threads > 0 {
            arguments.append("--threads=\(threads)")
        }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process
        self.pipe = pipe
        self.partialLine = ""
        self.acceptedShares = 0
        self.rejectedShares = 0
        self.latestHashrate = ""
        self.telemetrySource = "Log parser"
        self.apiStatus = "XMRig API starting on \(apiHost):\(apiPort)."

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.consume(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.pipe?.fileHandleForReading.readabilityHandler = nil
                self?.isRunning = false
                self?.status = "XMRig exited with status \(process.terminationStatus)."
                self?.append("XMRig exited with status \(process.terminationStatus).")
                self?.process = nil
                self?.pipe = nil
                self?.apiTask?.cancel()
                self?.apiTask = nil
            }
        }

        do {
            try process.run()
            isRunning = true
            status = "XMRig running on \(normalizedPool)."
            append("Started XMRig: \(executablePath) \(arguments.joined(separator: " "))")
            startAPIPolling()
        } catch {
            self.process = nil
            self.pipe = nil
            status = "Could not start XMRig: \(error.localizedDescription)"
            append(status)
        }
    }

    func startCustom(
        executablePath: String,
        arguments: [String],
        backendName: String
    ) {
        stop()

        let trimmedPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            status = "External miner executable is required."
            append("Missing external miner executable.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: trimmedPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process
        self.pipe = pipe
        self.partialLine = ""
        self.acceptedShares = 0
        self.rejectedShares = 0
        self.latestHashrate = ""
        self.telemetrySource = "Log parser"
        self.apiStatus = "External miner API unavailable."

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.consume(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.pipe?.fileHandleForReading.readabilityHandler = nil
                self?.isRunning = false
                self?.status = "\(backendName) exited with status \(process.terminationStatus)."
                self?.append("\(backendName) exited with status \(process.terminationStatus).")
                self?.process = nil
                self?.pipe = nil
                self?.apiTask?.cancel()
                self?.apiTask = nil
            }
        }

        do {
            try process.run()
            isRunning = true
            status = "\(backendName) running."
            append("Started \(backendName): \(trimmedPath) \(arguments.joined(separator: " "))")
        } catch {
            self.process = nil
            self.pipe = nil
            status = "Could not start \(backendName): \(error.localizedDescription)"
            append(status)
        }
    }

    func stop() {
        apiTask?.cancel()
        apiTask = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            status = "Stopping XMRig..."
        }
        process = nil
        pipe = nil
        isRunning = false
        apiStatus = "XMRig API stopped."
    }

    private func startAPIPolling() {
        apiTask?.cancel()
        apiTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.pollSummaryAPI()
            }
        }
    }

    private func pollSummaryAPI() async {
        guard isRunning else { return }
        guard let url = URL(string: "http://\(apiHost):\(apiPort)/2/summary") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                apiStatus = "XMRig API returned HTTP \(http.statusCode)."
                return
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                apiStatus = "XMRig API returned invalid JSON."
                return
            }
            applySummary(object)
            apiStatus = "XMRig API connected on \(apiHost):\(apiPort)."
            telemetrySource = "XMRig HTTP API"
        } catch {
            apiStatus = "Waiting for XMRig API: \(error.localizedDescription)"
        }
    }

    private func applySummary(_ object: [String: Any]) {
        if let results = object["results"] as? [String: Any] {
            if let accepted = results["accepted"] as? Int {
                acceptedShares = accepted
            }
            if let rejected = results["rejected"] as? Int {
                rejectedShares = rejected
            }
        }

        if let hashrate = object["hashrate"] as? [String: Any],
           let total = hashrate["total"] as? [Any] {
            let values = total.compactMap { value -> Double? in
                if let number = value as? Double {
                    return number
                }
                if let number = value as? Int {
                    return Double(number)
                }
                return nil
            }
            if let current = values.first {
                latestHashrate = "API hashrate \(Self.hashrateLabel(current))"
            }
        }
    }

    private func consume(_ text: String) {
        partialLine += text
        let parts = partialLine.split(separator: "\n", omittingEmptySubsequences: false)
        partialLine = parts.last.map(String.init) ?? ""
        for part in parts.dropLast() {
            let line = String(part).trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { continue }
            record(line)
        }
    }

    private func record(_ line: String) {
        append(line)
        let lower = line.lowercased()
        if lower.contains("accepted") {
            acceptedShares += 1
            status = "XMRig share accepted."
        } else if lower.contains("rejected") {
            rejectedShares += 1
            status = "XMRig share rejected."
        } else if lower.contains("speed") || lower.contains("h/s") {
            latestHashrate = line
        }
    }

    private func append(_ line: String) {
        let stamp = XMRigController.logStamp.string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func normalizePoolURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let components = URLComponents(string: trimmed), components.host != nil {
            let host = components.host ?? ""
            if let port = components.port {
                return "\(host):\(port)"
            }
            return host
        }
        return trimmed
            .replacingOccurrences(of: "stratum+tcp://", with: "")
            .replacingOccurrences(of: "stratum+ssl://", with: "")
            .replacingOccurrences(of: "stratum+tls://", with: "")
    }

    private static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func hashrateLabel(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2f MH/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.2f kH/s", value / 1_000)
        }
        return String(format: "%.2f H/s", value)
    }
}
