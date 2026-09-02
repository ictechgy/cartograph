// swift-tools-version: 6.0
import PackageDescription

/// Cartograph 는 계층별로 엄격히 분리된 모듈들로 구성된다.
///
/// 의존 방향은 항상 아래에서 위로만 흐른다.
///   CartographCore  ← Config / Analysis / Export / IndexStore  ← Kit ← CLI
/// 순수 도메인(Core)과 알고리즘(Analysis)은 IndexStoreDB 를 알지 못하므로
/// 인덱스 스토어 없이도 단위 테스트가 가능하다.
let package = Package(
    name: "Cartograph",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cartograph", targets: ["cartograph"]),
        .plugin(name: "CartographCommandPlugin", targets: ["CartographCommandPlugin"]),
        // 임베더가 반환 타입을 이름으로 부를 수 있어야 한다. Kit 타깃만 내보내면
        // CodeGraph, Diagnostic 같은 타입을 import 할 방법이 없어 API 가 사실상 잠긴다.
        .library(
            name: "CartographKit",
            targets: [
                "CartographKit",
                "CartographCore",
                "CartographConfig",
                "CartographSyntax",
                "CartographAnalysis",
                "CartographExport",
                "CartographIndexStore",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // indexstore-db 는 semver 태그를 제공하지 않고 Swift 릴리스에 맞춰 브랜치를 관리한다.
        // 로컬 툴체인(Swift 6.4)과 인덱스 스토어 포맷을 맞추기 위해 릴리스 브랜치를 고정한다.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "release/6.4.1"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0" ..< "605.0.0"),
    ],
    targets: [
        // MARK: - 도메인 계층 (외부 의존성 없음)
        .target(name: "CartographCore"),

        // MARK: - 기능 계층
        .target(
            name: "CartographConfig",
            dependencies: ["CartographCore", .product(name: "Yams", package: "Yams")]
        ),
        .target(
            name: "CartographSyntax",
            dependencies: [
                "CartographCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .target(name: "CartographAnalysis", dependencies: ["CartographCore"]),
        .target(name: "CartographExport", dependencies: ["CartographCore", "CartographAnalysis"]),
        .target(
            name: "CartographIndexStore",
            dependencies: [
                "CartographCore",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ]
        ),

        // MARK: - 조립 계층
        .target(
            name: "CartographKit",
            dependencies: [
                "CartographCore",
                "CartographConfig",
                "CartographSyntax",
                "CartographAnalysis",
                "CartographExport",
                "CartographIndexStore",
            ]
        ),
        // 실행 타깃 이름을 제품 이름과 맞춘다. 커맨드 플러그인은 실행 파일을
        // 제품 이름으로 찾는데, 같은 패키지의 제품은 의존성으로 선언할 수 없다.
        // 이름이 어긋나 있으면 플러그인이 도구를 찾지 못한다.
        .executableTarget(
            name: "cartograph",
            dependencies: [
                "CartographKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: - SwiftPM 커맨드 플러그인
        // 패키지에 의존성으로 추가하면 설치 없이 `swift package plugin cartograph` 로 쓸 수 있다.
        .plugin(
            name: "CartographCommandPlugin",
            capability: .command(
                intent: .custom(
                    verb: "cartograph",
                    description: "Analyze this package's dependency graph."
                )
            ),
            dependencies: ["cartograph"]
        ),

        // MARK: - 테스트 지원 (커버리지 집계에서 제외)
        .target(name: "CartographTestSupport", dependencies: ["CartographCore"]),

        // MARK: - 테스트
        .testTarget(
            name: "CartographCoreTests",
            dependencies: ["CartographCore", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographConfigTests",
            dependencies: ["CartographConfig", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographSyntaxTests",
            dependencies: ["CartographSyntax", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographAnalysisTests",
            dependencies: ["CartographAnalysis", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographExportTests",
            dependencies: ["CartographExport", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographIndexStoreTests",
            dependencies: ["CartographIndexStore", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographKitTests",
            dependencies: ["CartographKit", "CartographTestSupport"]
        ),
        .testTarget(
            name: "CartographCLITests",
            dependencies: ["cartograph", "CartographTestSupport"]
        ),
    ]
)
