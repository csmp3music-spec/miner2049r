import Foundation

enum MiningComputeTarget: String, Codable {
    case appleMetal = "Apple Metal"
    case cpuExternal = "CPU/external"
    case notSelected = "Not selected"
}

struct ProgPowProfile: Equatable, Codable {
    let period: Int
    let lanes: Int
    let registers: Int
    let dagLoads: Int
    let cacheBytes: Int
    let dagAccesses: Int
    let cacheAccessesPerLoop: Int
    let mathOpsPerLoop: Int
}

struct AlgorithmWorkProfile: Equatable, Codable {
    let algorithm: MiningAlgorithm
    let computeTarget: MiningComputeTarget
    let memoryHard: Bool
    let requiresDataset: Bool
    let requiresProgramPerBlock: Bool
    let progPow: ProgPowProfile?
    let notes: String
}

enum AlgorithmWorkProfiles {
    static let eip1057ProgPow = ProgPowProfile(
        period: 10,
        lanes: 16,
        registers: 32,
        dagLoads: 4,
        cacheBytes: 16 * 1_024,
        dagAccesses: 64,
        cacheAccessesPerLoop: 11,
        mathOpsPerLoop: 18
    )

    static let firoPow = ProgPowProfile(
        period: 1,
        lanes: 16,
        registers: 32,
        dagLoads: 4,
        cacheBytes: 16 * 1_024,
        dagAccesses: 64,
        cacheAccessesPerLoop: 11,
        mathOpsPerLoop: 18
    )

    static func profile(for algorithm: MiningAlgorithm) -> AlgorithmWorkProfile {
        switch algorithm {
        case .equihash200_9:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: false,
                requiresProgramPerBlock: false,
                progPow: nil,
                notes: "Native Equihash 200,9 Metal solver path."
            )
        case .kawPow:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: true,
                progPow: eip1057ProgPow,
                notes: "KawPow is a ProgPoW-family GPU target; this profile uses the EIP-1057 lane/register/cache shape as the Metal executor baseline."
            )
        case .autolykos2:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: false,
                progPow: nil,
                notes: "Autolykos v2 is a memory-hard Ergo PoW; Metal work starts with table lookup and Blake2b scoring primitives."
            )
        case .etchash:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: false,
                progPow: nil,
                notes: "Etchash shares the Ethash Hashimoto shape with recalibrated epoch sizing."
            )
        case .progPow:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: true,
                progPow: eip1057ProgPow,
                notes: "Generic ProgPoW uses KISS99-driven program selection, FNV1a merging, and DAG-fed lane math."
            )
        case .firopow:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .appleMetal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: true,
                progPow: firoPow,
                notes: "FiroPoW is treated as a ProgPoW variant with per-block program changes."
            )
        case .ghostRider:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .cpuExternal,
                memoryHard: false,
                requiresDataset: false,
                requiresProgramPerBlock: true,
                progPow: nil,
                notes: "GhostRider is CPU-oriented and should be routed through XMRig or a maintained CPU hash-chain implementation."
            )
        case .randomX:
            return AlgorithmWorkProfile(
                algorithm: algorithm,
                computeTarget: .cpuExternal,
                memoryHard: true,
                requiresDataset: true,
                requiresProgramPerBlock: true,
                progPow: nil,
                notes: "RandomX is a CPU VM/JIT proof of work; Metal is not the primary path."
            )
        }
    }
}
