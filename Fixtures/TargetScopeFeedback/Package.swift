// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "TargetScopeFeedback", products: [.library(name: "App", targets: ["App"])], targets: [
    .target(name: "App"),
    .target(name: "Tool"),
    .testTarget(name: "AppTests", dependencies: ["App"]),
])
