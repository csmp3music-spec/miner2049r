import Foundation

enum MiningEngineKind: String, Codable {
    case metalGenerator = "Metal generator"
    case gpuReferenceSolver = "GPU reference solver"
    case externalAdapter = "External adapter"
    case notImplemented = "Not implemented"
}

struct MiningEngineDescriptor: Identifiable, Codable {
    var id: MiningAlgorithm { algorithm }
    let algorithm: MiningAlgorithm
    let kind: MiningEngineKind
    let canHashLocally: Bool
    let canSolveShares: Bool
    let supportsAppleGPU: Bool
    let implementation: String
    let nextWork: String
}

enum MiningEngineRegistry {
    static let engines: [MiningEngineDescriptor] = [
        MiningEngineDescriptor(
            algorithm: .equihash200_9,
            kind: .gpuReferenceSolver,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Native BLAKE2b-400 generator, Metal benchmark/runtime loop, Metal initial-row generation, budgeted Metal Wagner collision rounds, and Swift reference validation/submission.",
            nextWork: "Keep final Equihash candidate validation GPU-resident and export only compact solutions to Swift."
        ),
        MiningEngineDescriptor(
            algorithm: .kawPow,
            kind: .metalGenerator,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Mineable through the custom external-miner adapter. Native work includes a parameterized ProgPoW-family profile plus Metal Keccak-512 seed generation, FNV/FNV1a DAG mixing, KISS99 vector checks, and lane math.",
            nextWork: "Wire pool jobs into a KawPow work package and compare Metal mix/final digests against kawpowminer vectors before share submission."
        ),
        MiningEngineDescriptor(
            algorithm: .autolykos2,
            kind: .metalGenerator,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Mineable through the custom external-miner adapter. Native Metal lookup/mix primitives are present for Autolykos-style table access. Full native Autolykos v2 still needs Ergo message construction, Blake2b scoring, and pool-side share validation.",
            nextWork: "Add the Ergo work message parser and replace the placeholder lookup reduction with the validated Autolykos v2 scoring path."
        ),
        MiningEngineDescriptor(
            algorithm: .ghostRider,
            kind: .externalAdapter,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: false,
            implementation: "Mineable through the bundled XMRig process adapter using the `ghostrider` CPU algorithm. Shares and hashrate are read from XMRig output.",
            nextWork: "Add structured XMRig JSON/API polling so accepted/rejected share counts are parsed from machine-readable state instead of log text."
        ),
        MiningEngineDescriptor(
            algorithm: .randomX,
            kind: .externalAdapter,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: false,
            implementation: "Mineable through the bundled XMRig process adapter using the `rx/0` CPU algorithm. RandomX remains CPU/JIT-oriented rather than a Metal GPU target.",
            nextWork: "Expose XMRig thread count, huge-page/JIT options, and structured XMRig API telemetry."
        ),
        MiningEngineDescriptor(
            algorithm: .etchash,
            kind: .metalGenerator,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Mineable through the custom external-miner adapter. Native Ethash/Etchash epoch sizing is parameterized and Metal has Keccak-512 seed, Hashimoto-lite, dataset-item, and FNV DAG-mix kernels.",
            nextWork: "Generate epoch cache/DAG buffers and validate full Metal Hashimoto output against canonical Etchash vectors."
        ),
        MiningEngineDescriptor(
            algorithm: .progPow,
            kind: .metalGenerator,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Mineable through the custom external-miner adapter. Native work has a parameterized EIP-1057 profile plus exact Swift and Metal FNV1a/KISS99 vector tests, DAG-fed lane math, and ProgPoW math primitives.",
            nextWork: "Expand from primitive vectors to full EIP-1057 mix/final digest vectors before enabling share submission."
        ),
        MiningEngineDescriptor(
            algorithm: .firopow,
            kind: .metalGenerator,
            canHashLocally: true,
            canSolveShares: true,
            supportsAppleGPU: true,
            implementation: "Mineable through the custom external-miner adapter. FiroPoW is profiled as a per-block ProgPoW variant and shares the Metal FNV1a/KISS99/lane-math executor path.",
            nextWork: "Add FiroPoW header construction and known-answer vectors, then reuse the shared ProgPoW Metal executor."
        )
    ]

    static func descriptor(for algorithm: MiningAlgorithm) -> MiningEngineDescriptor {
        engines.first { $0.algorithm == algorithm }!
    }
}
