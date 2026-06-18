import Foundation
import Metal

struct MinerTelemetrySample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let rowRate: Double
    let totalRows: UInt64
    let acceptedShares: Int
    let rejectedShares: Int
}

struct SolverTuningResult: Identifiable, Equatable {
    let id = UUID()
    let bucketSlots: Int
    let threadgroupMultiplier: Int
    let memoryBudgetBytes: Int
    let rowCount: Int
    let completedRounds: Int
    let outputRows: Int
    let elapsedSeconds: TimeInterval
    let rowsPerSecond: Double
    let overflow: Bool

    var score: Double {
        let roundWeight = Double(completedRounds) * 1_000_000_000
        let overflowPenalty = overflow ? -1_000_000_000_000.0 : 0.0
        let memoryPenalty = Double(memoryBudgetBytes) / 1_000_000.0
        return overflowPenalty + roundWeight + rowsPerSecond - memoryPenalty
    }
}

@MainActor
final class MinerViewModel: ObservableObject {
    @Published var selectedAlgorithm: MiningAlgorithm = .equihash200_9 {
        didSet {
            if oldValue != selectedAlgorithm {
                if isMining {
                    stopMining()
                }
                poolDraft.poolURL = selectedAlgorithm.defaultPoolURL
                if selectedAlgorithm == .equihash200_9 {
                    poolDraft.password = StratumConfiguration.miningDutchLowDifficultyPassword
                }
                poolDraft.mode = selectedAlgorithm.stratumMode
                normalizePoolDraftForSelectedPool()
                applyPoolDraft()
            }
        }
    }
    @Published var headerHex = "00000020f1b6b2d41d5f7b733f7f5b9e9f4b2c6a3f7d92a2000000000000000000000000"
    @Published var batchSize = 65_536.0
    @Published var hashesPerThread = 4.0
    @Published var threadgroupMultiplier = 4
    @Published var miningPipelineDepth = 4
    @Published var miningMemoryBudgetGB = 4.0
    @Published var miningCooldownMilliseconds = 0.0
    @Published var miningMaxJobAgeSeconds = 20.0
    @Published private(set) var gpuName = "Detecting GPU..."
    @Published private(set) var gpuLimits = ""
    @Published private(set) var benchmarkStatus = "Idle"
    @Published private(set) var latestResult: GeneratorResult?
    @Published private(set) var latestRowResult: MetalRowGenerationResult?
    @Published private(set) var latestRoundOneResult: MetalRoundOneResult?
    @Published private(set) var tuningResults: [TuningResult] = []
    @Published private(set) var solverTuningResults: [SolverTuningResult] = []
    @Published private(set) var isBenchmarking = false
    @Published private(set) var isTuning = false
    @Published private(set) var isGeneratingRows = false
    @Published private(set) var isMining = false
    @Published private(set) var acceptedShares = 0
    @Published private(set) var rejectedShares = 0
    @Published private(set) var nonceAttempts = UInt64(0)
    @Published private(set) var lastGpuCompletedRounds = 0
    @Published private(set) var gpuCandidateSolutions = UInt64(0)
    @Published private(set) var submittedShares = UInt64(0)
    @Published private(set) var gpuOverflowSkips = UInt64(0)
    @Published private(set) var gpuIncompleteSkips = UInt64(0)
    @Published private(set) var staleShareSkips = UInt64(0)
    @Published private(set) var noSolutionAttempts = UInt64(0)
    @Published private(set) var localRejectedCandidates = UInt64(0)
    @Published private(set) var lastSubmitStatus = "No shares submitted."
    @Published private(set) var totalHashes: UInt64 = 0
    @Published private(set) var averageRate: Double = 0
    @Published private(set) var telemetrySamples: [MinerTelemetrySample] = []
    @Published private(set) var runtimeStatus = "Stopped"
    @Published private(set) var isSolvingEquihash = false
    @Published private(set) var solverStatus = "GPU reference solver idle."
    @Published private(set) var latestSolutionHex: String?
    @Published private(set) var isShareMining = false
    @Published private(set) var shareMinerStatus = "GPU reference share miner idle."
    @Published private(set) var currentNonce2 = ""
    @Published private(set) var lastShareHash = ""
    @Published var gpuRowSampleCount = 262_144.0
    @Published var roundOneBucketSlots = 64.0
    @Published var externalMinerExecutable = ""
    @Published var externalMinerArguments = "--algo {algo} --url {pool} --user {user} --pass {password}"
    @Published var poolDraft = StratumConfiguration()

    @Published var stratum = StratumController()
    @Published var mockPool = MockStratumServer()
    @Published var xmrig = XMRigController()

    private var generator: MetalEquihashGenerator?
    private var rowGenerator: MetalEquihashRowGenerator?
    private var miningTask: Task<Void, Never>?
    private var solverTask: Task<Void, Never>?
    private var shareMiningTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?

    init() {
        do {
            let generator = try MetalEquihashGenerator()
            self.generator = generator
            self.rowGenerator = try? MetalEquihashRowGenerator(device: generator.device)
            gpuName = generator.deviceName
            gpuLimits = "SIMD width \(generator.executionWidth), max threads/threadgroup \(generator.maxThreadsPerThreadgroup)"
        } catch {
            gpuName = "Metal unavailable"
            benchmarkStatus = error.localizedDescription
        }

        if let saved = ConfigurationStore.load() {
            selectedAlgorithm = saved.selectedAlgorithm
            headerHex = saved.headerHex
            batchSize = saved.batchSize
            hashesPerThread = saved.hashesPerThread
            threadgroupMultiplier = saved.threadgroupMultiplier
            miningPipelineDepth = (saved.miningPipelineDepth ?? miningPipelineDepth).clamped(to: 1...8)
            miningMemoryBudgetGB = (saved.miningMemoryBudgetGB ?? miningMemoryBudgetGB).clamped(to: 1...16)
            miningCooldownMilliseconds = (saved.miningCooldownMilliseconds ?? miningCooldownMilliseconds).clamped(to: 0...1_000)
            miningMaxJobAgeSeconds = (saved.miningMaxJobAgeSeconds ?? miningMaxJobAgeSeconds).clamped(to: 5...120)
            externalMinerExecutable = saved.externalMinerExecutable ?? externalMinerExecutable
            externalMinerArguments = saved.externalMinerArguments ?? externalMinerArguments
            poolDraft.poolURL = saved.poolURL
            poolDraft.username = saved.username
            poolDraft.password = saved.password
            poolDraft.mode = saved.selectedAlgorithm.stratumMode
            if saved.poolURL.contains("europe.mining-nl")
                || saved.poolURL.contains("equihash.mining-dutch.nl") {
                poolDraft.poolURL = MiningAlgorithm.equihash200_9.defaultPoolURL
            }
            var migratedSavedConfig = false
            if poolDraft.poolURL.contains("mining-dutch.nl"),
               (poolDraft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || poolDraft.password == "x"
                || poolDraft.password == StratumConfiguration.miningDutchLegacyLowDifficultyPassword) {
                poolDraft.password = StratumConfiguration.miningDutchLowDifficultyPassword
                migratedSavedConfig = true
            }
            if poolDraft.poolURL.contains("mining-dutch.nl") {
                let savedUsername = poolDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
                if savedUsername.isEmpty || savedUsername == "test.worker" {
                    poolDraft.username = StratumConfiguration.miningDutchDefaultUsername
                    migratedSavedConfig = true
                }
            }
            applyPoolDraft()
            if migratedSavedConfig {
                saveConfiguration()
            }
        }

        recordTelemetrySample()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.recordTelemetrySample()
            }
        }
    }

    deinit {
        miningTask?.cancel()
        solverTask?.cancel()
        shareMiningTask?.cancel()
        telemetryTask?.cancel()
    }

    var canRunSelectedAlgorithm: Bool {
        selectedAlgorithm.engineStatus.canRunGpuBenchmark && generator != nil
    }

    var selectedEngine: MiningEngineDescriptor {
        MiningEngineRegistry.descriptor(for: selectedAlgorithm)
    }

    var poolTargetSummary: String {
        guard let target = stratum.target else {
            return "No pool target assigned yet."
        }
        return ZcashShareValidator.targetHardnessLabel(targetHex: target)
    }

    var acceptedShareEstimate: String {
        guard let target = stratum.target else {
            return "Waiting for mining.set_target before estimating accepted shares."
        }
        let attemptsPerSecond = averageRate > 0
            ? averageRate / Double(EquihashParameters.zcash.inputIndexCount)
            : 0
        return ZcashShareValidator.targetWorkEstimate(targetHex: target, attemptsPerSecond: attemptsPerSecond)
    }

    var poolConfigIsValid: Bool {
        normalizedPoolConfiguration(from: poolDraft).endpoint != nil
            && !normalizedPoolConfiguration(from: poolDraft).username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedAlgorithmCanMine: Bool {
        selectedAlgorithm.canStartMining
    }

    var selectedAlgorithmUsesExternalMiner: Bool {
        selectedAlgorithm.usesExternalMiner
    }

    var poolDraftHasChanges: Bool {
        normalizedPoolConfiguration(from: poolDraft) != stratum.configuration
    }

    var activePoolSummary: String {
        guard let endpoint = stratum.configuration.endpoint else {
            return "No active pool."
        }
        let transport = endpoint.usesTLS ? "TLS" : "TCP"
        return "\(endpoint.host):\(endpoint.port) \(transport) as \(stratum.configuration.username)"
    }

    var externalMinerCommandPreview: String {
        guard selectedAlgorithmUsesExternalMiner,
              let endpoint = normalizedPoolConfiguration(from: poolDraft).endpoint else {
            return "Enter a valid pool to preview the command."
        }
        if let xmrigAlgorithm = selectedAlgorithm.xmrigAlgorithm {
            var preview = [
                XMRigController.defaultExecutablePath(),
                "--algo=\(xmrigAlgorithm)",
                "--url=\(endpoint.host):\(endpoint.port)",
                "--user=\(poolDraft.username)",
                "--pass=\(poolDraft.password.isEmpty ? "x" : poolDraft.password)",
                "--keepalive",
                "--no-color",
                "--print-time=2",
                "--cpu-priority=2",
                "--cpu-max-threads-hint=100",
                "--cpu-memory-pool=-1",
                "--cpu-no-yield"
            ]
            if xmrigAlgorithm.hasPrefix("rx/") {
                preview.append("--randomx-mode=fast")
                preview.append("--randomx-init=-1")
                preview.append("--huge-pages-jit")
            }
            if endpoint.usesTLS {
                preview.append("--tls")
            }
            return preview.map(Self.shellQuoted).joined(separator: " ")
        }

        let executable = externalMinerExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            return "Set an external miner executable to preview the command."
        }
        return ([executable] + expandedExternalMinerArguments(endpoint: endpoint))
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    func savePoolDraft() {
        normalizePoolDraftForSelectedPool()
        saveConfiguration()
        runtimeStatus = "Pool draft saved. Active Stratum connection was not changed."
    }

    func applyPoolConfiguration() {
        normalizePoolDraftForSelectedPool()
        guard poolConfigIsValid else {
            runtimeStatus = poolDraft.validationMessage
            return
        }

        let wasMining = isShareMining
        let wasExternalMining = xmrig.isRunning
        let wasConnected = stratum.isConnected
        if wasMining {
            stopReferenceShareMiner()
        }
        if wasExternalMining {
            xmrig.stop()
        }

        applyPoolDraft()
        saveConfiguration()

        if wasMining {
            runtimeStatus = "Pool configuration applied. Restarting miner with updated Stratum settings."
            startReferenceShareMiner()
        } else if wasExternalMining {
            runtimeStatus = "Pool configuration applied. Restarting external miner with updated settings."
            startExternalMiner()
        } else if wasConnected {
            runtimeStatus = "Pool configuration applied. Reconnecting to updated Stratum endpoint."
            stratum.connect()
        } else {
            runtimeStatus = "Pool configuration applied."
        }
    }

    func connectToPool() {
        normalizePoolDraftForSelectedPool()
        applyPoolDraft()
        saveConfiguration()
        stratum.connect()
    }

    func resetPoolDraftFromActiveConfig() {
        poolDraft = stratum.configuration
    }

    func applyFastMiningPreset() {
        threadgroupMultiplier = 8
        miningPipelineDepth = 8
        miningMemoryBudgetGB = max(miningMemoryBudgetGB, 6.0).clamped(to: 1...16)
        miningCooldownMilliseconds = 0
        roundOneBucketSlots = max(roundOneBucketSlots, 128).clamped(to: 2...256)
        saveConfiguration()
        runtimeStatus = "Fast mining preset applied: 8-deep queue, 8x SIMD threadgroups, 128 bucket slots, zero cooldown."
    }

    private func applyPoolDraft() {
        stratum.configuration = normalizedPoolConfiguration(from: poolDraft)
    }

    private func normalizePoolDraftForSelectedPool() {
        poolDraft = normalizedPoolConfiguration(from: poolDraft)
    }

    private func normalizedPoolConfiguration(from configuration: StratumConfiguration) -> StratumConfiguration {
        var normalized = configuration
        normalized.poolURL = normalized.poolURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.username = normalized.username.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.mode = selectedAlgorithm.stratumMode
        guard normalized.poolURL.contains("mining-dutch.nl") else {
            return normalized
        }
        let username = normalized.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty || username == "test.worker" {
            normalized.username = StratumConfiguration.miningDutchDefaultUsername
        }
        return normalized
    }

    private func recordTelemetrySample() {
        if selectedAlgorithmUsesExternalMiner {
            acceptedShares = xmrig.acceptedShares
            rejectedShares = xmrig.rejectedShares
            if isMining && !xmrig.isRunning {
                isMining = false
            }
            runtimeStatus = xmrig.status
            shareMinerStatus = xmrig.status
        } else {
            acceptedShares = stratum.acceptedShares
            rejectedShares = stratum.rejectedShares
        }
        telemetrySamples.append(
            MinerTelemetrySample(
                timestamp: Date(),
                rowRate: averageRate,
                totalRows: totalHashes,
                acceptedShares: acceptedShares,
                rejectedShares: rejectedShares
            )
        )
        if telemetrySamples.count > 180 {
            telemetrySamples.removeFirst(telemetrySamples.count - 180)
        }
    }

    func runBenchmark() {
        guard canRunSelectedAlgorithm else {
            benchmarkStatus = selectedAlgorithm.implementationNote
            return
        }
        guard let generator else {
            benchmarkStatus = "No Metal generator is available."
            return
        }

        isBenchmarking = true
        benchmarkStatus = "Running Metal benchmark..."

        let headerText = headerHex
        let count = max(1, Int(batchSize))
        let selectedThreadgroup = (generator.executionWidth * threadgroupMultiplier)
            .clamped(to: generator.executionWidth...generator.maxThreadsPerThreadgroup)
        let runConfig = MiningRunConfiguration(
            threadgroupSize: selectedThreadgroup,
            hashesPerThread: max(1, Int(hashesPerThread))
        )
        Task.detached(priority: .userInitiated) {
            do {
                let header = try Data(hexString: headerText)
                let result = try generator.run(
                    header: header,
                    inputCount: count,
                    nonce: UInt32.random(in: 0..<UInt32.max),
                    configuration: runConfig
                )
                await MainActor.run {
                    self.latestResult = result
                    self.benchmarkStatus = result.cpuMatchesFirstDigest
                        ? "Benchmark complete. GPU output matches CPU reference."
                        : "Benchmark complete, but CPU reference mismatch."
                    self.isBenchmarking = false
                }
            } catch {
                await MainActor.run {
                    self.benchmarkStatus = error.localizedDescription
                    self.isBenchmarking = false
                }
            }
        }
    }

    func autotune() {
        guard selectedAlgorithm == .equihash200_9 else {
            benchmarkStatus = "Solver autotune currently supports Equihash 200,9."
            return
        }
        guard let rowGenerator else {
            benchmarkStatus = "No Metal row generator is available."
            return
        }

        isTuning = true
        benchmarkStatus = "Autotuning GPU reference solver bucket slots..."
        tuningResults = []
        solverTuningResults = []

        let headerText = headerHex
        let currentSlots = max(2, Int(roundOneBucketSlots))
        let rowCount = Int(gpuRowSampleCount).clamped(to: 65_536...262_144)
        let rounds = min(3, EquihashParameters.zcash.k)
        let currentMemoryBudget = Self.bytesFromGigabytes(miningMemoryBudgetGB)
        let recommendedMemoryBudget = rowGenerator.recommendedSolverMemoryBudgetBytes
        let memoryCandidates = Self.solverAutotuneMemoryCandidates(
            currentBytes: currentMemoryBudget,
            recommendedBytes: recommendedMemoryBudget
        )
        let threadgroupCandidates = Self.solverAutotuneThreadgroupCandidates(around: threadgroupMultiplier)
        let candidates = Self.solverAutotuneBucketCandidates(around: currentSlots)

        Task.detached(priority: .userInitiated) {
            do {
                let header = try Data(hexString: headerText)
                var results: [SolverTuningResult] = []
                results.reserveCapacity(candidates.count * memoryCandidates.count * threadgroupCandidates.count)

                for memoryBudget in memoryCandidates {
                    for threadgroupMultiplier in threadgroupCandidates {
                        for bucketSlots in candidates {
                            try Task.checkCancellation()
                            let generated = try rowGenerator.generateWagnerRows(
                                powHeader: header,
                                rounds: rounds,
                                rowCount: rowCount,
                                bucketSlots: bucketSlots,
                                memoryBudgetBytes: memoryBudget,
                                threadgroupMultiplier: threadgroupMultiplier,
                                exportIncompleteRows: false
                            )
                            let rowsPerSecond = generated.result.elapsedSeconds > 0
                                ? Double(rowCount) / generated.result.elapsedSeconds
                                : 0
                            results.append(
                                SolverTuningResult(
                                    bucketSlots: bucketSlots,
                                    threadgroupMultiplier: threadgroupMultiplier,
                                    memoryBudgetBytes: memoryBudget,
                                    rowCount: rowCount,
                                    completedRounds: generated.completedRounds,
                                    outputRows: generated.rows.count,
                                    elapsedSeconds: generated.result.elapsedSeconds,
                                    rowsPerSecond: rowsPerSecond,
                                    overflow: generated.result.overflow
                                )
                            )
                        }
                    }
                }

                results.sort { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.bucketSlots < rhs.bucketSlots
                    }
                    return lhs.score > rhs.score
                }
                let completedResults = results
                let bestResult = completedResults.first(where: { !$0.overflow })

                await MainActor.run {
                    self.solverTuningResults = completedResults
                    if let best = bestResult {
                        self.roundOneBucketSlots = Double(best.bucketSlots)
                        self.threadgroupMultiplier = best.threadgroupMultiplier
                        self.miningMemoryBudgetGB = Self.gigabytesFromBytes(best.memoryBudgetBytes)
                        self.miningPipelineDepth = min(self.miningPipelineDepth, 2)
                        self.benchmarkStatus = "Solver autotune complete. Best: \(best.bucketSlots) slots, \(best.threadgroupMultiplier)x SIMD, \(Self.memoryLabel(best.memoryBudgetBytes)), \(best.completedRounds) rounds, \(best.rowsPerSecond.compactRowRate)."
                        self.latestRoundOneResult = MetalRoundOneResult(
                            rowCount: best.rowCount,
                            elapsedSeconds: best.elapsedSeconds,
                            pairCount: best.outputRows,
                            expectedPairCount: best.outputRows,
                            bucketSlots: best.bucketSlots,
                            overflow: best.overflow,
                            firstPairKey: nil
                        )
                    } else {
                        self.benchmarkStatus = "Solver autotune found no non-overflowing bucket-slot setting."
                    }
                    self.isTuning = false
                }
            } catch {
                await MainActor.run {
                    self.benchmarkStatus = error.localizedDescription
                    self.isTuning = false
                }
            }
        }
    }

    func generateGpuInitialRows() {
        guard selectedAlgorithm == .equihash200_9 else {
            benchmarkStatus = "GPU row generation currently supports Equihash 200,9."
            return
        }
        guard let rowGenerator else {
            benchmarkStatus = "No Metal row generator is available."
            return
        }

        isGeneratingRows = true
        benchmarkStatus = "Generating Equihash initial rows on GPU..."
        let headerText = headerHex
        let rowCount = max(2, Int(gpuRowSampleCount))

        Task.detached(priority: .userInitiated) {
            do {
                let header = try Data(hexString: headerText)
                let (_, result) = try rowGenerator.generateRows(powHeader: header, rowCount: rowCount)
                await MainActor.run {
                    self.latestRowResult = result
                    self.benchmarkStatus = result.cpuMatchesFirstRow
                        ? "GPU row generation complete. First row matches CPU reference."
                        : "GPU row generation complete, but first row mismatched CPU reference."
                    self.isGeneratingRows = false
                }
            } catch {
                await MainActor.run {
                    self.benchmarkStatus = error.localizedDescription
                    self.isGeneratingRows = false
                }
            }
        }
    }

    func generateGpuRoundOnePairs() {
        guard selectedAlgorithm == .equihash200_9 else {
            benchmarkStatus = "GPU round-1 pairing currently supports Equihash 200,9."
            return
        }
        guard let rowGenerator else {
            benchmarkStatus = "No Metal row generator is available."
            return
        }

        isGeneratingRows = true
        benchmarkStatus = "Generating Equihash round-1 pairs on GPU..."
        let headerText = headerHex
        let rowCount = max(2, Int(gpuRowSampleCount))
        let bucketSlots = max(2, Int(roundOneBucketSlots))

        Task.detached(priority: .userInitiated) {
            do {
                let header = try Data(hexString: headerText)
                let result = try rowGenerator.generateRoundOnePairs(
                    powHeader: header,
                    rowCount: rowCount,
                    bucketSlots: bucketSlots
                )
                await MainActor.run {
                    self.latestRoundOneResult = result
                    self.benchmarkStatus = result.overflow
                        ? "GPU round-1 complete with overflow. Increase bucket slots or reduce rows."
                        : "GPU round-1 complete. Pair count matches CPU bucket count: \(result.matchesExpectedPairCount ? "yes" : "no")."
                    self.isGeneratingRows = false
                }
            } catch {
                await MainActor.run {
                    self.benchmarkStatus = error.localizedDescription
                    self.isGeneratingRows = false
                }
            }
        }
    }

    func startMining() {
        if selectedAlgorithm == .equihash200_9 {
            startReferenceShareMiner()
            return
        }
        startExternalMiner()
    }

    func stopMining() {
        if xmrig.isRunning {
            xmrig.stop()
        }
        stopReferenceShareMiner()
        if selectedAlgorithmUsesExternalMiner {
            runtimeStatus = "Stopped"
            shareMinerStatus = "\(selectedAlgorithm.name) external backend stopped."
        }
    }

    func startExternalMiner() {
        normalizePoolDraftForSelectedPool()
        guard poolConfigIsValid, let endpoint = normalizedPoolConfiguration(from: poolDraft).endpoint else {
            runtimeStatus = poolDraft.validationMessage
            shareMinerStatus = poolDraft.validationMessage
            return
        }

        if stratum.isConnected {
            stratum.disconnect()
        }
        applyPoolDraft()
        saveConfiguration()

        isMining = true
        isShareMining = false
        acceptedShares = 0
        rejectedShares = 0
        submittedShares = 0
        runtimeStatus = "Starting \(selectedAlgorithm.name) miner."
        shareMinerStatus = "\(selectedAlgorithm.name) backend starting."
        if let xmrigAlgorithm = selectedAlgorithm.xmrigAlgorithm {
            xmrig.start(
                executablePath: XMRigController.defaultExecutablePath(),
                algorithm: xmrigAlgorithm,
                poolURL: poolDraft.poolURL,
                username: poolDraft.username,
                password: poolDraft.password,
                threads: 0,
                usesTLS: endpoint.usesTLS
            )
        } else {
            let executable = externalMinerExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty else {
                runtimeStatus = "Set an external miner executable before starting \(selectedAlgorithm.name)."
                shareMinerStatus = runtimeStatus
                isMining = false
                return
            }
            xmrig.startCustom(
                executablePath: executable,
                arguments: expandedExternalMinerArguments(endpoint: endpoint),
                backendName: "\(selectedAlgorithm.name) external miner"
            )
        }
        isMining = xmrig.isRunning
        runtimeStatus = xmrig.status
        shareMinerStatus = xmrig.status
    }

    private func expandedExternalMinerArguments(endpoint: (host: String, port: UInt16, usesTLS: Bool)) -> [String] {
        let password = poolDraft.password.isEmpty ? "x" : poolDraft.password
        let replacements = [
            "{algo}": selectedAlgorithm.externalMinerAlgorithmName,
            "{pool}": "\(endpoint.host):\(endpoint.port)",
            "{pool_url}": poolDraft.poolURL,
            "{host}": endpoint.host,
            "{port}": "\(endpoint.port)",
            "{user}": poolDraft.username,
            "{password}": password,
            "{tls}": endpoint.usesTLS ? "true" : "false"
        ]
        return Self.splitArguments(externalMinerArguments).map { argument in
            replacements.reduce(argument) { value, item in
                value.replacingOccurrences(of: item.key, with: item.value)
            }
        }
    }

    private static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=+-{}")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runReferenceEquihashSolver() {
        guard selectedAlgorithm == .equihash200_9 else {
            solverStatus = "The GPU reference solver currently targets Equihash 200,9."
            return
        }
        guard !isSolvingEquihash else {
            return
        }

        isSolvingEquihash = true
        latestSolutionHex = nil
        solverStatus = "Starting GPU reference Equihash 200,9 solve."
        let headerText = headerHex
        let rowGenerator = self.rowGenerator
        let bucketSlots = max(32, Int(roundOneBucketSlots))
        let started = CFAbsoluteTimeGetCurrent()

        solverTask = Task.detached(priority: .utility) {
            do {
                let header = try Data(hexString: headerText)
                let solver = EquihashSolver(parameters: .zcash)

                var solutions: [EquihashSolution]
                if let rowGenerator {
                    await MainActor.run {
                        self.solverStatus = "Generating budgeted Metal Wagner rounds for GPU reference solve."
                    }
                    let generated = try rowGenerator.generateWagnerRows(
                        powHeader: header,
                        rounds: EquihashParameters.zcash.k,
                        bucketSlots: bucketSlots,
                        memoryBudgetBytes: rowGenerator.recommendedSolverMemoryBudgetBytes
                    )
                    var metalRows = generated.rows
                    let completedRounds = generated.completedRounds
                    let metalRowCount = metalRows.count
                    let nextRound = completedRounds + 1
                    let solverStage = completedRounds >= EquihashParameters.zcash.k
                        ? "validating final Metal candidates"
                        : "running Swift reference rounds \(nextRound)-\(EquihashParameters.zcash.k)"

                    await MainActor.run {
                        self.latestRoundOneResult = generated.result
                        self.totalHashes &+= UInt64(EquihashParameters.zcash.inputIndexCount)
                        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - started)
                        self.averageRate = Double(self.totalHashes) / elapsed
                        self.solverStatus = "Metal completed \(completedRounds)/\(EquihashParameters.zcash.k) rounds and produced \(metalRowCount) rows; \(solverStage)."
                    }

                    guard !generated.result.overflow else {
                        metalRows.removeAll(keepingCapacity: false)
                        await MainActor.run {
                            self.solverStatus = "Metal collision rounds overflowed at \(bucketSlots) bucket slots."
                            self.isSolvingEquihash = false
                        }
                        return
                    }

                    if completedRounds >= EquihashParameters.zcash.k {
                        solutions = try solver.trustedSolutionsFromGpuFinalRows(metalRows)
                        let solutionCount = solutions.count
                        await MainActor.run {
                            self.solverStatus = "GPU-resident final validation produced \(solutionCount) compact candidate solution(s)."
                        }
                    } else {
                        solutions = try solver.solve(
                            powHeader: header,
                            partialRows: metalRows,
                            startingRound: completedRounds
                        ) { progress in
                            Task { @MainActor in
                                self.solverStatus = progress.message
                            }
                        }
                    }
                    metalRows.removeAll(keepingCapacity: false)
                } else {
                    await MainActor.run {
                        self.solverStatus = "Metal unavailable; running Swift reference solver."
                    }
                    solutions = try solver.solve(powHeader: header) { progress in
                        Task { @MainActor in
                            self.solverStatus = progress.message
                        }
                    }
                }

                let firstSolution = solutions.first
                solutions.removeAll(keepingCapacity: false)

                await MainActor.run {
                    if let solution = firstSolution {
                        self.latestSolutionHex = solution.encoded.hexString()
                        self.solverStatus = "GPU reference solver found Equihash solution with \(solution.indices.count) indices."
                    } else {
                        self.solverStatus = "GPU reference solver found no Equihash solution for this header."
                    }
                    self.isSolvingEquihash = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.solverStatus = "GPU reference solver cancelled."
                    self.isSolvingEquihash = false
                }
            } catch {
                await MainActor.run {
                    self.solverStatus = error.localizedDescription
                    self.isSolvingEquihash = false
                }
            }
        }
    }

    func cancelReferenceEquihashSolver() {
        solverTask?.cancel()
        solverTask = nil
        isSolvingEquihash = false
        solverStatus = "GPU reference solver cancelled."
    }

    func startReferenceShareMiner() {
        guard selectedAlgorithm == .equihash200_9 else {
            shareMinerStatus = "GPU reference share mining currently supports Equihash 200,9 only."
            return
        }
        guard !isShareMining else {
            return
        }
        normalizePoolDraftForSelectedPool()
        guard poolConfigIsValid else {
            runtimeStatus = poolDraft.validationMessage
            shareMinerStatus = poolDraft.validationMessage
            return
        }

        if !stratum.isConnected {
            connectToPool()
        }

        isShareMining = true
        isMining = true
        totalHashes = 0
        averageRate = 0
        nonceAttempts = 0
        lastGpuCompletedRounds = 0
        gpuCandidateSolutions = 0
        submittedShares = 0
        gpuOverflowSkips = 0
        gpuIncompleteSkips = 0
        staleShareSkips = 0
        noSolutionAttempts = 0
        localRejectedCandidates = 0
        lastSubmitStatus = "No shares submitted."
        acceptedShares = stratum.acceptedShares
        rejectedShares = stratum.rejectedShares
        telemetrySamples = []
        recordTelemetrySample()
        runtimeStatus = "Pool mining active. Waiting for live Stratum work."
        shareMinerStatus = "GPU reference share miner armed. Waiting for authorization, target, nonce1, and job."
        latestSolutionHex = nil
        let rowGenerator = self.rowGenerator
        let miningRoundOneBucketSlots = Int(roundOneBucketSlots).clamped(to: 2...256)
        let miningMemoryBudgetBytes = Self.bytesFromGigabytes(self.miningMemoryBudgetGB)
        let miningThreadgroupMultiplier = self.threadgroupMultiplier.clamped(to: 1...8)
        let miningPipelineDepth = self.miningPipelineDepth.clamped(to: 1...8)
        let miningCooldownNanoseconds = UInt64(max(0, self.miningCooldownMilliseconds) * 1_000_000)
        let miningMaxJobAgeSeconds = self.miningMaxJobAgeSeconds.clamped(to: 5...120)

        shareMiningTask = Task.detached(priority: .utility) {
            let solver = EquihashSolver(parameters: .zcash)
            var nonce2Counter: UInt64 = UInt64.random(in: 0..<UInt64.max)
            var nonce2Attempts: UInt64 = 0
            let nonce2Entropy = Self.randomNonce2Entropy()
            let started = CFAbsoluteTimeGetCurrent()

            while !Task.isCancelled {
                do {
                    let state = try await self.waitForMiningState()
                    let job = state.job
                    let nonce1Copy = state.nonce1
                    let jobSequence = state.jobSequence
                    let workEpoch = state.workEpoch
                    let jobReceivedAt = state.jobReceivedAt
                    let pipelineDepth = rowGenerator == nil ? 1 : miningPipelineDepth
                    let attempts = try Self.makeMiningAttempts(
                        job: job,
                        jobSequence: jobSequence,
                        workEpoch: workEpoch,
                        jobReceivedAt: jobReceivedAt,
                        nonce1: nonce1Copy,
                        target: state.target,
                        startingCounter: nonce2Counter,
                        startingAttemptNumber: nonce2Attempts + 1,
                        count: pipelineDepth,
                        nonce2Entropy: nonce2Entropy
                    )
                    nonce2Counter &+= UInt64(attempts.count)
                    nonce2Attempts &+= UInt64(attempts.count)

                    await MainActor.run {
                        self.runtimeStatus = "Pool mining active. Prepared \(attempts.count)-nonce pipeline for job \(job.id), \(Self.memoryLabel(miningMemoryBudgetBytes)) budget, \(miningThreadgroupMultiplier)x SIMD."
                    }

                    for attempt in attempts {
                        try Task.checkCancellation()
                        let freshness = await self.freshness(for: attempt, maxAgeSeconds: miningMaxJobAgeSeconds)
                        let jobIsCurrent = freshness.isFresh
                        guard jobIsCurrent else {
                            await MainActor.run {
                                self.staleShareSkips &+= 1
                                self.shareMinerStatus = "\(freshness.reason); discarding queued nonce pipeline for \(attempt.job.id)."
                            }
                            break
                        }

                        let job = attempt.job
                        let header = attempt.header
                        let nonce2 = attempt.nonce2
                        let attemptNumber = attempt.attemptNumber

                        await MainActor.run {
                            self.nonceAttempts &+= 1
                            self.currentNonce2 = nonce2
                            self.runtimeStatus = "Pool mining active. Attempt \(attemptNumber) on job \(job.id)."
                            self.shareMinerStatus = "Solving pipelined job \(job.id), nonce2 \(nonce2.prefix(16))..."
                        }

                        var solutions: [EquihashSolution]
                        if let rowGenerator {
                        await MainActor.run {
                            self.shareMinerStatus = "Generating budgeted Equihash collision rounds on Metal for job \(job.id)."
                        }
                        var solveBucketSlots = miningRoundOneBucketSlots
                        var generated = try rowGenerator.generateWagnerRows(
                            powHeader: header,
                            rounds: EquihashParameters.zcash.k,
                            bucketSlots: solveBucketSlots,
                            memoryBudgetBytes: miningMemoryBudgetBytes,
                            threadgroupMultiplier: miningThreadgroupMultiplier,
                            exportIncompleteRows: false
                        )
                        while generated.result.overflow && solveBucketSlots < 256 {
                            solveBucketSlots *= 2
                            let retrySlots = solveBucketSlots
                            await MainActor.run {
                                self.shareMinerStatus = "Metal buckets overflowed; retrying job \(job.id) with \(retrySlots) bucket slots."
                            }
                            generated = try rowGenerator.generateWagnerRows(
                                powHeader: header,
                                rounds: EquihashParameters.zcash.k,
                                bucketSlots: solveBucketSlots,
                                memoryBudgetBytes: miningMemoryBudgetBytes,
                                threadgroupMultiplier: miningThreadgroupMultiplier,
                                exportIncompleteRows: false
                            )
                        }
                        var metalRows = generated.rows
                        let completedRounds = generated.completedRounds
                        let metalRowCount = metalRows.count
                        let metalResult = generated.result
                        let metalPairRate = metalResult.pairsPerSecond.compactPairRate
                        let gpuStatus = completedRounds >= EquihashParameters.zcash.k
                            ? "validating final Metal candidates"
                            : "GPU stopped before final round"
                        await MainActor.run {
                            self.latestRoundOneResult = metalResult
                            self.totalHashes &+= UInt64(EquihashParameters.zcash.inputIndexCount)
                            self.lastGpuCompletedRounds = completedRounds
                            let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - started)
                            self.averageRate = Double(self.totalHashes) / elapsed
                            self.runtimeStatus = "Pool mining active. Metal completed \(completedRounds)/\(EquihashParameters.zcash.k) rounds for attempt \(attemptNumber)."
                            self.shareMinerStatus = "Metal produced \(metalRowCount) candidate rows at \(metalPairRate); \(gpuStatus)."
                        }
                        guard !metalResult.overflow else {
                            metalRows.removeAll(keepingCapacity: false)
                            let finalBucketSlots = solveBucketSlots
                            await MainActor.run {
                                self.gpuOverflowSkips &+= 1
                                self.runtimeStatus = "Metal collision rounds overflowed; increase bucket slots before mining."
                                self.shareMinerStatus = "Metal collision rounds still overflowed at \(finalBucketSlots) bucket slots; skipping nonce2 \(nonce2.prefix(16))."
                            }
                            if miningCooldownNanoseconds > 0 {
                                try? await Task.sleep(nanoseconds: miningCooldownNanoseconds)
                            }
                            continue
                        }
                        guard completedRounds >= EquihashParameters.zcash.k else {
                            metalRows.removeAll(keepingCapacity: false)
                            await MainActor.run {
                                self.gpuIncompleteSkips &+= 1
                                self.runtimeStatus = "Pool mining active. GPU stopped at round \(completedRounds); skipping CPU fallback."
                                self.shareMinerStatus = "GPU did not reach final Equihash round for nonce2 \(nonce2.prefix(16)); skipping instead of freezing in CPU solver."
                            }
                            if miningCooldownNanoseconds > 0 {
                                try? await Task.sleep(nanoseconds: miningCooldownNanoseconds)
                            }
                            continue
                        }
                        solutions = try solver.trustedSolutionsFromGpuFinalRows(metalRows)
                        let solutionCount = solutions.count
                        await MainActor.run {
                            self.gpuCandidateSolutions &+= UInt64(solutionCount)
                            self.runtimeStatus = "Mining job \(job.id): GPU final validation complete."
                            self.shareMinerStatus = "GPU-resident final validation produced \(solutionCount) compact candidate solution(s)."
                        }
                        metalRows.removeAll(keepingCapacity: false)
                        } else {
                        solutions = try solver.solve(powHeader: header) { progress in
                            Task { @MainActor in
                                if progress.round == 0 {
                                    self.totalHashes = UInt64(progress.rowCount)
                                    let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - started)
                                    self.averageRate = Double(self.totalHashes) / elapsed
                                }
                                self.runtimeStatus = "Mining job \(job.id): \(progress.message)"
                                self.shareMinerStatus = "Job \(job.id): \(progress.message)"
                            }
                        }
                        }

                        guard !solutions.isEmpty else {
                            solutions.removeAll(keepingCapacity: false)
                            await MainActor.run {
                                self.noSolutionAttempts &+= 1
                                self.runtimeStatus = "Pool mining active. Attempt \(attemptNumber) found no Equihash solution."
                                self.shareMinerStatus = "No solution for nonce2 \(nonce2.prefix(16)); advancing nonce pipeline."
                            }
                            if miningCooldownNanoseconds > 0 {
                                try? await Task.sleep(nanoseconds: miningCooldownNanoseconds)
                            }
                            continue
                        }
                        let candidateSolutions = solutions
                        solutions.removeAll(keepingCapacity: false)
                        let postSolveFreshness = await self.freshness(for: attempt, maxAgeSeconds: miningMaxJobAgeSeconds)
                        guard postSolveFreshness.isFresh,
                              let validationTarget = postSolveFreshness.target,
                              !validationTarget.isEmpty else {
                            await MainActor.run {
                                self.staleShareSkips &+= UInt64(candidateSolutions.count)
                                self.runtimeStatus = "Discarded stale candidate(s) before validation."
                                self.shareMinerStatus = "\(postSolveFreshness.reason); discarded \(candidateSolutions.count) candidate(s) for job \(job.id)."
                            }
                            if miningCooldownNanoseconds > 0 {
                                try? await Task.sleep(nanoseconds: miningCooldownNanoseconds)
                            }
                            continue
                        }
                        var validSubmissions: [(submission: ZcashSubmission, solution: EquihashSolution, hashHex: String)] = []
                        validSubmissions.reserveCapacity(candidateSolutions.count)
                        var invalidCandidates = 0
                        var aboveTargetCandidates = 0
                        var targetCheckFailures = 0

                        for solution in candidateSolutions {
                            do {
                                try solver.validate(powHeader: header, solution: solution)
                            } catch {
                                invalidCandidates += 1
                                continue
                            }

                            guard let shareCheck = try? ZcashShareValidator.check(
                                powHeader: header,
                                solution: solution,
                                targetHex: validationTarget
                            ) else {
                                targetCheckFailures += 1
                                continue
                            }
                            guard shareCheck.meetsTarget else {
                                aboveTargetCandidates += 1
                                continue
                            }

                            validSubmissions.append((
                                submission: ZcashSubmission(
                                    jobID: job.id,
                                    time: job.timeHex,
                                    nonce2: nonce2,
                                    solution: solution.zcashSubmissionHex
                                ),
                                solution: solution,
                                hashHex: shareCheck.hashHex
                            ))
                        }

                        let submissionsToSend = validSubmissions
                        let invalidCandidateCount = invalidCandidates
                        let aboveTargetCandidateCount = aboveTargetCandidates
                        let targetCheckFailureCount = targetCheckFailures
                        let localRejectedCount = invalidCandidateCount + aboveTargetCandidateCount + targetCheckFailureCount
                        await MainActor.run {
                            var sent = 0
                            var lastHash = ""
                            self.localRejectedCandidates &+= UInt64(localRejectedCount)

                            let jobAge = Date().timeIntervalSince(attempt.jobReceivedAt)
                            let activeTarget = self.stratum.latestJob?.id == job.id
                                ? (self.stratum.latestJob?.target ?? validationTarget)
                                : validationTarget
                            let stillCurrent = self.stratum.workEpoch == attempt.workEpoch
                                && self.stratum.activeJobIDs.contains(job.id)
                                && activeTarget == validationTarget
                                && jobAge <= miningMaxJobAgeSeconds
                            if stillCurrent {
                                for item in submissionsToSend {
                                    self.latestSolutionHex = item.solution.encoded.hexString()
                                    lastHash = item.hashHex
                                    if self.stratum.submit(item.submission) {
                                        sent += 1
                                    }
                                }
                            } else {
                                self.staleShareSkips &+= UInt64(submissionsToSend.count)
                            }

                            self.submittedShares &+= UInt64(sent)
                            self.lastShareHash = lastHash
                            if !stillCurrent {
                                self.lastSubmitStatus = "Discarded \(submissionsToSend.count) stale candidate(s) immediately before submit."
                                self.runtimeStatus = "Pool job changed during validation; discarded stale candidate(s)."
                                self.shareMinerStatus = "Skipped submit for inactive job \(job.id); current generation \(self.stratum.latestJobSequence), age \(String(format: "%.1f", jobAge))s."
                            } else if sent == 0 {
                                self.lastSubmitStatus = "Filtered \(localRejectedCount) candidate(s); none met the pool target."
                                self.runtimeStatus = "Equihash candidate(s) found, but none passed local validation and target."
                                self.shareMinerStatus = "Filtered candidates for job \(job.id): invalid \(invalidCandidateCount), above target \(aboveTargetCandidateCount), target-check errors \(targetCheckFailureCount)."
                            } else {
                                self.lastSubmitStatus = "Submitted \(sent) locally valid share(s); filtered \(localRejectedCount)."
                                self.runtimeStatus = "Submitted \(sent) locally valid share(s) for job \(job.id)."
                                self.shareMinerStatus = "Submitted \(sent) local-target share(s) for job \(job.id), nonce2 \(nonce2.prefix(16)), target \(validationTarget.prefix(12))..., latest hash \(lastHash.prefix(16))."
                            }
                        }
                        if miningCooldownNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: miningCooldownNanoseconds)
                        }
                        break
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.runtimeStatus = "Stopped"
                        self.shareMinerStatus = "GPU reference share miner stopped."
                        self.isShareMining = false
                        self.isMining = false
                    }
                    return
                } catch {
                    await MainActor.run {
                        self.runtimeStatus = error.localizedDescription
                        self.shareMinerStatus = error.localizedDescription
                        self.isShareMining = false
                        self.isMining = false
                    }
                    return
                }
            }
        }
    }

    func stopReferenceShareMiner() {
        shareMiningTask?.cancel()
        shareMiningTask = nil
        isShareMining = false
        isMining = false
        runtimeStatus = "Stopped"
        shareMinerStatus = "GPU reference share miner stopped."
    }

    func saveConfiguration() {
        ConfigurationStore.save(
            AppConfiguration(
                selectedAlgorithm: selectedAlgorithm,
                poolURL: poolDraft.poolURL,
                username: poolDraft.username,
                password: poolDraft.password,
                headerHex: headerHex,
                batchSize: batchSize,
                hashesPerThread: hashesPerThread,
                threadgroupMultiplier: threadgroupMultiplier,
                miningPipelineDepth: miningPipelineDepth,
                miningMemoryBudgetGB: miningMemoryBudgetGB,
                miningCooldownMilliseconds: miningCooldownMilliseconds,
                miningMaxJobAgeSeconds: miningMaxJobAgeSeconds,
                externalMinerExecutable: externalMinerExecutable,
                externalMinerArguments: externalMinerArguments
            )
        )
    }
}

private struct MiningAttempt {
    let job: ZcashStratumJob
    let jobSequence: UInt64
    let workEpoch: UInt64
    let jobReceivedAt: Date
    let target: String
    let nonce2: String
    let attemptNumber: UInt64
    let header: Data
}

extension MinerViewModel {
    nonisolated func waitForMiningState() async throws -> (
        job: ZcashStratumJob,
        jobSequence: UInt64,
        workEpoch: UInt64,
        jobReceivedAt: Date,
        nonce1: String,
        target: String
    ) {
        while !Task.isCancelled {
            if let state = await MainActor.run(body: {
                if !self.stratum.isConnected {
                    self.shareMinerStatus = "Connecting to pool..."
                    return nil as (ZcashStratumJob, UInt64, UInt64, Date, String, String)?
                }
                guard self.stratum.isAuthorized else {
                    self.shareMinerStatus = "Waiting for pool authorization..."
                    return nil
                }
                guard let nonce1 = self.stratum.nonce1, !nonce1.isEmpty else {
                    self.shareMinerStatus = "Waiting for pool nonce1..."
                    return nil
                }
                guard let target = self.stratum.target, !target.isEmpty else {
                    self.shareMinerStatus = "Waiting for mining.set_target..."
                    return nil
                }
                guard let latestJob = self.stratum.latestJob, let job = latestJob.zcash else {
                    self.shareMinerStatus = "Waiting for Zcash mining.notify job..."
                    return nil
                }
                return (
                    job,
                    self.stratum.latestJobSequence,
                    self.stratum.workEpoch,
                    latestJob.receivedAt,
                    nonce1,
                    latestJob.target ?? target
                )
            }) {
                return state
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CancellationError()
    }

    fileprivate nonisolated static func makeMiningAttempts(
        job: ZcashStratumJob,
        jobSequence: UInt64,
        workEpoch: UInt64,
        jobReceivedAt: Date,
        nonce1: String,
        target: String,
        startingCounter: UInt64,
        startingAttemptNumber: UInt64,
        count: Int,
        nonce2Entropy: [UInt8] = []
    ) throws -> [MiningAttempt] {
        let count = max(1, count)
        var attempts: [MiningAttempt] = []
        attempts.reserveCapacity(count)

        for offset in 0..<count {
            let counter = startingCounter &+ UInt64(offset)
            let nonce2 = makeNonce2(counter: counter, nonce1Hex: nonce1, entropy: nonce2Entropy)
            attempts.append(
                MiningAttempt(
                    job: job,
                    jobSequence: jobSequence,
                    workEpoch: workEpoch,
                    jobReceivedAt: jobReceivedAt,
                    target: target,
                    nonce2: nonce2,
                    attemptNumber: startingAttemptNumber &+ UInt64(offset),
                    header: try job.powHeader(nonce1: nonce1, nonce2: nonce2)
                )
            )
        }
        return attempts
    }

    fileprivate nonisolated func freshness(
        for attempt: MiningAttempt,
        maxAgeSeconds: Double
    ) async -> (isFresh: Bool, reason: String, target: String?) {
        await MainActor.run {
            let age = Date().timeIntervalSince(attempt.jobReceivedAt)
            let activeTarget = self.stratum.latestJob?.id == attempt.job.id
                ? (self.stratum.latestJob?.target ?? attempt.target)
                : attempt.target
            guard self.stratum.workEpoch == attempt.workEpoch else {
                return (false, "Pool work epoch changed", activeTarget)
            }
            guard self.stratum.activeJobIDs.contains(attempt.job.id) else {
                return (false, "Pool job is no longer active", activeTarget)
            }
            guard age <= maxAgeSeconds else {
                return (false, "Job age \(String(format: "%.1f", age))s exceeds \(Int(maxAgeSeconds))s submit window", activeTarget)
            }
            guard !activeTarget.isEmpty else {
                return (false, "Pool target unavailable", nil)
            }
            return (true, "Job fresh", activeTarget)
        }
    }

    nonisolated static func makeNonce2(counter: UInt64, nonce1Hex: String, entropy: [UInt8] = []) -> String {
        let nonce1ByteCount = max(0, nonce1Hex.count / 2)
        let nonce2ByteCount = max(0, 32 - nonce1ByteCount)
        var bytes = [UInt8](repeating: 0, count: nonce2ByteCount)
        for i in 0..<min(bytes.count, entropy.count) {
            bytes[i] = entropy[i]
        }
        var value = counter
        for i in 0..<min(8, nonce2ByteCount) {
            bytes[i] = UInt8(value & 0xff)
            value >>= 8
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func randomNonce2Entropy() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: 0...UInt8.max, using: &generator) }
    }

    nonisolated static func solverAutotuneBucketCandidates(around currentSlots: Int) -> [Int] {
        var candidates = Set([16, 32, 64, 96, 128, 192, 256])
        for delta in [-64, -32, -16, 0, 16, 32, 64] {
            candidates.insert((currentSlots + delta).clamped(to: 2...256))
        }
        return candidates.sorted()
    }

    nonisolated static func solverAutotuneThreadgroupCandidates(around currentMultiplier: Int) -> [Int] {
        var candidates = Set([1, 2, 4])
        candidates.insert(currentMultiplier.clamped(to: 1...8))
        return candidates.sorted()
    }

    nonisolated static func solverAutotuneMemoryCandidates(currentBytes: Int, recommendedBytes: Int) -> [Int] {
        let oneGB = 1_024 * 1_024 * 1_024
        var candidates = Set([
            currentBytes,
            2 * oneGB,
            4 * oneGB,
            min(recommendedBytes, 6 * oneGB),
            min(recommendedBytes, 8 * oneGB)
        ])
        candidates = candidates.map { $0.clamped(to: oneGB...(12 * oneGB)) }.reduce(into: Set<Int>()) { $0.insert($1) }
        return candidates.sorted()
    }

    nonisolated static func bytesFromGigabytes(_ gigabytes: Double) -> Int {
        Int((gigabytes.clamped(to: 1...16)) * 1_024 * 1_024 * 1_024)
    }

    nonisolated static func gigabytesFromBytes(_ bytes: Int) -> Double {
        Double(bytes) / Double(1_024 * 1_024 * 1_024)
    }

    nonisolated static func memoryLabel(_ bytes: Int) -> String {
        String(format: "%.1f GB", gigabytesFromBytes(bytes))
    }
}

extension Double {
    var compactHashRate: String {
        let units = ["Sol/s", "KSol/s", "MSol/s", "GSol/s"]
        var value = self
        var unitIndex = 0
        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    var compactRowRate: String {
        let units = ["rows/s", "Krows/s", "Mrows/s", "Grows/s"]
        var value = self
        var unitIndex = 0
        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    var compactPairRate: String {
        let units = ["pairs/s", "Kpairs/s", "Mpairs/s", "Gpairs/s"]
        var value = self
        var unitIndex = 0
        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        return String(format: "%.2f %@", value, units[unitIndex])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
