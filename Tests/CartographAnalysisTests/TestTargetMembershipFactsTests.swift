import CartographAnalysis
import CartographCore
import Testing

@Suite("SwiftPM 선언 소속의 정확한 신원")
struct TestTargetMembershipFactsTests {
    @Test("동명 XCTest 선언도 일반 라이브러리와 테스트 타깃 소속을 구분한다")
    func separatesOrdinaryAndTestDeclarations() {
        let facts = TestTargetMembershipFacts(snapshot: snapshot(), targets: targets())
        #expect(facts.testUSRs == ["test"])
        #expect(facts.ordinaryUSRs == ["ordinary"])
        #expect(facts.unknownUSRs.isEmpty)
    }

    @Test("기존 또는 근거 없는 입력은 이름 규칙으로 타깃을 만들지 않는다")
    func missingEvidenceRemainsUnknown() {
        let facts = TestTargetMembershipFacts(snapshot: snapshot(), targets: nil)
        #expect(facts.testUSRs.isEmpty && facts.ordinaryUSRs.isEmpty)
        #expect(facts.unknownUSRs == ["test", "ordinary"])
    }

    @Test("충돌하거나 목록 밖인 소속은 미확인으로 남긴다", arguments: [
        "module", "name", "shared", "unlisted", "nested-root", "duplicate-usr",
        "duplicate-test", "duplicate-ordinary"
    ])
    func conflictsRemainUnknown(mode: String) {
        var owners = targets()
        var input = snapshot()
        if mode == "module" {
            owners.append(.init(packageRoot: "/q", name: "Other", module: "Probe",
                                isTest: true, sourcePaths: ["/q/File.swift"]))
        } else if mode == "name" {
            owners.append(.init(packageRoot: "/q", name: "Probe", module: "Other",
                                isTest: true, sourcePaths: ["/q/File.swift"]))
        } else if mode == "shared" {
            owners.append(.init(packageRoot: "/p", name: "Other", module: "Other",
                                isTest: true, sourcePaths: ["/p/Sources/Probe.swift"]))
        } else if mode == "unlisted" {
            input.symbols[0] = .init(usr: "ordinary", name: "testShared()", kind: .method, module: "Probe",
                                     location: .init(path: "/p/Generated.swift", line: 1, column: 1))
        } else if mode == "nested-root" {
            owners.append(.init(packageRoot: "/p/Nested", name: "Other", module: "Other",
                                isTest: true, sourcePaths: ["/p/Nested/File.swift"]))
        } else {
            if mode != "duplicate-usr" {
                owners = owners.map {
                    .init(packageRoot: $0.packageRoot, name: $0.name, module: $0.module,
                          isTest: mode == "duplicate-test", sourcePaths: $0.sourcePaths)
                }
            }
            input.symbols.append(.init(usr: "ordinary", name: "testShared()", kind: .method, module: "ProbeTests",
                location: .init(path: "/p/Tests/Probe.swift", line: 1, column: 1)))
        }
        let facts = TestTargetMembershipFacts(snapshot: input, targets: owners)
        #expect(facts.unknownUSRs.contains("ordinary"))
        #expect(!facts.testUSRs.contains("ordinary") && !facts.ordinaryUSRs.contains("ordinary"))
    }

    @Test("정렬과 기존 보존 표식은 타깃 소속을 바꾸지 않는다")
    func orderAndRetentionAreIndependent() {
        let original = snapshot()
        var reversed = original
        reversed.symbols.reverse()
        reversed.symbols.append(original.symbols[0])
        let before = TestTargetMembershipFacts(snapshot: original, targets: targets())
        #expect(before == TestTargetMembershipFacts(snapshot: reversed, targets: Array(targets().reversed())))
        #expect(original.symbols.allSatisfy { $0.attributes == [.unitTest] && $0.compilerUnitTest == true })
    }

    private func snapshot() -> IndexSnapshot {
        IndexSnapshot(symbols: [
            .init(usr: "ordinary", name: "testShared()", kind: .method, module: "Probe",
                  location: .init(path: "/p/Sources/Probe.swift", line: 1, column: 1),
                  attributes: [.unitTest], compilerUnitTest: true),
            .init(usr: "test", name: "testShared()", kind: .method, module: "ProbeTests",
                  location: .init(path: "/p/Tests/Probe.swift", line: 1, column: 1),
                  attributes: [.unitTest], compilerUnitTest: true),
        ])
    }

    private func targets() -> [SwiftPMDeclaredTarget] {
        [
            .init(packageRoot: "/p", name: "Probe", module: "Probe", isTest: false,
                  sourcePaths: ["/p/Sources/Probe.swift"]),
            .init(packageRoot: "/p", name: "ProbeTests", module: "ProbeTests", isTest: true,
                  sourcePaths: ["/p/Tests/Probe.swift"]),
        ]
    }
}
