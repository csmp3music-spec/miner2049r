import Foundation

struct EquihashParameters: Equatable {
    let n: Int
    let k: Int

    static let zcash = EquihashParameters(n: 200, k: 9)

    var collisionBitLength: Int { n / (k + 1) }
    var solutionIndexCount: Int { 1 << k }
    var inputIndexCount: Int { 1 << (collisionBitLength + 1) }
    var digestByteCount: Int { (n + 7) / 8 }
    var indicesPerHash: Int { 512 / n }
    var encodedSolutionByteCount: Int { (solutionIndexCount * (collisionBitLength + 1) + 7) / 8 }
}

struct EquihashSolution: Identifiable, Equatable {
    let id = UUID()
    let indices: [UInt32]
    let encoded: Data
}

struct EquihashSolverProgress: Equatable {
    let round: Int
    let rowCount: Int
    let message: String
}

struct EquihashInitialRow {
    let digest: [UInt8]
    let index: UInt32
}

struct EquihashPartialRow {
    let digest: [UInt8]
    let indices: [UInt32]
}

enum EquihashSolverError: LocalizedError {
    case unsupportedParameters
    case cancelled
    case powHeaderTooShort
    case invalidSolution(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedParameters:
            return "This reference solver currently supports Zcash Equihash n=200, k=9."
        case .cancelled:
            return "Equihash solver was cancelled."
        case .powHeaderTooShort:
            return "A Zcash powheader must include the 140-byte block header prefix through nNonce."
        case .invalidSolution(let reason):
            return "Invalid Equihash solution: \(reason)"
        }
    }
}

final class EquihashSolver {
    struct Options {
        var maxSolutions: Int = 1
        var maxRowsPerRound: Int? = nil
    }

    private struct Row {
        var digest: [UInt8]
        var indices: [UInt32]
    }

    let parameters: EquihashParameters

    init(parameters: EquihashParameters = .zcash) {
        self.parameters = parameters
    }

    func solve(
        powHeader: Data,
        options: Options = Options(),
        progress: ((EquihashSolverProgress) -> Void)? = nil
    ) throws -> [EquihashSolution] {
        guard parameters == .zcash else {
            throw EquihashSolverError.unsupportedParameters
        }
        guard powHeader.count >= 140 else {
            throw EquihashSolverError.powHeaderTooShort
        }

        let initial = try initialRows(powHeader: powHeader, progress: progress)
        return try solve(powHeader: powHeader, initialRows: initial, options: options, progress: progress)
    }

    func solve(
        powHeader: Data,
        initialRows: [EquihashInitialRow],
        options: Options = Options(),
        progress: ((EquihashSolverProgress) -> Void)? = nil
    ) throws -> [EquihashSolution] {
        guard parameters == .zcash else {
            throw EquihashSolverError.unsupportedParameters
        }
        guard powHeader.count >= 140 else {
            throw EquihashSolverError.powHeaderTooShort
        }

        let rows = initialRows.map { EquihashPartialRow(digest: $0.digest, indices: [$0.index]) }
        return try solve(
            powHeader: powHeader,
            partialRows: rows,
            startingRound: 0,
            options: options,
            progress: progress
        )
    }

    func solve(
        powHeader: Data,
        partialRows: [EquihashPartialRow],
        startingRound: Int,
        options: Options = Options(),
        progress: ((EquihashSolverProgress) -> Void)? = nil
    ) throws -> [EquihashSolution] {
        guard parameters == .zcash else {
            throw EquihashSolverError.unsupportedParameters
        }
        guard powHeader.count >= 140 else {
            throw EquihashSolverError.powHeaderTooShort
        }
        guard (0...parameters.k).contains(startingRound) else {
            throw EquihashSolverError.invalidSolution("invalid starting round \(startingRound)")
        }

        var rows = partialRows.map { Row(digest: $0.digest, indices: $0.indices) }
        var solutions: [EquihashSolution] = []

        for round in startingRound..<parameters.k {
            try Task.checkCancellation()
            progress?(
                EquihashSolverProgress(
                    round: round + 1,
                    rowCount: rows.count,
                    message: "Grouping rows on bit window \(round + 1)/\(parameters.k)."
                )
            )

            rows = try combine(rows: rows, round: round)
            if let limit = options.maxRowsPerRound, rows.count > limit {
                rows.removeLast(rows.count - limit)
            }

            progress?(
                EquihashSolverProgress(
                    round: round + 1,
                    rowCount: rows.count,
                    message: "Round \(round + 1) produced \(rows.count) candidate rows."
                )
            )
        }

        for row in rows where isZero(row.digest) {
            let encoded = encode(indices: row.indices)
            let solution = EquihashSolution(indices: row.indices, encoded: encoded)
            try validate(powHeader: powHeader, solution: solution)
            solutions.append(solution)
            if solutions.count >= options.maxSolutions {
                break
            }
        }

        return solutions
    }

    func trustedSolutionsFromGpuFinalRows(
        _ finalRows: [EquihashPartialRow],
        options: Options = Options()
    ) throws -> [EquihashSolution] {
        guard parameters == .zcash else {
            throw EquihashSolverError.unsupportedParameters
        }

        var solutions: [EquihashSolution] = []
        for row in finalRows {
            try Task.checkCancellation()
            guard row.digest.count == parameters.digestByteCount, isZero(row.digest) else {
                continue
            }

            do {
                try validateSolutionStructure(indices: row.indices)
            } catch {
                continue
            }
            let encoded = encode(indices: row.indices)
            solutions.append(EquihashSolution(indices: row.indices, encoded: encoded))
            if solutions.count >= options.maxSolutions {
                break
            }
        }
        return solutions
    }

    func validate(powHeader: Data, solution: EquihashSolution) throws {
        try validateSolutionStructure(indices: solution.indices)

        var accumulator = [UInt8](repeating: 0, count: parameters.digestByteCount)
        for index in solution.indices {
            let digest = generate(powHeader: powHeader, index: index)
            xor(into: &accumulator, digest)
        }

        guard isZero(accumulator) else {
            throw EquihashSolverError.invalidSolution("XOR of generated rows is not zero")
        }

        guard encode(indices: solution.indices) == solution.encoded else {
            throw EquihashSolverError.invalidSolution("encoded byte representation does not match indices")
        }
    }

    func decodeSolution(_ encoded: Data) throws -> EquihashSolution {
        guard encoded.count == parameters.encodedSolutionByteCount else {
            throw EquihashSolverError.invalidSolution("expected \(parameters.encodedSolutionByteCount) solution bytes")
        }

        let bitWidth = parameters.collisionBitLength + 1
        var indices: [UInt32] = []
        indices.reserveCapacity(parameters.solutionIndexCount)
        for offset in stride(from: 0, to: parameters.solutionIndexCount * bitWidth, by: bitWidth) {
            indices.append(UInt32(bitWindow(encoded, offset: offset, length: bitWidth) + 1))
        }
        return EquihashSolution(indices: indices, encoded: encoded)
    }

    func initialRows(powHeader: Data, progress: ((EquihashSolverProgress) -> Void)? = nil) throws -> [EquihashInitialRow] {
        let count = parameters.inputIndexCount
        var rows: [EquihashInitialRow] = []
        rows.reserveCapacity(count)

        for index in 1...count {
            if index.isMultiple(of: 131_072) {
                try Task.checkCancellation()
                progress?(
                    EquihashSolverProgress(
                        round: 0,
                        rowCount: rows.count,
                        message: "Generated \(rows.count)/\(count) initial Equihash rows."
                    )
                )
            }

            rows.append(
                EquihashInitialRow(
                    digest: generate(powHeader: powHeader, index: UInt32(index)),
                    index: UInt32(index)
                )
            )
        }

        return rows
    }

    func initialRow(powHeader: Data, index: UInt32) throws -> EquihashInitialRow {
        guard index >= 1 && index <= UInt32(parameters.inputIndexCount) else {
            throw EquihashSolverError.invalidSolution("initial row index outside valid range")
        }
        return EquihashInitialRow(digest: generate(powHeader: powHeader, index: index), index: index)
    }

    private func combine(rows: [Row], round: Int) throws -> [Row] {
        let bitLength = parameters.collisionBitLength
        let offset = round * bitLength
        var buckets: [UInt32: [Row]] = [:]
        buckets.reserveCapacity(max(1, rows.count / 2))

        for (rowNumber, row) in rows.enumerated() {
            let key = UInt32(bitWindow(row.digest, offset: offset, length: bitLength))
            buckets[key, default: []].append(row)
            if rowNumber.isMultiple(of: 65_536) {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }

        var combined: [Row] = []
        combined.reserveCapacity(max(1, rows.count))
        var workCounter = 0

        for bucket in buckets.values where bucket.count >= 2 {
            for leftIndex in 0..<(bucket.count - 1) {
                let left = bucket[leftIndex]
                for rightIndex in (leftIndex + 1)..<bucket.count {
                    workCounter &+= 1
                    if workCounter.isMultiple(of: 65_536) {
                        try Task.checkCancellation()
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                    let right = bucket[rightIndex]
                    guard areDisjoint(left.indices, right.indices) else {
                        continue
                    }

                    var digest = left.digest
                    xor(into: &digest, right.digest)

                    let ordered = orderedConcat(left.indices, right.indices)
                    combined.append(Row(digest: digest, indices: ordered))
                }
            }
        }

        return combined
    }

    private func generate(powHeader: Data, index: UInt32) -> [UInt8] {
        let zeroBased = Int(index - 1)
        let group = UInt32(zeroBased / parameters.indicesPerHash)
        let slot = zeroBased % parameters.indicesPerHash

        var input = Data(powHeader)
        input.append(contentsOf: group.littleEndianBytes)

        let digest = Blake2b400.zcashPersonalizedDigest(input: input)
        let start = slot * parameters.digestByteCount
        return Array(digest[start..<(start + parameters.digestByteCount)])
    }

    private func validateBinding(indices: [UInt32]) throws {
        for round in 1...parameters.k {
            let groupSize = 1 << round
            var offset = 0
            while offset < indices.count {
                let left = Array(indices[offset..<(offset + groupSize / 2)])
                let right = Array(indices[(offset + groupSize / 2)..<(offset + groupSize)])
                guard lexicographicLess(left, right) else {
                    throw EquihashSolverError.invalidSolution("algorithm-binding order failed at round \(round)")
                }
                offset += groupSize
            }
        }
    }

    private func validateSolutionStructure(indices: [UInt32]) throws {
        guard indices.count == parameters.solutionIndexCount else {
            throw EquihashSolverError.invalidSolution("expected \(parameters.solutionIndexCount) indices")
        }
        guard Set(indices).count == indices.count else {
            throw EquihashSolverError.invalidSolution("indices must be distinct")
        }

        let maxIndex = UInt32(parameters.inputIndexCount)
        guard indices.allSatisfy({ $0 >= 1 && $0 <= maxIndex }) else {
            throw EquihashSolverError.invalidSolution("one or more indices are outside 1...\(maxIndex)")
        }

        try validateBinding(indices: indices)
    }

    private func encode(indices: [UInt32]) -> Data {
        let bitWidth = parameters.collisionBitLength + 1
        var output = [UInt8](repeating: 0, count: parameters.encodedSolutionByteCount)
        for (slot, index) in indices.enumerated() {
            writeBits(value: UInt64(index - 1), bitWidth: bitWidth, into: &output, at: slot * bitWidth)
        }
        return Data(output)
    }
}

private func bitWindow(_ bytes: [UInt8], offset: Int, length: Int) -> UInt64 {
    var value: UInt64 = 0
    for bit in 0..<length {
        let absolute = offset + bit
        let byte = bytes[absolute / 8]
        let bitInByte = 7 - (absolute % 8)
        value = (value << 1) | UInt64((byte >> bitInByte) & 1)
    }
    return value
}

private func bitWindow(_ data: Data, offset: Int, length: Int) -> UInt64 {
    bitWindow(Array(data), offset: offset, length: length)
}

private func writeBits(value: UInt64, bitWidth: Int, into output: inout [UInt8], at offset: Int) {
    for bit in 0..<bitWidth {
        let shift = bitWidth - bit - 1
        let one = UInt8((value >> UInt64(shift)) & 1)
        let absolute = offset + bit
        output[absolute / 8] |= one << UInt8(7 - (absolute % 8))
    }
}

private func xor(into lhs: inout [UInt8], _ rhs: [UInt8]) {
    for i in lhs.indices {
        lhs[i] ^= rhs[i]
    }
}

private func isZero(_ bytes: [UInt8]) -> Bool {
    bytes.allSatisfy { $0 == 0 }
}

private func areDisjoint(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
    var seen = Set(lhs)
    for value in rhs {
        if !seen.insert(value).inserted {
            return false
        }
    }
    return true
}

private func orderedConcat(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
    lexicographicLess(lhs, rhs) ? lhs + rhs : rhs + lhs
}

private func lexicographicLess(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left < right { return true }
        if left > right { return false }
    }
    return lhs.count < rhs.count
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
