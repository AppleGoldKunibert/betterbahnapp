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
    targets: [
        .target(name: "KitBridge", dependencies: ["BetterBahnKit"], path: "Bridge"),
        .target(
            name: "BetterBahnKit",
            exclude: [
                // Apple frameworks: CryptoKit, Security, DeviceCheck, Compression, PDFKit, Vision.
                "Calendar", "Tickets", "Traewelling",
                "Sharing/JourneyShareLink.swift", "Sharing/ShortShareLinkClient.swift",
                "Support/WorkerAuth.swift",
            ],
            resources: [
                .copy("Resources/StationHints.json"), .copy("Resources/Ril100.json"), .copy("Resources/StationNames.json"),
                .copy("Resources/SeatMaps.json"), .copy("Resources/ExitSides.json"), .copy("Resources/ExitSideOverrides.json"),
                .copy("Resources/Platforms.json"),
            ],
            // SwiftPM's resource lookup reads the app's data folder (PACKAGE_RESOURCE_BUNDLE_PATH, set by the bridge)
            // only in debug builds; release builds need it too, the APK hides the data from every other place it
            // looks. The Kit itself uses DEBUG only for Apple's logging, which Android doesn't have.
            swiftSettings: [.define("DEBUG")]
        ),
    ]
)
