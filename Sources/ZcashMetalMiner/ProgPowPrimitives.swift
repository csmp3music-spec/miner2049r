import Foundation

struct Kiss99State: Equatable {
    var z: UInt32
    var w: UInt32
    var jsr: UInt32
    var jcong: UInt32

    static let eip1057Seed = Kiss99State(
        z: 362_436_069,
        w: 521_288_629,
        jsr: 123_456_789,
        jcong: 380_116_160
    )
}

enum ProgPowPrimitives {
    static func fnv1a(_ h: UInt32, _ d: UInt32) -> UInt32 {
        (h ^ d) &* 0x0100_0193
    }

    static func kiss99(_ state: inout Kiss99State) -> UInt32 {
        state.z = 36_969 &* (state.z & 65_535) &+ (state.z >> 16)
        state.w = 18_000 &* (state.w & 65_535) &+ (state.w >> 16)
        let mwc = (state.z << 16) &+ state.w
        state.jsr ^= state.jsr << 17
        state.jsr ^= state.jsr >> 13
        state.jsr ^= state.jsr << 5
        state.jcong = 69_069 &* state.jcong &+ 1_234_567
        return (mwc ^ state.jcong) &+ state.jsr
    }
}
