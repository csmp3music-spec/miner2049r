#include <metal_stdlib>
using namespace metal;

constant ulong blake2b_iv[8] = {
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL,
    0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL,
    0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL
};

constant uchar blake2b_sigma[12][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
    {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
    {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
    { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
    { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
    {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
    {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
    { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
    {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 },
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
    {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 }
};

struct WorkConfig {
    uint headerLength;
    uint outputStride;
    uint nonce;
    uint inputCount;
    uint hashesPerThread;
    uint checksumOffset;
    uint reserved0;
    uint reserved1;
};

struct RowConfig {
    uint headerLength;
    uint rowCount;
    uint collisionBits;
    uint reserved;
};

struct RoundOneConfig {
    uint rowCount;
    uint bucketCount;
    uint bucketSlots;
    uint maxPairs;
    uint secondKeyOffset;
    uint collisionBits;
    uint inputIndexWidth;
    uint reserved1;
};

struct CompactConfig {
    uint rowCount;
    uint indexWidth;
    uint maxSolutions;
    uint reserved;
};

static inline ulong rotr64(ulong x, uint n) {
    return (x >> n) | (x << (64 - n));
}

static inline void mix(thread ulong v[16], ulong x, ulong y, uint a, uint b, uint c, uint d) {
    v[a] = v[a] + v[b] + x;
    v[d] = rotr64(v[d] ^ v[a], 32);
    v[c] = v[c] + v[d];
    v[b] = rotr64(v[b] ^ v[c], 24);
    v[a] = v[a] + v[b] + y;
    v[d] = rotr64(v[d] ^ v[a], 16);
    v[c] = v[c] + v[d];
    v[b] = rotr64(v[b] ^ v[c], 63);
}

static inline ulong load64(const thread uchar *p) {
    ulong r = 0;
    for (uint i = 0; i < 8; i++) {
        r |= ((ulong)p[i]) << (8 * i);
    }
    return r;
}

static inline void store64(device uchar *p, ulong v) {
    for (uint i = 0; i < 8; i++) {
        p[i] = (uchar)((v >> (8 * i)) & 0xff);
    }
}

static inline uchar digest_byte(thread ulong h[8], uint offset) {
    uint word = offset / 8;
    uint shift = (offset % 8) * 8;
    return (uchar)((h[word] >> shift) & 0xff);
}

static inline uint load_be_bits(device const uchar *p, uint offset, uint length) {
    uint value = 0;
    for (uint bit = 0; bit < length; bit++) {
        uint absolute = offset + bit;
        uchar byte = p[absolute / 8];
        uint bitInByte = 7 - (absolute % 8);
        value = (value << 1) | ((byte >> bitInByte) & 1);
    }
    return value;
}

static inline bool indices_disjoint(device const uint *left, device const uint *right, uint width) {
    for (uint i = 0; i < width; i++) {
        for (uint j = 0; j < width; j++) {
            if (left[i] == right[j]) {
                return false;
            }
        }
    }
    return true;
}

static inline bool lexicographic_less(device const uint *left, device const uint *right, uint width) {
    for (uint i = 0; i < width; i++) {
        if (left[i] < right[i]) {
            return true;
        }
        if (left[i] > right[i]) {
            return false;
        }
    }
    return false;
}

static inline void store_ordered_indices(
    device uint *dst,
    device const uint *left,
    device const uint *right,
    uint width
) {
    bool leftFirst = lexicographic_less(left, right, width);
    device const uint *first = leftFirst ? left : right;
    device const uint *second = leftFirst ? right : left;
    for (uint i = 0; i < width; i++) {
        dst[i] = first[i];
        dst[width + i] = second[i];
    }
}

static void compress(thread ulong h[8], const thread uchar block[128], ulong bytes, bool lastBlock) {
    ulong m[16];
    ulong v[16];

    for (uint i = 0; i < 16; i++) {
        m[i] = load64(block + (i * 8));
    }
    for (uint i = 0; i < 8; i++) {
        v[i] = h[i];
        v[i + 8] = blake2b_iv[i];
    }

    v[12] ^= bytes;
    if (lastBlock) {
        v[14] = ~v[14];
    }

    for (uint round = 0; round < 12; round++) {
        mix(v, m[blake2b_sigma[round][0]], m[blake2b_sigma[round][1]], 0, 4,  8, 12);
        mix(v, m[blake2b_sigma[round][2]], m[blake2b_sigma[round][3]], 1, 5,  9, 13);
        mix(v, m[blake2b_sigma[round][4]], m[blake2b_sigma[round][5]], 2, 6, 10, 14);
        mix(v, m[blake2b_sigma[round][6]], m[blake2b_sigma[round][7]], 3, 7, 11, 15);
        mix(v, m[blake2b_sigma[round][8]], m[blake2b_sigma[round][9]], 0, 5, 10, 15);
        mix(v, m[blake2b_sigma[round][10]], m[blake2b_sigma[round][11]], 1, 6, 11, 12);
        mix(v, m[blake2b_sigma[round][12]], m[blake2b_sigma[round][13]], 2, 7,  8, 13);
        mix(v, m[blake2b_sigma[round][14]], m[blake2b_sigma[round][15]], 3, 4,  9, 14);
    }

    for (uint i = 0; i < 8; i++) {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

static inline void generate_digest(
    device const uchar *header,
    uint headerLength,
    uint nonce,
    uint index,
    thread ulong h[8]
) {
    thread uchar block[128];
    for (uint i = 0; i < 128; i++) {
        block[i] = 0;
    }

    uint cappedHeaderLength = min(headerLength, 120u);
    for (uint i = 0; i < cappedHeaderLength; i++) {
        block[i] = header[i];
    }

    uint p = cappedHeaderLength;
    for (uint i = 0; i < 4; i++) {
        block[p + i] = (uchar)((nonce >> (8 * i)) & 0xff);
        block[p + 4 + i] = (uchar)((index >> (8 * i)) & 0xff);
    }

    for (uint i = 0; i < 8; i++) {
        h[i] = blake2b_iv[i];
    }

    // BLAKE2b parameter block for a 50-byte digest with Zcash Equihash personalization.
    h[0] ^= 0x01010032UL;
    h[6] ^= 0x576f50687361635aUL; // "ZcashPoW"
    h[7] ^= 0x00000000000900c8UL; // n=200, k=9, little-endian 32-bit words

    compress(h, block, cappedHeaderLength + 8, true);
}

static inline void generate_powheader_digest(
    device const uchar *header,
    uint headerLength,
    uint group,
    thread ulong h[8]
) {
    thread uchar block[128];
    for (uint i = 0; i < 128; i++) {
        block[i] = 0;
    }

    for (uint i = 0; i < 8; i++) {
        h[i] = blake2b_iv[i];
    }

    h[0] ^= 0x01010032UL;
    h[6] ^= 0x576f50687361635aUL; // "ZcashPoW"
    h[7] ^= 0x00000000000900c8UL; // n=200, k=9

    if (headerLength <= 124) {
        for (uint i = 0; i < headerLength; i++) {
            block[i] = header[i];
        }
        for (uint i = 0; i < 4; i++) {
            block[headerLength + i] = (uchar)((group >> (8 * i)) & 0xff);
        }
        compress(h, block, headerLength + 4, true);
        return;
    }

    for (uint i = 0; i < 128; i++) {
        block[i] = header[i];
    }
    compress(h, block, 128, false);

    for (uint i = 0; i < 128; i++) {
        block[i] = 0;
    }
    uint tailLength = headerLength - 128;
    for (uint i = 0; i < tailLength; i++) {
        block[i] = header[128 + i];
    }
    for (uint i = 0; i < 4; i++) {
        block[tailLength + i] = (uchar)((group >> (8 * i)) & 0xff);
    }
    compress(h, block, headerLength + 4, true);
}

kernel void equihashGenerate(
    constant WorkConfig &config [[buffer(0)]],
    device const uchar *header [[buffer(1)]],
    device uchar *out [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    uint baseIndex = gid * config.hashesPerThread;
    uint checksum = 0;

    for (uint pass = 0; pass < config.hashesPerThread; pass++) {
        uint index = baseIndex + pass;
        if (index >= config.inputCount) {
            break;
        }

        ulong h[8];
        generate_digest(header, config.headerLength, config.nonce, index, h);

        checksum ^= (uint)(h[0] ^ (h[0] >> 32) ^ h[1] ^ (h[1] >> 32));

        if (index == 0) {
            for (uint i = 0; i < 6; i++) {
                store64(out + (i * 8), h[i]);
            }
            ulong tail = h[6];
            out[48] = (uchar)(tail & 0xff);
            out[49] = (uchar)((tail >> 8) & 0xff);
        }
    }

    device uint *checksums = reinterpret_cast<device uint *>(out + config.checksumOffset);
    checksums[gid] = checksum;
}

kernel void equihashInitialRows(
    constant RowConfig &config [[buffer(0)]],
    device const uchar *header [[buffer(1)]],
    device uchar *rowDigests [[buffer(2)]],
    device uint *rowIndices [[buffer(3)]],
    device uint *rowKeys [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.rowCount) {
        return;
    }

    uint oneBasedIndex = gid + 1;
    uint zeroBased = oneBasedIndex - 1;
    uint group = zeroBased / 2;
    uint slot = zeroBased % 2;

    ulong h[8];
    generate_powheader_digest(header, config.headerLength, group, h);

    device uchar *dst = rowDigests + ((ulong)gid * 25UL);
    uint sourceOffset = slot * 25;
    for (uint i = 0; i < 25; i++) {
        dst[i] = digest_byte(h, sourceOffset + i);
    }

    rowIndices[gid] = oneBasedIndex;
    rowKeys[gid] = load_be_bits(dst, 0, config.collisionBits);
}

kernel void clearUIntBuffer(
    device uint *buffer [[buffer(0)]],
    constant uint &count [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid < count) {
        buffer[gid] = 0;
    }
}

kernel void equihashBucketInitialRows(
    constant RoundOneConfig &config [[buffer(0)]],
    device const uint *rowKeys [[buffer(1)]],
    device uint *bucketCountsRaw [[buffer(2)]],
    device uint *bucketSlots [[buffer(3)]],
    device atomic_uint *overflow [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.rowCount) {
        return;
    }

    uint key = rowKeys[gid];
    if (key >= config.bucketCount) {
        atomic_store_explicit(overflow, 1, memory_order_relaxed);
        return;
    }

    device atomic_uint *bucketCounts = reinterpret_cast<device atomic_uint *>(bucketCountsRaw);
    uint slot = atomic_fetch_add_explicit(bucketCounts + key, 1, memory_order_relaxed);
    if (slot < config.bucketSlots) {
        bucketSlots[((ulong)key * config.bucketSlots) + slot] = gid;
    } else {
        atomic_store_explicit(overflow, 1, memory_order_relaxed);
    }
}

kernel void equihashRoundOnePairs(
    constant RoundOneConfig &config [[buffer(0)]],
    device const uchar *rowDigests [[buffer(1)]],
    device const uint *rowIndices [[buffer(2)]],
    device const uint *bucketCounts [[buffer(3)]],
    device const uint *bucketSlots [[buffer(4)]],
    device uchar *outDigests [[buffer(5)]],
    device uint *outIndices [[buffer(6)]],
    device uint *outKeys [[buffer(7)]],
    device atomic_uint *pairCounter [[buffer(8)]],
    device atomic_uint *overflow [[buffer(9)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.bucketCount) {
        return;
    }

    uint count = min(bucketCounts[gid], config.bucketSlots);
    if (bucketCounts[gid] > config.bucketSlots) {
        atomic_store_explicit(overflow, 1, memory_order_relaxed);
    }

    for (uint leftSlot = 0; leftSlot < count; leftSlot++) {
        uint leftRow = bucketSlots[((ulong)gid * config.bucketSlots) + leftSlot];
        for (uint rightSlot = leftSlot + 1; rightSlot < count; rightSlot++) {
            uint rightRow = bucketSlots[((ulong)gid * config.bucketSlots) + rightSlot];
            uint inputWidth = max(1u, config.inputIndexWidth);
            device const uint *leftIndices = rowIndices + ((ulong)leftRow * inputWidth);
            device const uint *rightIndices = rowIndices + ((ulong)rightRow * inputWidth);
            if (!indices_disjoint(leftIndices, rightIndices, inputWidth)) {
                continue;
            }

            uint out = atomic_fetch_add_explicit(pairCounter, 1, memory_order_relaxed);
            if (out >= config.maxPairs) {
                atomic_store_explicit(overflow, 1, memory_order_relaxed);
                continue;
            }

            device uchar *dst = outDigests + ((ulong)out * 25UL);
            device const uchar *left = rowDigests + ((ulong)leftRow * 25UL);
            device const uchar *right = rowDigests + ((ulong)rightRow * 25UL);
            for (uint i = 0; i < 25; i++) {
                dst[i] = left[i] ^ right[i];
            }

            device uint *dstIndices = outIndices + ((ulong)out * inputWidth * 2UL);
            store_ordered_indices(dstIndices, leftIndices, rightIndices, inputWidth);
            outKeys[out] = load_be_bits(dst, config.secondKeyOffset, config.collisionBits);
        }
    }
}

kernel void equihashFinalRoundSolutions(
    constant RoundOneConfig &config [[buffer(0)]],
    device const uchar *rowDigests [[buffer(1)]],
    device const uint *rowIndices [[buffer(2)]],
    device const uint *bucketCounts [[buffer(3)]],
    device const uint *bucketSlots [[buffer(4)]],
    device uint *solutionIndices [[buffer(5)]],
    device atomic_uint *solutionCounter [[buffer(6)]],
    device atomic_uint *overflow [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.bucketCount) {
        return;
    }

    uint count = min(bucketCounts[gid], config.bucketSlots);
    if (bucketCounts[gid] > config.bucketSlots) {
        atomic_store_explicit(overflow, 1, memory_order_relaxed);
    }

    uint inputWidth = max(1u, config.inputIndexWidth);
    for (uint leftSlot = 0; leftSlot < count; leftSlot++) {
        uint leftRow = bucketSlots[((ulong)gid * config.bucketSlots) + leftSlot];
        for (uint rightSlot = leftSlot + 1; rightSlot < count; rightSlot++) {
            uint rightRow = bucketSlots[((ulong)gid * config.bucketSlots) + rightSlot];
            device const uint *leftIndices = rowIndices + ((ulong)leftRow * inputWidth);
            device const uint *rightIndices = rowIndices + ((ulong)rightRow * inputWidth);
            if (!indices_disjoint(leftIndices, rightIndices, inputWidth)) {
                continue;
            }

            device const uchar *left = rowDigests + ((ulong)leftRow * 25UL);
            device const uchar *right = rowDigests + ((ulong)rightRow * 25UL);
            bool isZero = true;
            for (uint i = 0; i < 25; i++) {
                if ((left[i] ^ right[i]) != 0) {
                    isZero = false;
                    break;
                }
            }
            if (!isZero) {
                continue;
            }

            uint out = atomic_fetch_add_explicit(solutionCounter, 1, memory_order_relaxed);
            if (out >= config.maxPairs) {
                continue;
            }

            device uint *dstIndices = solutionIndices + ((ulong)out * inputWidth * 2UL);
            store_ordered_indices(dstIndices, leftIndices, rightIndices, inputWidth);
        }
    }
}

kernel void equihashCompactZeroRows(
    constant CompactConfig &config [[buffer(0)]],
    device const uchar *rowDigests [[buffer(1)]],
    device const uint *rowIndices [[buffer(2)]],
    device uint *solutionIndices [[buffer(3)]],
    device atomic_uint *solutionCounter [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.rowCount) {
        return;
    }

    device const uchar *digest = rowDigests + ((ulong)gid * 25UL);
    for (uint i = 0; i < 25; i++) {
        if (digest[i] != 0) {
            return;
        }
    }

    uint out = atomic_fetch_add_explicit(solutionCounter, 1, memory_order_relaxed);
    if (out >= config.maxSolutions) {
        return;
    }

    device const uint *src = rowIndices + ((ulong)gid * config.indexWidth);
    device uint *dst = solutionIndices + ((ulong)out * config.indexWidth);
    for (uint i = 0; i < config.indexWidth; i++) {
        dst[i] = src[i];
    }
}
