import Foundation
import Metal
import Darwin

struct MetalRowGenerationResult {
    let rowCount: Int
    let elapsedSeconds: TimeInterval
    let firstRow: EquihashInitialRow
    let firstKey: UInt32
    let cpuMatchesFirstRow: Bool

    var rowsPerSecond: Double {
        elapsedSeconds > 0 ? Double(rowCount) / elapsedSeconds : 0
    }
}

struct MetalRoundOneResult {
    let rowCount: Int
    let elapsedSeconds: TimeInterval
    let pairCount: Int
    let expectedPairCount: Int
    let bucketSlots: Int
    let overflow: Bool
    let firstPairKey: UInt32?

    var pairsPerSecond: Double {
        elapsedSeconds > 0 ? Double(pairCount) / elapsedSeconds : 0
    }

    var matchesExpectedPairCount: Bool {
        !overflow && pairCount == expectedPairCount
    }
}

final class MetalEquihashRowGenerator {
    private struct RowConfig {
        var headerLength: UInt32
        var rowCount: UInt32
        var collisionBits: UInt32
        var reserved: UInt32 = 0
    }

    private struct RoundOneConfig {
        var rowCount: UInt32
        var bucketCount: UInt32
        var bucketSlots: UInt32
        var maxPairs: UInt32
        var secondKeyOffset: UInt32
        var collisionBits: UInt32
        var inputIndexWidth: UInt32
        var reserved1: UInt32 = 0
    }

    private struct CompactConfig {
        var rowCount: UInt32
        var indexWidth: UInt32
        var maxSolutions: UInt32
        var reserved: UInt32 = 0
    }

    private let parameters = EquihashParameters.zcash
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let bucketPipeline: MTLComputePipelineState
    private let roundOnePipeline: MTLComputePipelineState
    private let finalRoundPipeline: MTLComputePipelineState
    private let compactPipeline: MTLComputePipelineState

    var executionWidth: Int { pipeline.threadExecutionWidth }
    var maxThreadsPerThreadgroup: Int { pipeline.maxTotalThreadsPerThreadgroup }
    var recommendedSolverMemoryBudgetBytes: Int {
        let recommended = device.recommendedMaxWorkingSetSize
        if recommended > 0 {
            return Int(min(Double(recommended) * 0.85, Double(12 * 1_024 * 1_024 * 1_024)))
        }
        return 4 * 1_024 * 1_024 * 1_024
    }

    init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
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
        guard let function = library.makeFunction(name: "equihashInitialRows"),
              let clearFunction = library.makeFunction(name: "clearUIntBuffer"),
              let bucketFunction = library.makeFunction(name: "equihashBucketInitialRows"),
              let roundOneFunction = library.makeFunction(name: "equihashRoundOnePairs"),
              let finalRoundFunction = library.makeFunction(name: "equihashFinalRoundSolutions"),
              let compactFunction = library.makeFunction(name: "equihashCompactZeroRows") else {
            throw GeneratorError.pipelineUnavailable
        }

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        let clearDescriptor = MTLComputePipelineDescriptor()
        clearDescriptor.computeFunction = clearFunction
        clearDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        let bucketDescriptor = MTLComputePipelineDescriptor()
        bucketDescriptor.computeFunction = bucketFunction
        bucketDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        let roundOneDescriptor = MTLComputePipelineDescriptor()
        roundOneDescriptor.computeFunction = roundOneFunction
        roundOneDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        let finalRoundDescriptor = MTLComputePipelineDescriptor()
        finalRoundDescriptor.computeFunction = finalRoundFunction
        finalRoundDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        let compactDescriptor = MTLComputePipelineDescriptor()
        compactDescriptor.computeFunction = compactFunction
        compactDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        self.clearPipeline = try device.makeComputePipelineState(descriptor: clearDescriptor, options: [], reflection: nil)
        self.bucketPipeline = try device.makeComputePipelineState(descriptor: bucketDescriptor, options: [], reflection: nil)
        self.roundOnePipeline = try device.makeComputePipelineState(descriptor: roundOneDescriptor, options: [], reflection: nil)
        self.finalRoundPipeline = try device.makeComputePipelineState(descriptor: finalRoundDescriptor, options: [], reflection: nil)
        self.compactPipeline = try device.makeComputePipelineState(descriptor: compactDescriptor, options: [], reflection: nil)
    }

    func generateRows(powHeader: Data, rowCount requestedRows: Int? = nil) throws -> (rows: [EquihashInitialRow], result: MetalRowGenerationResult) {
        guard powHeader.count <= 140 else {
            throw GeneratorError.headerTooLarge(powHeader.count)
        }

        let rowCount = requestedRows.map { min($0, parameters.inputIndexCount) } ?? parameters.inputIndexCount
        var config = RowConfig(
            headerLength: UInt32(powHeader.count),
            rowCount: UInt32(rowCount),
            collisionBits: UInt32(parameters.collisionBitLength)
        )

        let digestByteCount = rowCount * parameters.digestByteCount
        let indexByteCount = rowCount * MemoryLayout<UInt32>.stride
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<RowConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](powHeader), length: max(powHeader.count, 1)),
              let digestBuffer = device.makeBuffer(length: digestByteCount, options: [.storageModeShared]),
              let indexBuffer = device.makeBuffer(length: indexByteCount, options: [.storageModeShared]),
              let keyBuffer = device.makeBuffer(length: indexByteCount, options: [.storageModeShared]) else {
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
        encoder.setBuffer(digestBuffer, offset: 0, index: 2)
        encoder.setBuffer(indexBuffer, offset: 0, index: 3)
        encoder.setBuffer(keyBuffer, offset: 0, index: 4)

        let threadsPerThreadgroup = MTLSize(width: min(maxThreadsPerThreadgroup, max(executionWidth, executionWidth * 4)), height: 1, depth: 1)
        let threads = MTLSize(width: rowCount, height: 1, depth: 1)
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

        let digestPointer = digestBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let keyPointer = keyBuffer.contents().assumingMemoryBound(to: UInt32.self)

        var rows: [EquihashInitialRow] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let start = row * parameters.digestByteCount
            let digest = Array(UnsafeBufferPointer(start: digestPointer.advanced(by: start), count: parameters.digestByteCount))
            rows.append(EquihashInitialRow(digest: digest, index: indexPointer[row]))
        }

        let firstRow = rows[0]
        let cpuFirst = try EquihashSolver(parameters: parameters).initialRow(powHeader: powHeader, index: 1)
        let result = MetalRowGenerationResult(
            rowCount: rowCount,
            elapsedSeconds: elapsed,
            firstRow: firstRow,
            firstKey: keyPointer[0],
            cpuMatchesFirstRow: firstRow.digest == cpuFirst.digest && firstRow.index == cpuFirst.index
        )
        return (rows, result)
    }

    func generateRoundOnePairs(powHeader: Data, rowCount requestedRows: Int? = nil, bucketSlots: Int = 16) throws -> MetalRoundOneResult {
        (try generateRoundOneRows(
            powHeader: powHeader,
            rowCount: requestedRows,
            bucketSlots: bucketSlots
        )).result
    }

    func generateRoundOneRows(
        powHeader: Data,
        rowCount requestedRows: Int? = nil,
        bucketSlots: Int = 16
    ) throws -> (rows: [EquihashPartialRow], result: MetalRoundOneResult) {
        guard powHeader.count <= 140 else {
            throw GeneratorError.headerTooLarge(powHeader.count)
        }

        let rowCount = requestedRows.map { min($0, parameters.inputIndexCount) } ?? parameters.inputIndexCount
        let bucketCount = 1 << parameters.collisionBitLength
        let bucketSlots = max(2, bucketSlots)
        let maxPairs = max(rowCount, rowCount * 4)

        var rowConfig = RowConfig(
            headerLength: UInt32(powHeader.count),
            rowCount: UInt32(rowCount),
            collisionBits: UInt32(parameters.collisionBitLength)
        )
        var roundConfig = RoundOneConfig(
            rowCount: UInt32(rowCount),
            bucketCount: UInt32(bucketCount),
            bucketSlots: UInt32(bucketSlots),
            maxPairs: UInt32(maxPairs),
            secondKeyOffset: UInt32(parameters.collisionBitLength),
            collisionBits: UInt32(parameters.collisionBitLength),
            inputIndexWidth: 1
        )

        let digestByteCount = rowCount * parameters.digestByteCount
        let rowIndexByteCount = rowCount * MemoryLayout<UInt32>.stride
        let bucketCountByteCount = bucketCount * MemoryLayout<UInt32>.stride
        let bucketSlotByteCount = bucketCount * bucketSlots * MemoryLayout<UInt32>.stride
        let pairDigestByteCount = maxPairs * parameters.digestByteCount
        let pairIndexByteCount = maxPairs * 2 * MemoryLayout<UInt32>.stride
        let pairKeyByteCount = maxPairs * MemoryLayout<UInt32>.stride

        guard let rowConfigBuffer = device.makeBuffer(bytes: &rowConfig, length: MemoryLayout<RowConfig>.stride),
              let roundConfigBuffer = device.makeBuffer(bytes: &roundConfig, length: MemoryLayout<RoundOneConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](powHeader), length: max(powHeader.count, 1)),
              let rowDigestBuffer = device.makeBuffer(length: digestByteCount, options: [.storageModeShared]),
              let rowIndexBuffer = device.makeBuffer(length: rowIndexByteCount, options: [.storageModeShared]),
              let rowKeyBuffer = device.makeBuffer(length: rowIndexByteCount, options: [.storageModeShared]),
              let bucketCountBuffer = device.makeBuffer(length: bucketCountByteCount, options: [.storageModeShared]),
              let bucketSlotBuffer = device.makeBuffer(length: bucketSlotByteCount, options: [.storageModeShared]),
              let pairDigestBuffer = device.makeBuffer(length: pairDigestByteCount, options: [.storageModeShared]),
              let pairIndexBuffer = device.makeBuffer(length: pairIndexByteCount, options: [.storageModeShared]),
              let pairKeyBuffer = device.makeBuffer(length: pairKeyByteCount, options: [.storageModeShared]),
              let pairCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]),
              let overflowBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        memset(bucketCountBuffer.contents(), 0, bucketCountByteCount)
        memset(bucketSlotBuffer.contents(), 0, bucketSlotByteCount)
        memset(pairCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)
        memset(overflowBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw GeneratorError.commandBufferUnavailable
        }

        let started = CFAbsoluteTimeGetCurrent()
        try encodeInitialRows(
            commandBuffer: commandBuffer,
            configBuffer: rowConfigBuffer,
            headerBuffer: headerBuffer,
            digestBuffer: rowDigestBuffer,
            indexBuffer: rowIndexBuffer,
            keyBuffer: rowKeyBuffer,
            rowCount: rowCount
        )
        try encodeBucketRows(
            commandBuffer: commandBuffer,
            roundConfigBuffer: roundConfigBuffer,
            rowKeyBuffer: rowKeyBuffer,
            bucketCountBuffer: bucketCountBuffer,
            bucketSlotBuffer: bucketSlotBuffer,
            overflowBuffer: overflowBuffer,
            rowCount: rowCount
        )
        try encodeRoundOnePairs(
            commandBuffer: commandBuffer,
            roundConfigBuffer: roundConfigBuffer,
            rowDigestBuffer: rowDigestBuffer,
            rowIndexBuffer: rowIndexBuffer,
            bucketCountBuffer: bucketCountBuffer,
            bucketSlotBuffer: bucketSlotBuffer,
            pairDigestBuffer: pairDigestBuffer,
            pairIndexBuffer: pairIndexBuffer,
            pairKeyBuffer: pairKeyBuffer,
            pairCounterBuffer: pairCounterBuffer,
            overflowBuffer: overflowBuffer,
            bucketCount: bucketCount
        )

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

        let pairCount = min(Int(pairCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee), maxPairs)
        let overflow = overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0
        let bucketCounts = bucketCountBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var expectedPairs = 0
        for bucket in 0..<bucketCount {
            let count = Int(bucketCounts[bucket])
            expectedPairs += count * max(0, count - 1) / 2
        }
        let firstKey = pairCount > 0 ? pairKeyBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee : nil

        let pairDigestPointer = pairDigestBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let pairIndexPointer = pairIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var rows: [EquihashPartialRow] = []
        rows.reserveCapacity(pairCount)
        for row in 0..<pairCount {
            let digestStart = row * parameters.digestByteCount
            let digest = Array(
                UnsafeBufferPointer(
                    start: pairDigestPointer.advanced(by: digestStart),
                    count: parameters.digestByteCount
                )
            )
            let indexStart = row * 2
            rows.append(
                EquihashPartialRow(
                    digest: digest,
                    indices: [pairIndexPointer[indexStart], pairIndexPointer[indexStart + 1]]
                )
            )
        }

        let result = MetalRoundOneResult(
            rowCount: rowCount,
            elapsedSeconds: elapsed,
            pairCount: pairCount,
            expectedPairCount: expectedPairs,
            bucketSlots: bucketSlots,
            overflow: overflow,
            firstPairKey: firstKey
        )
        return (rows, result)
    }

    func generateRoundTwoRows(
        powHeader: Data,
        rowCount requestedRows: Int? = nil,
        bucketSlots: Int = 32
    ) throws -> (rows: [EquihashPartialRow], result: MetalRoundOneResult) {
        guard powHeader.count <= 140 else {
            throw GeneratorError.headerTooLarge(powHeader.count)
        }

        let rowCount = requestedRows.map { min($0, parameters.inputIndexCount) } ?? parameters.inputIndexCount
        let bucketCount = 1 << parameters.collisionBitLength
        let bucketSlots = max(2, bucketSlots)
        let firstMaxPairs = max(rowCount, rowCount * 4)

        var rowConfig = RowConfig(
            headerLength: UInt32(powHeader.count),
            rowCount: UInt32(rowCount),
            collisionBits: UInt32(parameters.collisionBitLength)
        )
        var firstConfig = RoundOneConfig(
            rowCount: UInt32(rowCount),
            bucketCount: UInt32(bucketCount),
            bucketSlots: UInt32(bucketSlots),
            maxPairs: UInt32(firstMaxPairs),
            secondKeyOffset: UInt32(parameters.collisionBitLength),
            collisionBits: UInt32(parameters.collisionBitLength),
            inputIndexWidth: 1
        )

        let digestByteCount = rowCount * parameters.digestByteCount
        let rowIndexByteCount = rowCount * MemoryLayout<UInt32>.stride
        let bucketCountByteCount = bucketCount * MemoryLayout<UInt32>.stride
        let bucketSlotByteCount = bucketCount * bucketSlots * MemoryLayout<UInt32>.stride
        let firstPairDigestByteCount = firstMaxPairs * parameters.digestByteCount
        let firstPairIndexByteCount = firstMaxPairs * 2 * MemoryLayout<UInt32>.stride
        let firstPairKeyByteCount = firstMaxPairs * MemoryLayout<UInt32>.stride

        guard let rowConfigBuffer = device.makeBuffer(bytes: &rowConfig, length: MemoryLayout<RowConfig>.stride),
              let firstConfigBuffer = device.makeBuffer(bytes: &firstConfig, length: MemoryLayout<RoundOneConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](powHeader), length: max(powHeader.count, 1)),
              let rowDigestBuffer = device.makeBuffer(length: digestByteCount, options: [.storageModeShared]),
              let rowIndexBuffer = device.makeBuffer(length: rowIndexByteCount, options: [.storageModeShared]),
              let rowKeyBuffer = device.makeBuffer(length: rowIndexByteCount, options: [.storageModeShared]),
              let bucketCountBuffer = device.makeBuffer(length: bucketCountByteCount, options: [.storageModeShared]),
              let bucketSlotBuffer = device.makeBuffer(length: bucketSlotByteCount, options: [.storageModeShared]),
              let firstPairDigestBuffer = device.makeBuffer(length: firstPairDigestByteCount, options: [.storageModeShared]),
              let firstPairIndexBuffer = device.makeBuffer(length: firstPairIndexByteCount, options: [.storageModeShared]),
              let firstPairKeyBuffer = device.makeBuffer(length: firstPairKeyByteCount, options: [.storageModeShared]),
              let firstPairCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]),
              let overflowBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        memset(bucketCountBuffer.contents(), 0, bucketCountByteCount)
        memset(bucketSlotBuffer.contents(), 0, bucketSlotByteCount)
        memset(firstPairCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)
        memset(overflowBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

        guard let firstCommandBuffer = queue.makeCommandBuffer() else {
            throw GeneratorError.commandBufferUnavailable
        }

        let started = CFAbsoluteTimeGetCurrent()
        try encodeInitialRows(
            commandBuffer: firstCommandBuffer,
            configBuffer: rowConfigBuffer,
            headerBuffer: headerBuffer,
            digestBuffer: rowDigestBuffer,
            indexBuffer: rowIndexBuffer,
            keyBuffer: rowKeyBuffer,
            rowCount: rowCount
        )
        try encodeBucketRows(
            commandBuffer: firstCommandBuffer,
            roundConfigBuffer: firstConfigBuffer,
            rowKeyBuffer: rowKeyBuffer,
            bucketCountBuffer: bucketCountBuffer,
            bucketSlotBuffer: bucketSlotBuffer,
            overflowBuffer: overflowBuffer,
            rowCount: rowCount
        )
        try encodeRoundOnePairs(
            commandBuffer: firstCommandBuffer,
            roundConfigBuffer: firstConfigBuffer,
            rowDigestBuffer: rowDigestBuffer,
            rowIndexBuffer: rowIndexBuffer,
            bucketCountBuffer: bucketCountBuffer,
            bucketSlotBuffer: bucketSlotBuffer,
            pairDigestBuffer: firstPairDigestBuffer,
            pairIndexBuffer: firstPairIndexBuffer,
            pairKeyBuffer: firstPairKeyBuffer,
            pairCounterBuffer: firstPairCounterBuffer,
            overflowBuffer: overflowBuffer,
            bucketCount: bucketCount
        )
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()
        if let error = firstCommandBuffer.error {
            throw error
        }

        let firstPairCount = min(Int(firstPairCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee), firstMaxPairs)
        let secondMaxPairs = max(rowCount, min(firstMaxPairs, firstPairCount * 4))
        var secondConfig = RoundOneConfig(
            rowCount: UInt32(firstPairCount),
            bucketCount: UInt32(bucketCount),
            bucketSlots: UInt32(bucketSlots),
            maxPairs: UInt32(secondMaxPairs),
            secondKeyOffset: UInt32(parameters.collisionBitLength * 2),
            collisionBits: UInt32(parameters.collisionBitLength),
            inputIndexWidth: 2
        )

        let secondPairDigestByteCount = secondMaxPairs * parameters.digestByteCount
        let secondPairIndexByteCount = secondMaxPairs * 4 * MemoryLayout<UInt32>.stride
        let secondPairKeyByteCount = secondMaxPairs * MemoryLayout<UInt32>.stride
        guard let secondConfigBuffer = device.makeBuffer(bytes: &secondConfig, length: MemoryLayout<RoundOneConfig>.stride),
              let secondBucketCountBuffer = device.makeBuffer(length: bucketCountByteCount, options: [.storageModeShared]),
              let secondBucketSlotBuffer = device.makeBuffer(length: bucketSlotByteCount, options: [.storageModeShared]),
              let secondPairDigestBuffer = device.makeBuffer(length: secondPairDigestByteCount, options: [.storageModeShared]),
              let secondPairIndexBuffer = device.makeBuffer(length: secondPairIndexByteCount, options: [.storageModeShared]),
              let secondPairKeyBuffer = device.makeBuffer(length: secondPairKeyByteCount, options: [.storageModeShared]),
              let secondPairCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        memset(secondBucketCountBuffer.contents(), 0, bucketCountByteCount)
        memset(secondBucketSlotBuffer.contents(), 0, bucketSlotByteCount)
        memset(secondPairCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

        guard let secondCommandBuffer = queue.makeCommandBuffer() else {
            throw GeneratorError.commandBufferUnavailable
        }
        try encodeBucketRows(
            commandBuffer: secondCommandBuffer,
            roundConfigBuffer: secondConfigBuffer,
            rowKeyBuffer: firstPairKeyBuffer,
            bucketCountBuffer: secondBucketCountBuffer,
            bucketSlotBuffer: secondBucketSlotBuffer,
            overflowBuffer: overflowBuffer,
            rowCount: firstPairCount
        )
        try encodeRoundOnePairs(
            commandBuffer: secondCommandBuffer,
            roundConfigBuffer: secondConfigBuffer,
            rowDigestBuffer: firstPairDigestBuffer,
            rowIndexBuffer: firstPairIndexBuffer,
            bucketCountBuffer: secondBucketCountBuffer,
            bucketSlotBuffer: secondBucketSlotBuffer,
            pairDigestBuffer: secondPairDigestBuffer,
            pairIndexBuffer: secondPairIndexBuffer,
            pairKeyBuffer: secondPairKeyBuffer,
            pairCounterBuffer: secondPairCounterBuffer,
            overflowBuffer: overflowBuffer,
            bucketCount: bucketCount
        )
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()
        if let error = secondCommandBuffer.error {
            throw error
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let secondPairCount = min(Int(secondPairCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee), secondMaxPairs)
        let overflow = overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0
        let secondBucketCounts = secondBucketCountBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var expectedPairs = 0
        for bucket in 0..<bucketCount {
            let count = Int(secondBucketCounts[bucket])
            expectedPairs += count * max(0, count - 1) / 2
        }
        let firstKey = secondPairCount > 0 ? secondPairKeyBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee : nil

        let rows = copyPartialRows(
            digestBuffer: secondPairDigestBuffer,
            indexBuffer: secondPairIndexBuffer,
            rowCount: secondPairCount,
            indexWidth: 4
        )
        let result = MetalRoundOneResult(
            rowCount: rowCount,
            elapsedSeconds: elapsed,
            pairCount: secondPairCount,
            expectedPairCount: expectedPairs,
            bucketSlots: bucketSlots,
            overflow: overflow,
            firstPairKey: firstKey
        )
        return (rows, result)
    }

    func generateWagnerRows(
        powHeader: Data,
        rounds requestedRounds: Int,
        rowCount requestedRows: Int? = nil,
        bucketSlots: Int = 32,
        memoryBudgetBytes: Int? = nil,
        threadgroupMultiplier: Int = 4,
        exportIncompleteRows: Bool = true
    ) throws -> (rows: [EquihashPartialRow], completedRounds: Int, result: MetalRoundOneResult) {
        guard powHeader.count <= 140 else {
            throw GeneratorError.headerTooLarge(powHeader.count)
        }

        let rounds = max(1, min(requestedRounds, parameters.k))
        let initialRowCount = requestedRows.map { min($0, parameters.inputIndexCount) } ?? parameters.inputIndexCount
        let bucketCount = 1 << parameters.collisionBitLength
        let bucketSlots = max(2, bucketSlots)
        let maxPairLimit = max(initialRowCount, initialRowCount * 2)
        let memoryBudgetBytes = memoryBudgetBytes ?? recommendedSolverMemoryBudgetBytes
        let gpuOnlyOptions: MTLResourceOptions = [.storageModePrivate]

        var rowConfig = RowConfig(
            headerLength: UInt32(powHeader.count),
            rowCount: UInt32(initialRowCount),
            collisionBits: UInt32(parameters.collisionBitLength)
        )

        let digestByteCount = initialRowCount * parameters.digestByteCount
        let indexByteCount = initialRowCount * MemoryLayout<UInt32>.stride
        guard let rowConfigBuffer = device.makeBuffer(bytes: &rowConfig, length: MemoryLayout<RowConfig>.stride),
              let headerBuffer = device.makeBuffer(bytes: [UInt8](powHeader), length: max(powHeader.count, 1)),
              var currentDigestBuffer = device.makeBuffer(length: digestByteCount, options: gpuOnlyOptions),
              var currentIndexBuffer = device.makeBuffer(length: indexByteCount, options: gpuOnlyOptions),
              var currentKeyBuffer = device.makeBuffer(length: indexByteCount, options: gpuOnlyOptions),
              let overflowBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }

        memset(overflowBuffer.contents(), 0, MemoryLayout<UInt32>.stride)
        guard let initialCommandBuffer = queue.makeCommandBuffer() else {
            throw GeneratorError.commandBufferUnavailable
        }

        let started = CFAbsoluteTimeGetCurrent()
        try encodeInitialRows(
            commandBuffer: initialCommandBuffer,
            configBuffer: rowConfigBuffer,
            headerBuffer: headerBuffer,
            digestBuffer: currentDigestBuffer,
            indexBuffer: currentIndexBuffer,
            keyBuffer: currentKeyBuffer,
            rowCount: initialRowCount,
            threadgroupMultiplier: threadgroupMultiplier
        )
        initialCommandBuffer.commit()
        initialCommandBuffer.waitUntilCompleted()
        if let error = initialCommandBuffer.error {
            throw error
        }

        var currentRowCount = initialRowCount
        var currentIndexWidth = 1
        var expectedPairs = 0
        var firstKey: UInt32?
        var completedRounds = 0

        for round in 0..<rounds {
            if currentRowCount == 0 {
                break
            }

            let outputIndexWidth = currentIndexWidth * 2
            let bucketCountByteCount = bucketCount * MemoryLayout<UInt32>.stride
            let bucketSlotByteCount = bucketCount * bucketSlots * MemoryLayout<UInt32>.stride
            let fixedRoundBytes = estimateRoundFixedWorkingSetBytes(
                currentRowCount: currentRowCount,
                currentIndexWidth: currentIndexWidth,
                bucketCount: bucketCount,
                bucketSlots: bucketSlots
            )
            if fixedRoundBytes >= memoryBudgetBytes {
                if completedRounds == 0 {
                    throw GeneratorError.outputUnavailable
                }
                break
            }

            let bytesPerOutputPair = parameters.digestByteCount
                + MemoryLayout<UInt32>.stride
                + outputIndexWidth * MemoryLayout<UInt32>.stride
            var roundConfig = RoundOneConfig(
                rowCount: UInt32(currentRowCount),
                bucketCount: UInt32(bucketCount),
                bucketSlots: UInt32(bucketSlots),
                maxPairs: 1,
                secondKeyOffset: UInt32(parameters.collisionBitLength * (round + 1)),
                collisionBits: UInt32(parameters.collisionBitLength),
                inputIndexWidth: UInt32(currentIndexWidth)
            )

            guard let bucketConfigBuffer = device.makeBuffer(bytes: &roundConfig, length: MemoryLayout<RoundOneConfig>.stride),
                  let bucketCountBuffer = device.makeBuffer(length: bucketCountByteCount, options: [.storageModeShared]),
                  let bucketSlotBuffer = device.makeBuffer(length: bucketSlotByteCount, options: gpuOnlyOptions) else {
                throw GeneratorError.outputUnavailable
            }

            memset(bucketCountBuffer.contents(), 0, bucketCountByteCount)

            guard let bucketCommandBuffer = queue.makeCommandBuffer() else {
                throw GeneratorError.commandBufferUnavailable
            }
            try encodeBucketRows(
                commandBuffer: bucketCommandBuffer,
                roundConfigBuffer: bucketConfigBuffer,
                rowKeyBuffer: currentKeyBuffer,
                bucketCountBuffer: bucketCountBuffer,
                bucketSlotBuffer: bucketSlotBuffer,
                overflowBuffer: overflowBuffer,
                rowCount: currentRowCount,
                threadgroupMultiplier: threadgroupMultiplier
            )
            bucketCommandBuffer.commit()
            bucketCommandBuffer.waitUntilCompleted()
            if let error = bucketCommandBuffer.error {
                throw error
            }

            let bucketCounts = bucketCountBuffer.contents().assumingMemoryBound(to: UInt32.self)
            expectedPairs = 0
            for bucket in 0..<bucketCount {
                let count = min(Int(bucketCounts[bucket]), bucketSlots)
                expectedPairs += count * max(0, count - 1) / 2
            }

            if overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0 {
                break
            }

            let isFinalRound = round == parameters.k - 1
                && outputIndexWidth == parameters.solutionIndexCount
                && rounds == parameters.k
            if isFinalRound {
                let maxSolutions = 8
                roundConfig.maxPairs = UInt32(maxSolutions)
                let solutionIndexByteCount = maxSolutions * outputIndexWidth * MemoryLayout<UInt32>.stride
                guard let roundConfigBuffer = device.makeBuffer(bytes: &roundConfig, length: MemoryLayout<RoundOneConfig>.stride),
                      let solutionIndexBuffer = device.makeBuffer(length: solutionIndexByteCount, options: [.storageModeShared]),
                      let solutionCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
                    throw GeneratorError.outputUnavailable
                }

                memset(solutionCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

                guard let commandBuffer = queue.makeCommandBuffer() else {
                    throw GeneratorError.commandBufferUnavailable
                }
                try encodeFinalRoundSolutions(
                    commandBuffer: commandBuffer,
                    roundConfigBuffer: roundConfigBuffer,
                    rowDigestBuffer: currentDigestBuffer,
                    rowIndexBuffer: currentIndexBuffer,
                    bucketCountBuffer: bucketCountBuffer,
                    bucketSlotBuffer: bucketSlotBuffer,
                    solutionIndexBuffer: solutionIndexBuffer,
                    solutionCounterBuffer: solutionCounterBuffer,
                    overflowBuffer: overflowBuffer,
                    bucketCount: bucketCount,
                    threadgroupMultiplier: threadgroupMultiplier
                )
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error {
                    throw error
                }

                let candidateCount = min(
                    Int(solutionCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee),
                    maxSolutions
                )
                let rows = copySolutionRows(
                    solutionIndexBuffer: solutionIndexBuffer,
                    rowCount: candidateCount,
                    indexWidth: outputIndexWidth
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                let overflow = overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0
                let result = MetalRoundOneResult(
                    rowCount: initialRowCount,
                    elapsedSeconds: elapsed,
                    pairCount: rows.count,
                    expectedPairCount: rows.count,
                    bucketSlots: bucketSlots,
                    overflow: overflow,
                    firstPairKey: nil
                )
                return (rows, parameters.k, result)
            }

            if expectedPairs == 0 {
                currentRowCount = 0
                completedRounds = round + 1
                break
            }

            let memoryBoundPairLimit = max(1, (memoryBudgetBytes - fixedRoundBytes) / max(1, bytesPerOutputPair))
            guard expectedPairs <= memoryBoundPairLimit else {
                overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee = 1
                break
            }
            guard expectedPairs <= maxPairLimit else {
                overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee = 1
                break
            }

            let maxPairs = max(1, min(maxPairLimit, expectedPairs))
            roundConfig.maxPairs = UInt32(maxPairs)
            let outputDigestByteCount = maxPairs * parameters.digestByteCount
            let outputIndexByteCount = maxPairs * outputIndexWidth * MemoryLayout<UInt32>.stride
            let outputKeyByteCount = maxPairs * MemoryLayout<UInt32>.stride

            guard let roundConfigBuffer = device.makeBuffer(bytes: &roundConfig, length: MemoryLayout<RoundOneConfig>.stride),
                  let outputDigestBuffer = device.makeBuffer(length: outputDigestByteCount, options: gpuOnlyOptions),
                  let outputIndexBuffer = device.makeBuffer(length: outputIndexByteCount, options: gpuOnlyOptions),
                  let outputKeyBuffer = device.makeBuffer(length: outputKeyByteCount, options: gpuOnlyOptions),
                  let pairCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]) else {
                throw GeneratorError.outputUnavailable
            }

            memset(pairCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw GeneratorError.commandBufferUnavailable
            }
            try encodeRoundOnePairs(
                commandBuffer: commandBuffer,
                roundConfigBuffer: roundConfigBuffer,
                rowDigestBuffer: currentDigestBuffer,
                rowIndexBuffer: currentIndexBuffer,
                bucketCountBuffer: bucketCountBuffer,
                bucketSlotBuffer: bucketSlotBuffer,
                pairDigestBuffer: outputDigestBuffer,
                pairIndexBuffer: outputIndexBuffer,
                pairKeyBuffer: outputKeyBuffer,
                pairCounterBuffer: pairCounterBuffer,
                overflowBuffer: overflowBuffer,
                bucketCount: bucketCount,
                threadgroupMultiplier: threadgroupMultiplier
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw error
            }

            currentRowCount = min(Int(pairCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee), maxPairs)
            firstKey = nil
            currentDigestBuffer = outputDigestBuffer
            currentIndexBuffer = outputIndexBuffer
            currentKeyBuffer = outputKeyBuffer
            currentIndexWidth = outputIndexWidth
            completedRounds = round + 1

            if overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0 {
                break
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let overflow = overflowBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee != 0
        let rows: [EquihashPartialRow]
        if completedRounds == parameters.k,
           currentIndexWidth == parameters.solutionIndexCount,
           !overflow {
            rows = try compactZeroRows(
                digestBuffer: currentDigestBuffer,
                indexBuffer: currentIndexBuffer,
                rowCount: currentRowCount,
                indexWidth: currentIndexWidth,
                maxSolutions: 8
            )
        } else if !exportIncompleteRows {
            rows = []
        } else {
            let readableDigestBuffer = try readableBuffer(
                currentDigestBuffer,
                length: currentRowCount * parameters.digestByteCount
            )
            let readableIndexBuffer = try readableBuffer(
                currentIndexBuffer,
                length: currentRowCount * currentIndexWidth * MemoryLayout<UInt32>.stride
            )
            rows = copyPartialRows(
                digestBuffer: readableDigestBuffer,
                indexBuffer: readableIndexBuffer,
                rowCount: currentRowCount,
                indexWidth: currentIndexWidth
            )
        }
        let result = MetalRoundOneResult(
            rowCount: initialRowCount,
            elapsedSeconds: elapsed,
            pairCount: rows.count,
            expectedPairCount: expectedPairs,
            bucketSlots: bucketSlots,
            overflow: overflow,
            firstPairKey: firstKey
        )
        return (rows, completedRounds, result)
    }

    private func estimateRoundFixedWorkingSetBytes(
        currentRowCount: Int,
        currentIndexWidth: Int,
        bucketCount: Int,
        bucketSlots: Int
    ) -> Int {
        let currentBytes = currentRowCount * (
            parameters.digestByteCount
            + MemoryLayout<UInt32>.stride
            + currentIndexWidth * MemoryLayout<UInt32>.stride
        )
        let bucketBytes = bucketCount * MemoryLayout<UInt32>.stride
            + bucketCount * bucketSlots * MemoryLayout<UInt32>.stride
        return currentBytes + bucketBytes + (8 * 1_024 * 1_024)
    }

    private func compactZeroRows(
        digestBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        rowCount: Int,
        indexWidth: Int,
        maxSolutions: Int
    ) throws -> [EquihashPartialRow] {
        guard rowCount > 0, indexWidth == parameters.solutionIndexCount else {
            return []
        }

        var config = CompactConfig(
            rowCount: UInt32(rowCount),
            indexWidth: UInt32(indexWidth),
            maxSolutions: UInt32(max(1, maxSolutions))
        )
        let outputIndexByteCount = maxSolutions * indexWidth * MemoryLayout<UInt32>.stride
        guard let configBuffer = device.makeBuffer(bytes: &config, length: MemoryLayout<CompactConfig>.stride),
              let outputIndexBuffer = device.makeBuffer(length: outputIndexByteCount, options: [.storageModeShared]),
              let solutionCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: [.storageModeShared]),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.outputUnavailable
        }

        memset(solutionCounterBuffer.contents(), 0, MemoryLayout<UInt32>.stride)

        encoder.setComputePipelineState(compactPipeline)
        encoder.setBuffer(configBuffer, offset: 0, index: 0)
        encoder.setBuffer(digestBuffer, offset: 0, index: 1)
        encoder.setBuffer(indexBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputIndexBuffer, offset: 0, index: 3)
        encoder.setBuffer(solutionCounterBuffer, offset: 0, index: 4)
        dispatch(encoder: encoder, count: rowCount, pipeline: compactPipeline)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }

        let candidateCount = min(
            Int(solutionCounterBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee),
            maxSolutions
        )
        let indexPointer = outputIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let zeroDigest = [UInt8](repeating: 0, count: parameters.digestByteCount)
        return copySolutionRows(
            indexPointer: indexPointer,
            rowCount: candidateCount,
            indexWidth: indexWidth,
            zeroDigest: zeroDigest
        )
    }

    private func copySolutionRows(
        solutionIndexBuffer: MTLBuffer,
        rowCount: Int,
        indexWidth: Int
    ) -> [EquihashPartialRow] {
        let indexPointer = solutionIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let zeroDigest = [UInt8](repeating: 0, count: parameters.digestByteCount)
        return copySolutionRows(
            indexPointer: indexPointer,
            rowCount: rowCount,
            indexWidth: indexWidth,
            zeroDigest: zeroDigest
        )
    }

    private func copySolutionRows(
        indexPointer: UnsafePointer<UInt32>,
        rowCount: Int,
        indexWidth: Int,
        zeroDigest: [UInt8]
    ) -> [EquihashPartialRow] {
        var rows: [EquihashPartialRow] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let indexStart = row * indexWidth
            let indices = Array(
                UnsafeBufferPointer(
                    start: indexPointer.advanced(by: indexStart),
                    count: indexWidth
                )
            )
            rows.append(EquihashPartialRow(digest: zeroDigest, indices: indices))
        }
        return rows
    }

    private func readableBuffer(_ buffer: MTLBuffer, length: Int) throws -> MTLBuffer {
        guard buffer.storageMode == .private else {
            return buffer
        }

        guard let sharedBuffer = device.makeBuffer(length: max(1, length), options: [.storageModeShared]) else {
            throw GeneratorError.outputUnavailable
        }
        guard length > 0 else {
            return sharedBuffer
        }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.copy(from: buffer, sourceOffset: 0, to: sharedBuffer, destinationOffset: 0, size: length)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }
        return sharedBuffer
    }

    private func copyPartialRows(
        digestBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        rowCount: Int,
        indexWidth: Int
    ) -> [EquihashPartialRow] {
        let digestPointer = digestBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var rows: [EquihashPartialRow] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            if row.isMultiple(of: 65_536) {
                Thread.sleep(forTimeInterval: 0.0005)
            }
            let digestStart = row * parameters.digestByteCount
            let digest = Array(
                UnsafeBufferPointer(
                    start: digestPointer.advanced(by: digestStart),
                    count: parameters.digestByteCount
                )
            )
            let indexStart = row * indexWidth
            let indices = Array(
                UnsafeBufferPointer(
                    start: indexPointer.advanced(by: indexStart),
                    count: indexWidth
                )
            )
            rows.append(EquihashPartialRow(digest: digest, indices: indices))
        }
        return rows
    }

    private func encodeInitialRows(
        commandBuffer: MTLCommandBuffer,
        configBuffer: MTLBuffer,
        headerBuffer: MTLBuffer,
        digestBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        keyBuffer: MTLBuffer,
        rowCount: Int,
        threadgroupMultiplier: Int = 4
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(configBuffer, offset: 0, index: 0)
        encoder.setBuffer(headerBuffer, offset: 0, index: 1)
        encoder.setBuffer(digestBuffer, offset: 0, index: 2)
        encoder.setBuffer(indexBuffer, offset: 0, index: 3)
        encoder.setBuffer(keyBuffer, offset: 0, index: 4)
        dispatch(encoder: encoder, count: rowCount, pipeline: pipeline, threadgroupMultiplier: threadgroupMultiplier)
        encoder.endEncoding()
    }

    private func encodeBucketRows(
        commandBuffer: MTLCommandBuffer,
        roundConfigBuffer: MTLBuffer,
        rowKeyBuffer: MTLBuffer,
        bucketCountBuffer: MTLBuffer,
        bucketSlotBuffer: MTLBuffer,
        overflowBuffer: MTLBuffer,
        rowCount: Int,
        threadgroupMultiplier: Int = 4
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.setComputePipelineState(bucketPipeline)
        encoder.setBuffer(roundConfigBuffer, offset: 0, index: 0)
        encoder.setBuffer(rowKeyBuffer, offset: 0, index: 1)
        encoder.setBuffer(bucketCountBuffer, offset: 0, index: 2)
        encoder.setBuffer(bucketSlotBuffer, offset: 0, index: 3)
        encoder.setBuffer(overflowBuffer, offset: 0, index: 4)
        dispatch(encoder: encoder, count: rowCount, pipeline: bucketPipeline, threadgroupMultiplier: threadgroupMultiplier)
        encoder.endEncoding()
    }

    private func encodeRoundOnePairs(
        commandBuffer: MTLCommandBuffer,
        roundConfigBuffer: MTLBuffer,
        rowDigestBuffer: MTLBuffer,
        rowIndexBuffer: MTLBuffer,
        bucketCountBuffer: MTLBuffer,
        bucketSlotBuffer: MTLBuffer,
        pairDigestBuffer: MTLBuffer,
        pairIndexBuffer: MTLBuffer,
        pairKeyBuffer: MTLBuffer,
        pairCounterBuffer: MTLBuffer,
        overflowBuffer: MTLBuffer,
        bucketCount: Int,
        threadgroupMultiplier: Int = 4
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.setComputePipelineState(roundOnePipeline)
        encoder.setBuffer(roundConfigBuffer, offset: 0, index: 0)
        encoder.setBuffer(rowDigestBuffer, offset: 0, index: 1)
        encoder.setBuffer(rowIndexBuffer, offset: 0, index: 2)
        encoder.setBuffer(bucketCountBuffer, offset: 0, index: 3)
        encoder.setBuffer(bucketSlotBuffer, offset: 0, index: 4)
        encoder.setBuffer(pairDigestBuffer, offset: 0, index: 5)
        encoder.setBuffer(pairIndexBuffer, offset: 0, index: 6)
        encoder.setBuffer(pairKeyBuffer, offset: 0, index: 7)
        encoder.setBuffer(pairCounterBuffer, offset: 0, index: 8)
        encoder.setBuffer(overflowBuffer, offset: 0, index: 9)
        dispatch(encoder: encoder, count: bucketCount, pipeline: roundOnePipeline, threadgroupMultiplier: threadgroupMultiplier)
        encoder.endEncoding()
    }

    private func encodeFinalRoundSolutions(
        commandBuffer: MTLCommandBuffer,
        roundConfigBuffer: MTLBuffer,
        rowDigestBuffer: MTLBuffer,
        rowIndexBuffer: MTLBuffer,
        bucketCountBuffer: MTLBuffer,
        bucketSlotBuffer: MTLBuffer,
        solutionIndexBuffer: MTLBuffer,
        solutionCounterBuffer: MTLBuffer,
        overflowBuffer: MTLBuffer,
        bucketCount: Int,
        threadgroupMultiplier: Int = 4
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GeneratorError.commandBufferUnavailable
        }
        encoder.setComputePipelineState(finalRoundPipeline)
        encoder.setBuffer(roundConfigBuffer, offset: 0, index: 0)
        encoder.setBuffer(rowDigestBuffer, offset: 0, index: 1)
        encoder.setBuffer(rowIndexBuffer, offset: 0, index: 2)
        encoder.setBuffer(bucketCountBuffer, offset: 0, index: 3)
        encoder.setBuffer(bucketSlotBuffer, offset: 0, index: 4)
        encoder.setBuffer(solutionIndexBuffer, offset: 0, index: 5)
        encoder.setBuffer(solutionCounterBuffer, offset: 0, index: 6)
        encoder.setBuffer(overflowBuffer, offset: 0, index: 7)
        dispatch(encoder: encoder, count: bucketCount, pipeline: finalRoundPipeline, threadgroupMultiplier: threadgroupMultiplier)
        encoder.endEncoding()
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        count: Int,
        pipeline: MTLComputePipelineState,
        threadgroupMultiplier: Int = 4
    ) {
        let multiplier = max(1, threadgroupMultiplier)
        let width = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            max(pipeline.threadExecutionWidth, pipeline.threadExecutionWidth * multiplier)
        )
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }
}
