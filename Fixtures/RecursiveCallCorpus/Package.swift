// swift-tools-version: 6.0
import PackageDescription

// 실제 컴파일러의 재귀 호출 인덱스를 외부 의존성 없이 재현한다.
let package = Package(
    name: "RecursiveCallCorpus",
    targets: [.executableTarget(name: "RecursiveCalls")]
)
