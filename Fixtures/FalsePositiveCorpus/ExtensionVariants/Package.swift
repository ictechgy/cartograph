// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "ExtensionVariants", platforms: [.macOS(.v14)], targets: [
    .target(name: "Domain"),
    .target(name: "Data"),
    .target(name: "Presentation", dependencies: ["Domain", "Data"]),
    .target(name: "CycleControl"),
    .executableTarget(name: "App", dependencies: ["Presentation", "CycleControl"]),
])
