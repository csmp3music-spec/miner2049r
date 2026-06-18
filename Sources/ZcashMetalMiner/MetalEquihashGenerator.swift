import Foundation
import Metal

struct GeneratorResult {
    let inputCount: Int
    let elapsedSeconds: TimeInterval
    let firstDigest: Data
    let cpuMatchesFirstDigest: Bool
    let threadgroupSize: Int
    let hashesPerThread: Int
    let checksum: UInt32

    var solutionsPerSecond: Double {
        elapsedSeconds > 0 ? Double(inputCount) / elapsedSeconds : 0
    }
}

struct MiningRunConfiguration: Equatable {
    var threadgroupSize: Int
    var hashesPerThread: Int

    static let automatic = MiningRunConfiguration(threadgroupSize: 0, hashesPerThread: 4)
}

struct TuningResult: Identifiable {
    let id = UUID()
    let configuration: MiningRunConfiguration
    let result: GeneratorResult
}

enum GeneratorError: LocalizedError {
    case noMetalDevice
    case resourceMissing
    case pipelineUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case outputUnavailable
    case headerTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "No Metal-capable GPU is available."
        case .resourceMissing:
            return "The Metal kernel resource could not be loaded."
        case .pipelineUnavailable:
            return "The Metal compute pipeline could not be created."
        case .commandQueueUnavailable:
            return "The Metal command queue could not be created."
        case .commandBufferUnavailable:
            return "The Metal command buffer could not be created."
        case .outputUnavailable:
            return "The GPU output buffer could not be read."
        case .headerTooLarge(let length):
            return "The benchmark generator currently supports headers up to 120 bytes; got \(length)."
        }
    }
}

final class MetalEquihashGenerator {
    private struct WorkConfig {
        var headerLength: UInt32
        var outputStride: UInt32
        var nonce: UInt32
        var inputCount: UInt32
        var hashesPerThread: UInt32
        var checksumOffset: UInt32
        var reserved0: UInt32 = 0
        var reserved1: UInt32 = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    var deviceName: String { device.name }
    var executionWidth: Int { pipeline.threadExecutionWidth }
    var maxThreadsPerThreadgroup: Int { pipeline.maxTotalThreadsPerThreadgroup }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GeneratorError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GeneratorError.commandQueueUnavailable
        }
        guard
            let url = Bundle.module.url(forResource: "ZcashEquihash", withExtension: "metal"),
            let source = try? String(contentsOf: url)
        else {
            throw GeneratorError.resourceMissing
        }

        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "equihashGenerate") else {
            throw GeneratorError.pipelineUnavailable
        }

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    }

    func run(header: Data, inputCount: Int, nonce: UInt32, configuration: MiningRunConfiguration = .automatic) throws -> GeneratorResult {
        guard header.count <= 120 else {
            throw GeneratorError.headerTooLarge(header.count)
        }

        let hashesPerThread = max(1, configuration.hashesPerThread)
        let threadCount = (inputCount + hashesPerThread - 1) / hashesPerThread
        let threadgroupSize = resolvedThreadgroupSize(configuration.threadgroupSize)
        let checksumOffset = 64
        let outputByteCount = checksumOffset + (threadCount * MemoryLayout<UInt32>.stride)
        var config = WorkConfig(
            headerLength: UInt32(header.count),
            outputStride: 50,
            nonce: nonce,
            inputCount: UInt32(inputCount),
            hashesPerThread: UInt32(hashesPerThread),
            checksumOffset: UInt32(checksumOffset)
        )

        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<WorkConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](header), length: max(header.count, 1)),
              let outputBuffer = device.makeBuffer(length: outputByteCount, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }

        let started = CFAbsoluteTimeGetCurrent()
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(configBuffer, offset: 0, index: 0)
        encoder.setBuffer(headerBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)

        let threadsPerThreadgroup = MTLSize(width: threadgroupSize, height: 1, depth: 1)
        let threads = MTLSize(width: threadCount, height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let wallElapsed = CFAbsoluteTimeGetCurrent() - started
        let gpuElapsed = commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
            ? commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
            : 0
        let elapsed = gpuElapsed > 0 ? gpuElapsed : wallElapsed

        if let error = commandBuffer.error {
            throw error
        }

        let firstDigest = Data(bytes: outputBuffer.contents(), count: 50)
        let checksumStart = outputBuffer.contents().advanced(by: checksumOffset).assumingMemoryBound(to: UInt32.self)
        var checksum: UInt32 = 0
        for i in 0..<threadCount {
            checksum ^= checksumStart[i]
        }
        var cpuInput = Data(header)
        cpuInput.append(contentsOf: nonce.littleEndianBytes)
        cpuInput.append(contentsOf: UInt32(0).littleEndianBytes)
        let cpuDigest = Blake2b400.zcashPersonalizedDigest(input: cpuInput)

        return GeneratorResult(
            inputCount: inputCount,
            elapsedSeconds: elapsed,
            firstDigest: firstDigest,
            cpuMatchesFirstDigest: firstDigest == cpuDigest,
            threadgroupSize: threadgroupSize,
            hashesPerThread: hashesPerThread,
            checksum: checksum
        )
    }

    func tune(header: Data, inputCount: Int) throws -> [TuningResult] {
        var candidates = Set<MiningRunConfiguration>()
        let widths = [1, 2, 4, 8].map { executionWidth * $0 }
        for width in widths where width <= maxThreadsPerThreadgroup {
            for hashesPerThread in [1, 2, 4, 8, 16] {
                candidates.insert(MiningRunConfiguration(threadgroupSize: width, hashesPerThread: hashesPerThread))
            }
        }

        var results: [TuningResult] = []
        for candidate in candidates.sorted(by: { lhs, rhs in
            if lhs.threadgroupSize == rhs.threadgroupSize {
                return lhs.hashesPerThread < rhs.hashesPerThread
            }
            return lhs.threadgroupSize < rhs.threadgroupSize
        }) {
            let result = try run(
                header: header,
                inputCount: inputCount,
                nonce: UInt32.random(in: 0..<UInt32.max),
                configuration: candidate
            )
            results.append(TuningResult(configuration: candidate, result: result))
        }
        return results.sorted { $0.result.solutionsPerSecond > $1.result.solutionsPerSecond }
    }

    private func resolvedThreadgroupSize(_ requested: Int) -> Int {
        guard requested > 0 else {
            return min(maxThreadsPerThreadgroup, max(executionWidth, executionWidth * 4))
        }
        let aligned = max(executionWidth, (requested / executionWidth) * executionWidth)
        return min(maxThreadsPerThreadgroup, aligned)
    }
}

extension MiningRunConfiguration: Hashable {}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
