// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "CoreDataVersionCorpus", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "CoreDataVersionProbe", resources: [.copy("Resources")]),
])
