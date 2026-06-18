import Foundation

enum EthashFamily: String, Codable, CaseIterable {
    case ethash
    case etchash
}

struct EthashEpoch: Equatable {
    static let wordBytes = 4
    static let hashBytes = 64
    static let mixBytes = 128
    static let datasetBytesInitial = 1 << 30
    static let datasetBytesGrowth = 1 << 23
    static let cacheBytesInitial = 1 << 24
    static let cacheBytesGrowth = 1 << 17
    static let ethashEpochLength = 30_000
    static let etchashEpochLength = 60_000
    static let datasetParents = 256
    static let cacheRounds = 3
    static let hashimotoAccesses = 64

    let family: EthashFamily
    let blockNumber: Int

    var epochLength: Int {
        switch family {
        case .ethash: return Self.ethashEpochLength
        case .etchash: return Self.etchashEpochLength
        }
    }

    var epoch: Int {
        max(0, blockNumber / epochLength)
    }

    var cacheSizeBytes: Int {
        primeAdjustedSize(
            initial: Self.cacheBytesInitial,
            growth: Self.cacheBytesGrowth,
            epoch: epoch,
            itemBytes: Self.hashBytes
        )
    }

    var datasetSizeBytes: Int {
        primeAdjustedSize(
            initial: Self.datasetBytesInitial,
            growth: Self.datasetBytesGrowth,
            epoch: epoch,
            itemBytes: Self.mixBytes
        )
    }

    var cacheNodeCount: Int {
        cacheSizeBytes / Self.hashBytes
    }

    var datasetItemCount: Int {
        datasetSizeBytes / Self.mixBytes
    }

    private func primeAdjustedSize(initial: Int, growth: Int, epoch: Int, itemBytes: Int) -> Int {
        var size = initial + (growth * epoch) - itemBytes
        while !Self.isPrime(size / itemBytes) {
            size -= 2 * itemBytes
        }
        return size
    }

    static func isPrime(_ value: Int) -> Bool {
        if value <= 1 {
            return false
        }
        if value <= 3 {
            return true
        }
        if value % 2 == 0 || value % 3 == 0 {
            return false
        }
        var divisor = 5
        while divisor * divisor <= value {
            if value % divisor == 0 || value % (divisor + 2) == 0 {
                return false
            }
            divisor += 6
        }
        return true
    }
}
