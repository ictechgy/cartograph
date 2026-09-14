// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeContractCorpus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RuntimeProbe", targets: ["RuntimeProbe"])],
    targets: [.executableTarget(name: "RuntimeProbe")]
)
