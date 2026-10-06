// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterBahnKit",
    defaultLocalization: "de",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BetterBahnKit", targets: ["BetterBahnKit"]),
    ],
    targets: [
        .target(name: "BetterBahnKit", resources: [.copy("Resources/StationHints.json"), .copy("Resources/Drawings")]),
        .testTarget(
            name: "BetterBahnKitTests",
            dependencies: ["BetterBahnKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
