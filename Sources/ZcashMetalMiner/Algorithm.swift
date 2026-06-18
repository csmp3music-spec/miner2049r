import Foundation

enum MiningAlgorithm: String, CaseIterable, Identifiable, Codable {
    case equihash200_9
    case kawPow
    case autolykos2
    case ghostRider
    case randomX
    case etchash
    case progPow
    case firopow

    var id: String { rawValue }

    var name: String {
        switch self {
        case .equihash200_9: return "Equihash 200,9"
        case .kawPow: return "KawPow"
        case .autolykos2: return "Autolykos v2"
        case .ghostRider: return "GhostRider"
        case .randomX: return "RandomX"
        case .etchash: return "Etchash"
        case .progPow: return "ProgPoW"
        case .firopow: return "FiroPoW"
        }
    }

    var commonCoins: String {
        switch self {
        case .equihash200_9: return "ZEC, ZEN-compatible pools"
        case .kawPow: return "RVN"
        case .autolykos2: return "ERG"
        case .ghostRider: return "RTM"
        case .randomX: return "XMR-style CPU mining"
        case .etchash: return "ETC-style pools"
        case .progPow: return "ProgPoW-family coins"
        case .firopow: return "FIRO"
        }
    }

    var engineStatus: EngineStatus {
        switch self {
        case .equihash200_9:
            return .gpuBenchmark
        case .randomX, .ghostRider:
            return .externalMineable
        default:
            return .notImplemented
        }
    }

    var xmrigAlgorithm: String? {
        switch self {
        case .randomX: return "rx/0"
        case .ghostRider: return "ghostrider"
        default: return nil
        }
    }

    var canStartMining: Bool {
        true
    }

    var usesExternalMiner: Bool {
        self != .equihash200_9
    }

    var usesXMRigDefault: Bool {
        xmrigAlgorithm != nil
    }

    var externalMinerAlgorithmName: String {
        xmrigAlgorithm ?? rawValue
    }

    var stratumMode: StratumMode {
        switch self {
        case .equihash200_9:
            return .zcashZip301
        default:
            return .jsonRpcGeneric
        }
    }

    var defaultPoolURL: String {
        switch self {
        case .equihash200_9: return "stratum+tcp://europe.mining-dutch.nl:6663"
        case .kawPow: return "stratum+tcp://rvn.2miners.com:6060"
        case .autolykos2: return "stratum+tcp://erg.2miners.com:8888"
        case .ghostRider: return "stratum+tcp://ghostrider.mine.zergpool.com:5354"
        case .randomX: return "stratum+tcp://xmr.2miners.com:2222"
        case .etchash: return "stratum+tcp://etc.2miners.com:1010"
        case .progPow: return "stratum+tcp://example.invalid:3333"
        case .firopow: return "stratum+tcp://firo.2miners.com:8181"
        }
    }

    var implementationNote: String {
        switch engineStatus {
        case .gpuBenchmark:
            return "Zcash Stratum mining is implemented with a GPU reference solver: Metal initial-row generation, budgeted Metal Wagner collision rounds, and Swift reference validation/submission."
        case .externalMineable:
            return "Mining is available through the XMRig CPU backend. Start Pool Mining launches XMRig with this algorithm and the active pool credentials."
        case .notImplemented:
            switch self {
            case .kawPow, .etchash, .progPow, .firopow:
                return "Configuration, Stratum connection, and early Metal GPU primitives are available. A full share solver still needs DAG/epoch construction and block-specific validation."
            case .autolykos2:
                return "Configuration, Stratum connection, and early Metal lookup/mix primitives are available. A full Ergo Autolykos v2 message builder and validator still need to be wired in."
            default:
                return "Configuration and Stratum connection are available. The hashing engine for this algorithm is not implemented yet."
            }
        }
    }
}

enum EngineStatus {
    case gpuBenchmark
    case externalMineable
    case notImplemented

    var canRunGpuBenchmark: Bool {
        if case .gpuBenchmark = self {
            return true
        }
        return false
    }
}

enum StratumMode: String {
    case zcashZip301 = "Zcash ZIP-301"
    case jsonRpcGeneric = "Generic JSON-RPC Stratum"
}
