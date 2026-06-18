import Foundation

struct ZcashStratumJob: Identifiable, Equatable {
    let id: String
    let version: Data
    let previousHash: Data
    let merkleRoot: Data
    let reserved: Data
    let time: Data
    let bits: Data
    let cleanJobs: Bool

    init(params: [Any]) throws {
        guard params.count >= 8,
              let id = params[0] as? String,
              let versionHex = params[1] as? String,
              let previousHashHex = params[2] as? String,
              let merkleRootHex = params[3] as? String,
              let reservedHex = params[4] as? String,
              let timeHex = params[5] as? String,
              let bitsHex = params[6] as? String,
              let cleanJobs = params[7] as? Bool else {
            throw ZcashJobError.invalidNotify
        }

        self.id = id
        self.version = try Data(hexString: versionHex)
        self.previousHash = try Data(hexString: previousHashHex)
        self.merkleRoot = try Data(hexString: merkleRootHex)
        self.reserved = try Data(hexString: reservedHex)
        self.time = try Data(hexString: timeHex)
        self.bits = try Data(hexString: bitsHex)
        self.cleanJobs = cleanJobs

        guard version.count == 4, versionHex.lowercased() == "04000000" else {
            throw ZcashJobError.unsupportedVersion(versionHex)
        }
        guard previousHash.count == 32,
              merkleRoot.count == 32,
              reserved.count == 32,
              time.count == 4,
              bits.count == 4 else {
            throw ZcashJobError.invalidFieldLength
        }
    }

    func powHeader(nonce1: String, nonce2: String) throws -> Data {
        let nonce1Data = try Data(hexString: nonce1)
        let nonce2Data = try Data(hexString: nonce2)
        guard nonce1Data.count + nonce2Data.count == 32 else {
            throw ZcashJobError.invalidNonceLength(nonce1Data.count + nonce2Data.count)
        }

        var header = Data(capacity: 140)
        header.append(version)
        header.append(previousHash)
        header.append(merkleRoot)
        header.append(reserved)
        header.append(time)
        header.append(bits)
        header.append(nonce1Data)
        header.append(nonce2Data)
        return header
    }

    var timeHex: String { time.hexString() }
}

struct ZcashSubmission {
    let jobID: String
    let time: String
    let nonce2: String
    let solution: String
}

enum ZcashJobError: LocalizedError {
    case invalidNotify
    case unsupportedVersion(String)
    case invalidFieldLength
    case invalidNonceLength(Int)

    var errorDescription: String? {
        switch self {
        case .invalidNotify:
            return "mining.notify did not match the Zcash ZIP-301 parameter shape."
        case .unsupportedVersion(let version):
            return "Unsupported Zcash block header version: \(version)."
        case .invalidFieldLength:
            return "Zcash mining.notify contained one or more fields with an invalid byte length."
        case .invalidNonceLength(let length):
            return "Zcash nonce1 + nonce2 must be 32 bytes; got \(length)."
        }
    }
}

enum CompactSize {
    static func encode(_ value: Int) -> Data {
        if value < 0xfd {
            return Data([UInt8(value)])
        }
        if value <= 0xffff {
            return Data([0xfd, UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
        }
        if value <= 0xffff_ffff {
            return Data([
                0xfe,
                UInt8(value & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 24) & 0xff)
            ])
        }

        var encoded = Data([0xff])
        var little = UInt64(value).littleEndian
        withUnsafeBytes(of: &little) { encoded.append(contentsOf: $0) }
        return encoded
    }
}

extension EquihashSolution {
    var zcashSubmissionPayload: Data {
        var payload = CompactSize.encode(encoded.count)
        payload.append(encoded)
        return payload
    }

    var zcashSubmissionHex: String {
        zcashSubmissionPayload.hexString()
    }
}
