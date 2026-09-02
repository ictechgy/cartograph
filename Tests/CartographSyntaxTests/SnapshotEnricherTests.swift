import CartographCore
import CartographSyntax
import CartographTestSupport
import Testing

@Suite("스냅샷 보강")
struct SnapshotEnricherTests {
    @Test("구문 정보가 접근 수준과 속성을 채운다")
    func fillsAccessibilityAndAttributes() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/App.swift", line: 1)
        let snapshot = builder.build()

        let facts = [
            "/p/App.swift": SourceFileFacts(
                path: "/p/App.swift",
                declarations: [
                    DeclarationFacts(name: "App", line: 1, accessibility: .publicLevel, attributes: [.entryPoint])
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(snapshot, with: facts)
        #expect(enriched.symbols[0].accessibility == .publicLevel)
        #expect(enriched.symbols[0].attributes.contains(.entryPoint))
    }

    @Test("줄 번호가 어긋나면 이름으로 다시 찾는다")
    func fallsBackToNameMatching() {
        // 매크로 확장이나 생성 코드에서는 인덱스와 구문의 줄 번호가 어긋날 수 있다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/App.swift", line: 42)
        let facts = [
            "/p/App.swift": SourceFileFacts(
                path: "/p/App.swift",
                declarations: [
                    DeclarationFacts(name: "App", line: 1, accessibility: .publicLevel, attributes: [])
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        #expect(enriched.symbols[0].accessibility == .publicLevel)
    }

    @Test("파일 단위 무시는 그 파일의 모든 심볼에 적용된다")
    func fileLevelIgnoreAppliesToEverySymbol() {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/Generated.swift", line: 1)
        builder.symbol("B", kind: .structType, path: "/p/Generated.swift", line: 9)
        builder.symbol("C", kind: .structType, path: "/p/Normal.swift", line: 1)

        let facts = [
            "/p/Generated.swift": SourceFileFacts(
                path: "/p/Generated.swift", declarations: [], ignoresEntireFile: true
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        let byUSR = enriched.symbolsByUSR()
        #expect(byUSR["A"]?.attributes.contains(.ignoreComment) == true)
        #expect(byUSR["B"]?.attributes.contains(.ignoreComment) == true)
        #expect(byUSR["C"]?.attributes.contains(.ignoreComment) == false)
    }

    @Test("구문 정보가 없는 파일의 심볼은 그대로 둔다")
    func symbolsWithoutFactsAreUnchanged() {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/Unknown.swift")
        let snapshot = builder.build()
        #expect(SnapshotEnricher.enrich(snapshot, with: [:]) == snapshot)
    }

    @Test("파일을 읽어 실제로 보강한다")
    func enrichesFromFileSystem() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": """
                @main
                public struct App {}
                """
        ])
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/App.swift", line: 2)

        let enriched = SnapshotEnricher(fileSystem: fileSystem).enrich(builder.build())
        #expect(enriched.symbols[0].accessibility == .publicLevel)
        #expect(enriched.symbols[0].attributes.contains(.entryPoint))
    }

    @Test("읽을 수 없는 파일은 조용히 건너뛴다")
    func unreadableFilesAreSkipped() {
        // 인덱스에는 남아 있지만 이미 삭제된 파일 때문에 분석 전체가 실패해서는 안 된다.
        var builder = SnapshotBuilder()
        builder.symbol("Ghost", kind: .structType, path: "/p/Deleted.swift")
        let snapshot = builder.build()
        #expect(SnapshotEnricher(fileSystem: InMemoryFileSystem()).enrich(snapshot) == snapshot)
    }

    @Test("Swift 가 아닌 파일은 분석하지 않는다")
    func nonSwiftFilesAreIgnored() {
        let fileSystem = InMemoryFileSystem(files: ["/p/Legacy.m": "@implementation Legacy @end"])
        var builder = SnapshotBuilder()
        builder.symbol("Legacy", kind: .classType, path: "/p/Legacy.m")
        let snapshot = builder.build()
        #expect(SnapshotEnricher(fileSystem: fileSystem).enrich(snapshot) == snapshot)
    }
}
