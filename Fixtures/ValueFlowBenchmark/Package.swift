// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ValueFlowBenchmark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ValueFlowBenchmark"),
    ]
)
