// swift-tools-version: 6.0
import PackageDescription

// 실제 소비자 파이프라인에서 진단 파일과 보존 루트가 함께 남는지 검증한다.
let package = Package(
    name: "CartographGitLabProbe",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Probe")]
)
