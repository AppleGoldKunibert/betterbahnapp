// swift-tools-version: 6.2
import PackageDescription

// BetterBahnKit for Android, built with the Swift SDK for Android by build.sh (which links the Kit's source
// folders into Sources/BetterBahnKit first). The sources are the iOS app's, minus what needs Apple frameworks.
let package = Package(
    name: "BetterBahnKitAndroid",
    defaultLocalization: "de",
    products: [
        // libBetterBahnKit.so: the Kit with the JNI bridge, the Swift runtime linked in.
        .library(name: "BetterBahnKit", type: .dynamic, targets: ["KitBridge"]),
    ],
    dependencies: [
        // SHA-256 for Träwelling's PKCE and Wallet passes, where Apple platforms use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "KitBridge", dependencies: ["BetterBahnKit"], path: "Bridge"),
        // zlib from the NDK, for raw DEFLATE (Support/RawDeflate.swift) where Apple platforms use Compression.
        .systemLibrary(name: "CZlib", path: "CZlib"),
        // What the Swift runtime needs from libc++ but the NDK's libc++ lacks (std::__hash_memory).
        .target(name: "CxxShims", path: "CxxShims"),
        .target(
            name: "BetterBahnKit",
            dependencies: ["CZlib", "CxxShims", .product(name: "Crypto", package: "swift-crypto")],
            // App Attest (DeviceCheck) only exists on Apple devices; Shims/ has the Play Integrity stand-in.
            exclude: ["Support/WorkerAuth.swift"],
            resources: [
                .copy("Resources/StationHints.json"), .copy("Resources/Ril100.json"), .copy("Resources/StationNames.json"),
                .copy("Resources/SeatMaps.json"), .copy("Resources/ExitSides.json"), .copy("Resources/ExitSideOverrides.json"),
                .copy("Resources/Platforms.json"),
            ],
            // SwiftPM's resource lookup reads the app's data folder (PACKAGE_RESOURCE_BUNDLE_PATH, set by the bridge)
            // only in debug builds; release builds need it too, the APK hides the data from every other place it
            // looks. The Kit itself uses DEBUG only for Apple's logging, which Android doesn't have.
            swiftSettings: [.define("DEBUG")],
            // URLSession (FoundationNetworking) uses the SDK's static libcurl, which needs OpenSSL; its autolink
            // only names curl, and Android refuses to load a library with unresolved symbols (X509_free …).
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto")]
        ),
    ]
)
