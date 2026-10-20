import Foundation
import Testing

/// 저장소 루트의 `Package.swift` 가 소비자 빌드를 이 저장소가 검증한 의존성 커밋에 묶어 두는지 고정한다.
///
/// SwiftPM 은 의존 패키지의 `Package.resolved` 를 소비자의 해석에 쓰지 않는다. 그래서 매니페스트가
/// 브랜치를 요구하면 같은 Cartograph 태그를 쓰는 소비자도 해석 시점의 브랜치 머리를 받아, 이 저장소
/// CI 가 빌드한 적 없는 조합으로 인덱스를 읽게 된다. semver 태그가 없는 indexstore-db 는 커밋으로
/// 고정하고, 그 커밋이 커밋된 `Package.resolved` 의 기록과 같은지 여기서 확인한다.
@Suite("패키지 매니페스트")
struct PackageManifestTests {
    private static let indexStoreDBLocation = "https://github.com/swiftlang/indexstore-db.git"

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("semver 태그가 없는 indexstore-db 는 Package.resolved 가 기록한 커밋 그대로 고정한다")
    func indexStoreDBIsPinnedToTheResolvedCommit() throws {
        let declared = try Self.dependencies(in: text(of: "Package.swift"))
            .first { $0.location == Self.indexStoreDBLocation }
        let pin = try Self.pins(in: text(of: "Package.resolved"))
            .first { $0.location == Self.indexStoreDBLocation }
        #expect(declared?.commit != nil, "indexstore-db 요구 조건: \(declared?.requirement ?? "선언 없음")")
        #expect(pin != nil, "Package.resolved 에 indexstore-db 핀이 없다")
        #expect(declared?.commit == pin?.state.revision)
        // 매니페스트만 고치고 해석을 다시 하지 않으면 잠금 파일에 예전 브랜치 요구가 남는다.
        #expect(pin?.state.branch == nil, "Package.resolved 가 브랜치 \(pin?.state.branch ?? "") 를 기록한다")
    }

    @Test("어떤 원격 의존성도 움직이는 브랜치를 따라가지 않는다")
    func noDependencyFollowsABranch() throws {
        let manifest = try text(of: "Package.swift")
        let dependencies = Self.dependencies(in: manifest)
        // 해석기가 선언 하나를 놓치면 검사가 헛돈다. `.package(` 수와 읽은 선언 수가 같아야 한다.
        #expect(!dependencies.isEmpty)
        #expect(dependencies.count == manifest.components(separatedBy: ".package(").count - 1)
        let floating = dependencies.filter { !$0.isVersionRange && $0.commit == nil }
        #expect(floating.isEmpty, "\(floating.map { "\($0.location) — \($0.requirement)" })")
    }

    private func text(of file: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
    }

    /// 매니페스트의 `.package(url:…, <요구 조건>)` 선언 하나.
    private struct Dependency {
        let location: String
        /// `url:` 뒤의 인자 그대로(`from: "1.5.0"`, `revision: "…"` 등).
        let requirement: String

        /// `from:`·`exact:`·`"a" ..< "b"` 같은 semver 요구. 소비자 해석이 semver 규칙을 따른다.
        var isVersionRange: Bool {
            requirement.wholeMatch(of: #/(?:from|exact): "[^"]+"|"[^"]+" *\.\.[.<] *"[^"]+"/#) != nil
        }

        /// 40자리 커밋 해시로 고정했으면 그 해시. 브랜치·태그 이름은 움직일 수 있어 커밋으로 치지 않는다.
        var commit: String? {
            requirement.wholeMatch(of: #/revision: "(?<hash>[0-9a-f]{40})"/#).map { String($0.hash) }
        }
    }

    /// 요구 조건 문자열에는 `)` 가 없으므로 선언의 닫는 괄호까지를 한 선언으로 읽는다(여러 줄 포함).
    private static func dependencies(in manifest: String) -> [Dependency] {
        manifest.matches(of: #/\.package\(\s*url:\s*"(?<location>[^"]+)"\s*,\s*(?<requirement>[^)]*?)\s*,?\s*\)/#)
            .map { Dependency(location: String($0.location), requirement: String($0.requirement)) }
    }

    /// `Package.resolved`(형식 2·3)의 핀. 브랜치로 해석된 핀만 `state.branch` 를 가진다.
    private struct ResolvedFile: Decodable {
        struct Pin: Decodable {
            struct State: Decodable {
                let revision: String
                let branch: String?
            }

            let location: String
            let state: State
        }

        let pins: [Pin]
    }

    private static func pins(in resolved: String) throws -> [ResolvedFile.Pin] {
        try JSONDecoder().decode(ResolvedFile.self, from: Data(resolved.utf8)).pins
    }
}
