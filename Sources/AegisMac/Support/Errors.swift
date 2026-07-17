import Foundation

/// Shared error type for all AegisMac modules.
enum AegisError: Error, LocalizedError, Equatable {
    case encoding(String)
    case crypto(String)
    case otp(String)
    case vault(String)
    case uri(String)
    case importError(String)

    var errorDescription: String? {
        switch self {
        case .encoding(let m), .crypto(let m), .otp(let m),
             .vault(let m), .uri(let m), .importError(let m):
            return m
        }
    }
}

/// JSON object alias used across modules. Vault (de)serialization uses
/// JSONSerialization dictionaries (not Codable) to mirror the dynamic
/// org.json semantics of the Android app.
typealias JSONObject = [String: Any]
