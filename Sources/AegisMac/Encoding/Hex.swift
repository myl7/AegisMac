import Foundation

/// Base16 / Hex encoding matching Aegis' Guava-backed `Hex`.
///
/// - `encode` produces **lowercase** output (`base16().lowerCase()`).
/// - `decode` is **case-insensitive** (Aegis uppercases the input before decoding).
///
/// Odd length or invalid characters throw `AegisError.encoding`.
enum HexCodec {
    private static let hexChars: [Character] = Array("0123456789abcdef")

    static func encode(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count * 2)
        for byte in data {
            result.append(hexChars[Int(byte >> 4)])
            result.append(hexChars[Int(byte & 0x0F)])
        }
        return result
    }

    static func decode(_ s: String) throws -> Data {
        let bytes = Array(s.utf8)
        if bytes.count % 2 != 0 {
            throw AegisError.encoding("invalid hex length")
        }
        var output = [UInt8]()
        output.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            let hi = try nibble(bytes[i])
            let lo = try nibble(bytes[i + 1])
            output.append((hi << 4) | lo)
            i += 2
        }
        return Data(output)
    }

    private static func nibble(_ c: UInt8) throws -> UInt8 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return c - UInt8(ascii: "A") + 10
        default:
            throw AegisError.encoding("invalid hex character")
        }
    }
}
