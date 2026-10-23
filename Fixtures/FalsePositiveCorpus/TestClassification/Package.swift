// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "TestClassificationFeedback", platforms: [.macOS(.v13)], targets: [
    .target(name: "App"),
    .testTarget(name: "AppTests", dependencies: ["App"]),
])
