// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChangeImpactCorpus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ImpactApp", targets: ["ImpactApp"])],
    targets: [
        .target(name: "ImpactData", resources: [.copy("Resources")]),
        .target(name: "ImpactFeatures", dependencies: ["ImpactData"]),
        .executableTarget(name: "ImpactApp", dependencies: ["ImpactFeatures", "ImpactData"]),
        .testTarget(name: "ImpactChecks", dependencies: ["ImpactFeatures", "ImpactData"]),
    ]
)
