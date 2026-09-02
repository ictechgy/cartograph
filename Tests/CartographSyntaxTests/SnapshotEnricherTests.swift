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

    @Test("줄 번호가 크게 어긋나도 이름이 맞으면 찾는다")
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

    @Test("인자 라벨이 붙은 인덱스 이름도 구문 선언과 맞춘다")
    func matchesIndexNamesCarryingArgumentLabels() {
        // 인덱스는 `emit(_:options:)` 로, 구문 분석은 `emit` 으로 부른다.
        // 이 정규화가 없으면 함수·메서드·이니셜라이저·연관값 케이스는
        // 이름으로 절대 매칭되지 않는다.
        var builder = SnapshotBuilder()
        builder.symbol("emit(_:options:)", kind: .method, path: "/p/A.swift", line: 9)
        builder.symbol("init(value:)", kind: .initializer, path: "/p/A.swift", line: 20)
        builder.symbol("found(_:)", kind: .enumCase, path: "/p/A.swift", line: 30)
        let facts = [
            "/p/A.swift": SourceFileFacts(
                path: "/p/A.swift",
                declarations: [
                    DeclarationFacts(name: "emit", line: 9, accessibility: .publicLevel, attributes: []),
                    DeclarationFacts(name: "init", line: 20, accessibility: .privateLevel, attributes: []),
                    DeclarationFacts(name: "found", line: 30, accessibility: .publicLevel, attributes: []),
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        let byName = Dictionary(uniqueKeysWithValues: enriched.symbols.map { ($0.name, $0) })
        #expect(byName["emit(_:options:)"]?.accessibility == .publicLevel)
        #expect(byName["init(value:)"]?.accessibility == .privateLevel)
        #expect(byName["found(_:)"]?.accessibility == .publicLevel)
    }

    @Test("속성이 윗줄에 있어 줄이 어긋나도 이름으로 찾는다")
    func matchesWhenAttributeShiftsTheDeclarationLine() {
        // `@discardableResult` 가 윗줄이면 구문 쪽 줄은 속성 줄, 인덱스 쪽 줄은
        // 이름 줄이라 한 줄 어긋난다. 실제 저장소에서 private 선언이 internal 로
        // 보고되던 원인이다.
        var builder = SnapshotBuilder()
        builder.symbol("record(name:)", kind: .method, path: "/p/A.swift", line: 221)
        let facts = [
            "/p/A.swift": SourceFileFacts(
                path: "/p/A.swift",
                declarations: [
                    DeclarationFacts(name: "record", line: 220, accessibility: .privateLevel, attributes: [])
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        #expect(enriched.symbols[0].accessibility == .privateLevel)
    }

    @Test("한 줄에 선언이 여럿이면 이름이 맞는 쪽을 고른다")
    func doesNotAttachAnotherDeclarationOnTheSameLine() {
        // 같은 줄의 첫 선언을 그냥 쓰면 메서드가 타입의 정보를 물려받아
        // `@objc` 를 잃는다. 실제로 쓰이는 심볼이 미사용으로 보고되는 경로다.
        var builder = SnapshotBuilder()
        builder.symbol("restorePurchases()", kind: .method, path: "/p/A.swift", line: 1)
        let facts = [
            "/p/A.swift": SourceFileFacts(
                path: "/p/A.swift",
                declarations: [
                    DeclarationFacts(name: "SettingsVC", line: 1, accessibility: .publicLevel, attributes: []),
                    DeclarationFacts(
                        name: "restorePurchases", line: 1, accessibility: .internalLevel, attributes: [.objc]
                    ),
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        #expect(enriched.symbols[0].attributes.contains(.objc))
        #expect(enriched.symbols[0].accessibility == .internalLevel)
    }

    @Test("이름이 같은 선언이 여럿이면 줄이 가장 가까운 것을 쓴다")
    func choosesTheNearestDeclarationAmongSameNames() {
        var builder = SnapshotBuilder()
        builder.symbol("run()", kind: .method, path: "/p/A.swift", line: 51)
        let facts = [
            "/p/A.swift": SourceFileFacts(
                path: "/p/A.swift",
                declarations: [
                    DeclarationFacts(name: "run", line: 10, accessibility: .publicLevel, attributes: []),
                    DeclarationFacts(name: "run", line: 50, accessibility: .privateLevel, attributes: []),
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        #expect(enriched.symbols[0].accessibility == .privateLevel)
    }

    @Test("이름이 하나도 맞지 않으면 아무 정보도 붙이지 않는다")
    func attachesNothingWhenNoNameMatches() {
        var builder = SnapshotBuilder()
        builder.symbol("Unknown", kind: .structType, path: "/p/A.swift", line: 1)
        let facts = [
            "/p/A.swift": SourceFileFacts(
                path: "/p/A.swift",
                declarations: [
                    DeclarationFacts(name: "Other", line: 1, accessibility: .publicLevel, attributes: [.entryPoint])
                ]
            )
        ]
        let enriched = SnapshotEnricher.enrich(builder.build(), with: facts)
        #expect(enriched.symbols[0].accessibility == .internalLevel)
        #expect(enriched.symbols[0].attributes.isEmpty)
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
