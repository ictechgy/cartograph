@testable import CartographAnalysis
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
    ) -> UnusedCodeReport {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer(policy: RetentionPolicy(options: retention), options: options)
        return analyzer.analyze(graph: graph, snapshot: snapshot)
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

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("참조되는 선언의 무시 주석은 불필요로 보고한다")
    func reportsSuperfluousIgnoreOnUsedDeclaration() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.reference(from: "App", to: "Used", kind: .reference)

        let report = analyze(builder.build())
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

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["App"])
    }

    @Test("멤버에 자기 주석이 있으면 타입의 주석만 불필요다")
    func parentIgnoreIsSuperfluousWhenMemberHasOwnComment() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Used.helper", name: "helper", kind: .method,
            parent: "Used", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)

        // 코멘트는 선언마다 따로 판정한다. 타입의 주석을 떼어도 Used 는
        // 참조로 살아 있고 helper 는 자기 주석이 덮으므로 새 보고가 없다
        // — 타입의 주석은 불필요다. 반대로 helper 의 주석은 떼면 멤버가
        // 미사용으로 보고되므로 필요하다. 둘을 한 단위로 묶으면 helper
        // 때문에 타입의 불필요 주석이 숨겨진다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Used"])
    }

    @Test("조상 주석이 물려준 무시는 자기 단위를 만들지 않는다")
    func inheritedIgnoreDoesNotFormOwnUnit() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Dead.member", name: "member", kind: .method,
            parent: "Dead", attributes: [.ignoreComment, .ignoreInherited]
        )

        // member 에는 자기 코멘트가 없다 — Dead 의 주석 하나가 서브트리를
        // 덮는다. member 를 따로 판정하면 커버리지가 둘로 세어져 Dead 가
        // member 의 물려받은 보존으로 살아남아 필요한 주석이 불필요로 오판된다.
        // 떼면 둘 다 죽고 Dead 가 보고되므로 주석은 필요하다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("살아 있는 서브트리를 덮는 주석 하나는 한 건으로 보고한다")
    func liveSubtreeCoveredByOneCommentReportsOnce() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Used.member", name: "member", kind: .method,
            parent: "Used", attributes: [.ignoreComment, .ignoreInherited]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "App", to: "Used.member", kind: .call)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // 코멘트는 Used 에 하나뿐 — member 에 대한 발견이 따로 나오면
        // 없는 코멘트를 찾아 헤맨 것이다.
        let finding = try #require(report.superfluousIgnores.first)
        #expect(report.superfluousIgnores.count == 1)
        #expect(finding.node.name == "Used")
        #expect(finding.coveredCount == 2)
    }

    @Test("무시된 타입과 멤버가 모두 살아 있으면 두 주석 모두 불필요다")
    func ignoreOnFullyUsedTypeIsSuperfluous() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Used.helper", name: "helper", kind: .method,
            parent: "Used", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "App", to: "Used.helper", kind: .call)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // 코멘트는 선언마다 따로 판정한다 — 둘 다 아무것도 억제하지 않는다.
        #expect(superfluousNames(report) == ["Used", "helper"])
        let finding = try #require(report.superfluousIgnores.first)
        #expect(finding.node.name == "Used")
        #expect(finding.coveredCount == 2)
        #expect(!finding.coversWholeFile)
    }

    @Test("ignore:all 파일이 모두 살아 있으면 파일 범위로 한 건 보고한다")
    func fullyIgnoredLiveFileReportsOneFileScopeFinding() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.symbol(
            "AlsoUsed", kind: .classType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "App", to: "AlsoUsed", kind: .reference)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        let finding = try #require(report.superfluousIgnores.first)
        #expect(report.superfluousIgnores.count == 1)
        #expect(finding.coversWholeFile)
        #expect(finding.coveredCount == 2)
        #expect(finding.node.location?.path == "/project/Sources/App/Other.swift")
    }

    @Test("ignore:all 파일의 일부가 죽으면 그 주석은 필요하다")
    func fullyIgnoredFileWithDeadDeclarationIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.symbol(
            "Dead", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)

        let report = analyze(builder.build())
        // 코멘트 하나가 파일 전체를 덮으므로, 살아 있는 Used 쪽 범위가
        // 불필요해 보여도 코멘트를 떼면 Dead 가 보고된다 — 필요한 주석이다.
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("선언별 주석으로 전부 무시된 파일은 주석마다 따로 판정한다")
    func perDeclarationIgnoresInFullyIgnoredFileAreJudgedIndependently() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // ignore:all 이 아니라 선언마다 주석이 붙은 파일 — 그래프의 모든
        // 정점이 무시돼도 파일 범위 주석은 없다.
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.symbol(
            "Dead", kind: .structType,
            path: "/project/Sources/App/Other.swift", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // 두 주석을 한 단위로 묶으면 Dead 때문에 둘 다 필요해 보여
        // Used 의 불필요 주석이 숨겨진다.
        let finding = try #require(report.superfluousIgnores.first)
        #expect(report.superfluousIgnores.count == 1)
        #expect(finding.node.name == "Used")
        #expect(!finding.coversWholeFile)
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

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Covered"])
    }

    @Test("서로만 참조하는 무시 덩어리는 한쪽 주석만 불필요로 보고한다")
    func mutuallyDependentIgnoresReportOnlyOne() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("First", kind: .structType, line: 5, attributes: [.ignoreComment])
        builder.symbol("Second", kind: .structType, line: 10, attributes: [.ignoreComment])
        builder.reference(from: "First", to: "Second", kind: .reference)
        builder.reference(from: "Second", to: "First", kind: .reference)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // 각각을 따로 보면 상대 주석이 살려 주므로 둘 다 불필요해 보이지만,
        // 한꺼번에 떼면 둘 다 죽는다. 위치가 앞선 주석 하나만 보고해야
        // 보고된 주석을 모두 떼어도 새 보고가 생기지 않는다.
        let finding = try #require(report.superfluousIgnores.first)
        #expect(report.superfluousIgnores.count == 1)
        #expect(finding.node.name == "First")
    }

    @Test("다른 파일의 무시된 부모가 이 파일의 주석을 삼키지 않는다")
    func crossFileIgnoredMemberFormsOwnUnit() throws {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Target", kind: .structType,
            path: "/project/Sources/App/A.swift", attributes: [.ignoreComment]
        )
        // 인덱스가 확장 대상을 멤버 부모로 기록하는 형태. 멤버와 부모가
        // 다른 파일이면 주석도 따로 있으므로 단위를 합치면 안 된다.
        builder.symbol(
            "Target.extMember", name: "extMember", kind: .method,
            path: "/project/Sources/App/B.swift",
            parent: "Target", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Target", kind: .reference)

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        // Target 의 주석은 불필요하지만 extMember 는 떼면 죽는다 — 두
        // 코멘트를 한 단위로 보면 Target 의 불필요 주석이 숨겨진다.
        let finding = try #require(report.superfluousIgnores.first)
        #expect(report.superfluousIgnores.count == 1)
        #expect(finding.node.name == "Target")
        #expect(finding.coveredCount == 1)
    }

    @Test("시드 정점의 역방향 오버라이드 증인도 반사실 세계에서 살아남는다")
    func seededRequirementKeepsReverseOverrideWitnessAlive() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // 요구사항은 시드(무시 없는 세계)에 들어간다 — App 이 호출하므로.
        builder.symbol("P", kind: .protocolType, line: 2)
        builder.symbol("P.req", name: "req", kind: .method, line: 3, parent: "P")
        // 판정 대상: 다른 무시가 살려 주는 선언의 불필요 주석. 무시 없는
        // 세계에서는 죽어 있어야 빠른 경로가 아니라 반사실 탐색을 탄다.
        builder.symbol("Keeper", kind: .structType, line: 5, attributes: [.ignoreComment])
        builder.symbol("Covered", kind: .structType, line: 6, attributes: [.ignoreComment])
        // 세 번째 무시 단위: 요구사항의 구현을 가진 타입. 멤버에는 주석이 없고
        // 요구사항 역방향 디스패치로만 살아난다.
        builder.symbol("Impl", kind: .structType, line: 10, attributes: [.ignoreComment])
        builder.symbol("Impl.req", name: "req", kind: .method, line: 11, parent: "Impl")
        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.req", kind: .call)
        builder.reference(from: "Keeper", to: "Covered", kind: .reference)
        builder.reference(from: "Impl.req", to: "P.req", kind: .overrides)

        let report = analyze(builder.build())
        // Covered 의 주석을 떼어도 Keeper 의 주석이 살려 준다. 반사실 탐색이
        // 시드 정점의 오버라이드 관계를 건너뛰면 Impl.req 가 죽은 것으로
        // 계산되어 무관한 Covered 의 주석이 필요로 오판된다.
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
        let report = analyze(builder.build())
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

        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["extension"])
    }

    @Test("테스트에서만 도달되는 선언의 무시 주석은 test-only 보고를 억제하므로 필요하다")
    func ignoreCoveringTestOnlyDeclarationIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("TestRoot", kind: .classType, module: "AppTests", attributes: [.unitTest])
        builder.symbol(
            "Helper", kind: .structType, module: "App", attributes: [.ignoreComment]
        )
        builder.reference(from: "TestRoot", to: "Helper", kind: .call)

        let report = analyze(
            builder.build(), options: .init(findsTestOnlyCode: true))
        // 주석이 있으면 보고가 없고, 떼면 test-only 발견이 된다 — 주석은
        // 일을 하고 있으므로 불필요로 보고하면 안 된다.
        #expect(report.unused.isEmpty)
        #expect(report.testOnly.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("생산 코드가 참조하면 테스트 참조가 있어도 주석은 불필요다")
    func productionReachableIgnoreIsSuperfluousEvenWithTestReferences() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, module: "App", attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType, module: "App", attributes: [.ignoreComment])
        builder.symbol("TestRoot", kind: .classType, module: "AppTests", attributes: [.unitTest])
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.reference(from: "TestRoot", to: "Used", kind: .call)

        let report = analyze(
            builder.build(), options: .init(findsTestOnlyCode: true))
        #expect(superfluousNames(report) == ["Used"])
    }

    @Test("무시 주석이 assign-only 보고를 억제하면 필요하다")
    func ignoreSuppressingAssignOnlyFindingIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Box", kind: .structType)
        builder.symbol(
            "Box.state", name: "state", kind: .property,
            parent: "Box", attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Box", kind: .reference)
        builder.reference(from: "App", to: "Box.state", kind: .reference)
        builder.propertyAccess("Box.state", write: true)

        // state 는 쓰기만 되고 읽히지 않는다 — 주석이 없으면 assign-only
        // 발견이 된다. 주석을 떼어도 참조로 도달되므로 죽음 판정만으로는
        // 잡히지 않는다. 그 보고를 억제하는 주석은 필요하다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("다른 주석 덕에만 사는 프로퍼티도 자기 주석이 assign-only 보고를 억제하면 그 주석은 필요하다")
    func ignoreSuppressingAssignOnlyOfDeclarationKeptByAnotherIgnoreIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Keeper", kind: .structType, line: 5, attributes: [.ignoreComment])
        builder.symbol("Box", kind: .structType, line: 10)
        builder.symbol(
            "Box.state", name: "state", kind: .property, line: 11,
            parent: "Box", attributes: [.ignoreComment]
        )
        builder.reference(from: "Keeper", to: "Box", kind: .reference)
        builder.reference(from: "Keeper", to: "Box.state", kind: .reference)
        builder.propertyAccess("Box.state", write: true)

        // 주석이 하나도 없으면 셋 다 죽으므로 state 의 주석은 빠른 경로가 아니라 반사실 탐색으로 판정한다.
        // state 의 주석만 떼면 Keeper 의 주석이 state 를 살려 죽는 정점은 없지만 assign-only 발견이 드러난다.
        // 그 판정은 닫힌 집합이 아니라 이 세계에서 새로 닿은 정점까지 합친 도달 집합으로 해야 한다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.assignOnly.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("ignore:all 이 미사용 import 를 억제하면 파일 주석은 필요하다")
    func fileIgnoreSuppressingUnusedImportIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.importDecl(
            "UnusedModule", path: "/project/Sources/App/Other.swift",
            isIgnored: true, isIgnoredOnlyByFileComment: true
        )
        builder.fileModuleUsage(
            path: "/project/Sources/App/Other.swift", owningModule: "App")

        // 파일 주석을 떼면 import 도 무시가 풀려 미사용 import 발견이
        // 새로 생긴다 — import 는 그래프 정점이 아니라 도달성 반사실에
        // 잡히지 않으므로 따로 재본다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("ignore:all 파일의 import 가 쓰이면 파일 주석은 불필요다")
    func fileIgnoreWithUsedImportIsSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        builder.importDecl(
            "UsedModule", path: "/project/Sources/App/Other.swift",
            isIgnored: true, isIgnoredOnlyByFileComment: true
        )
        builder.fileModuleUsage(
            path: "/project/Sources/App/Other.swift",
            owningModule: "App", referencedModules: ["UsedModule"])

        // import 가 실제로 쓰이면 무시를 풀어도 발견이 생기지 않는다 —
        // import 검사가 무관한 파일 주석까지 붙잡으면 안 된다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.count == 1)
        #expect(report.superfluousIgnores.first?.coversWholeFile == true)
    }

    @Test("ignore:all 을 떼어도 자기 ignore 가 있는 import 는 무시가 남는다")
    func fileIgnoreLeavesOwnCommentedImportIgnored() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol(
            "Used", kind: .structType,
            path: "/project/Sources/App/Other.swift",
            attributes: [.ignoreComment, .ignoreAllComment]
        )
        builder.reference(from: "App", to: "Used", kind: .reference)
        // 파일 지시로만 무시된 import — `ignore:all` 을 떼면 풀리지만 쓰인다.
        builder.importDecl(
            "UsedModule", path: "/project/Sources/App/Other.swift",
            isIgnored: true, isIgnoredOnlyByFileComment: true
        )
        // 자기 `ignore` 주석이 있는 미사용 import — 파일 주석을 떼도
        // 무시가 남아 보고가 생기지 않는다.
        builder.importDecl(
            "OwnIgnoredModule", path: "/project/Sources/App/Other.swift",
            line: 2, isIgnored: true
        )
        builder.fileModuleUsage(
            path: "/project/Sources/App/Other.swift",
            owningModule: "App", referencedModules: ["UsedModule"])

        // 출처를 구분하지 않고 파일의 무시 import 를 전부 풀면 자기 주석이
        // 억제하는 OwnIgnoredModule 보고를 파일 주석이 떠받치는 것으로
        // 오판해 필요한 주석으로 남는다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.count == 1)
        #expect(report.superfluousIgnores.first?.coversWholeFile == true)
    }

    @Test("무시 부모가 없는 전파 무시 정점은 스스로 단위를 만든다")
    func orphanInheritedIgnoreFormsOwnUnit() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Parent", kind: .structType)
        builder.symbol(
            "Parent.member", name: "member", kind: .method,
            parent: "Parent", attributes: [.ignoreComment, .ignoreInherited]
        )
        builder.reference(from: "App", to: "Parent", kind: .reference)
        builder.reference(from: "App", to: "Parent.member", kind: .call)

        // member 의 무시는 주석을 단 조상이 물려준 것인데 그 조상은 그래프
        // 정점이 아니다(비정점 컨테이너거나 부모 바인딩 실패). 어느 단위에도
        // 접히지 않으면 그 무시를 거둘 주석이 영원히 판정되지 않으므로
        // 고아는 스스로 단위 꼭대기가 된다 — member 는 참조로 살아 있어
        // 그 무시는 불필요다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["member"])
    }

    @Test("고아 전파 무시가 죽은 선언을 덮으면 그 무시는 필요하다")
    func orphanInheritedIgnoreOnDeadDeclarationIsNeeded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Parent", kind: .structType)
        builder.symbol(
            "Parent.member", name: "member", kind: .method,
            parent: "Parent", attributes: [.ignoreComment, .ignoreInherited]
        )
        builder.reference(from: "App", to: "Parent", kind: .reference)

        // 고아 단위를 떼면 member 가 미사용으로 보고되므로 그 무시는 필요하다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("자기 주석 있는 멤버가 부모를 살리면 부모의 주석은 불필요다")
    func memberCommentKeepingParentAliveMakesParentCommentSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Dead.member", name: "member", kind: .method,
            parent: "Dead", attributes: [.ignoreComment]
        )

        // member 의 자기 주석이 member 를 보존하고 보존된 멤버는 부모를
        // 살린다 — Dead 의 주석을 떼어도 Dead 는 살아 있어 새 보고가 없다.
        // member 의 주석을 떼면 member 가 죽으므로 그쪽은 필요하다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Dead"])
    }

    @Test("다른 주석이 살려 둔 조상은 반사실 세계에서 멤버 보고를 가리지 않는다")
    func ancestorKeptByAnotherCommentDoesNotHideMember() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // 확장 대상을 멤버 부모로 기록하는 형태라 두 주석이 다른 파일에 있고, 멤버 쪽을 먼저 판정한다.
        builder.symbol("Shell", kind: .structType, path: "/project/Sources/App/B.swift", attributes: [.ignoreComment])
        builder.symbol(
            "Shell.extMember", name: "extMember", kind: .method,
            path: "/project/Sources/App/A.swift", parent: "Shell", attributes: [.ignoreComment]
        )

        // extMember 의 주석을 떼면 extMember 가 죽는다. Shell 은 무시 없이는 죽지만 이 세계에서는 자기 주석으로
        // 살아 있어 extMember 를 덮어 숨기지 않는다 — 보고가 생기므로 그 주석은 필요하다. Shell 의 주석은
        // extMember 의 주석이 물려준 보존이 Shell 을 살리므로 불필요다. 반사실 세계에서 새로 산 조상을
        // 도달 불가로 보면 두 판정이 뒤바뀐다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Shell"])
    }

    @Test("삼단 자기 주석 중첩은 누적 판정으로 위쪽 둘만 불필요다")
    func threeLevelNestedOwnCommentsJudgeCumulatively() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Outer", kind: .structType, attributes: [.ignoreComment])
        builder.symbol(
            "Outer.mid", name: "mid", kind: .method,
            parent: "Outer", attributes: [.ignoreComment]
        )
        builder.symbol(
            "Outer.mid.leaf", name: "leaf", kind: .method,
            parent: "Outer.mid", attributes: [.ignoreComment]
        )

        // 셋 다 참조가 없다. Outer 를 떼어도 mid 의 주석이 Outer 를 살리고,
        // mid 를 떼어도 leaf 의 주석이 mid 를 살린다 — 위쪽 둘은 불필요다.
        // leaf 를 떼면 이미 확정된 mid 와 함께 죽으므로 필요하다 — 확정분을
        // 누적해 빼지 않으면 mid 도 살아 있다고 나와 leaf 가 불필요로 오판된다.
        let report = analyze(builder.build())
        #expect(report.unused.isEmpty)
        #expect(superfluousNames(report) == ["Outer", "mid"])
    }

    @Test("무시 주석이 없으면 아무것도 보고하지 않는다")
    func noIgnoresMeansNoFindings() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType)

        let report = analyze(builder.build())
        #expect(unusedNames(report) == ["Dead"])
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("불필요 무시는 위치 순으로 정렬된다")
    func superfluousIgnoresAreSortedByLocation() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        // 이름 순서와 줄 순서가 어긋나게 두어 정렬 기준이 위치임을 고정한다.
        builder.symbol(
            "Zulu", kind: .structType, line: 5, attributes: [.ignoreComment]
        )
        builder.symbol(
            "Alpha", kind: .structType, line: 20, attributes: [.ignoreComment]
        )
        builder.reference(from: "App", to: "Zulu", kind: .reference)
        builder.reference(from: "App", to: "Alpha", kind: .reference)

        let report = analyze(builder.build())
        #expect(report.superfluousIgnores.map(\.node.name) == ["Zulu", "Alpha"])
    }

    @Test("반사실 판정의 갈래가 한 그래프에 섞여도 단위마다 같은 답을 같은 순서로 낸다", arguments: [false, true])
    func combinedCounterfactualsKeepTheirAnswers(findsTestOnlyCode: Bool) {
        let report = analyze(combinedSnapshot(), options: .init(findsTestOnlyCode: findsTestOnlyCode))
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: combinedSnapshot())
        // 테스트 전용 보고를 켜면 Helper·Glue 의 주석은 그 보고를 억제하므로 필요해진다.
        let expected: [(name: String, covered: Int, wholeFile: Bool)] = findsTestOnlyCode
            ? [("Covered", 1, false), ("First", 1, false), ("T", 2, false), ("WholeA", 2, true)]
            : [("Covered", 1, false), ("First", 1, false), ("T", 2, false), ("Helper", 1, false),
               ("Glue", 1, false), ("WholeA", 2, true)]
        #expect(report.superfluousIgnores.map(\.node.name) == expected.map(\.name))
        #expect(report.superfluousIgnores.map(\.coveredCount) == expected.map(\.covered))
        #expect(report.superfluousIgnores.map(\.coversWholeFile) == expected.map(\.wholeFile))
        #expect(unusedNames(report) == ["Orphan"])
        #expect(report.testOnly.isEmpty)
        #expect(report.explain("Impl.req", in: graph) == .reachable(path: ["App", "P.req", "Impl.req"]))
        #expect(report.explain("Shared", in: graph) == .reachable(path: ["Glue", "Shared"]))
        #expect(report.explain("T.m", in: graph) == .retained(.ignoreComment))
    }

    @Test("불필요 무시 판정을 끄면 반사실 탐색을 돌지 않고 다른 보고와 설명은 그대로다", arguments: [false, true])
    func disablingSuperfluousIgnoresKeepsEveryOtherAnswer(findsTestOnlyCode: Bool) {
        let snapshot = combinedSnapshot()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let full = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: findsTestOnlyCode))
            .analyze(graph: graph, snapshot: snapshot)
        var counterfactuals = 0
        let skipped = ReachabilityAnalyzer(
            options: .init(findsTestOnlyCode: findsTestOnlyCode, computesSuperfluousIgnores: false)
        ).analyze(graph: graph, snapshot: snapshot, onCounterfactualTraversal: { _ in counterfactuals += 1 })

        // check·baseline·fix·query 는 superfluous 결과를 읽지 않는다. 그 비용만 빠지고 나머지는 같아야 한다.
        #expect(counterfactuals == 0)
        #expect(!full.superfluousIgnores.isEmpty)
        #expect(skipped.superfluousIgnores.isEmpty)
        #expect(skipped.unused == full.unused)
        #expect(skipped.retentions == full.retentions)
        #expect(skipped.inheritedRetentions == full.inheritedRetentions)
        #expect(skipped.testOnly == full.testOnly)
        #expect(skipped.assignOnly == full.assignOnly)
        #expect(skipped.unusedParameters == full.unusedParameters)
        #expect(skipped.unusedImports == full.unusedImports)
        #expect(skipped.redundantPublic == full.redundantPublic)
        #expect(skipped.reachableCount == full.reachableCount)
        #expect(skipped.totalCount == full.totalCount)
        #expect(graph.nodeIDs.allSatisfy { skipped.explain($0, in: graph) == full.explain($0, in: graph) })
    }

    @Test("단위별 반사실 탐색은 닫힌 도달 집합이 커져도 바깥 증인의 시드만 보고 닫힌 정점은 펼치지 않는다")
    func counterfactualWorkDoesNotGrowWithClosedReach() {
        // 살아 있는 선언이 늘어도 무시 단위 하나의 반사실 탐색이 하는 일은 같아야 한다. 단위마다 닫힌 집합
        // 전체를 정렬해 오버라이드를 다시 보거나 닫힌 정점을 다시 펼치면 작업이 그 크기만큼 늘어 단위 수와 곱해진다.
        let small = counterfactualWork(liveTypes: 5)
        let large = counterfactualWork(liveTypes: 200)
        // 두 단위 모두 요구사항 P.req 하나만 다시 본다 — 그 증인만 닫힌 집합 밖에 있다. 펼치는 정점은 남은
        // 무시 타입과 그 구현 둘이다. 그 타입이 참조하는 Registry 는 이미 닫혀 있어 다시 걷지 않는다.
        #expect(small.map(\.reexaminedSeeds) == [1, 1])
        #expect(small.map(\.expandedNodes) == [2, 2])
        #expect(large == small)
    }

    /// 무시 단위마다 반사실 탐색이 한 일. 살아 있는 타입 수로 닫힌 도달 집합의 크기만 바꾼다.
    private func counterfactualWork(liveTypes: Int) -> [ReachabilityAnalyzer.CounterfactualWork] {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType, line: 2)
        builder.symbol("P.req", name: "req", kind: .method, line: 3, parent: "P")
        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.req", kind: .call)
        // 살아 있는 선언은 모두 Registry 를 거쳐 닿는다. 무시 타입도 Registry 를 참조하므로, 단위별 탐색이
        // 닫힌 정점을 다시 펼치면 그 아래를 통째로 다시 걷는다.
        builder.symbol("Registry", kind: .structType, line: 4)
        builder.reference(from: "App", to: "Registry", kind: .reference)
        for index in 0..<liveTypes {
            builder.symbol("Live\(index)", kind: .structType, line: 100 + index)
            builder.symbol("Live\(index).run", name: "run", kind: .method, line: 100 + index, parent: "Live\(index)")
            builder.reference(from: "Registry", to: "Live\(index)", kind: .reference)
            builder.reference(from: "Registry", to: "Live\(index).run", kind: .call)
        }
        // 주석으로만 사는 두 타입. 요구사항 구현은 역방향 디스패치로만 산다.
        for (name, line) in [("First", 10), ("Second", 20)] {
            builder.symbol(name, kind: .structType, line: line, attributes: [.ignoreComment])
            builder.symbol(
                "\(name).req", name: "req", kind: .method, line: line + 1,
                parent: name, attributes: [.ignoreComment, .ignoreInherited]
            )
            builder.reference(from: "\(name).req", to: "P.req", kind: .overrides)
            builder.reference(from: name, to: "Registry", kind: .reference)
        }
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        var work: [ReachabilityAnalyzer.CounterfactualWork] = []
        let report = ReachabilityAnalyzer().analyze(
            graph: graph, snapshot: snapshot, onCounterfactualTraversal: { work.append($0) }
        )
        // 두 주석 모두 자기 타입을 살리고 있다.
        #expect(report.superfluousIgnores.isEmpty)
        return work
    }

    /// 반사실 판정의 갈래를 한 그래프에 모은 스냅샷.
    ///
    /// 다른 무시가 살리는 선언(Covered), 역방향 오버라이드로만 사는 증인(Impl.req), 서로만 참조하는 무시
    /// 덩어리(First·Second), 두 주석이 함께 덮는 멤버(T.m), 파일 범위 주석(Whole.swift), 테스트만 붙잡는
    /// 선언(Helper·Shared)이 섞여 있다. 앞 단위의 확정이 뒤 단위의 답을 바꾸는 경우들이라, 반사실 탐색을
    /// 고칠 때 단위별 답과 순서가 그대로인지 한 번에 고정한다.
    private func combinedSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType, line: 2)
        builder.symbol("P.req", name: "req", kind: .method, line: 3, parent: "P")
        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.req", kind: .call)
        builder.symbol("Keeper", kind: .structType, line: 5, attributes: [.ignoreComment])
        builder.symbol("Covered", kind: .structType, line: 6, attributes: [.ignoreComment])
        builder.reference(from: "Keeper", to: "Covered", kind: .reference)
        builder.symbol("Impl", kind: .structType, line: 10, attributes: [.ignoreComment])
        builder.symbol("Impl.req", name: "req", kind: .method, line: 11, parent: "Impl")
        builder.reference(from: "Impl.req", to: "P.req", kind: .overrides)
        builder.symbol("First", kind: .structType, line: 20, attributes: [.ignoreComment])
        builder.symbol("Second", kind: .structType, line: 21, attributes: [.ignoreComment])
        builder.reference(from: "First", to: "Second", kind: .reference)
        builder.reference(from: "Second", to: "First", kind: .reference)
        // T.m 은 T 와 Ext 의 두 주석이 함께 덮는다. 위치가 앞선 T 를 먼저 판정한다.
        builder.symbol("T", kind: .structType, line: 30, attributes: [.ignoreComment])
        builder.symbol(
            "T.m", name: "m", kind: .method, line: 31,
            parent: "T", attributes: [.ignoreComment, .ignoreInherited]
        )
        builder.symbol("Ext", kind: .extensionDeclaration, line: 40, attributes: [.ignoreComment])
        builder.reference(from: "App", to: "T", kind: .reference)
        builder.reference(from: "Ext", to: "T", kind: .extends)
        builder.reference(from: "Ext", to: "T.m", kind: .member)
        // Glue 는 보고되지 않는 종류라 떼어도 죽음 보고가 없고, Shared 가 테스트 전용이 될 뿐이다.
        builder.symbol("Helper", kind: .structType, line: 45, attributes: [.ignoreComment])
        builder.symbol("Glue", kind: .extensionDeclaration, line: 50, attributes: [.ignoreComment])
        builder.symbol("Shared", kind: .structType, line: 51)
        builder.reference(from: "Glue", to: "Shared", kind: .reference)
        builder.symbol(
            "TestRoot", kind: .classType, module: "AppTests",
            path: "/project/Tests/AppTests/RootTests.swift", attributes: [.unitTest]
        )
        builder.reference(from: "TestRoot", to: "Helper", kind: .call)
        builder.reference(from: "TestRoot", to: "Shared", kind: .call)
        builder.symbol("Orphan", kind: .structType, line: 60)
        for (name, line) in [("WholeA", 1), ("WholeB", 2)] {
            builder.symbol(
                name, kind: .structType, path: "/project/Sources/App/Whole.swift",
                line: line, attributes: [.ignoreComment, .ignoreAllComment]
            )
            builder.reference(from: "App", to: name, kind: .reference)
        }
        return builder.build()
    }

    private func unusedNames(_ report: UnusedCodeReport) -> [String] {
        report.unused.map(\.name).sorted()
    }
}
