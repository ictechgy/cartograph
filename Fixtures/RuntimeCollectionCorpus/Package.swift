// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeCollectionCorpus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RuntimeCollectionProbe"),
    ]
)
