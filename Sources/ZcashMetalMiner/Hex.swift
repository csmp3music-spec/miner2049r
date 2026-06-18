import Foundation

enum HexError: LocalizedError {
    case oddLength
    case invalidCharacter(String)

    var errorDescription: String? {
        switch self {
        case .oddLength:
            return "Hex input must have an even number of characters."
        case .invalidCharacter(let value):
            return "Invalid hex byte: \(value)"
        }
    }
}

extension Data {
    init(hexString: String) throws {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")

        guard cleaned.count.isMultiple(of: 2) else {
            throw HexError.oddLength
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let token = String(cleaned[index..<next])
            guard let byte = UInt8(token, radix: 16) else {
                throw HexError.invalidCharacter(token)
            }
            bytes.append(byte)
            index = next
        }

        self = Data(bytes)
    }

    func hexString(limit: Int? = nil) -> String {
        let slice = limit.map { self.prefix($0) } ?? self[...]
        return slice.map { String(format: "%02x", $0) }.joined()
    }
}
