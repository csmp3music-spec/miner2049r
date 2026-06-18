import CryptoKit
import Foundation

struct ZcashShareCheck {
    let hash: Data
    let rawHash: Data
    let target: Data
    let meetsTarget: Bool

    var hashHex: String { hash.hexString() }
    var rawHashHex: String { rawHash.hexString() }
    var targetHex: String { target.hexString() }
}

enum ZcashShareValidationError: LocalizedError {
    case invalidTarget(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let value):
            return "Invalid Zcash share target: \(value)"
        }
    }
}

enum ZcashShareValidator {
    static func check(powHeader: Data, solution: EquihashSolution, targetHex: String) throws -> ZcashShareCheck {
        let target = try normalizedTarget(targetHex)
        let payload = solution.zcashSubmissionPayload
        var header = Data(powHeader)
        header.append(payload)
        let rawHash = doubleSHA256(header)
        let displayHash = Data(rawHash.reversed())
        let meetsTarget = lessThanOrEqual(displayHash, target)
        return ZcashShareCheck(hash: displayHash, rawHash: rawHash, target: target, meetsTarget: meetsTarget)
    }

    static func blockHashForTarget(_ fullHeader: Data) -> Data {
        Data(doubleSHA256(fullHeader).reversed())
    }

    static func normalizedTarget(_ hex: String) throws -> Data {
        let cleaned = hex
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, cleaned.count <= 64 else {
            throw ZcashShareValidationError.invalidTarget(hex)
        }

        let padded = String(repeating: "0", count: 64 - cleaned.count) + cleaned
        let data = try Data(hexString: padded)
        guard data.count == 32 else {
            throw ZcashShareValidationError.invalidTarget(hex)
        }
        return data
    }

    static func targetWorkEstimate(targetHex: String, attemptsPerSecond: Double) -> String {
        guard let target = try? normalizedTarget(targetHex),
              let log2Target = approximateLog2(target),
              log2Target < 256 else {
            return "Target accepts every locally valid solution."
        }

        let expectedAttemptsLog2 = 256 - log2Target
        let difficulty = pow(2.0, expectedAttemptsLog2)
        let difficultyText = formatLargeNumber(difficulty)
        guard attemptsPerSecond > 0 else {
            return "Pool target requires about \(difficultyText) locally valid solution(s) per accepted share."
        }

        let seconds = difficulty / attemptsPerSecond
        return "At current rate, expected accepted-share interval is \(formatDuration(seconds)) (about \(difficultyText) locally valid solution trials)."
    }

    static func targetHardnessLabel(targetHex: String) -> String {
        guard let target = try? normalizedTarget(targetHex),
              let log2Target = approximateLog2(target) else {
            return "Invalid target"
        }
        if log2Target >= 256 {
            return "Max target"
        }
        let leadingBits = Int(max(0, floor(255 - log2Target)))
        return "Approx. \(leadingBits) leading zero bit target"
    }

    private static func doubleSHA256(_ data: Data) -> Data {
        let first = SHA256.hash(data: data)
        let second = SHA256.hash(data: Data(first))
        return Data(second)
    }

    private static func approximateLog2(_ data: Data) -> Double? {
        let bytes = Array(data)
        guard let firstIndex = bytes.firstIndex(where: { $0 != 0 }) else {
            return nil
        }
        let byte = bytes[firstIndex]
        let bit = 7 - byte.leadingZeroBitCount
        let fraction = Double(byte) / pow(2.0, Double(bit))
        return Double((bytes.count - firstIndex - 1) * 8 + bit) + log2(fraction)
    }

    private static func formatLargeNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "an unreachable number of"
        }
        let units = ["", "K", "M", "B", "T", "P", "E"]
        var scaled = value
        var unit = 0
        while scaled >= 1_000, unit < units.count - 1 {
            scaled /= 1_000
            unit += 1
        }
        return String(format: "%.2f%@", scaled, units[unit])
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "effectively never"
        }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: "%.1f min", minutes)
        }
        let hours = minutes / 60
        if hours < 48 {
            return String(format: "%.1f h", hours)
        }
        let days = hours / 24
        if days < 365 {
            return String(format: "%.1f days", days)
        }
        return String(format: "%.1f years", days / 365)
    }

    private static func lessThanOrEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        for (l, r) in zip(left, right) {
            if l < r { return true }
            if l > r { return false }
        }
        return true
    }
}
