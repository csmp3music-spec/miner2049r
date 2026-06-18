import SwiftUI
import AppKit
import Darwin

@main
struct Miner2049erApp: App {
    @StateObject private var model = MinerViewModel()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfTest.run()
                print("Self-test passed.")
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--mine") {
            HeadlessMinerCommand.runAndExit(arguments: Array(CommandLine.arguments.dropFirst()))
        }
    }

    var body: some Scene {
        WindowGroup(AppBrand.displayName) {
            MinerDashboard()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560)
                .padding(20)
        }
    }
}

private struct HeadlessMinerOptions {
    var poolURL = StratumConfiguration().poolURL
    var username = StratumConfiguration().username
    var password = StratumConfiguration().password
    var pipelineDepth = 4
    var memoryGB = 4.0
    var cooldownMilliseconds = 0.0
    var maxJobAgeSeconds = 20.0
    var useMockPool = false
    var shouldPrintHelp = false

    static func parse(_ arguments: [String]) throws -> HeadlessMinerOptions {
        var options = HeadlessMinerOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--mine":
                break
            case "--help", "-h":
                options.shouldPrintHelp = true
            case "--mock-pool":
                options.useMockPool = true
            case "--pool":
                index += 1
                options.poolURL = try value(for: argument, at: index, in: arguments)
            case "--user", "--username":
                index += 1
                options.username = try value(for: argument, at: index, in: arguments)
            case "--password", "--pass":
                index += 1
                options.password = try value(for: argument, at: index, in: arguments)
            case "--pipeline-depth":
                index += 1
                guard let value = Int(try value(for: argument, at: index, in: arguments)) else {
                    throw HeadlessMinerError.invalidValue(argument)
                }
                options.pipelineDepth = clamp(value, to: 1...8)
            case "--memory-gb":
                index += 1
                guard let value = Double(try value(for: argument, at: index, in: arguments)) else {
                    throw HeadlessMinerError.invalidValue(argument)
                }
                options.memoryGB = clamp(value, to: 1...16)
            case "--cooldown-ms":
                index += 1
                guard let value = Double(try value(for: argument, at: index, in: arguments)) else {
                    throw HeadlessMinerError.invalidValue(argument)
                }
                options.cooldownMilliseconds = clamp(value, to: 0...1_000)
            case "--max-job-age-s":
                index += 1
                guard let value = Double(try value(for: argument, at: index, in: arguments)) else {
                    throw HeadlessMinerError.invalidValue(argument)
                }
                options.maxJobAgeSeconds = clamp(value, to: 5...120)
            default:
                if let split = splitAssignment(argument) {
                    switch split.name {
                    case "--pool": options.poolURL = split.value
                    case "--user", "--username": options.username = split.value
                    case "--password", "--pass": options.password = split.value
                    case "--pipeline-depth":
                        guard let value = Int(split.value) else { throw HeadlessMinerError.invalidValue(split.name) }
                        options.pipelineDepth = clamp(value, to: 1...8)
                    case "--memory-gb":
                        guard let value = Double(split.value) else { throw HeadlessMinerError.invalidValue(split.name) }
                        options.memoryGB = clamp(value, to: 1...16)
                    case "--cooldown-ms":
                        guard let value = Double(split.value) else { throw HeadlessMinerError.invalidValue(split.name) }
                        options.cooldownMilliseconds = clamp(value, to: 0...1_000)
                    case "--max-job-age-s":
                        guard let value = Double(split.value) else { throw HeadlessMinerError.invalidValue(split.name) }
                        options.maxJobAgeSeconds = clamp(value, to: 5...120)
                    default:
                        throw HeadlessMinerError.unknownArgument(argument)
                    }
                } else {
                    throw HeadlessMinerError.unknownArgument(argument)
                }
            }
            index += 1
        }
        return options
    }

    private static func value(for option: String, at index: Int, in arguments: [String]) throws -> String {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw HeadlessMinerError.missingValue(option)
        }
        return arguments[index]
    }

    private static func splitAssignment(_ argument: String) -> (name: String, value: String)? {
        guard let separator = argument.firstIndex(of: "=") else {
            return nil
        }
        let name = String(argument[..<separator])
        let value = String(argument[argument.index(after: separator)...])
        return (name, value)
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private enum HeadlessMinerError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option): return "Missing value for \(option)."
        case .invalidValue(let option): return "Invalid value for \(option)."
        case .unknownArgument(let argument): return "Unknown argument \(argument)."
        }
    }
}

private enum HeadlessMinerCommand {
    static func runAndExit(arguments: [String]) -> Never {
        do {
            let options = try HeadlessMinerOptions.parse(arguments)
            if options.shouldPrintHelp {
                print(Self.usage)
                exit(0)
            }

            signal(SIGINT) { _ in exit(130) }
            signal(SIGTERM) { _ in exit(143) }

            Task { @MainActor in
                let model = MinerViewModel()
                model.selectedAlgorithm = .equihash200_9
                model.miningPipelineDepth = options.pipelineDepth
                model.miningMemoryBudgetGB = options.memoryGB
                model.miningCooldownMilliseconds = options.cooldownMilliseconds
                model.miningMaxJobAgeSeconds = options.maxJobAgeSeconds

                if options.useMockPool {
                    model.mockPool.start()
                    model.poolDraft.poolURL = model.mockPool.endpoint
                    model.poolDraft.username = "test.worker"
                    model.poolDraft.password = "x"
                } else {
                    model.poolDraft.poolURL = options.poolURL
                    model.poolDraft.username = options.username
                    model.poolDraft.password = options.password
                }

                print("Starting headless \(AppBrand.displayName) Zcash ZIP-301 miner.")
                print("Pool: \(model.poolDraft.poolURL)")
                print("User: \(model.poolDraft.username)")
                print("Pipeline: \(model.miningPipelineDepth), memory: \(String(format: "%.1f", model.miningMemoryBudgetGB)) GB, max job age: \(Int(model.miningMaxJobAgeSeconds))s")
                model.startMining()

                Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    Task { @MainActor in
                        print(Self.statusLine(for: model))
                    }
                }
                RunLoop.main.add(Port(), forMode: .default)
            }

            RunLoop.main.run()
            exit(0)
        } catch {
            fputs("\(error.localizedDescription)\n\n\(Self.usage)\n", stderr)
            exit(2)
        }
    }

    @MainActor
    private static func statusLine(for model: MinerViewModel) -> String {
        let rate = model.averageRate.compactRowRate
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return [
            formatter.string(from: Date()),
            model.runtimeStatus,
            "rate=\(rate)",
            "attempts=\(model.nonceAttempts)",
            "submitted=\(model.submittedShares)",
            "accepted=\(model.acceptedShares)",
            "rejected=\(model.rejectedShares)"
        ].joined(separator: " | ")
    }

    private static let usage = """
    Usage:
      miner-2049er --mine [options]

    Options:
      --pool URL              Stratum URL, for example stratum+tcp://host:port
      --user NAME             Pool worker/account name
      --password VALUE        Pool password or difficulty hint
      --pipeline-depth N      Nonce pipeline depth, 1...8
      --memory-gb VALUE       Metal solver memory budget, 1...16
      --cooldown-ms VALUE     Delay between nonce attempts, 0...1000
      --max-job-age-s VALUE   Discard solved shares for jobs older than this, 5...120
      --mock-pool             Mine against the local mock Stratum server
      --help                  Show this help
    """
}

struct MinerDashboard: View {
    @EnvironmentObject private var model: MinerViewModel

    var body: some View {
        NavigationSplitView {
            List(MiningAlgorithm.allCases, selection: $model.selectedAlgorithm) { algorithm in
                VStack(alignment: .leading, spacing: 4) {
                    Text(algorithm.name)
                        .font(.headline)
                    Text(algorithm.commonCoins)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .tag(algorithm)
            }
            .navigationTitle("Algorithms")
            .scrollContentBackground(.hidden)
            .background(AppTheme.sidebar)
            .frame(minWidth: 230)
        } detail: {
            AlwaysVisibleVerticalScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    runtimePanel
                    enginePanel
                    configurationPanel
                    benchmarkPanel
                    solverPanel
                    jobPanel
                    logPanel
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.background)
            }
            .background(AppTheme.background)
        }
        .tint(AppTheme.cyan)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppBrand.displayName)
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.titleGradient)
                            .shadow(color: AppTheme.magenta.opacity(0.55), radius: 0, x: 2, y: 2)
                        Text("Apple Silicon mining console")
                            .font(.headline)
                            .foregroundStyle(AppTheme.cyan)
                    }
                    Spacer()
                    StatusPill(text: model.selectedAlgorithm.stratumMode.rawValue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedAlgorithm.name)
                        .font(.title.bold())
                        .foregroundStyle(AppTheme.gold)
                    Text(model.selectedAlgorithm.commonCoins)
                        .foregroundStyle(AppTheme.softText)
                }

                Text(model.selectedAlgorithm.implementationNote)
                    .font(.callout)
                    .foregroundStyle(AppTheme.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            MinerBoxArtView()
                .frame(width: 178, height: 178)
        }
    }

    private var runtimePanel: some View {
        Panel(title: "Runtime") {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    model.startMining()
                } label: {
                    Label("Start Pool Mining", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isMining || !model.selectedAlgorithmCanMine)

                Button {
                    model.stopMining()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!model.isMining)

                Spacer()
                StatusPill(text: model.isMining ? "Running" : "Stopped")
            }

            Text(model.runtimeStatus)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            if model.selectedAlgorithmUsesExternalMiner {
                MetricGrid(items: [
                    MetricItem(title: "Backend", value: model.selectedAlgorithm.usesXMRigDefault ? "XMRig" : "External"),
                    MetricItem(title: "Algorithm", value: model.selectedAlgorithm.externalMinerAlgorithmName),
                    MetricItem(title: "Accepted Shares", value: "\(model.xmrig.acceptedShares)"),
                    MetricItem(title: "Rejected Shares", value: "\(model.xmrig.rejectedShares)"),
                    MetricItem(title: "Running", value: model.xmrig.isRunning ? "Yes" : "No"),
                    MetricItem(title: "Telemetry", value: model.xmrig.telemetrySource)
                ])
                if !model.xmrig.latestHashrate.isEmpty {
                    Text(model.xmrig.latestHashrate)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.softText)
                        .textSelection(.enabled)
                }
                Text(model.xmrig.apiStatus)
                    .font(.caption)
                    .foregroundStyle(AppTheme.softText)
            } else {
                MetricGrid(items: [
                    MetricItem(title: "Average Row Rate", value: model.averageRate.compactRowRate),
                    MetricItem(title: "Equihash Rows", value: "\(model.totalHashes)"),
                    MetricItem(title: "Nonce Attempts", value: "\(model.nonceAttempts)"),
                    MetricItem(title: "Last GPU Round", value: "\(model.lastGpuCompletedRounds)/9"),
                    MetricItem(title: "GPU Candidates", value: "\(model.gpuCandidateSolutions)"),
                    MetricItem(title: "Submitted Shares", value: "\(model.submittedShares)"),
                    MetricItem(title: "Accepted Shares", value: "\(model.acceptedShares)"),
                    MetricItem(title: "Rejected Shares", value: "\(model.rejectedShares)"),
                    MetricItem(title: "Local Rejects", value: "\(model.localRejectedCandidates)"),
                    MetricItem(title: "Stale Skips", value: "\(model.staleShareSkips)"),
                    MetricItem(title: "GPU Skips", value: "\(model.gpuOverflowSkips + model.gpuIncompleteSkips)"),
                    MetricItem(title: "No-Solution Nonces", value: "\(model.noSolutionAttempts)")
                ])
            }

            Text(model.lastSubmitStatus)
                .font(.callout)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            if model.selectedAlgorithmUsesExternalMiner {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.xmrig.status)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.gold)
                    Text("Pool: \(model.activePoolSummary)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.poolTargetSummary)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.gold)
                    Text(model.acceptedShareEstimate)
                        .font(.callout)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pool submit: \(model.stratum.lastSubmitResult)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TelemetryGraphs(samples: model.telemetrySamples)
        }
    }

    private var enginePanel: some View {
        let engine = model.selectedEngine
        return Panel(title: "Engine Status") {
            MetricGrid(items: [
                MetricItem(title: "Engine", value: engine.kind.rawValue),
                MetricItem(title: "Local Hashing", value: engine.canHashLocally ? "Available" : "Missing"),
                MetricItem(title: "Share Solver", value: engine.canSolveShares ? "Available" : "Missing"),
                MetricItem(title: "Apple GPU", value: engine.supportsAppleGPU ? "Supported" : "Not yet")
            ])

            VStack(alignment: .leading, spacing: 8) {
                Text("Implementation")
                    .font(.headline)
                    .foregroundStyle(AppTheme.gold)
                Text(engine.implementation)
                    .foregroundStyle(AppTheme.softText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Next Work")
                    .font(.headline)
                    .foregroundStyle(AppTheme.gold)
                Text(engine.nextWork)
                    .foregroundStyle(AppTheme.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationPanel: some View {
        Panel(title: "Pool Configuration") {
            Text("Edit the draft pool anytime. Apply reconnects Stratum and restarts active mining against the new endpoint.")
                .font(.callout)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("Active: \(model.activePoolSummary)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                if model.poolDraftHasChanges {
                    StatusPill(text: "Draft changes")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Pool")
                    TextField("stratum+tcp://host:port or stratum+ssl://host:port", text: $model.poolDraft.poolURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("User")
                    TextField("wallet.worker or pool user", text: $model.poolDraft.username)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    SecureField("x", text: $model.poolDraft.password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text(model.poolDraft.validationMessage)
                .font(.caption)
                .foregroundStyle(model.poolConfigIsValid ? AppTheme.green : AppTheme.gold)
                .fixedSize(horizontal: false, vertical: true)

            if model.selectedAlgorithmUsesExternalMiner && !model.selectedAlgorithm.usesXMRigDefault {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("External Miner")
                        .font(.headline)
                        .foregroundStyle(AppTheme.gold)
                    TextField("/absolute/path/to/miner", text: $model.externalMinerExecutable)
                        .textFieldStyle(.roundedBorder)
                    TextField("arguments with {pool}, {pool_url}, {user}, {password}, {algo}", text: $model.externalMinerArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Tokens: {pool}, {pool_url}, {host}, {port}, {user}, {password}, {algo}, {tls}")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                    Text(model.externalMinerCommandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.cyan)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }

            HStack {
                Button {
                    model.savePoolDraft()
                } label: {
                    Label("Save Draft", systemImage: "square.and.arrow.down")
                }

                Button {
                    model.resetPoolDraftFromActiveConfig()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.poolDraftHasChanges)

                Button {
                    model.applyPoolConfiguration()
                } label: {
                    Label(model.stratum.isConnected ? "Apply & Reconnect" : "Apply", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.poolConfigIsValid || (!model.poolDraftHasChanges && model.stratum.isConnected))

                Button {
                    model.connectToPool()
                } label: {
                    Label("Connect", systemImage: "network")
                }
                .disabled(model.stratum.isConnected || !model.poolConfigIsValid)

                Button {
                    model.stratum.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(!model.stratum.isConnected)

                Spacer()
                ConnectionStateView()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Mock Pool")
                        .font(.headline)
                        .foregroundStyle(AppTheme.gold)
                    Text(model.mockPool.isRunning ? model.mockPool.endpoint : "Stopped")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    model.mockPool.start()
                    model.poolDraft.poolURL = model.mockPool.endpoint
                    model.poolDraft.username = "test.worker"
                    model.poolDraft.password = "x"
                    model.applyPoolConfiguration()
                } label: {
                    Label("Start Mock Pool", systemImage: "server.rack")
                }
                .disabled(model.mockPool.isRunning)

                Button {
                    model.mockPool.stop()
                } label: {
                    Label("Stop Mock Pool", systemImage: "power")
                }
                .disabled(!model.mockPool.isRunning)
            }
        }
    }

    private var benchmarkPanel: some View {
        Panel(title: "GPU Engine") {
            Text("Use Autotune to measure launch settings on this Mac. Apple GPUs are sensitive to SIMD width, threadgroup occupancy, command submission overhead, and memory write volume, so measured settings are more useful than fixed defaults.")
                .font(.callout)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(model.gpuName, systemImage: "cpu")
                        .foregroundStyle(AppTheme.gold)
                    Text(model.gpuLimits)
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Button {
                    model.autotune()
                } label: {
                    Label(model.isTuning ? "Tuning" : "Autotune", systemImage: "speedometer")
                }
                .disabled(model.isBenchmarking || model.isTuning || !model.canRunSelectedAlgorithm)

                Button {
                    model.runBenchmark()
                } label: {
                    Label(model.isBenchmarking ? "Running" : "Run Benchmark", systemImage: "play.fill")
                }
                .disabled(model.isBenchmarking || model.isTuning || !model.canRunSelectedAlgorithm)

                Button {
                    model.applyFastMiningPreset()
                } label: {
                    Label("Fast Preset", systemImage: "bolt.circle")
                }
                .disabled(model.isMining || model.isBenchmarking || model.isTuning || !model.canRunSelectedAlgorithm)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Header seed")
                    .font(.caption)
                    .foregroundStyle(AppTheme.softText)
                TextField("hex header seed", text: $model.headerHex)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canRunSelectedAlgorithm)
            }

            HStack {
                Text("Batch")
                Slider(value: $model.batchSize, in: 1_024...1_048_576, step: 1_024)
                    .disabled(!model.canRunSelectedAlgorithm)
                Text("\(Int(model.batchSize))")
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Threadgroup")
                    Picker("Threadgroup", selection: $model.threadgroupMultiplier) {
                        Text("1x SIMD").tag(1)
                        Text("2x SIMD").tag(2)
                        Text("4x SIMD").tag(4)
                        Text("8x SIMD").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!model.canRunSelectedAlgorithm)
                }
                GridRow {
                    Text("Hashes/thread")
                    Slider(value: $model.hashesPerThread, in: 1...16, step: 1)
                        .disabled(!model.canRunSelectedAlgorithm)
                    Text("\(Int(model.hashesPerThread))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                GridRow {
                    Text("Queue depth")
                    Stepper(value: $model.miningPipelineDepth, in: 1...8) {
                        Text("\(model.miningPipelineDepth)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                    .disabled(model.isMining || !model.canRunSelectedAlgorithm)
                }
                GridRow {
                    Text("Memory budget")
                    Slider(value: $model.miningMemoryBudgetGB, in: 1...12, step: 0.5)
                        .disabled(model.isMining || !model.canRunSelectedAlgorithm)
                    Text(String(format: "%.1f GB", model.miningMemoryBudgetGB))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                GridRow {
                    Text("Cooldown")
                    Slider(value: $model.miningCooldownMilliseconds, in: 0...500, step: 25)
                        .disabled(model.isMining || !model.canRunSelectedAlgorithm)
                    Text("\(Int(model.miningCooldownMilliseconds)) ms")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                GridRow {
                    Text("Submit window")
                    Slider(value: $model.miningMaxJobAgeSeconds, in: 5...120, step: 5)
                        .disabled(model.isMining || !model.canRunSelectedAlgorithm)
                    Text("\(Int(model.miningMaxJobAgeSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU Initial Rows")
                        .font(.headline)
                        .foregroundStyle(AppTheme.gold)
                    Text("Generates Zcash Equihash 25-byte initial rows and 20-bit collision keys from a full powheader on Metal.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    model.generateGpuInitialRows()
                } label: {
                    Label(model.isGeneratingRows ? "Generating" : "Generate Rows", systemImage: "memorychip")
                }
                .disabled(model.isGeneratingRows || model.selectedAlgorithm != .equihash200_9)
            }

            HStack {
                Text("Rows")
                Slider(value: $model.gpuRowSampleCount, in: 1_024...2_097_152, step: 1_024)
                    .disabled(model.isGeneratingRows || model.selectedAlgorithm != .equihash200_9)
                Text("\(Int(model.gpuRowSampleCount))")
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }

            HStack {
                Text("Bucket slots")
                Slider(value: $model.roundOneBucketSlots, in: 2...256, step: 1)
                    .disabled(model.isGeneratingRows || model.selectedAlgorithm != .equihash200_9)
                Text("\(Int(model.roundOneBucketSlots))")
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
                Button {
                    model.generateGpuRoundOnePairs()
                } label: {
                    Label("Round 1 Pairs", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(model.isGeneratingRows || model.selectedAlgorithm != .equihash200_9)
            }

            Text(model.benchmarkStatus)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            if let result = model.latestResult {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Rate")
                            .foregroundStyle(AppTheme.softText)
                        Text(result.solutionsPerSecond.compactHashRate)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Elapsed")
                            .foregroundStyle(AppTheme.softText)
                        Text(String(format: "%.4f s", result.elapsedSeconds))
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Launch")
                            .foregroundStyle(AppTheme.softText)
                        Text("tg \(result.threadgroupSize), h/t \(result.hashesPerThread)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Checksum")
                            .foregroundStyle(AppTheme.softText)
                        Text(String(format: "%08x", result.checksum))
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("First digest")
                            .foregroundStyle(AppTheme.softText)
                        Text(result.firstDigest.hexString(limit: 18) + "...")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if let rowResult = model.latestRowResult {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Rows/sec")
                            .foregroundStyle(AppTheme.softText)
                        Text(rowResult.rowsPerSecond.compactHashRate.replacingOccurrences(of: "Sol", with: "rows"))
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Rows")
                            .foregroundStyle(AppTheme.softText)
                        Text("\(rowResult.rowCount)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("First key")
                            .foregroundStyle(AppTheme.softText)
                        Text(String(format: "%05x", rowResult.firstKey))
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("CPU check")
                            .foregroundStyle(AppTheme.softText)
                        Text(rowResult.cpuMatchesFirstRow ? "match" : "mismatch")
                    }
                }
            }

            if let roundOne = model.latestRoundOneResult {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("GPU pairs/sec")
                            .foregroundStyle(AppTheme.softText)
                        Text(roundOne.pairsPerSecond.compactPairRate)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Output pairs")
                            .foregroundStyle(AppTheme.softText)
                        Text("\(roundOne.pairCount) / \(roundOne.expectedPairCount)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Bucket slots")
                            .foregroundStyle(AppTheme.softText)
                        Text("\(roundOne.bucketSlots)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Overflow")
                            .foregroundStyle(AppTheme.softText)
                        Text(roundOne.overflow ? "yes" : "no")
                    }
                    if let firstKey = roundOne.firstPairKey {
                        GridRow {
                            Text("First pair key")
                                .foregroundStyle(AppTheme.softText)
                            Text(String(format: "%05x", firstKey))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            if !model.tuningResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Autotune Results")
                        .font(.headline)
                    ForEach(model.tuningResults.prefix(6)) { item in
                        HStack {
                            Text("tg \(item.configuration.threadgroupSize)")
                                .frame(width: 76, alignment: .leading)
                            Text("h/t \(item.configuration.hashesPerThread)")
                                .frame(width: 56, alignment: .leading)
                            Spacer()
                            Text(item.result.solutionsPerSecond.compactHashRate)
                                .monospacedDigit()
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }

            if !model.solverTuningResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Solver Autotune")
                        .font(.headline)
                    ForEach(model.solverTuningResults.prefix(6)) { item in
                        HStack {
                            Text("\(item.bucketSlots) slots")
                                .frame(width: 82, alignment: .leading)
                            Text("\(item.threadgroupMultiplier)x SIMD")
                                .frame(width: 76, alignment: .leading)
                            Text(String(format: "%.1f GB", Double(item.memoryBudgetBytes) / Double(1_024 * 1_024 * 1_024)))
                                .frame(width: 70, alignment: .leading)
                            Text("\(item.completedRounds)/9")
                                .frame(width: 42, alignment: .leading)
                            Spacer()
                            Text(item.rowsPerSecond.compactRowRate)
                                .monospacedDigit()
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(item.overflow ? AppTheme.red : AppTheme.softText)
                    }
                }
            }
        }
    }

    private var jobPanel: some View {
        Panel(title: "Current Stratum Job") {
            Text("When connected to a pool, incoming work appears here. A full miner still needs the algorithm-specific share solver to turn these jobs into valid submissions.")
                .font(.callout)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            if let job = model.stratum.latestJob {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Job ID").foregroundStyle(AppTheme.softText)
                        Text(job.id).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Received").foregroundStyle(AppTheme.softText)
                        Text(job.receivedAt.formatted(date: .omitted, time: .standard))
                    }
                    GridRow {
                        Text("Params").foregroundStyle(AppTheme.softText)
                        Text("\(job.rawParams.count)").monospacedDigit()
                    }
                }
            } else {
                Text("No job received yet.")
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }

    private var solverPanel: some View {
        Panel(title: "Equihash GPU Reference Solver") {
            Text("This runs Zcash Equihash 200,9 with Metal initial-row generation and budgeted Metal Wagner collision rounds, then uses the Swift reference validator/submission path for any remaining work. Use a complete 140-byte Zcash powheader in the header seed field.")
                .font(.callout)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    model.runReferenceEquihashSolver()
                } label: {
                    Label(model.isSolvingEquihash ? "Solving" : "Run GPU Reference Solver", systemImage: "square.grid.3x3.fill")
                }
                .disabled(model.isSolvingEquihash || model.selectedAlgorithm != .equihash200_9)

                Button {
                    model.cancelReferenceEquihashSolver()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .disabled(!model.isSolvingEquihash)

                Spacer()
            }

            Text(model.solverStatus)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button {
                    model.startReferenceShareMiner()
                } label: {
                    Label(model.isShareMining ? "Share Miner Running" : "Start Share Miner", systemImage: "paperplane.fill")
                }
                .disabled(model.isShareMining || model.selectedAlgorithm != .equihash200_9)

                Button {
                    model.stopReferenceShareMiner()
                } label: {
                    Label("Stop Share Miner", systemImage: "stop.circle")
                }
                .disabled(!model.isShareMining)

                Spacer()
                if !model.currentNonce2.isEmpty {
                    Text("nonce2 \(model.currentNonce2.prefix(12))...")
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.softText)
                }
            }

            Text(model.shareMinerStatus)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)

            if let solution = model.latestSolutionHex {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Encoded Solution")
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                    Text(solution)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }
        }
    }

    private var logPanel: some View {
        let external = model.selectedAlgorithmUsesExternalMiner
        let lines = external ? model.xmrig.logs : model.stratum.logs
        return Panel(title: external ? "XMRig Log" : "Stratum Log") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.visible)
            .frame(height: 190)
            .background(AppTheme.console)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.gold.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

enum AppBrand {
    static let displayName = "Miner 2049'er"
    static let userAgent = "Miner2049er/0.1"
}

struct MinerBoxArtView: View {
    private let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "miner-2049er-box-art", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        ZStack(alignment: .top) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AppTheme.console
            }

            VStack(spacing: 1) {
                Text("MINER")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                Text("2049'er")
                    .font(.system(size: 25, weight: .black, design: .rounded))
            }
            .foregroundStyle(AppTheme.titleGradient)
            .shadow(color: .black.opacity(0.92), radius: 2, x: 2, y: 2)
            .shadow(color: AppTheme.magenta.opacity(0.7), radius: 0, x: -1, y: 1)
            .padding(.top, 13)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.paper.opacity(0.82), lineWidth: 2)
        )
        .shadow(color: AppTheme.cyan.opacity(0.22), radius: 18, x: 0, y: 8)
        .shadow(color: .black.opacity(0.55), radius: 12, x: 0, y: 7)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: MinerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Miner Configuration")
                .font(.title2.bold())

            Picker("Algorithm", selection: $model.selectedAlgorithm) {
                ForEach(MiningAlgorithm.allCases) { algorithm in
                    Text(algorithm.name).tag(algorithm)
                }
            }

            TextField("Pool URL", text: $model.poolDraft.poolURL)
                .textFieldStyle(.roundedBorder)
            TextField("User", text: $model.poolDraft.username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $model.poolDraft.password)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save Draft") {
                    model.savePoolDraft()
                }
                Button(model.stratum.isConnected ? "Apply & Reconnect" : "Apply") {
                    model.applyPoolConfiguration()
                }
                Button("Connect") {
                    model.connectToPool()
                }
                .disabled(!model.poolConfigIsValid || model.stratum.isConnected)
            }

            Text(model.poolDraft.validationMessage)
                .font(.caption)
                .foregroundStyle(model.poolConfigIsValid ? AppTheme.green : AppTheme.gold)

            Text(model.selectedAlgorithm.implementationNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.gold)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.gold.opacity(0.22), lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(AppTheme.paper)
            .background(
                LinearGradient(
                    colors: [AppTheme.magenta.opacity(0.42), AppTheme.cyan.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
    }
}

struct AlwaysVisibleVerticalScrollView<Content: View>: NSViewRepresentable {
    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .allowed

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        documentView.addSubview(hostingView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        context.coordinator.hostingView = hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct ConnectionStateView: View {
    @EnvironmentObject private var model: MinerViewModel

    var body: some View {
        HStack(spacing: 10) {
            Label(model.stratum.isConnected ? "Connected" : "Offline", systemImage: model.stratum.isConnected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.stratum.isConnected ? AppTheme.green : AppTheme.softText)
            Label(model.stratum.isAuthorized ? "Authorized" : "Unauthorized", systemImage: model.stratum.isAuthorized ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                .foregroundStyle(model.stratum.isAuthorized ? AppTheme.green : AppTheme.softText)
            if let difficulty = model.stratum.difficulty {
                Text("Diff \(difficulty, specifier: "%.4g")")
                    .monospacedDigit()
            }
            if let target = model.stratum.target {
                Text("Target \(target.prefix(8))...")
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }
}

struct TelemetryGraphs: View {
    let samples: [MinerTelemetrySample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Telemetry", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(AppTheme.gold)
                Spacer()
                Text("\(samples.count)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.softText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                LiveLineChart(
                    title: "Hashrate",
                    valueText: latestRowRate.compactRowRate,
                    yMax: max(1, samples.map(\.rowRate).max() ?? 1),
                    series: [
                        TelemetrySeries(name: "Rows/sec", color: AppTheme.green, values: samples.map(\.rowRate))
                    ]
                )

                LiveLineChart(
                    title: "Shares",
                    valueText: "\(latestAccepted) accepted / \(latestRejected) rejected",
                    yMax: Double(max(1, latestAccepted, latestRejected)),
                    series: [
                        TelemetrySeries(name: "Accepted", color: AppTheme.green, values: samples.map { Double($0.acceptedShares) }),
                        TelemetrySeries(name: "Rejected", color: AppTheme.red, values: samples.map { Double($0.rejectedShares) })
                    ]
                )
            }
        }
    }

    private var latestRowRate: Double {
        samples.last?.rowRate ?? 0
    }

    private var latestAccepted: Int {
        samples.last?.acceptedShares ?? 0
    }

    private var latestRejected: Int {
        samples.last?.rejectedShares ?? 0
    }
}

struct TelemetrySeries: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let values: [Double]
}

struct LiveLineChart: View {
    let title: String
    let valueText: String
    let yMax: Double
    let series: [TelemetrySeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.softText)
                Spacer()
                Text(valueText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Canvas { context, size in
                let plot = CGRect(x: 0, y: 4, width: size.width, height: max(1, size.height - 8))
                var grid = Path()
                for step in 0...3 {
                    let y = plot.minY + (plot.height * CGFloat(step) / 3)
                    grid.move(to: CGPoint(x: plot.minX, y: y))
                    grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                context.stroke(grid, with: .color(AppTheme.gold.opacity(0.14)), lineWidth: 1)

                for item in series {
                    guard item.values.count >= 2 else { continue }
                    var path = Path()
                    for (index, rawValue) in item.values.enumerated() {
                        let x = plot.minX + (plot.width * CGFloat(index) / CGFloat(max(1, item.values.count - 1)))
                        let normalized = min(max(rawValue / max(0.000001, yMax), 0), 1)
                        let y = plot.maxY - (plot.height * CGFloat(normalized))
                        let point = CGPoint(x: x, y: y)
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                    context.stroke(path, with: .color(item.color), lineWidth: 2.2)
                }
            }
            .frame(height: 120)
            .background(AppTheme.console)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.gold.opacity(0.18), lineWidth: 1)
            )

            HStack(spacing: 12) {
                ForEach(series) { item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.softText)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.metric)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct MetricGrid: View {
    let items: [MetricItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(AppTheme.softText)
                    Text(item.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.gold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.metric)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

enum AppTheme {
    static let void = Color(red: 0.015, green: 0.017, blue: 0.024)
    static let midnight = Color(red: 0.025, green: 0.053, blue: 0.105)
    static let deepBlue = Color(red: 0.03, green: 0.11, blue: 0.19)
    static let cyan = Color(red: 0.13, green: 0.74, blue: 0.96)
    static let magenta = Color(red: 0.92, green: 0.08, blue: 0.45)
    static let orange = Color(red: 0.95, green: 0.33, blue: 0.08)
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.05)
    static let paper = Color(red: 0.88, green: 0.82, blue: 0.68)

    static let background = LinearGradient(
        colors: [
            void,
            Color(red: 0.035, green: 0.045, blue: 0.095),
            Color(red: 0.10, green: 0.025, blue: 0.082)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let titleGradient = LinearGradient(
        colors: [paper, amber, orange, magenta],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let sidebar = Color(red: 0.018, green: 0.024, blue: 0.042)
    static let panel = Color(red: 0.025, green: 0.07, blue: 0.13).opacity(0.94)
    static let metric = Color(red: 0.018, green: 0.052, blue: 0.098).opacity(0.97)
    static let console = Color(red: 0.006, green: 0.011, blue: 0.022)
    static let green = Color(red: 0.18, green: 0.86, blue: 0.58)
    static let gold = amber
    static let red = Color(red: 1.0, green: 0.23, blue: 0.18)
    static let softText = Color(red: 0.78, green: 0.83, blue: 0.84)
}
