import Foundation

enum EthashPrimitives {
    static func fnv1(_ x: UInt32, _ y: UInt32) -> UInt32 {
        (x &* 0x0100_0193) ^ y
    }

    static func keccak256(_ data: Data) -> Data {
        keccak(data, outputByteCount: 32)
    }

    static func keccak512(_ data: Data) -> Data {
        keccak(data, outputByteCount: 64)
    }

    private static func keccak(_ data: Data, outputByteCount: Int) -> Data {
        let rate = 200 - (outputByteCount * 2)
        precondition(rate > 0 && rate < 200 && outputByteCount <= 64)

        var state = [UInt64](repeating: 0, count: 25)
        let bytes = [UInt8](data)
        var offset = 0

        while bytes.count - offset >= rate {
            absorb(block: bytes[offset..<(offset + rate)], into: &state)
            keccakF1600(&state)
            offset += rate
        }

        var block = [UInt8](repeating: 0, count: rate)
        if offset < bytes.count {
            block.replaceSubrange(0..<(bytes.count - offset), with: bytes[offset...])
        }
        block[bytes.count - offset] ^= 0x01
        block[rate - 1] ^= 0x80
        absorb(block: block[0..<rate], into: &state)
        keccakF1600(&state)

        var output = Data()
        output.reserveCapacity(outputByteCount)
        while output.count < outputByteCount {
            for lane in state {
                var little = lane.littleEndian
                withUnsafeBytes(of: &little) { raw in
                    let remaining = outputByteCount - output.count
                    output.append(contentsOf: raw.prefix(remaining))
                }
                if output.count == outputByteCount {
                    break
                }
            }
            if output.count < outputByteCount {
                keccakF1600(&state)
            }
        }
        return output
    }

    private static func absorb(block: ArraySlice<UInt8>, into state: inout [UInt64]) {
        var laneIndex = 0
        var byteIndex = block.startIndex
        while byteIndex < block.endIndex {
            var lane: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 8) {
                if byteIndex < block.endIndex {
                    lane |= UInt64(block[byteIndex]) << UInt64(shift)
                    byteIndex = block.index(after: byteIndex)
                }
            }
            state[laneIndex] ^= lane
            laneIndex += 1
        }
    }

    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0..<24 {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }

            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], by: 1)
            }
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0..<5 {
                    state[x + y] ^= d[x]
                }
            }

            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    let source = x + (5 * y)
                    let destinationX = y
                    let destinationY = (2 * x + 3 * y) % 5
                    b[destinationX + (5 * destinationY)] = rotateLeft(state[source], by: rotationOffsets[source])
                }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    let index = x + (5 * y)
                    state[index] = b[index] ^ ((~b[((x + 1) % 5) + (5 * y)]) & b[((x + 2) % 5) + (5 * y)])
                }
            }

            state[0] ^= roundConstants[round]
        }
    }

    private static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        guard count != 0 else { return value }
        return (value << count) | (value >> (64 - count))
    }

    private static let rotationOffsets: [UInt64] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14
    ]

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082,
        0x8000_0000_0000_808a, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808b, 0x0000_0000_8000_0001,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008a, 0x0000_0000_0000_0088,
        0x0000_0000_8000_8009, 0x0000_0000_8000_000a,
        0x0000_0000_8000_808b, 0x8000_0000_0000_008b,
        0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
        0x0000_0000_0000_800a, 0x8000_0000_8000_000a,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
        0x0000_0000_8000_0001, 0x8000_0000_8000_8008
    ]
}
