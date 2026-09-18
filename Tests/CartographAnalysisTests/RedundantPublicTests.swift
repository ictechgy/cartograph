import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("불필요한 public 접근 수준")
struct RedundantPublicTests {
    /// 스냅샷을 심볼 레벨 그래프로 만들고 분석한다.
    private func analyze(
        _ snapshot: IndexSnapshot,
        retention: RetentionOptions = .default
    ) -> UnusedCodeReport {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer(policy: RetentionPolicy(options: retention))
        return analyzer.analyze(graph: graph, snapshot: snapshot)
    }

    private func names(_ report: UnusedCodeReport) -> [String] {
        report.redundantPublic.map(\.node.name).sorted()
    }

    /// 엔트리포인트와 내부 도우미가 public 선언을 참조하는 최소 형태.
    private func snapshot(referencing position: ReferencePosition) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Helper", kind: .function, accessibility: .internalLevel)
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Helper", kind: .call, position: .body)
        builder.reference(from: "Helper", to: "Api", kind: .reference, position: position)
        return builder.build()
    }

    @Test("자기 모듈에서만 참조되는 public 선언을 보고한다")
    func reportsModuleInternalUse() throws {
        let report = analyze(snapshot(referencing: .body))
        let finding = try #require(report.redundantPublic.first)
        #expect(names(report) == ["Api"])
        #expect(finding.referenceCount == 1)
        #expect(finding.node.accessibility == .publicLevel)
    }

    @Test("다른 모듈에서 참조되는 public 선언은 보고하지 않는다")
    func staysQuietWhenReferencedCrossModule() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Client", kind: .structType, module: "Other")
        builder.reference(from: "App", to: "Api", kind: .reference, position: .body)
        builder.reference(from: "Client", to: "Api", kind: .reference, position: .signature)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("참조가 없는 public 선언은 의도된 표면으로 두고 보고하지 않는다")
    func skipsNeverReferencedSurface() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)

        // `retain_public` 이 살려 둔 API 전체를 "internal 로 줄이라"고 하면
        // 보고가 쏟아진다. 미사용 여부는 dead 의 다른 보고가 답한다.
        #expect(analyze(builder.build(), retention: RetentionOptions(retainPublic: true)).redundantPublic.isEmpty)

        // 합성 Codable 이 읽는 저장소도 참조가 없으면 같은 이유로 조용하다.
        var model = SnapshotBuilder()
        model.symbol("Model", kind: .structType, accessibility: .publicLevel, attributes: [.codable])
        model.symbol("Model.value", name: "value", kind: .property, parent: "Model",
            accessibility: .publicLevel)
        #expect(analyze(model.build()).redundantPublic.isEmpty)
    }

    @Test("retain_public 이 켜지면 공개 표면이 의도된 것이라 침묵한다")
    func staysQuietWithRetainPublic() {
        // 모듈 안에서만 쓰이는 public 이라도 `retain_public` 이 켜져 있으면
        // 사용자가 공개 표면을 의도한 것이다. 라이브러리는 자기 API 를 모듈
        // 안에서 읽으므로, 침묵하지 않으면 표면 전체가 보고된다.
        #expect(
            analyze(snapshot(referencing: .body), retention: RetentionOptions(retainPublic: true))
                .redundantPublic.isEmpty
        )
    }

    @Test("보존 규칙이 살린 public 선언은 보고하지 않는다")
    func skipsUserRetainedDeclaration() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)

        // retain_public 이 아니어도 살아 있어야 ③의 대상이 된다 — 설정 보존으로 살린다.
        #expect(
            analyze(builder.build(), retention: RetentionOptions(
                retainedNames: [GlobPattern("Api")]
            )).redundantPublic.isEmpty
        )
    }

    @Test("살아 있지 않은 public 선언은 미사용 몫으로 남긴다")
    func skipsUnreachableDeclaration() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)

        let report = analyze(builder.build())
        #expect(report.redundantPublic.isEmpty)
        #expect(report.unused.map(\.name) == ["Api"])
    }

    @Test("인터페이스 자리의 참조는 대상을 공개로 요구한다")
    func signatureReferenceForcesPublicType() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Holder", kind: .structType, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Holder", kind: .reference, position: .body)
        builder.reference(from: "Holder", to: "Api", kind: .reference, position: .signature)

        // Holder 는 내부에서만 쓰이므로 보고 대상이지만, Api 는 Holder 의
        // 인터페이스가 요구하므로 대상이 아니다. 둘 다 internal 로 줄이는 것은
        // 안전하지만 Api 만 먼저 줄이면 Holder 의 선언이 깨진다.
        #expect(names(analyze(builder.build())) == ["Holder"])
    }

    @Test("본문 자리의 참조는 대상을 공개로 요구하지 않는다")
    func bodyReferenceDoesNotForce() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Holder", kind: .structType, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Holder", kind: .reference, position: .body)
        builder.reference(from: "Holder", to: "Api", kind: .reference, position: .body)

        #expect(names(analyze(builder.build())) == ["Api", "Holder"])
    }

    @Test("자리 판단이 없는 참조는 인터페이스처럼 다룬다")
    func unknownPositionForces() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Holder", kind: .structType, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Holder", kind: .reference, position: .body)
        builder.reference(from: "Holder", to: "Api", kind: .reference)

        #expect(names(analyze(builder.build())) == ["Holder"])
    }

    @Test("internal 출처의 인터페이스 참조는 요구가 아니다")
    func internalSourceSignatureDoesNotForce() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Helper", kind: .function, accessibility: .internalLevel)
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Helper", kind: .call, position: .body)
        builder.reference(from: "Helper", to: "Api", kind: .reference, position: .signature)

        #expect(names(analyze(snapshot(referencing: .body))) == ["Api"])
        #expect(names(analyze(builder.build())) == ["Api"])
    }

    @Test("internal 타입 안의 명시적 public 멤버는 공개 표면이 아니다")
    func nestedPublicInInternalTypeIsNotSurface() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Outer", kind: .structType, accessibility: .internalLevel)
        builder.symbol(
            "Outer.Api", name: "Api", kind: .structType,
            parent: "Outer", accessibility: .publicLevel
        )
        builder.reference(from: "App", to: "Outer.Api", kind: .reference, position: .body)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("오버라이드와 프로토콜 요구사항·증인은 보고하지 않는다")
    func skipsOverridesAndProtocolMembers() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType, accessibility: .publicLevel)
        builder.symbol("P.req", name: "req", kind: .method, parent: "P", accessibility: .publicLevel)
        builder.symbol("Impl", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Impl.req", name: "req", kind: .method, parent: "Impl", accessibility: .publicLevel)
        builder.symbol("Impl.base", name: "base", kind: .method, parent: "Impl", accessibility: .publicLevel,
            attributes: [.overrideDeclaration])
        builder.reference(from: "App", to: "P.req", kind: .call, position: .body)
        builder.reference(from: "App", to: "Impl.req", kind: .call, position: .body)
        builder.reference(from: "App", to: "Impl.base", kind: .call, position: .body)
        builder.reference(from: "Impl.req", to: "P.req", kind: .overrides, position: .signature)
        builder.reference(from: "Impl.base", to: "SDK.base", kind: .overrides, position: .signature)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("무시 주석이 붙은 public 선언은 보고하지 않는다")
    func ignoreCommentSuppressesFinding() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel, attributes: [.ignoreComment])
        builder.reference(from: "App", to: "Api", kind: .reference, position: .body)

        let report = analyze(builder.build())
        #expect(report.redundantPublic.isEmpty)
        // 주석을 떼면 이 발견이 드러나므로 주석은 일을 하고 있다.
        #expect(report.superfluousIgnores.isEmpty)
    }

    @Test("주석 없이도 공개 표면이 아닌 선언의 무시 주석은 불필요로 남는다")
    func ignoreCommentOnNonSurfaceStaysSuperfluous() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Helper", kind: .function, accessibility: .internalLevel, attributes: [.ignoreComment])
        builder.reference(from: "App", to: "Helper", kind: .call, position: .body)

        let report = analyze(builder.build())
        #expect(report.redundantPublic.isEmpty)
        #expect(report.superfluousIgnores.map(\.node.name) == ["Helper"])
    }

    @Test("테스트 타깃의 public 선언은 보고하지 않는다")
    func skipsTestTargets() {
        var builder = SnapshotBuilder()
        builder.symbol("AppTests", kind: .structType, module: "AppTests", attributes: [.unitTest])
        builder.symbol("Api", kind: .structType, module: "AppTests", accessibility: .publicLevel)
        builder.reference(from: "AppTests", to: "Api", kind: .reference, position: .body)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("Objective-C 노출 선언은 보고하지 않는다")
    func skipsObjectiveCExposed() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .method, accessibility: .publicLevel, attributes: [.objc])
        builder.reference(from: "App", to: "Api", kind: .call, position: .body)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("출처 모듈을 알 수 없는 참조는 밖에서 온 것으로 본다")
    func skipsUnattributableReferences() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Api", kind: .structType, accessibility: .publicLevel)
        // 모듈 이름도 파일 근거도 없는 출처 — 어느 모듈에서 왔는지 주장할 수 없다.
        builder.symbol("Mystery", kind: .function, module: "")
        builder.reference(from: "Mystery", to: "Api", kind: .reference, position: .body)

        #expect(analyze(builder.build()).redundantPublic.isEmpty)
    }

    @Test("발견은 위치 순으로 정렬된다")
    func findingsAreSortedByLocation() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Zulu", kind: .structType, line: 40, accessibility: .publicLevel)
        builder.symbol("Alpha", kind: .structType, line: 10, accessibility: .publicLevel)
        builder.reference(from: "App", to: "Zulu", kind: .reference, position: .body)
        builder.reference(from: "App", to: "Alpha", kind: .reference, position: .body)

        #expect(names(analyze(builder.build())) == ["Alpha", "Zulu"])
    }
}
