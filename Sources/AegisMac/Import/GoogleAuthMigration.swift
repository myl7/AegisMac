import Foundation

/// Decoder for Google Authenticator `otpauth-migration://offline?data=…` export
/// URIs. The `data` param is standard base64 wrapping a proto3 `MigrationPayload`.
///
/// A hand-rolled protobuf wire decoder (varint + length-delimited only) is used —
/// no proto runtime dependency. Field numbers, enum mappings and the name/issuer
/// split reproduce `GoogleAuthInfo.parseExportUri` exactly (otp-algorithms spec §7,
/// import-export spec §8).
enum GoogleAuthMigration {

    static func parse(uri: String) throws -> [GoogleAuthInfo] {
        guard let u = AegisUri.parse(uri) else {
            throw AegisError.uri("Bad URI format")
        }
        guard u.scheme == GoogleAuthInfo.schemeExport else {
            throw AegisError.uri("Unsupported protocol")
        }
        guard let host = u.host, host == "offline" else {
            throw AegisError.uri("Unsupported host")
        }
        guard let data = u.queryParameter("data") else {
            throw AegisError.uri("Parameter 'data' is not set")
        }
        let bytes = try decodeBase64(data)
        return try decodePayload([UInt8](bytes))
    }

    // MARK: - Payload decoding

    /// Raw wire values collected for a single `OtpParameters` message.
    private struct RawOtpParameters {
        var secret: [UInt8] = []
        var name: String = ""
        var issuer: String = ""
        var algorithm: UInt64 = 0   // Algorithm enum
        var digits: UInt64 = 0      // DigitCount enum
        var type: UInt64 = 0        // OtpType enum
        var counter: Int64 = 0
    }

    /// Decodes a `MigrationPayload`: field 1 = repeated `OtpParameters`
    /// (length-delimited), fields 2–5 = version/batch metadata (varint, skipped
    /// here). Unknown fields are skipped by wire type.
    private static func decodePayload(_ bytes: [UInt8]) throws -> [GoogleAuthInfo] {
        var reader = ProtoReader(bytes: bytes)
        var otpMessages: [[UInt8]] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                otpMessages.append(try reader.readLengthDelimited())
            default:
                try reader.skip(wireType: wire)
            }
        }

        var infos: [GoogleAuthInfo] = []
        infos.reserveCapacity(otpMessages.count)
        for message in otpMessages {
            infos.append(try decodeOtpParameters(message))
        }
        return infos
    }

    private static func decodeOtpParameters(_ bytes: [UInt8]) throws -> GoogleAuthInfo {
        var reader = ProtoReader(bytes: bytes)
        var raw = RawOtpParameters()
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2): raw.secret = try reader.readLengthDelimited()
            case (2, 2): raw.name = try reader.readString()
            case (3, 2): raw.issuer = try reader.readString()
            case (4, 0): raw.algorithm = try reader.readVarint()
            case (5, 0): raw.digits = try reader.readVarint()
            case (6, 0): raw.type = try reader.readVarint()
            case (7, 0): raw.counter = Int64(bitPattern: try reader.readVarint())
            default: try reader.skip(wireType: wire)
            }
        }

        // DigitCount: UNSPECIFIED(0)/SIX(1) -> 6, EIGHT(2) -> 8.
        let digits: Int
        switch raw.digits {
        case 0, 1: digits = OtpInfo.defaultDigits
        case 2: digits = 8
        default: throw AegisError.uri("Unsupported digits: \(raw.digits)")
        }

        // Algorithm: UNSPECIFIED(0)/SHA1(1) -> SHA1, SHA256(2), SHA512(3). MD5(4) rejected.
        let algo: String
        switch raw.algorithm {
        case 0, 1: algo = "SHA1"
        case 2: algo = "SHA256"
        case 3: algo = "SHA512"
        default: throw AegisError.uri("Unsupported hash algorithm: \(raw.algorithm)")
        }

        if raw.secret.isEmpty {
            throw AegisError.uri("Secret is empty")
        }
        let secret = Data(raw.secret)

        // OtpType: UNSPECIFIED(0)/TOTP(2) -> TotpInfo(period 30), HOTP(1) -> HotpInfo(counter).
        let info: OtpInfo
        switch raw.type {
        case 0, 2:
            info = try TotpInfo(secret: secret, algorithm: algo, digits: digits, period: TotpInfo.defaultPeriod)
        case 1:
            info = try HotpInfo(secret: secret, algorithm: algo, digits: digits, counter: raw.counter)
        default:
            throw AegisError.uri("Unsupported OTP type: \(raw.type)")
        }

        // name/issuer split: only when issuer is empty and name has a ':', at the FIRST ':'.
        var name = raw.name
        var issuer = raw.issuer
        if issuer.isEmpty, let colon = name.firstIndex(of: ":") {
            issuer = String(name[name.startIndex..<colon])
            name = String(name[name.index(after: colon)...])
        }

        return GoogleAuthInfo(info: info, accountName: name, issuer: issuer)
    }

    // MARK: - Base64 (standard, padding-tolerant)

    /// Standard RFC 4648 base64 decode, tolerant of missing padding (Google
    /// exports are padded, but we normalize defensively).
    static func decodeBase64(_ s: String) throws -> Data {
        var core = s
        core.removeAll { $0 == "=" }
        switch core.count % 4 {
        case 0: break
        case 2: core += "=="
        case 3: core += "="
        default: throw AegisError.uri("Invalid base64 data")
        }
        guard let data = Data(base64Encoded: core) else {
            throw AegisError.uri("Invalid base64 data")
        }
        return data
    }
}

// MARK: - Protobuf wire reader

/// Minimal proto3 wire-format reader supporting varint (wire type 0) and
/// length-delimited (wire type 2) fields, and skipping of 64-bit (1) / 32-bit (5)
/// fields. All this decoder needs for `MigrationPayload`.
private struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else {
                throw AegisError.uri("Malformed protobuf: truncated varint")
            }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
            if shift >= 64 {
                throw AegisError.uri("Malformed protobuf: varint too long")
            }
        }
        return result
    }

    mutating func readTag() throws -> (field: Int, wireType: Int) {
        let tag = try readVarint()
        return (Int(tag >> 3), Int(tag & 0x07))
    }

    mutating func readLengthDelimited() throws -> [UInt8] {
        let length = Int(try readVarint())
        guard length >= 0, index + length <= bytes.count else {
            throw AegisError.uri("Malformed protobuf: bad length")
        }
        let slice = Array(bytes[index..<(index + length)])
        index += length
        return slice
    }

    mutating func readString() throws -> String {
        return String(decoding: try readLengthDelimited(), as: UTF8.self)
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard index + 8 <= bytes.count else {
                throw AegisError.uri("Malformed protobuf: truncated 64-bit field")
            }
            index += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard index + 4 <= bytes.count else {
                throw AegisError.uri("Malformed protobuf: truncated 32-bit field")
            }
            index += 4
        default:
            throw AegisError.uri("Malformed protobuf: unknown wire type \(wireType)")
        }
    }
}
