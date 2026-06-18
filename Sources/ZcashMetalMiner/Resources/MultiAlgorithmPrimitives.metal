#include <metal_stdlib>
using namespace metal;

struct MultiAlgoSeedConfig {
    uint headerLength;
    uint nonce;
    uint itemCount;
    uint outputStride;
};

struct DagMixConfig {
    uint seedWordCount;
    uint dagWordCount;
    uint accesses;
    uint outputStride;
};

struct EthashHashimotoConfig {
    uint headerLength;
    uint nonce;
    uint itemCount;
    uint dagWordCount;
    uint accesses;
};

struct EthashDatasetConfig {
    uint cacheNodeCount;
    uint itemCount;
    uint parents;
    uint outputStride;
};

struct ProgPowConfig {
    uint dagWordCount;
    uint lanes;
    uint rounds;
    uint outputStride;
    uint programSeed;
    uint cacheWordCount;
};

struct ProgPowVectorConfig {
    uint iterations;
    uint reserved0;
    uint reserved1;
    uint reserved2;
};

struct AutolykosConfig {
    uint messageWordCount;
    uint tableWordCount;
    uint lookups;
    uint outputStride;
};

constant ulong keccak_round_constants[24] = {
    0x0000000000000001UL, 0x0000000000008082UL,
    0x800000000000808aUL, 0x8000000080008000UL,
    0x000000000000808bUL, 0x0000000080000001UL,
    0x8000000080008081UL, 0x8000000000008009UL,
    0x000000000000008aUL, 0x0000000000000088UL,
    0x0000000080008009UL, 0x000000008000000aUL,
    0x000000008000808bUL, 0x800000000000008bUL,
    0x8000000000008089UL, 0x8000000000008003UL,
    0x8000000000008002UL, 0x8000000000000080UL,
    0x000000000000800aUL, 0x800000008000000aUL,
    0x8000000080008081UL, 0x8000000000008080UL,
    0x0000000080000001UL, 0x8000000080008008UL
};

constant uint keccak_rotation_offsets[25] = {
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14
};

static inline uint fnv1(uint x, uint y) {
    return (x * 0x01000193U) ^ y;
}

static inline uint fnv1a(uint x, uint y) {
    return (x ^ y) * 0x01000193U;
}

static inline ulong rotl64(ulong value, uint count) {
    return count == 0 ? value : ((value << count) | (value >> (64 - count)));
}

static inline uint rotl32(uint value, uint count) {
    count &= 31;
    return count == 0 ? value : ((value << count) | (value >> (32 - count)));
}

static inline uint rotr32(uint value, uint count) {
    count &= 31;
    return count == 0 ? value : ((value >> count) | (value << (32 - count)));
}

static inline uint mul_hi32(uint a, uint b) {
    return (uint)(((ulong)a * (ulong)b) >> 32);
}

static inline uint clz32(uint value) {
    if (value == 0) {
        return 32;
    }
    uint count = 0;
    for (int bit = 31; bit >= 0; bit--) {
        if (((value >> (uint)bit) & 1u) != 0) {
            break;
        }
        count++;
    }
    return count;
}

static inline uint popcount32(uint value) {
    uint count = 0;
    while (value != 0) {
        value &= value - 1;
        count++;
    }
    return count;
}

struct Kiss99State {
    uint z;
    uint w;
    uint jsr;
    uint jcong;
};

static inline uint kiss99(thread Kiss99State &state) {
    state.z = 36969U * (state.z & 65535U) + (state.z >> 16);
    state.w = 18000U * (state.w & 65535U) + (state.w >> 16);
    uint mwc = (state.z << 16) + state.w;
    state.jsr ^= state.jsr << 17;
    state.jsr ^= state.jsr >> 13;
    state.jsr ^= state.jsr << 5;
    state.jcong = 69069U * state.jcong + 1234567U;
    return (mwc ^ state.jcong) + state.jsr;
}

static inline uint progpow_math(uint a, uint b, uint selector) {
    switch (selector % 11) {
    case 0: return a + b;
    case 1: return a * b;
    case 2: return mul_hi32(a, b);
    case 3: return min(a, b);
    case 4: return rotl32(a, b);
    case 5: return rotr32(a, b);
    case 6: return a & b;
    case 7: return a | b;
    case 8: return a ^ b;
    case 9: return clz32(a) + clz32(b);
    default: return popcount32(a) + popcount32(b);
    }
}

static inline uint read_u32_le(device const uchar *bytes, uint offset) {
    return ((uint)bytes[offset])
        | (((uint)bytes[offset + 1]) << 8)
        | (((uint)bytes[offset + 2]) << 16)
        | (((uint)bytes[offset + 3]) << 24);
}

static inline uint read_u32_le_thread(thread const uchar *bytes, uint offset) {
    return ((uint)bytes[offset])
        | (((uint)bytes[offset + 1]) << 8)
        | (((uint)bytes[offset + 2]) << 16)
        | (((uint)bytes[offset + 3]) << 24);
}

static inline void write_u32_le(device uchar *bytes, uint offset, uint value) {
    bytes[offset] = (uchar)(value & 0xff);
    bytes[offset + 1] = (uchar)((value >> 8) & 0xff);
    bytes[offset + 2] = (uchar)((value >> 16) & 0xff);
    bytes[offset + 3] = (uchar)((value >> 24) & 0xff);
}

static inline void write_u64_le(device uchar *bytes, uint offset, ulong value) {
    for (uint i = 0; i < 8; i++) {
        bytes[offset + i] = (uchar)((value >> (8 * i)) & 0xff);
    }
}

static void keccak_f1600(thread ulong state[25]) {
    for (uint round = 0; round < 24; round++) {
        ulong c[5];
        ulong d[5];
        ulong b[25];

        for (uint x = 0; x < 5; x++) {
            c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        }
        for (uint x = 0; x < 5; x++) {
            d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
        }
        for (uint y = 0; y < 25; y += 5) {
            for (uint x = 0; x < 5; x++) {
                state[x + y] ^= d[x];
            }
        }
        for (uint x = 0; x < 5; x++) {
            for (uint y = 0; y < 5; y++) {
                uint source = x + (5 * y);
                uint destinationX = y;
                uint destinationY = (2 * x + 3 * y) % 5;
                b[destinationX + (5 * destinationY)] = rotl64(state[source], keccak_rotation_offsets[source]);
            }
        }
        for (uint x = 0; x < 5; x++) {
            for (uint y = 0; y < 5; y++) {
                uint index = x + (5 * y);
                state[index] = b[index] ^ ((~b[((x + 1) % 5) + (5 * y)]) & b[((x + 2) % 5) + (5 * y)]);
            }
        }
        state[0] ^= keccak_round_constants[round];
    }
}

static void keccak256_96(thread const uchar *input, device uchar *dst) {
    ulong state[25];
    thread uchar block[136];
    for (uint i = 0; i < 25; i++) {
        state[i] = 0;
    }
    for (uint i = 0; i < 136; i++) {
        block[i] = 0;
    }
    for (uint i = 0; i < 96; i++) {
        block[i] = input[i];
    }
    block[96] ^= 0x01;
    block[135] ^= 0x80;

    for (uint lane = 0; lane < 17; lane++) {
        ulong value = 0;
        for (uint byteIndex = 0; byteIndex < 8; byteIndex++) {
            value |= ((ulong)block[(lane * 8) + byteIndex]) << (8 * byteIndex);
        }
        state[lane] ^= value;
    }
    keccak_f1600(state);
    for (uint i = 0; i < 4; i++) {
        write_u64_le(dst, i * 8, state[i]);
    }
}

static void keccak512_words16(thread uint words[16]) {
    ulong state[25];
    thread uchar block[72];
    for (uint i = 0; i < 25; i++) {
        state[i] = 0;
    }
    for (uint i = 0; i < 72; i++) {
        block[i] = 0;
    }
    for (uint word = 0; word < 16; word++) {
        uint value = words[word];
        block[(word * 4) + 0] = (uchar)(value & 0xff);
        block[(word * 4) + 1] = (uchar)((value >> 8) & 0xff);
        block[(word * 4) + 2] = (uchar)((value >> 16) & 0xff);
        block[(word * 4) + 3] = (uchar)((value >> 24) & 0xff);
    }
    block[64] ^= 0x01;
    block[71] ^= 0x80;

    for (uint lane = 0; lane < 9; lane++) {
        ulong value = 0;
        for (uint byteIndex = 0; byteIndex < 8; byteIndex++) {
            value |= ((ulong)block[(lane * 8) + byteIndex]) << (8 * byteIndex);
        }
        state[lane] ^= value;
    }
    keccak_f1600(state);

    for (uint lane = 0; lane < 8; lane++) {
        ulong value = state[lane];
        words[(lane * 2) + 0] = (uint)(value & 0xffffffffUL);
        words[(lane * 2) + 1] = (uint)((value >> 32) & 0xffffffffUL);
    }
}

kernel void multiAlgoKeccak512Seed(
    constant MultiAlgoSeedConfig &config [[buffer(0)]],
    device const uchar *header [[buffer(1)]],
    device uchar *out [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.itemCount) {
        return;
    }

    ulong state[25];
    for (uint i = 0; i < 25; i++) {
        state[i] = 0;
    }

    thread uchar block[72];
    for (uint i = 0; i < 72; i++) {
        block[i] = 0;
    }

    uint cappedHeaderLength = min(config.headerLength, 64u);
    for (uint i = 0; i < cappedHeaderLength; i++) {
        block[i] = header[i];
    }
    uint nonce = config.nonce + gid;
    for (uint i = 0; i < 4; i++) {
        block[cappedHeaderLength + i] = (uchar)((nonce >> (8 * i)) & 0xff);
    }

    uint used = cappedHeaderLength + 4;
    block[used] ^= 0x01;
    block[71] ^= 0x80;

    for (uint lane = 0; lane < 9; lane++) {
        ulong value = 0;
        for (uint byteIndex = 0; byteIndex < 8; byteIndex++) {
            value |= ((ulong)block[(lane * 8) + byteIndex]) << (8 * byteIndex);
        }
        state[lane] ^= value;
    }

    keccak_f1600(state);

    device uchar *dst = out + ((ulong)gid * max(config.outputStride, 64u));
    for (uint i = 0; i < 8; i++) {
        write_u64_le(dst, i * 8, state[i]);
    }
}

kernel void ethashEtchashDagMix(
    constant DagMixConfig &config [[buffer(0)]],
    device const uint *seedWords [[buffer(1)]],
    device const uint *dagWords [[buffer(2)]],
    device uint *outWords [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint seedCount = max(config.seedWordCount, 1u);
    uint dagCount = max(config.dagWordCount, 1u);
    uint accesses = max(config.accesses, 1u);
    uint mix[32];

    for (uint i = 0; i < 32; i++) {
        mix[i] = fnv1(seedWords[i % seedCount], gid ^ i);
    }

    for (uint access = 0; access < accesses; access++) {
        uint lane = access & 31;
        uint index = fnv1(gid ^ access, mix[lane]) % dagCount;
        uint dag = dagWords[index];
        mix[lane] = fnv1(mix[lane], dag);
        mix[(lane + 13) & 31] ^= rotl32(dag + access, (mix[lane] & 31));
    }

    device uint *dst = outWords + ((ulong)gid * max(config.outputStride, 8u));
    for (uint i = 0; i < 8; i++) {
        uint a = mix[i * 4];
        a = fnv1(a, mix[(i * 4) + 1]);
        a = fnv1(a, mix[(i * 4) + 2]);
        a = fnv1(a, mix[(i * 4) + 3]);
        dst[i] = a;
    }
}

kernel void ethashDatasetItemLite(
    constant EthashDatasetConfig &config [[buffer(0)]],
    device const uint *cacheWords [[buffer(1)]],
    device uint *outWords [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.itemCount) {
        return;
    }

    uint cacheNodeCount = max(config.cacheNodeCount, 1u);
    uint sourceNode = gid % cacheNodeCount;
    uint mix[16];
    for (uint word = 0; word < 16; word++) {
        mix[word] = cacheWords[((ulong)sourceNode * 16UL) + word];
    }
    mix[0] ^= gid;
    keccak512_words16(mix);

    uint parents = max(config.parents, 1u);
    for (uint parent = 0; parent < parents; parent++) {
        uint parentNode = fnv1(gid ^ parent, mix[parent & 15u]) % cacheNodeCount;
        for (uint word = 0; word < 16; word++) {
            mix[word] = fnv1(mix[word], cacheWords[((ulong)parentNode * 16UL) + word]);
        }
    }
    keccak512_words16(mix);

    device uint *dst = outWords + ((ulong)gid * max(config.outputStride, 16u));
    for (uint word = 0; word < 16; word++) {
        dst[word] = mix[word];
    }
}

kernel void ethashHashimotoLite(
    constant EthashHashimotoConfig &config [[buffer(0)]],
    device const uchar *header [[buffer(1)]],
    device const uint *dagWords [[buffer(2)]],
    device uchar *out [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.itemCount) {
        return;
    }

    ulong state[25];
    for (uint i = 0; i < 25; i++) {
        state[i] = 0;
    }

    thread uchar block[72];
    for (uint i = 0; i < 72; i++) {
        block[i] = 0;
    }

    uint cappedHeaderLength = min(config.headerLength, 64u);
    for (uint i = 0; i < cappedHeaderLength; i++) {
        block[i] = header[i];
    }
    uint nonce = config.nonce + gid;
    for (uint i = 0; i < 4; i++) {
        block[cappedHeaderLength + i] = (uchar)((nonce >> (8 * i)) & 0xff);
    }
    uint used = cappedHeaderLength + 4;
    block[used] ^= 0x01;
    block[71] ^= 0x80;

    for (uint lane = 0; lane < 9; lane++) {
        ulong value = 0;
        for (uint byteIndex = 0; byteIndex < 8; byteIndex++) {
            value |= ((ulong)block[(lane * 8) + byteIndex]) << (8 * byteIndex);
        }
        state[lane] ^= value;
    }
    keccak_f1600(state);

    thread uchar seedBytes[64];
    for (uint i = 0; i < 8; i++) {
        ulong value = state[i];
        for (uint byteIndex = 0; byteIndex < 8; byteIndex++) {
            seedBytes[(i * 8) + byteIndex] = (uchar)((value >> (8 * byteIndex)) & 0xff);
        }
    }

    uint mix[32];
    for (uint i = 0; i < 32; i++) {
        mix[i] = read_u32_le_thread(seedBytes, (i % 16) * 4);
    }

    uint dagWordCount = max(config.dagWordCount, 32u);
    uint dagPages = max(dagWordCount / 32u, 1u);
    uint accesses = max(config.accesses, 1u);
    for (uint access = 0; access < accesses; access++) {
        uint page = fnv1(access ^ seedBytes[0], mix[access & 31]) % dagPages;
        uint base = page * 32u;
        for (uint word = 0; word < 32; word++) {
            mix[word] = fnv1(mix[word], dagWords[(base + word) % dagWordCount]);
        }
    }

    uint cmix[8];
    for (uint i = 0; i < 8; i++) {
        uint value = mix[i * 4];
        value = fnv1(value, mix[(i * 4) + 1]);
        value = fnv1(value, mix[(i * 4) + 2]);
        value = fnv1(value, mix[(i * 4) + 3]);
        cmix[i] = value;
    }

    thread uchar finalInput[96];
    for (uint i = 0; i < 64; i++) {
        finalInput[i] = seedBytes[i];
    }
    for (uint i = 0; i < 8; i++) {
        finalInput[64 + (i * 4)] = (uchar)(cmix[i] & 0xff);
        finalInput[65 + (i * 4)] = (uchar)((cmix[i] >> 8) & 0xff);
        finalInput[66 + (i * 4)] = (uchar)((cmix[i] >> 16) & 0xff);
        finalInput[67 + (i * 4)] = (uchar)((cmix[i] >> 24) & 0xff);
    }

    device uchar *dst = out + ((ulong)gid * 64UL);
    keccak256_96(finalInput, dst);
    for (uint i = 0; i < 8; i++) {
        write_u32_le(dst, 32 + (i * 4), cmix[i]);
    }
}

kernel void progpowLaneMix(
    constant ProgPowConfig &config [[buffer(0)]],
    device const uint *seedWords [[buffer(1)]],
    device const uint *dagWords [[buffer(2)]],
    device uint *outWords [[buffer(3)]],
    uint2 tid [[thread_position_in_grid]]
) {
    uint lane = tid.x;
    uint work = tid.y;
    if (lane >= max(config.lanes, 1u)) {
        return;
    }

    uint dagCount = max(config.dagWordCount, 1u);
    uint cacheCount = max(config.cacheWordCount, 1u);
    thread Kiss99State rng;
    rng.z = fnv1a(362436069U, config.programSeed ^ lane);
    rng.w = fnv1a(521288629U, work);
    rng.jsr = fnv1a(123456789U, lane + (work << 8));
    rng.jcong = fnv1a(380116160U, config.programSeed + work);

    uint acc = fnv1a(seedWords[work & 7], lane ^ work ^ config.programSeed);
    uint rounds = max(config.rounds, 1u);

    for (uint round = 0; round < rounds; round++) {
        uint leaderLane = round % max(config.lanes, 1u);
        uint dagBase = fnv1a(acc ^ leaderLane, round + config.programSeed) % dagCount;
        uint dag = dagWords[(dagBase + ((lane ^ round) & 15u)) % dagCount];
        uint cache = dagWords[(kiss99(rng) + lane) % min(dagCount, cacheCount)];
        uint selector = kiss99(rng);
        uint math = progpow_math(acc ^ cache, dag, selector);
        acc = fnv1a(acc, math);
        acc = fnv1a(acc, dag);
    }

    outWords[((ulong)work * max(config.outputStride, max(config.lanes, 1u))) + lane] = acc;
}

kernel void progpowReferenceVectors(
    constant ProgPowVectorConfig &config [[buffer(0)]],
    device uint *outWords [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid > 0) {
        return;
    }

    outWords[0] = fnv1a(0x811c9dc5U, 0xddd0a47bU);
    outWords[1] = fnv1a(outWords[0], 0xee304846U);
    outWords[2] = fnv1a(outWords[1], 0x00000000U);

    thread Kiss99State rng;
    rng.z = 362436069U;
    rng.w = 521288629U;
    rng.jsr = 123456789U;
    rng.jcong = 380116160U;

    uint limit = max(config.iterations, 1u);
    uint first = 0;
    uint second = 0;
    uint third = 0;
    uint fourth = 0;
    uint last = 0;
    for (uint i = 1; i <= limit; i++) {
        last = kiss99(rng);
        if (i == 1) {
            first = last;
        } else if (i == 2) {
            second = last;
        } else if (i == 3) {
            third = last;
        } else if (i == 4) {
            fourth = last;
        }
    }

    outWords[3] = first;
    outWords[4] = second;
    outWords[5] = third;
    outWords[6] = fourth;
    outWords[7] = last;
}

kernel void progpowMergeLanes(
    constant ProgPowConfig &config [[buffer(0)]],
    device const uint *laneWords [[buffer(1)]],
    device uint *outWords [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    uint lanes = max(config.lanes, 1u);
    uint outputStride = max(config.outputStride, 8u);
    uint digest[8];
    for (uint i = 0; i < 8; i++) {
        digest[i] = 0x811c9dc5U;
    }

    for (uint lane = 0; lane < lanes; lane++) {
        uint laneValue = laneWords[((ulong)gid * lanes) + lane];
        digest[lane & 7u] = fnv1a(digest[lane & 7u], laneValue);
        digest[(lane + 3u) & 7u] = fnv1a(digest[(lane + 3u) & 7u], laneValue ^ config.programSeed);
    }

    device uint *dst = outWords + ((ulong)gid * outputStride);
    for (uint i = 0; i < 8; i++) {
        dst[i] = digest[i];
    }
}

kernel void autolykosLookupMix(
    constant AutolykosConfig &config [[buffer(0)]],
    device const uint *messageWords [[buffer(1)]],
    device const uint *tableWords [[buffer(2)]],
    device uint *outWords [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint messageCount = max(config.messageWordCount, 1u);
    uint tableCount = max(config.tableWordCount, 1u);
    uint lookups = max(config.lookups, 1u);
    uint acc0 = fnv1(messageWords[gid % messageCount], gid);
    uint acc1 = fnv1(messageWords[(gid + 1) % messageCount], gid ^ 0x9e3779b9U);

    for (uint i = 0; i < lookups; i++) {
        uint index = fnv1(acc0 + i, acc1) % tableCount;
        uint table = tableWords[index];
        acc0 = fnv1(acc0, table);
        acc1 = rotl32(acc1 + table + i, (table & 15) + 1);
    }

    device uint *dst = outWords + ((ulong)gid * max(config.outputStride, 4u));
    dst[0] = acc0;
    dst[1] = acc1;
    dst[2] = fnv1(acc0, acc1);
    dst[3] = acc0 ^ acc1;
}
