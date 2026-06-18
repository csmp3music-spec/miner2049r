# Miner 2049'er

Native macOS Apple Silicon mining workbench with retro box-art branding.

## What works

- SwiftUI configuration GUI.
- Retro cyan/magenta/amber dashboard with bundled Miner 2049'er box art.
- Live runtime graphs for row/hash rate plus accepted and rejected shares.
- Pool URL, worker/user, and password fields.
- Saved configuration in the user's Application Support folder.
- TCP JSON-RPC Stratum client.
- Local mock Stratum server for testing subscribe/authorize/notify without real pool credentials.
- ZIP-301 Zcash job parser for `mining.notify`.
- Zcash powheader construction from pool job fields, nonce1, and nonce2.
- ZIP-301 `mining.submit` payload assembly with CompactSize-prefixed Equihash solution bytes.
- Zcash ZIP-301-style `mining.subscribe`, `mining.authorize`, `mining.set_difficulty`, `mining.set_target`, `mining.notify`, and `mining.submit` handling.
- Metal GPU benchmark for the Zcash Equihash generator digest path using BLAKE2b-400 with `ZcashPoW`, `n=200`, `k=9` personalization.
- CPU reference validation for the first GPU digest.
- Full CPU reference Equihash 200,9 Wagner collision solver and solution validator.
- GPU reference share miner loop that uses the latest valid Zcash pool job, searches nonce2 values, and submits a found Equihash solution.
- GPU reference solving that runs Equihash initial row generation and as many Wagner collision rounds as fit the current Metal memory budget before handing any remaining rounds to the Swift reference validator/submission path.
- Continual solver memory budgeting: each Metal round estimates current rows, bucket tables, output buffers, and a safety reserve before allocating the next stage.
- GPU-private intermediate row buffers for the budgeted Wagner chain, with CPU-readable copies made only at solver handoff.
- GPU-side final zero-digest compaction when Metal completes all nine Wagner rounds, so Swift reads compact candidate solutions instead of scanning every final row.
- GPU-final trusted solution packing: when Metal completes all nine Wagner rounds, Swift verifies only structure/ranges/binding order and packs the compact solution without regenerating the 512 Equihash row hashes on CPU.
- Four-nonce live mining pipeline for the GPU path, with queued headers discarded when a newer Stratum job arrives.
- Apple GPU performance controls:
  - threadgroup size aligned to the pipeline SIMD execution width;
  - multiple hashes per GPU thread to reduce launch overhead;
  - compact checksum output to avoid writing every 50-byte digest to memory during benchmarking;
  - GPU elapsed time from Metal command-buffer timestamps when available;
  - autotune pass that benchmarks threadgroup and hashes-per-thread combinations on the current Mac;
  - Fast Preset button for an 8-deep mining queue, 8x SIMD threadgroups, 128 solver bucket slots, and zero cooldown.
- Metal initial-row generation for full 140-byte Zcash powheaders:
  - hashes `powheader || group_index` on the GPU;
  - emits 25-byte Equihash rows for each index;
  - emits first-round 20-bit collision keys;
  - validates GPU rows against the CPU generator in `--self-test`.
- Continuous Metal work loop with start/stop controls and aggregate runtime hash-rate display.
- Algorithm and engine registry for Equihash 200,9, KawPow, Autolykos v2, GhostRider, RandomX, Etchash, ProgPoW, and FiroPoW.
- Compile-tested Metal primitive kernels for Keccak-512 seed generation, Ethash/Etchash-style FNV DAG mixing, ProgPoW/FiroPoW/KawPow lane math, and Autolykos-style table lookup mixing.

## What is not complete

This is not yet a profitable full miner. Equihash now has a correctness-oriented CPU solver, but real high-throughput share mining still needs these pieces:

- Fully GPU-resident final Equihash validation and submission path. The Metal runner can chain every Wagner round within budget, but rows are still exported to the Swift reference validator/submission path.
- Complete native share-solving engines for KawPow, Autolykos, GhostRider, Etchash, ProgPoW, and FiroPoW.
- Native RandomX CPU VM/JIT integration. RandomX is mineable through the XMRig backend, not as an Apple GPU algorithm.
- Per-pool protocol variants beyond the Zcash ZIP-301 and generic Stratum JSON-RPC connection layer.
- High-throughput share finding; the current real-share path is correctness-oriented and may still fall back to CPU rounds when the configured memory budget would make another Metal round too large.

## Build

```sh
swift build
```

## Run

```sh
swift run miner-2049er
```

The GUI opens a native macOS window. Select an algorithm, enter pool settings, connect to Stratum, run the GPU benchmark, or start the continuous Metal work loop for Equihash 200,9.

For headless pool mining:

```sh
swift run miner-2049er --mine \
  --pool stratum+tcp://europe.mining-dutch.nl:6663 \
  --user your-worker \
  --password d=0.000000001 \
  --pipeline-depth 4 \
  --memory-gb 4 \
  --max-job-age-s 20
```

Use `swift run miner-2049er --mine --help` for all command-line options. For local protocol testing without pool credentials, run `swift run miner-2049er --mine --mock-pool`.

The default Mining-Dutch password is `d=0.000000001` instead of `x` so the pool assigns the lowest practical share difficulty it is willing to allow for testing this slow native solver. If the pool clamps the request upward, accepted shares may still be rare.

The miner discards solved candidates for old work before submission. Keep `--max-job-age-s` low when a pool reports stale shares frequently; this reduces pool-side stale rejects by skipping shares that were found too late.

For local protocol testing, use **Start Mock Pool**, then **Connect**. The mock pool emits difficulty and a fake job so the Stratum log and job panel can be tested without a live mining pool.

For RandomX and GhostRider, **Start Pool Mining** launches XMRig with the active pool credentials. The built-in XMRig profile uses auto CPU memory pooling, no-yield CPU scheduling, normal process priority, full thread autoconfig hints, and local HTTP API telemetry; RandomX also enables fast mode, all-thread dataset initialization, and huge-page JIT when the installed XMRig build supports it.

## Verify

```sh
swift build
swift run miner-2049er --self-test
```

The self-test validates ZIP-301 powheader assembly, nonce placement, CompactSize encoding, solution submit payload formatting, the Metal initial-row kernel against CPU reference rows, and compilation of the multi-algorithm Metal primitive kernels.

## Equihash Solver

`Sources/ZcashMetalMiner/EquihashSolver.swift` implements a full reference Wagner solver for Zcash Equihash `n=200, k=9`:

- Generates `2^(n/(k+1)+1)` initial rows.
- Groups rows by each 20-bit collision window.
- Combines rows with distinct indices.
- Maintains algorithm-binding lexicographic order.
- Encodes and decodes the 1344-byte compact solution.
- Validates final XOR-to-zero and encoded byte consistency.

The GPU reference solver has a Metal front end: Metal generates the initial Equihash rows from the full Zcash powheader and chains Wagner collision pairing rounds while staying under a per-device working-set budget. Intermediate row, index, key, and bucket-slot buffers are GPU-private. The Swift reference validator consumes the last exported Metal rows only for rounds that did not fit the current budget. When Metal completes all nine rounds, a Metal compaction kernel filters zero-digest candidates first, and Swift reads only those compact candidates. That GPU-final path skips CPU regeneration of the 512 Equihash row hashes and only performs structural checks before packing the CompactSize-prefixed solution. Large exported row arrays are released after the solve/submission step for each nonce attempt.

The GPU reference share miner is still correctness-first. It submits real Stratum shares and now prepares a four-nonce queue for each live Stratum job, discarding queued work when a new job arrives. The remaining performance work is a larger GPU command-buffer pipeline that can keep multiple nonce attempts in flight.

## Other Algorithms

The GUI lists KawPow, Autolykos v2, GhostRider, RandomX, Etchash, ProgPoW, and FiroPoW. RandomX and GhostRider are mineable through XMRig. KawPow, Autolykos v2, Etchash, ProgPoW, and FiroPoW can launch a configured external miner command and now have early Metal primitive kernels, but they are not full native share solvers yet.

- KawPow/FiroPoW/ProgPoW need DAG/cache generation, validated Keccak/FNV mix wiring, period-specific programs, and pool-specific share payloads.
- Autolykos v2 needs Ergo-specific message construction, validated table lookups, and final Blake2b scoring.
- RandomX should use the official CPU VM/JIT library rather than an Apple GPU path.
- GhostRider needs a maintained CPU hash-chain implementation before a Metal port makes sense.

## Apple GPU performance strategy

The app does not hard-code one "best" launch shape. Apple Silicon GPUs vary by generation and core count, and the best settings also depend on register pressure and memory traffic in the kernel. The GUI exposes manual controls and an `Autotune` button.

Current optimizations:

- Use `threadExecutionWidth` and `maxTotalThreadsPerThreadgroup` from the compiled Metal pipeline.
- Dispatch threadgroups in multiples of the execution width.
- Let each GPU thread process 1, 2, 4, 8, or 16 candidate inputs before returning.
- Avoid benchmarking memory bandwidth accidentally by writing one digest plus one checksum per thread, instead of writing every generated digest.
- Keep the CPU validation path on the first digest so kernel changes still get checked.
- Budget each solver round before allocation and stop Metal chaining before projected row, bucket, and output buffers exceed the current Apple GPU working-set target.
- Use GPU-private storage for solver intermediates that are produced and consumed only by Metal kernels.
- Compact final zero-digest candidates on the GPU and avoid CPU readback of non-solution rows.
- Size late-round output buffers from the current candidate row count instead of the original input row count.
- Skip full CPU Equihash revalidation for GPU-final rows and pack compact solutions directly after structural checks.
- Prepare a small nonce/header queue per Stratum job so CPU header construction is not interleaved with each individual GPU solve.
- Use the Fast Preset as an aggressive local-mining profile when the Mac can spare the memory and UI responsiveness.
- Route RandomX and GhostRider through XMRig with CPU memory pool and RandomX JIT/dataset flags validated against the installed macOS ARM build.

Further work for real mining throughput:

- Keep final Equihash candidate validation in GPU memory and export only compact solutions to the CPU.
- Use private/storage buffers for large solver state instead of shared memory where CPU readback is not needed.
- Batch multiple Stratum jobs/nonces per command buffer to reduce command submission overhead.
- Add algorithm-specific kernels; KawPow, Autolykos, and FiroPoW are not interchangeable with Equihash.
