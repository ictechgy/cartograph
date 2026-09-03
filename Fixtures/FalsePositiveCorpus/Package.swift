// swift-tools-version: 6.0
import PackageDescription

/// 실제 코드에서 오탐을 냈던 패턴만 모아 둔 픽스처.
///
/// 단위 테스트는 손으로 만든 스냅샷 위에서 돌기 때문에, 컴파일러가 실제로 무엇을
/// 인덱스에 남기는지는 검증하지 못한다. 이 저장소에서 찾아낸 오탐은 전부 그
/// 지점에 있었다. 그래서 진짜로 컴파일되는 코드가 필요하다.
///
/// SwiftUI 를 쓴다. 컴파일러가 `$name` 을 별도 심볼로 내보내는 것은 `@State` 같은
/// 경우뿐이고, 직접 만든 프로퍼티 래퍼로는 그 구조가 재현되지 않는다. 실측해 보니
/// 빌드 비용은 7초라 충실도를 택했다.
let package = Package(
    name: "FalsePositiveCorpus",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Corpus"),
        .executableTarget(name: "CorpusApp", dependencies: ["Corpus"]),
        .testTarget(name: "CorpusTests", dependencies: ["Corpus"]),
    ]
)
