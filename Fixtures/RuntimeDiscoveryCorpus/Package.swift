// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeDiscoveryCorpus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RuntimeDiscoveryApp",
            resources: [.copy("Resources")]
        ),
    ]
)
