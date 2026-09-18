import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("불필요한 무시 주석")
struct SuperfluousIgnoreTests {
    /// 스냅샷을 심볼 레벨 그래프로 만들고 분석한다.
    private func analyze(
        _ snapshot: IndexSnapshot,
        retention: RetentionOptions = .default,
        options: ReachabilityAnalyzer.Options = .init()
    ) -> (report: UnusedCodeReport, graph: CodeGraph) {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer(policy: RetentionPolicy(options: retention), options: options)
        return (analyzer.analyze(graph: graph, snapshot: snapshot), graph)
    }

    /// 불필요로 판정된 주석의 앵커 이름.
    private func superfluousNames(_ report: UnusedCodeReport) -> [String] {
        report.superfluousIgnores.map(\.node.name).sorted()
    }

    @Test("도달 불가능한 선언을 덮는 주석은 일을 하므로 보고하지 않는다")
    func neededIgnoreOnDeadDeclaration() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType, attributes: [.ignoreComment])

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("참조되는 선언의 무시 주석은 불필요로 보고한다")
    func reportsSuperfluousIgnoreOnUsedDeclaration() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.reference(from: "App", to: "Used", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Used"])
    }

    @Test("다른 보존 근거로 살아 있는 선언의 무시 주석은 불필요로 보고한다")
    func ignoreOnDeclarationWithOtherRetentionReason() {
        var builder = SnapshotBuilder()
        builder.symbol(
            "App", kind: .structType,
            attributes: [.entryPoint, .ignoreComment]
        )

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["App"])
    }

    @Test("무시된 타입의 죽은 멤버가 있으면 그 주석은 필요하다")
    func ignoreCoveringDeadMemberIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType)
        builder.symbol(
            "Used.helper", name: "helper", kind: .method,
            parent: "Used", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)

        // helper 에 붙은 주석 하나가 없으면 멤버가 미사용으로 보고된다.
        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("무시된 타입과 멤버가 모두 살아 있으면 주석은 불필요다")
    func ignoreOnFullyUsedTypeIsSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Used.helper", name: "helper", kind: .method,
            parent: "Used", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "App", to: "Used.helper", kind: .call)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // 코멘트 하나가 타입과 멤버를 함께 덮으므로 한 건이다.
        #expect(report.superfluousIgnores.count == 1)
        #expect(report.superfluousIgnores[0].node.name == "Used")
        #expect(report.superfluousIgnores[0].coveredCount == 2)
        #expect(report.superfluousIgnores[0].coversWholeFile == false)
    }

    @Test("파일 전체가 무시되고 모두 살아 있으면 파일 범위로 한 건 보고한다")
    func fullyIgnoredLiveFileReportsOneFileScopeFinding() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.symbol(
            "AlsoUsed", kind: .classType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "App", to: "AlsoUsed", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // ignore:all 과 선언별 주석은 그래프에서 구별할 수 없다 — 파일 하나가
        // 전부 무시되면 코멘트 하나라고 보고 한 건만 낸다.
        #expect(report.superfluousIgnores.count == 1)
        #expect(report.superfluousIgnores[0].coversWholeFile)
    }

    @Test("파일 전체가 무시돼도 일부가 죽으면 그 주석은 필요하다")
    func fullyIgnoredFileWithDeadDeclarationIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.symbol(
            "Dead", kind: .structType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)

        let (report, _) = analyze(builder.build())
        // 코멘트 하나가 파일 전체를 덮으므로, 살아 있는 Used 쪽 범위가
        // 불필요해 보여도 코멘트를 떼면 Dead 가 보고된다 — 필요한 주석이다.
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("다른 무시가 살리는 선언을 덮는 주석은 불필요다")
    func ignoreKeptAliveByAnotherIgnoreIsSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // Dead 는 자기 주석이 없으면 죽는다 — 그 주석은 필요하다.
        builder.symbol("Dead", kind: .structType, attributes: [.ignoreComment])
        // Covered 는 Dead 만 참조한다. 자기 주석을 떼어도 Dead 의 주석이
        // 살아 있는 한 Dead 경유로 도달 가능하다 — 이 주석은 불필요다.
        builder.symbol("Covered", kind: .structType, attributes: [.ignoreComment])
        builder.reference(from: "Dead", to: "Covered", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Covered"])
    }

    @Test("무시된 멤버가 타입을 살리고 있으면 그 주석은 필요하다")
    func ignoredMemberRetainingItsTypeIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Shell", kind: .structType)
        builder.symbol(
            "Shell.anchor", name: "anchor", kind: .property,
            parent: "Shell", attributes: [.ignoreComment]
        )

        // anchor 의 무지가 물려받은 보존으로 Shell 까지 살린다. 떼어 내면
        // 둘 다 보고되므로 주석은 필요하다 — 상속 보존을 다시 계산하지 않으면
        // 이 판정이 틀어진다.
        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("죽어도 보고되지 않는 종류의 무시 주석은 불필요다")
    func ignoreOnExcludedKindIsSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // 익스텐션 선언은 보고 대상 종류가 아니다 — 떼어 내도 아무것도
        // 보고되지 않으므로 이 주석은 불필요다.
        builder.symbol(
            "Ext", name: "extension", kind: .extensionDeclaration,
            attributes: [.ignoreComment]
        )

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["extension"])
    }

    @Test("무시 주석이 없으면 아무것도 보고하지 않는다")
    func noIgnoresMeansNoFindings() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType)

        let (report, _) = analyze(builder.build())
        #expect(unusedNames(report) == ["Dead"])
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("불필요 무시는 위치 순으로 정렬된다")
    func superfluousIgnoresAreSortedByLocation() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Late", kind: .structType, line: 20, attributes: [.ignoreComment]
        )
        builder.symbol(
            "Early", kind: .structType, line: 5, attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Late", kind: .reference)
        builder.reference(from: "App", to: "Early", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.superfluousIgnores.map(\.node.name) == ["Early", "Late"])
    }

    private func unusedNames(_ report: UnusedCodeReport) -> [String] {
        report.unused.map(\.name).sorted()
    }
}
