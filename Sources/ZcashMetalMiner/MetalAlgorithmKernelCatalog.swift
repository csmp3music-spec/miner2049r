import Foundation
import Metal

struct MetalAlgorithmKernelCatalog {
    private struct MultiAlgoSeedConfig {
        var headerLength: UInt32
        var nonce: UInt32
        var itemCount: UInt32
        var outputStride: UInt32
    }

    private struct EthashHashimotoConfig {
        var headerLength: UInt32
        var nonce: UInt32
        var itemCount: UInt32
        var dagWordCount: UInt32
        var accesses: UInt32
    }

    private struct EthashDatasetConfig {
        var cacheNodeCount: UInt32
        var itemCount: UInt32
        var parents: UInt32
        var outputStride: UInt32
    }

    private struct ProgPowConfig {
        var dagWordCount: UInt32
        var lanes: UInt32
        var rounds: UInt32
        var outputStride: UInt32
        var programSeed: UInt32
        var cacheWordCount: UInt32
    }

    private struct ProgPowVectorConfig {
        var iterations: UInt32
        var reserved0: UInt32 = 0
        var reserved1: UInt32 = 0
        var reserved2: UInt32 = 0
    }

    private struct AutolykosConfig {
        var messageWordCount: UInt32
        var tableWordCount: UInt32
        var lookups: UInt32
        var outputStride: UInt32
    }

    static let kernelNames = [
        "multiAlgoKeccak512Seed",
        "ethashEtchashDagMix",
        "ethashDatasetItemLite",
        "ethashHashimotoLite",
        "progpowLaneMix",
        "progpowReferenceVectors",
        "progpowMergeLanes",
        "autolykosLookupMix"
    ]

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw GeneratorError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GeneratorError.commandQueueUnavailable
        }
        self.device = device
        self.queue = queue
    }

    func compileAvailableKernels() throws -> [String] {
        let library = try makeLibrary()
        var compiled: [String] = []
        for name in Self.kernelNames {
            _ = try makePipeline(named: name, in: library)
            compiled.append(name)
        }
        return compiled
    }

    func runSmokeTests() throws {
        let library = try makeLibrary()
        try runKeccakSeedSmokeTest(library: library)
        try runEthashDatasetSmokeTest(library: library)
        try runHashimotoSmokeTest(library: library)
        try runProgPowSmokeTest(library: library)
        try runProgPowVectorTest(library: library)
        try runProgPowMergeSmokeTest(library: library)
        try runAutolykosSmokeTest(library: library)
    }

    private func makeLibrary() throws -> MTLLibrary {
        guard
            let url = Bundle.module.url(forResource: "MultiAlgorithmPrimitives", withExtension: "metal"),
            let source = try? String(contentsOf: url)
        else {
            throw GeneratorError.resourceMissing
        }
        return try device.makeLibrary(source: source, options: nil)
    }

    private func makePipeline(named name: String, in library: MTLLibrary) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw GeneratorError.pipelineUnavailable
        }
        return try device.makeComputePipelineState(function: function)
    }

    private func runKeccakSeedSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "multiAlgoKeccak512Seed", in: library)
        let header = Data("miner-2049er".utf8)
        var nonce = UInt32(7)
        let nonceBytes = withUnsafeBytes(of: &nonce) { Data($0) }
        let expected = EthashPrimitives.keccak512(header + nonceBytes)
        var config = MultiAlgoSeedConfig(
            headerLength: UInt32(header.count),
            nonce: nonce,
            itemCount: 1,
            outputStride: 64
        )
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<MultiAlgoSeedConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](header), length: header.count),
              let outputBuffer = device.makeBuffer(length: 64, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, headerBuffer, outputBuffer],
            threads: MTLSize(width: 1, height: 1, depth: 1)
        )
        let output = Data(bytes: outputBuffer.contents(), count: 64)
        guard output == expected else {
            throw KernelCatalogError.smokeTestFailed("multiAlgoKeccak512Seed")
        }
    }

    private func runHashimotoSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "ethashHashimotoLite", in: library)
        let header = Data((0..<32).map(UInt8.init))
        var config = EthashHashimotoConfig(
            headerLength: UInt32(header.count),
            nonce: 11,
            itemCount: 1,
            dagWordCount: 128,
            accesses: 8
        )
        var dag = (0..<128).map { UInt32($0) &* 2_654_435_761 }
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<EthashHashimotoConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](header), length: header.count),
              let dagBuffer = device.makeBuffer(bytes: &dag, length: dag.count * MemoryLayout<UInt32>.stride),
              let outputBuffer = device.makeBuffer(length: 64, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, headerBuffer, dagBuffer, outputBuffer],
            threads: MTLSize(width: 1, height: 1, depth: 1)
        )
        let output = Data(bytes: outputBuffer.contents(), count: 64)
        guard output.contains(where: { $0 != 0 }) else {
            throw KernelCatalogError.smokeTestFailed("ethashHashimotoLite")
        }
    }

    private func runEthashDatasetSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "ethashDatasetItemLite", in: library)
        var config = EthashDatasetConfig(cacheNodeCount: 8, itemCount: 2, parents: 16, outputStride: 16)
        var cache = (0..<128).map { (UInt32($0) &* 747_796_405) &+ 2_891_336_453 }
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<EthashDatasetConfig>.stride),
              let cacheBuffer = device.makeBuffer(bytes: &cache, length: cache.count * MemoryLayout<UInt32>.stride),
              let outputBuffer = device.makeBuffer(length: 2 * 16 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, cacheBuffer, outputBuffer],
            threads: MTLSize(width: 2, height: 1, depth: 1)
        )
        let output = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: 32)
        guard (0..<32).contains(where: { output[$0] != 0 }),
              (0..<16).contains(where: { output[$0] != output[16 + $0] }) else {
            throw KernelCatalogError.smokeTestFailed("ethashDatasetItemLite")
        }
    }

    private func runProgPowSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "progpowLaneMix", in: library)
        var config = ProgPowConfig(
            dagWordCount: 128,
            lanes: 4,
            rounds: 12,
            outputStride: 4,
            programSeed: 19,
            cacheWordCount: 64
        )
        var seed = (0..<8).map { UInt32($0 &+ 1) }
        var dag = (0..<128).map { (UInt32($0) &* 1_664_525) &+ 1_013_904_223 }
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<ProgPowConfig>.stride),
              let seedBuffer = device.makeBuffer(bytes: &seed, length: seed.count * MemoryLayout<UInt32>.stride),
              let dagBuffer = device.makeBuffer(bytes: &dag, length: dag.count * MemoryLayout<UInt32>.stride),
              let outputBuffer = device.makeBuffer(length: 4 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, seedBuffer, dagBuffer, outputBuffer],
            threads: MTLSize(width: 4, height: 1, depth: 1)
        )
        let output = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
        guard (0..<4).contains(where: { output[$0] != 0 }) else {
            throw KernelCatalogError.smokeTestFailed("progpowLaneMix")
        }
    }

    private func runProgPowVectorTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "progpowReferenceVectors", in: library)
        var config = ProgPowVectorConfig(iterations: 100_000)
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<ProgPowVectorConfig>.stride),
              let outputBuffer = device.makeBuffer(length: 8 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, outputBuffer],
            threads: MTLSize(width: 1, height: 1, depth: 1)
        )
        let output = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        let expected: [UInt32] = [
            0xd37e_e61a,
            0xdedc_7ad4,
            0xa915_5bbc,
            769_445_856,
            742_012_328,
            2_121_196_314,
            2_805_620_942,
            941_074_834
        ]
        guard expected.indices.allSatisfy({ output[$0] == expected[$0] }) else {
            throw KernelCatalogError.smokeTestFailed("progpowReferenceVectors")
        }
    }

    private func runProgPowMergeSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "progpowMergeLanes", in: library)
        var config = ProgPowConfig(
            dagWordCount: 128,
            lanes: 4,
            rounds: 12,
            outputStride: 8,
            programSeed: 19,
            cacheWordCount: 64
        )
        var lanes = (0..<4).map { (UInt32($0) &* 1_103_515_245) &+ 12_345 }
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<ProgPowConfig>.stride),
              let laneBuffer = device.makeBuffer(bytes: &lanes, length: lanes.count * MemoryLayout<UInt32>.stride),
              let outputBuffer = device.makeBuffer(length: 8 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, laneBuffer, outputBuffer],
            threads: MTLSize(width: 1, height: 1, depth: 1)
        )
        let output = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        guard (0..<8).contains(where: { output[$0] != 0x811c9dc5 }) else {
            throw KernelCatalogError.smokeTestFailed("progpowMergeLanes")
        }
    }

    private func runAutolykosSmokeTest(library: MTLLibrary) throws {
        let pipeline = try makePipeline(named: "autolykosLookupMix", in: library)
        var config = AutolykosConfig(messageWordCount: 8, tableWordCount: 64, lookups: 16, outputStride: 4)
        var message = (0..<8).map { UInt32($0 &* 17 &+ 3) }
        var table = (0..<64).map { UInt32($0 &* 97 &+ 31) }
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<AutolykosConfig>.stride),
              let messageBuffer = device.makeBuffer(bytes: &message, length: message.count * MemoryLayout<UInt32>.stride),
              let tableBuffer = device.makeBuffer(bytes: &table, length: table.count * MemoryLayout<UInt32>.stride),
              let outputBuffer = device.makeBuffer(length: 4 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        try dispatch(
            pipeline: pipeline,
            buffers: [configBuffer, messageBuffer, tableBuffer, outputBuffer],
            threads: MTLSize(width: 1, height: 1, depth: 1)
        )
        let output = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
        guard (0..<4).contains(where: { output[$0] != 0 }) else {
            throw KernelCatalogError.smokeTestFailed("autolykosLookupMix")
        }
    }

    private func dispatch(
        pipeline: MTLComputePipelineState,
        buffers: [MTLBuffer],
        threads: MTLSize
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        let width = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth))
        encoder.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }
    }
}

enum KernelCatalogError: LocalizedError {
    case smokeTestFailed(String)

    var errorDescription: String? {
        switch self {
        case .smokeTestFailed(let kernel):
            return "Metal kernel smoke test failed for \(kernel)."
        }
    }
}
