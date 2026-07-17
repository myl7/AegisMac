// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AegisMac",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Pure-Swift scrypt implementation for the Aegis vault KDF.
        // AES-GCM / HMAC use Apple CryptoKit.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0")
    ],
    targets: [
        .executableTarget(
            name: "AegisMac",
            dependencies: [
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ],
            path: "Sources/AegisMac"
        ),
        .testTarget(
            name: "AegisMacTests",
            dependencies: ["AegisMac"],
            path: "Tests/AegisMacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
