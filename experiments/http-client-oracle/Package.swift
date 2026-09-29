// swift-tools-version: 5.9
import PackageDescription

// cartograph `routes` 의 라이브러리 규칙을 실제 요청과 대조하는 합성 픽스처.
//
// `OracleClient` 는 앱 코드 역할이고 `OracleRunner` 가 로컬 기록 서버(127.0.0.1 임시 포트)를 프록시로 두고
// 각 요청을 실행한다. Alamofire·Moya 를 SwiftPM 으로 받아야 하므로 기본 CI 에서는 빌드하지 않는다.
// 기록은 `record.sh` 가 `recorded.json` 에 남기고, cartograph 테스트는 그 파일과 이 소스만 읽는다.
let package = Package(
    name: "HTTPClientOracle",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.12.2"),
        .package(url: "https://github.com/Moya/Moya.git", exact: "15.0.3"),
    ],
    targets: [
        .target(name: "OracleClient", dependencies: [
            .product(name: "Alamofire", package: "Alamofire"),
            .product(name: "Moya", package: "Moya"),
        ]),
        .executableTarget(name: "OracleRunner", dependencies: ["OracleClient"]),
    ]
)
