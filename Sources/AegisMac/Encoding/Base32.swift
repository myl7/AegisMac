import Foundation

/// RFC 4648 Base32 (alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`).
///
/// Mirrors Aegis' Guava-backed `Base32`:
/// - `decode` uppercases the input first and accepts input **with or without**
///   trailing `=` padding.
/// - `encode` produces **UPPERCASE** output with **NO** padding (`omitPadding()`).
///
/// Invalid characters or invalid final-block lengths throw `AegisError.encoding`.
enum Base32 {
    private static let encodeTable: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// ASCII byte -> 5-bit value for the RFC 4648 alphabet.
    private static let decodeMap: [UInt8: UInt8] = {
        var map = [UInt8: UInt8]()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        for (index, byte) in alphabet.enumerated() {
            map[byte] = UInt8(index)
        }
        return map
    }()

    static func decode(_ s: String) throws -> Data {
        // Uppercase first (matches BaseEncoding.base32().decode(s.toUpperCase())).
        let upper = s.uppercased()

        // Collect significant characters, stopping at the first '=' padding byte.
        var chars = [UInt8]()
        chars.reserveCapacity(upper.utf8.count)
        for byte in upper.utf8 {
            if byte == UInt8(ascii: "=") {
                break
            }
            chars.append(byte)
        }

        // Validate the length of the (possibly unpadded) final quantum.
        // Valid counts mod 8 are {0, 2, 4, 5, 7}; 1, 3 and 6 are impossible.
        switch chars.count % 8 {
        case 1, 3, 6:
            throw AegisError.encoding("invalid base32 length")
        default:
            break
        }

        var output = [UInt8]()
        output.reserveCapacity(chars.count * 5 / 8)
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for c in chars {
            guard let value = decodeMap[c] else {
                throw AegisError.encoding("invalid base32 character")
            }
            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xFF))
            }
        }
        return Data(output)
    }

    static func encode(_ data: Data) -> String {
        if data.isEmpty {
            return ""
        }
        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> UInt32(bitsLeft)) & 0x1F)
                result.append(encodeTable[index])
            }
        }
        if bitsLeft > 0 {
            // Pad the remaining bits on the right with zeros to form a 5-bit group.
            let index = Int((buffer << UInt32(5 - bitsLeft)) & 0x1F)
            result.append(encodeTable[index])
        }
        return result
    }
}
