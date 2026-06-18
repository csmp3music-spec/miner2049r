import Foundation

struct Blake2b400 {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]

    private static let sigma: [[Int]] = [
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 ],
        [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 ],
        [11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 ],
        [ 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 ],
        [ 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 ],
        [ 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 ],
        [12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 ],
        [13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 ],
        [ 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 ],
        [10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 ],
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 ],
        [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 ]
    ]

    static func zcashPersonalizedDigest(input: Data) -> Data {
        var state = iv
        state[0] ^= 0x01010032
        state[6] ^= 0x576f50687361635a
        state[7] ^= 0x00000000000900c8

        var offset = 0
        while offset < input.count || input.isEmpty {
            let remaining = input.count - offset
            let blockLength = min(128, max(remaining, 0))
            var block = [UInt8](repeating: 0, count: 128)
            if blockLength > 0 {
                block.replaceSubrange(0..<blockLength, with: input[offset..<(offset + blockLength)])
            }
            let isLast = offset + blockLength >= input.count
            compress(state: &state, block: block, bytes: UInt64(offset + blockLength), isLast: isLast)
            if isLast {
                break
            }
            offset += blockLength
        }

        var output = Data(capacity: 50)
        for word in state.prefix(6) {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
        }
        var tail = state[6].littleEndian
        withUnsafeBytes(of: &tail) { output.append(contentsOf: $0.prefix(2)) }
        return output
    }

    private static func compress(state h: inout [UInt64], block: [UInt8], bytes: UInt64, isLast: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in 0..<8 {
                word |= UInt64(block[i * 8 + j]) << UInt64(8 * j)
            }
            m[i] = word
        }

        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 {
            v[i] = h[i]
            v[i + 8] = iv[i]
        }
        v[12] ^= bytes
        if isLast {
            v[14] = ~v[14]
        }

        for round in 0..<12 {
            let s = sigma[round]
            mix(&v, m[s[0]], m[s[1]], 0, 4, 8, 12)
            mix(&v, m[s[2]], m[s[3]], 1, 5, 9, 13)
            mix(&v, m[s[4]], m[s[5]], 2, 6, 10, 14)
            mix(&v, m[s[6]], m[s[7]], 3, 7, 11, 15)
            mix(&v, m[s[8]], m[s[9]], 0, 5, 10, 15)
            mix(&v, m[s[10]], m[s[11]], 1, 6, 11, 12)
            mix(&v, m[s[12]], m[s[13]], 2, 7, 8, 13)
            mix(&v, m[s[14]], m[s[15]], 3, 4, 9, 14)
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func mix(_ v: inout [UInt64], _ x: UInt64, _ y: UInt64, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotatedRight(32)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotatedRight(16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }
}

private extension UInt64 {
    func rotatedRight(_ amount: UInt64) -> UInt64 {
        (self >> amount) | (self << (64 - amount))
    }
}
