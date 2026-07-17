import Foundation

/// A parsed `otpauth://` (or `motp://`) URI: an `OtpInfo` plus the human-readable
/// account name and issuer. Mirrors Android's `GoogleAuthInfo`.
///
/// The parse/serialize logic reproduces `GoogleAuthInfo.parseUri` / `getUri`
/// byte-for-byte (otp-algorithms spec §5/§6), including Android's URI quirks:
/// host is lowercased, query params are percent-decoded with `+` → space, the
/// label is split on `:` with Java `String.split` semantics, and the recognized
/// override params are `algorithm`/`digits` (never `algo`).
struct GoogleAuthInfo {
    var info: OtpInfo
    var accountName: String
    var issuer: String

    static let scheme = "otpauth"
    static let schemeExport = "otpauth-migration"
    static let motpScheme = "motp"

    init(info: OtpInfo, accountName: String, issuer: String) {
        self.info = info
        self.accountName = accountName
        self.issuer = issuer
    }

    // MARK: - Parsing

    static func parseUri(_ s: String) throws -> GoogleAuthInfo {
        guard let uri = AegisUri.parse(s) else {
            throw AegisError.uri("Bad URI format: \(s)")
        }
        return try parseUri(uri)
    }

    static func parseUri(_ uri: AegisUri) throws -> GoogleAuthInfo {
        guard let scheme = uri.scheme,
              scheme == GoogleAuthInfo.scheme || scheme == GoogleAuthInfo.motpScheme else {
            throw AegisError.uri("Unsupported protocol: \(uri.scheme ?? "")")
        }

        // 'secret' is a required parameter.
        guard let encodedSecret = uri.queryParameter("secret") else {
            throw AegisError.uri("Parameter 'secret' is not present")
        }

        let secret: Data
        if scheme == GoogleAuthInfo.motpScheme {
            secret = try HexCodec.decode(encodedSecret)
        } else {
            secret = try parseSecret(encodedSecret)
        }
        if secret.isEmpty {
            throw AegisError.uri("Secret is empty")
        }

        var info: OtpInfo
        var issuer = ""

        // The type is the URI host for otpauth, or forced to "motp" for the motp scheme.
        let type: String
        if scheme == GoogleAuthInfo.motpScheme {
            type = "motp"
        } else {
            guard let host = uri.host, !host.isEmpty else {
                throw AegisError.uri("Host not present in URI")
            }
            type = host
        }

        switch type {
        case "totp":
            let totp = try TotpInfo(secret: secret)
            if let period = uri.queryParameter("period") {
                try totp.applyPeriod(period)
            }
            info = totp
        case "steam":
            let steam = try SteamInfo(secret: secret)
            if let period = uri.queryParameter("period") {
                try steam.applyPeriod(period)
            }
            info = steam
        case "hotp":
            let hotp = try HotpInfo(secret: secret)
            guard let counter = uri.queryParameter("counter") else {
                throw AegisError.uri("Parameter 'counter' is not present")
            }
            guard let counterValue = Int64(counter) else {
                throw AegisError.uri("Invalid counter: \(counter)")
            }
            try hotp.setCounter(counterValue)
            info = hotp
        case "yaotp":
            var pin: String? = nil
            if let pinParam = uri.queryParameter("pin") {
                pin = String(decoding: try parseSecret(pinParam), as: UTF8.self)
            }
            let yandex = try YandexInfo(secret: secret, pin: pin)
            info = yandex
            issuer = yandex.typeName  // "Yandex"
        case "motp":
            info = try MotpInfo(secret: secret)
        default:
            throw AegisError.uri("Unsupported OTP type: \(type)")
        }

        // Label / issuer / accountName resolution (precedence matters).
        let path = uri.path
        let label: String
        if let path = path, !path.isEmpty {
            label = String(path.dropFirst())  // strip the leading '/'
        } else {
            label = ""
        }

        var accountName = ""
        if label.contains(":") {
            // A label can only contain one colon; anything else falls back to the whole label.
            let strings = javaSplitColon(label)
            if strings.count == 2 {
                issuer = strings[0]
                accountName = strings[1]
            } else {
                accountName = label
            }
        } else {
            let issuerParam = uri.queryParameter("issuer")
            if issuer.isEmpty {
                issuer = issuerParam ?? ""
            }
            accountName = label
        }

        // Apply the algorithm/digits overrides last (applies to all types).
        if let algorithm = uri.queryParameter("algorithm") {
            try info.setAlgorithm(algorithm)
        }
        if let digits = uri.queryParameter("digits") {
            guard let digitsValue = Int(digits) else {
                throw AegisError.uri("Invalid digits: \(digits)")
            }
            try info.setDigits(digitsValue)
        }

        return GoogleAuthInfo(info: info, accountName: accountName, issuer: issuer)
    }

    /// Decodes a base32 secret, tolerating whitespace and dashes.
    /// (`GoogleAuthInfo.parseSecret`: trim, strip `-` and space, then base32-decode.)
    static func parseSecret(_ s: String) throws -> Data {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return try Base32.decode(cleaned)
    }

    // MARK: - Serialization

    /// Builds the `otpauth://` / `motp://` URI. Query-parameter order matches
    /// Android's `getUri`: `[period|counter, digits, algorithm, secret, (pin), issuer]`
    /// for otpauth and `[secret, issuer]` for motp.
    func getUri() -> String {
        var params: [(String, String)] = []
        var uriScheme: String
        var authority: String?

        if info is MotpInfo {
            uriScheme = GoogleAuthInfo.motpScheme
            authority = nil
            params.append(("secret", HexCodec.encode(info.secret)))
        } else {
            uriScheme = GoogleAuthInfo.scheme
            if let steam = info as? SteamInfo {
                authority = "steam"
                params.append(("period", String(steam.period)))
            } else if let yandex = info as? YandexInfo {
                authority = "yaotp"
                params.append(("period", String(yandex.period)))
            } else if let totp = info as? TotpInfo {
                authority = "totp"
                params.append(("period", String(totp.period)))
            } else if let hotp = info as? HotpInfo {
                authority = "hotp"
                params.append(("counter", String(hotp.counter)))
            } else {
                // Unreachable for the five supported OtpInfo subclasses.
                authority = "totp"
            }
            params.append(("digits", String(info.digits)))
            params.append(("algorithm", info.getAlgorithm(false)))
            params.append(("secret", Base32.encode(info.secret)))
            if let yandex = info as? YandexInfo {
                params.append(("pin", Base32.encode(Data((yandex.pin ?? "").utf8))))
            }
        }

        let pathValue: String
        if !issuer.isEmpty {
            pathValue = "\(issuer):\(accountName)"
            params.append(("issuer", issuer))
        } else {
            pathValue = accountName
        }

        return AegisUri.build(scheme: uriScheme,
                              authority: authority,
                              path: pathValue,
                              queryItems: params)
    }

    // MARK: - Conversion

    /// Wraps this parsed URI into a `VaultEntry` (mirrors Java's
    /// `VaultEntry(GoogleAuthInfo)` = `VaultEntry(otpInfo, accountName, issuer)`).
    func toVaultEntry() -> VaultEntry {
        return VaultEntry(name: accountName, issuer: issuer, info: info)
    }
}

// MARK: - Java String.split(":") helper

/// Reproduces Java `label.split(":")` with the default limit (trailing empty
/// strings removed, leading/middle empties kept). Used for the URI label rules.
func javaSplitColon(_ s: String) -> [String] {
    var parts = s.components(separatedBy: ":")
    while let last = parts.last, last.isEmpty {
        parts.removeLast()
    }
    return parts
}

// MARK: - TotpInfo period-override helpers

private extension TotpInfo {
    func applyPeriod(_ s: String) throws {
        guard let value = Int(s) else {
            throw AegisError.uri("Invalid period: \(s)")
        }
        try setPeriod(value)
    }
}

// MARK: - Minimal URI parser/builder (Android Uri semantics)

/// A tiny URI parser reproducing the parts of Android's `android.net.Uri` that
/// Aegis relies on:
/// - `host` is the authority, **lowercased** (Android `getHost`).
/// - `path` is percent-decoded (**no** `+` → space), or `nil` for opaque URIs
///   (no `//` authority), matching Android `getPath`.
/// - `queryParameter` percent-decodes and converts `+` → space (Android
///   `getQueryParameter` uses `convertPlus = true`).
struct AegisUri {
    let scheme: String?
    let host: String?
    let path: String?
    private let rawQueryPairs: [(String, String)]  // still percent-encoded

    private init(scheme: String?, host: String?, path: String?, rawQueryPairs: [(String, String)]) {
        self.scheme = scheme
        self.host = host
        self.path = path
        self.rawQueryPairs = rawQueryPairs
    }

    func queryParameter(_ key: String) -> String? {
        for (rawKey, rawValue) in rawQueryPairs {
            if AegisUri.percentDecode(rawKey, plusToSpace: true) == key {
                return AegisUri.percentDecode(rawValue, plusToSpace: true)
            }
        }
        return nil
    }

    static func parse(_ s: String) -> AegisUri? {
        // scheme = everything up to the first ':'.
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = String(s[s.startIndex..<colon])
        if scheme.isEmpty { return nil }
        var rest = String(s[s.index(after: colon)...])

        var host: String? = nil
        var pathPart: String? = nil
        var queryAndFragment: String

        if rest.hasPrefix("//") {
            // Hierarchical: //authority[/path][?query][#fragment]
            rest = String(rest.dropFirst(2))
            // authority ends at the first '/', '?' or '#'.
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            let authority: String
            if let end = authorityEnd {
                authority = String(rest[rest.startIndex..<end])
                rest = String(rest[end...])
            } else {
                authority = rest
                rest = ""
            }
            host = authority.lowercased()

            // Path is everything up to '?' or '#'.
            let pathEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" })
            if let end = pathEnd {
                pathPart = percentDecode(String(rest[rest.startIndex..<end]), plusToSpace: false)
                queryAndFragment = String(rest[end...])
            } else {
                pathPart = percentDecode(rest, plusToSpace: false)
                queryAndFragment = ""
            }
        } else {
            // Opaque: no authority, no path (Android getPath() == null).
            queryAndFragment = rest
        }

        // Extract the query (between '?' and '#').
        var query = ""
        if let qMark = queryAndFragment.firstIndex(of: "?") {
            let afterQ = String(queryAndFragment[queryAndFragment.index(after: qMark)...])
            if let hash = afterQ.firstIndex(of: "#") {
                query = String(afterQ[afterQ.startIndex..<hash])
            } else {
                query = afterQ
            }
        }

        var pairs: [(String, String)] = []
        if !query.isEmpty {
            for component in query.split(separator: "&", omittingEmptySubsequences: true) {
                let item = String(component)
                if let eq = item.firstIndex(of: "=") {
                    let key = String(item[item.startIndex..<eq])
                    let value = String(item[item.index(after: eq)...])
                    pairs.append((key, value))
                } else {
                    pairs.append((item, ""))
                }
            }
        }

        return AegisUri(scheme: scheme, host: host, path: pathPart, rawQueryPairs: pairs)
    }

    // MARK: Building

    /// Character set left unencoded in query values (RFC 3986 unreserved). Every
    /// other byte — including `+`, space, `/`, `=`, `&` — is percent-encoded so the
    /// output re-parses unambiguously and survives Android's `getQueryParameter`.
    private static let unreservedQuery = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// Query-value set plus `:` and `@`, which are allowed inside a URI path and
    /// must stay literal so the label split on `:` round-trips.
    private static let unreservedPath = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:@")

    static func build(scheme: String, authority: String?, path: String, queryItems: [(String, String)]) -> String {
        var result = scheme + ":"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: unreservedPath) ?? path
        if let authority = authority {
            result += "//" + authority + "/" + encodedPath
        } else {
            // Opaque form (matches Android's motp URI: `motp:path?...`).
            result += encodedPath
        }
        if !queryItems.isEmpty {
            let query = queryItems.map { key, value in
                let ek = key.addingPercentEncoding(withAllowedCharacters: unreservedQuery) ?? key
                let ev = value.addingPercentEncoding(withAllowedCharacters: unreservedQuery) ?? value
                return "\(ek)=\(ev)"
            }.joined(separator: "&")
            result += "?" + query
        }
        return result
    }

    // MARK: Percent decoding

    /// Decodes `%XX` escapes over the UTF-8 byte stream. When `plusToSpace` is
    /// true, literal `+` becomes a space (Android query-param semantics); `%2B`
    /// always decodes to a literal `+`.
    static func percentDecode(_ s: String, plusToSpace: Bool) -> String {
        let chars = Array(s.utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "%"), i + 2 < chars.count,
               let hi = hexNibble(chars[i + 1]), let lo = hexNibble(chars[i + 2]) {
                bytes.append((hi << 4) | lo)
                i += 3
                continue
            }
            if plusToSpace && c == UInt8(ascii: "+") {
                bytes.append(0x20)
                i += 1
                continue
            }
            bytes.append(c)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
