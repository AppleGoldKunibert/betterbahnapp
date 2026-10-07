// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SearchSim",
    targets: [
        .target(name: "Kit", resources: [.copy("Resources/StationHints.json"), .copy("Resources/Ril100.json")]),
        .executableTarget(name: "SearchSim", dependencies: ["Kit"]),
        .testTarget(name: "KitTests", dependencies: ["Kit"], resources: [.copy("Fixtures")]),
    ]
)
