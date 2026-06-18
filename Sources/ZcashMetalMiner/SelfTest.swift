import Foundation

enum SelfTest {
    static func run() throws {
        let job = try ZcashStratumJob(params: [
            "job-1",
            "04000000",
            String(repeating: "00", count: 32),
            String(repeating: "11", count: 32),
            String(repeating: "22", count: 32),
            "1d00ffff",
            "ffff001d",
            true
        ])
        let nonce1 = "abcdef1234567890"
        let nonce2 = String(repeating: "11", count: 24)
        let header = try job.powHeader(nonce1: nonce1, nonce2: nonce2)
        try assert(header.count == 140, "powheader length")
        try assert(header.prefix(4).hexString() == "04000000", "powheader version")
        try assert(header.suffix(32).hexString() == nonce1 + nonce2, "powheader nonce")
        try assert(CompactSize.encode(1_344).hexString() == "fd4005", "compactSize 1344")

        let encoded = Data(repeating: 0xab, count: EquihashParameters.zcash.encodedSolutionByteCount)
        let solution = EquihashSolution(indices: Array(repeating: 1, count: 512), encoded: encoded)
        try assert(solution.zcashSubmissionHex.hasPrefix("fd4005"), "solution compactSize prefix")
        try assert(solution.zcashSubmissionHex.count == (3 + encoded.count) * 2, "solution hex length")
        let shareCheck = try ZcashShareValidator.check(
            powHeader: header,
            solution: solution,
            targetHex: String(repeating: "f", count: 64)
        )
        try assert(shareCheck.meetsTarget, "max target share check")
        try assert(ZcashShareValidator.blockHashForTarget(header).count == 32, "target hash width")
        let zeroNonceHeader = try job.powHeader(nonce1: nonce1, nonce2: String(repeating: "00", count: 24))
        let displayTargetShare = try ZcashShareValidator.check(
            powHeader: zeroNonceHeader,
            solution: solution,
            targetHex: String(repeating: "f", count: 64)
        )
        let equalityTargetShare = try ZcashShareValidator.check(
            powHeader: zeroNonceHeader,
            solution: solution,
            targetHex: displayTargetShare.hashHex
        )
        try assert(equalityTargetShare.meetsTarget, "target comparison uses displayed big-endian hash")

        try assert(
            EthashPrimitives.keccak256(Data()).hexString()
                == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            "Keccak-256 empty vector"
        )
        try assert(
            EthashPrimitives.keccak256(Data("abc".utf8)).hexString()
                == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
            "Keccak-256 abc vector"
        )
        try assert(
            EthashPrimitives.keccak512(Data()).hexString()
                == "0eab42de4c3ceb9235fc91acffe746b29c29a8c366b7c60e4e67c466f36a4304c00fa9caf9d87976ba469bcbe06713b435f091ef2769fb160cdab33d3670680e",
            "Keccak-512 empty vector"
        )
        try assert(
            EthashPrimitives.fnv1(0x811c9dc5, 0x12345678) == 0x1738_0b67,
            "FNV1 mix"
        )
        try assert(
            ProgPowPrimitives.fnv1a(0x811c9dc5, 0xddd0a47b) == 0xd37e_e61a,
            "ProgPoW FNV1a vector 1"
        )
        var kiss99 = Kiss99State.eip1057Seed
        try assert(ProgPowPrimitives.kiss99(&kiss99) == 769_445_856, "ProgPoW KISS99 vector 1")
        try assert(ProgPowPrimitives.kiss99(&kiss99) == 742_012_328, "ProgPoW KISS99 vector 2")
        try assert(ProgPowPrimitives.kiss99(&kiss99) == 2_121_196_314, "ProgPoW KISS99 vector 3")
        try assert(ProgPowPrimitives.kiss99(&kiss99) == 2_805_620_942, "ProgPoW KISS99 vector 4")
        var kiss99Long = Kiss99State.eip1057Seed
        for _ in 0..<99_999 {
            _ = ProgPowPrimitives.kiss99(&kiss99Long)
        }
        try assert(ProgPowPrimitives.kiss99(&kiss99Long) == 941_074_834, "ProgPoW KISS99 vector 100000")

        let kawPowProfile = AlgorithmWorkProfiles.profile(for: .kawPow)
        try assert(kawPowProfile.computeTarget == .appleMetal, "KawPow Metal profile")
        try assert(kawPowProfile.progPow?.lanes == 16, "KawPow lane profile")
        let firoPowProfile = AlgorithmWorkProfiles.profile(for: .firopow)
        try assert(firoPowProfile.progPow?.period == 1, "FiroPoW per-block program profile")
        try assert(AlgorithmWorkProfiles.profile(for: .randomX).computeTarget == .cpuExternal, "RandomX CPU profile")
        try assert(AlgorithmWorkProfiles.profile(for: .ghostRider).computeTarget == .cpuExternal, "GhostRider CPU profile")
        try assert(MiningAlgorithm.randomX.xmrigAlgorithm == "rx/0", "RandomX XMRig algorithm")
        try assert(MiningAlgorithm.ghostRider.xmrigAlgorithm == "ghostrider", "GhostRider XMRig algorithm")
        try assert(MiningAlgorithm.randomX.canStartMining, "RandomX mineable through XMRig")
        try assert(MiningAlgorithm.ghostRider.canStartMining, "GhostRider mineable through XMRig")
        try assert(MiningAlgorithm.allCases.allSatisfy(\.canStartMining), "all listed algorithms have a mining launch path")
        let ethashTransition = EthashEpoch(family: .ethash, blockNumber: 11_700_000)
        let etchashTransition = EthashEpoch(family: .etchash, blockNumber: 11_700_000)
        try assert(ethashTransition.epoch == 390, "Ethash epoch at ETC Thanos block")
        try assert(etchashTransition.epoch == 195, "Etchash recalibrated epoch at ETC Thanos block")
        try assert(EthashEpoch.isPrime(ethashTransition.datasetItemCount), "Ethash dataset item count prime")
        try assert(EthashEpoch.isPrime(etchashTransition.datasetItemCount), "Etchash dataset item count prime")
        let kernelCatalog = try MetalAlgorithmKernelCatalog()
        let compiledKernels = try kernelCatalog.compileAvailableKernels()
        try assert(compiledKernels == MetalAlgorithmKernelCatalog.kernelNames, "multi-algorithm Metal kernels compile")
        try kernelCatalog.runSmokeTests()

        let trustedGpuFinal = try EquihashSolver().trustedSolutionsFromGpuFinalRows([
            EquihashPartialRow(
                digest: [UInt8](repeating: 0, count: EquihashParameters.zcash.digestByteCount),
                indices: (1...UInt32(EquihashParameters.zcash.solutionIndexCount)).map { $0 }
            )
        ])
        try assert(trustedGpuFinal.count == 1, "trusted GPU final row conversion")
        try assert(trustedGpuFinal[0].encoded.count == EquihashParameters.zcash.encodedSolutionByteCount, "trusted GPU final encoding")

        let miningDutchSubscribe = StratumClient.parseSubscribeResult([NSNull(), "0120cf9b"], mode: .zcashZip301)
        try assert(miningDutchSubscribe.nonce1 == "0120cf9b", "nullable ZIP-301 session id")
        try assert(miningDutchSubscribe.sessionID == nil, "nullable ZIP-301 session value")
        var miningDutchConfig = StratumConfiguration()
        miningDutchConfig.password = StratumConfiguration.miningDutchLowDifficultyPassword
        try assert(miningDutchConfig.suggestedDifficulty == 0.000000001, "Mining-Dutch suggested difficulty")
        try assert(miningDutchConfig.suggestedTarget == StratumConfiguration.easiestShareTarget, "Mining-Dutch suggested target")
        let nonce2ForMiningDutch = MinerViewModel.makeNonce2(counter: 1, nonce1Hex: miningDutchSubscribe.nonce1)
        try assert(nonce2ForMiningDutch.count == 64 - miningDutchSubscribe.nonce1.count, "ZIP-301 nonce2 length")
        try assert(nonce2ForMiningDutch.hasPrefix("0100000000000000"), "ZIP-301 nonce2 little-endian counter")
        let entropyNonce2 = MinerViewModel.makeNonce2(
            counter: 1,
            nonce1Hex: miningDutchSubscribe.nonce1,
            entropy: Array(0..<32).map(UInt8.init)
        )
        try assert(entropyNonce2.hasPrefix("0100000000000000"), "ZIP-301 nonce2 keeps counter in low bytes")
        try assert(entropyNonce2.dropFirst(16).prefix(8) == "08090a0b", "ZIP-301 nonce2 preserves run entropy")

        let liveMiningDutchJob = try ZcashStratumJob(params: [
            "7a65632d63353538-422",
            "04000000",
            "aed1f363ed27d354c25c9247165478ee773c58485dd78f87a7e30b0000000000",
            "2b9afe0b0103a01c43d28457549cf986633da7a715a3aedeb4b6c4b2a9f5a9ae",
            "3b1b7e8a52561536982603f35f1ea277078cf3a5fadeb820e09efda5e9aae7f9",
            "fb90136a",
            "b9c5001c",
            true,
            "200_9",
            "ZcashPoW"
        ])
        try assert(liveMiningDutchJob.id == "7a65632d63353538-422", "live ZIP-301 job id")

        let rowGenerator = try MetalEquihashRowGenerator()
        let metalRows = try rowGenerator.generateRows(powHeader: header, rowCount: 2)
        try assert(metalRows.result.cpuMatchesFirstRow, "Metal initial row 1")
        let cpuSecond = try EquihashSolver().initialRow(powHeader: header, index: 2)
        try assert(metalRows.rows[1].digest == cpuSecond.digest, "Metal initial row 2")

        let roundOne = try rowGenerator.generateRoundOnePairs(powHeader: header, rowCount: 2, bucketSlots: 2)
        try assert(!roundOne.overflow, "Metal round-1 overflow on tiny sample")
        try assert(roundOne.matchesExpectedPairCount, "Metal round-1 expected pair count")

        let roundOneRows = try rowGenerator.generateRoundOneRows(powHeader: header, rowCount: 4_096, bucketSlots: 4)
        try assert(!roundOneRows.result.overflow, "Metal round-1 row export overflow")
        try assert(roundOneRows.rows.count == roundOneRows.result.pairCount, "Metal round-1 exported row count")
        if let firstPair = roundOneRows.rows.first {
            try assert(firstPair.digest.count == EquihashParameters.zcash.digestByteCount, "Metal round-1 exported digest width")
            try assert(firstPair.indices.count == 2, "Metal round-1 exported index width")
        }

        let roundTwoRows = try rowGenerator.generateRoundTwoRows(powHeader: header, rowCount: 65_536, bucketSlots: 8)
        try assert(!roundTwoRows.result.overflow, "Metal round-2 row export overflow")
        try assert(roundTwoRows.rows.count == roundTwoRows.result.pairCount, "Metal round-2 exported row count")
        if let firstPair = roundTwoRows.rows.first {
            try assert(firstPair.digest.count == EquihashParameters.zcash.digestByteCount, "Metal round-2 exported digest width")
            try assert(firstPair.indices.count == 4, "Metal round-2 exported index width")
        }

        let budgetedRows = try rowGenerator.generateWagnerRows(
            powHeader: header,
            rounds: 3,
            rowCount: 65_536,
            bucketSlots: 8,
            memoryBudgetBytes: 256 * 1_024 * 1_024
        )
        try assert(!budgetedRows.result.overflow, "Metal budgeted Wagner overflow")
        try assert((1...3).contains(budgetedRows.completedRounds), "Metal budgeted Wagner completed rounds")
        try assert(budgetedRows.rows.count == budgetedRows.result.pairCount, "Metal budgeted Wagner row count")
        if let firstPair = budgetedRows.rows.first {
            let expectedWidth = 1 << budgetedRows.completedRounds
            try assert(firstPair.digest.count == EquihashParameters.zcash.digestByteCount, "Metal budgeted Wagner digest width")
            try assert(firstPair.indices.count == expectedWidth, "Metal budgeted Wagner index width")
        }
    }

    private static func assert(_ condition: Bool, _ label: String) throws {
        if !condition {
            throw SelfTestError.failed(label)
        }
    }
}

enum SelfTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let label):
            return "Self-test failed: \(label)"
        }
    }
}
