// swift-tools-version: 6.0
import PackageDescription

// Git 이 무시하지만 컴파일러가 색인하는 소스(생성 코드)의 보존 경계를 실제 인덱스로 고정한다.
// 무시 파일은 저장소에 커밋할 수 없으므로 검증기가 Templates/ 에서 복사본 안으로 옮긴 뒤 빌드한다.
let package = Package(
    name: "IgnoredSourceCorpus",
    targets: [.target(name: "IgnoredSources")]
)
