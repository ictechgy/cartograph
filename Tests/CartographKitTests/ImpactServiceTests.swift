import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("수정 전 영향 점검")
struct ImpactServiceTests {
    @Test("입력 문자열을 되돌려주는 목록도 출력 한도와 전체 개수를 지킨다")
    func capsEchoedSelectors() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(symbols: ["Storage", "Service", "App"], limit: 1, in: context)
        #expect(document.requestedSymbols == ["Storage"])
        #expect(document.summary.requestedSymbols == 3)
        #expect(document.truncated.sections.contains("requestedSymbols"))
    }

    @Test("컴파일러가 모르는 런타임 계약의 소비자도 구별된 근거로 따라간다")
    func followsDeclaredRuntimeDependencies() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("App", attributes: [.entryPoint])
        builder.symbol("Dispatcher", kind: .function)
        builder.symbol("Handler", kind: .function)
        builder.reference(from: "App", to: "Dispatcher", kind: .call)
        let context = AnalysisContext(snapshot: builder.build())
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "route", source: "Dispatcher", target: "Handler", mechanism: .callback,
                  requiredScenarios: ["launch"]),
        ])
        let without = try service.impactDocument(symbols: ["Handler"], in: context)
        #expect(without.affected.isEmpty)
        let withRuntime = try service.impactDocument(symbols: ["Handler"], runtimeContracts: contracts, in: context)
        #expect(withRuntime.affected.compactMap(\.symbol.usr) == ["Dispatcher", "App"])
        #expect(withRuntime.affected.first?.relationship == "runtimeContract")
        #expect(withRuntime.affected.first?.runtimeContracts == ["route"])
        #expect(withRuntime.affected.first?.runtimeContractsCount == nil)
        #expect(withRuntime.affected.first?.runtimeContractsOmitted == nil)
        #expect(withRuntime.runtimeDependencies.first?.status == "declared")
        #expect(withRuntime.runtimeReview.contains { $0.symbol.usr == "Handler" && $0.runtimeContracts == ["route"] })
        #expect(context.buildGraph(level: .symbol).graph.edgeCount == 1)
    }

    @Test("런타임 계약의 대상이 없어도 연결을 만들어 성공으로 위장하지 않는다")
    func reportsUnresolvedRuntimeDependency() throws {
        let (service, context) = fixture()
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "broken", source: "Service", target: "MissingHandler", mechanism: .callback,
                  requiredScenarios: ["launch"]),
        ])
        let document = try service.impactDocument(symbols: ["Storage"], runtimeContracts: contracts, in: context)
        #expect(document.status == "incomplete")
        #expect(document.selectionIssues.first?.kind == "runtimeContract")
        #expect(document.selectionIssues.first?.status == "missingTarget")
        #expect(document.affected.allSatisfy { $0.relationship != "runtimeContract" })
    }

    private func fixture() -> (CartographService, AnalysisContext) {
        var builder = SnapshotBuilder(module: "App", path: "/p/App.swift")
        builder.symbol("App", attributes: [.entryPoint])
        builder.symbol("Service", kind: .function, path: "/p/Service.swift")
        builder.symbol("Storage", kind: .function, module: "Data", path: "/p/Storage.swift")
        builder.symbol("Test", kind: .function, module: "Checks", path: "/p/Test.swift", attributes: [.testFunction])
        builder.symbol("Unrelated", kind: .function, path: "/p/Unrelated.swift")
        builder.reference(from: "App", to: "Service", kind: .call)
        builder.reference(from: "Service", to: "Storage", kind: .call)
        builder.reference(from: "Test", to: "Service", kind: .call)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: .init(fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(builder.build())),
            reportScope: ReportScope(files: ["/p/Storage.swift"])
        )
        return (service, AnalysisContext(snapshot: builder.build()))
    }

    @Test("변경 파일 밖의 전이 소비자와 테스트를 근거와 함께 보고한다")
    func reportsConsumersOutsideSelection() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(symbols: ["Storage"], in: context)
        #expect(document.status == "found")
        #expect(document.level == "symbol")
        #expect(Set(document.affected.compactMap(\.symbol.usr)) == ["Service", "App", "Test"])
        let caller = try #require(document.affected.first { $0.symbol.usr == "Service" })
        #expect(caller.via == "Storage")
        #expect(caller.depth == 1)
        #expect(caller.edges == ["call"])
        #expect(document.tests.compactMap(\.usr) == ["Test"])
        #expect(document.entryPoints.compactMap(\.usr) == ["App"])
        #expect(document.summary.modules == ["App", "Checks"])
        #expect(!document.truncated.depth)
    }

    @Test("상대 파일은 프로젝트 기준으로 풀고 진단 범위로 소비자를 숨기지 않는다")
    func selectsFileWithoutFilteringConsumers() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(files: ["Storage.swift"], in: context)
        #expect(document.changeScope.compactMap(\.usr) == ["Storage"])
        #expect(document.summary.affectedSymbols == 3)
        #expect(document.summary.files == ["/p/App.swift", "/p/Service.swift", "/p/Test.swift"])
    }

    @Test("표시 한도는 전체 집계를 줄이지 않고 깊이 절단과 구별된다")
    func distinguishesOutputAndDepthLimits() throws {
        let (service, context) = fixture()
        let capped = try service.impactDocument(symbols: ["Storage"], limit: 1, in: context)
        #expect(capped.affected.count == 1)
        #expect(capped.summary.affectedSymbols == 3)
        #expect(capped.summary.testSymbols == 1)
        #expect(capped.truncated.output)
        #expect(!capped.truncated.depth)
        let shallow = try service.impactDocument(symbols: ["Storage"], maxDepth: 1, in: context)
        #expect(shallow.affected.compactMap(\.symbol.usr) == ["Service"])
        #expect(shallow.truncated.depth)
        #expect(!shallow.truncated.output)
    }

    @Test("없는 파일을 영향 없음으로 판정하지 않는다")
    func reportsUnindexedOrDeletedFiles() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(files: ["Deleted.swift"], in: context)
        #expect(document.status == "incomplete")
        #expect(document.selectionIssues.count == 1)
        #expect(document.selectionIssues.first?.kind == "file")
        #expect(document.selectionIssues.first?.status == "unindexed")
        #expect(document.limitations.contains { $0.hasPrefix("unresolved-impact-inputs:") })
    }

    @Test("일부 이름이 없더라도 알려진 입력의 영향과 미확인 입력을 모두 남긴다")
    func preservesPartialResults() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(symbols: ["Storage", "Missing"], in: context)
        #expect(document.status == "incomplete")
        #expect(document.summary.affectedSymbols == 3)
        #expect(document.selectionIssues.first?.requested == "Missing")
    }

    @Test("같은 이름을 가진 선언은 후보로 돌려주고 임의로 영향을 합치지 않는다")
    func preservesAmbiguity() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder()
        builder.symbol("left", name: "Duplicate")
        builder.symbol("right", name: "Duplicate")
        let document = try service.impactDocument(symbols: ["Duplicate"], in: .init(snapshot: builder.build()))
        #expect(document.status == "incomplete")
        #expect(document.changeScope.isEmpty)
        #expect(document.selectionIssues.first?.status == "ambiguous")
        #expect(document.selectionIssues.first?.candidates?.count == 2)
    }

    @Test("변경 입력이 없으면 미확인과 다른 noChanges 상태를 낸다")
    func noChangesIsExplicit() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(in: context)
        #expect(document.status == "noChanges")
        #expect(document.selectionIssues.isEmpty)
        #expect(document.affected.isEmpty)
    }

    @Test("git이 찾은 삭제 경로는 사용자 오타와 다른 분석 불완전 상태로 실패한다")
    func distinguishesDerivedSelectionFailure() throws {
        let (service, _) = fixture()
        let git = try service.impact(files: ["Deleted.swift"], format: "json", fileSelectionIsDerived: true)
        #expect(!git.subjectNotFound)
        #expect(git.incompleteAnalysis != nil)
        let explicit = try service.impact(files: ["Deleted.swift"], format: "json")
        #expect(explicit.subjectNotFound)
        #expect(explicit.incompleteAnalysis == nil)
    }

    @Test("타입 선택과 멤버 확장을 구분하고 시드만 많아도 잘렸다고 표시한다")
    func separatesSelectionAndExpandedScope() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder()
        builder.symbol("Type")
        builder.symbol("MemberA", kind: .method, parent: "Type")
        builder.symbol("Extension", kind: .extensionDeclaration)
        builder.symbol("MemberB", kind: .method, parent: "Extension")
        builder.reference(from: "Extension", to: "Type", kind: .extends)
        let document = try service.impactDocument(symbols: ["Type"], limit: 1, in: .init(snapshot: builder.build()))
        #expect(document.selected.compactMap(\.usr) == ["Type"])
        #expect(document.summary.selectedSymbols == 1)
        #expect(document.summary.changeScopeSymbols == 4)
        #expect(document.changeScope.count == 1)
        #expect(document.truncated.sections.contains("changeScope"))
    }

    @Test("동명 후보가 한 타입과 그 익스텐션뿐이면 같은 타입 범위로 선택한다")
    func resolvesTypeAndItsExtensionsTogether() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder()
        builder.symbol("T", name: "Thing")
        builder.symbol("E", name: "Thing", kind: .extensionDeclaration)
        builder.symbol("f", kind: .method, parent: "E")
        builder.reference(from: "E", to: "T", kind: .extends)
        let document = try service.impactDocument(symbols: ["Thing"], in: .init(snapshot: builder.build()))
        #expect(document.status == "found")
        #expect(document.selected.compactMap(\.usr) == ["T"])
        #expect(Set(document.changeScope.compactMap(\.usr)) == ["T", "E", "f"])
    }

    @Test("동적 선언과 외부 브리지 근거를 런타임 검토 목록에 싣는다")
    func includesRuntimeEvidence() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("Handler", kind: .function, attributes: [.objc])
        let evidence = ExternalRetention.Evidence(
            channel: "camera", method: "takePhoto",
            caller: .init(platform: "dart", path: "lib/camera.dart", line: 7)
        )
        let context = AnalysisContext(
            snapshot: builder.build(),
            externalRetentions: .init(retentions: [
                .init(symbol: .init(usr: "Handler", qualifiedName: nil), reason: "bridge", evidence: evidence),
            ])
        )
        let document = try service.impactDocument(symbols: ["Handler"], in: context)
        let review = try #require(document.runtimeReview.first)
        #expect(review.symbol.usr == "Handler")
        #expect(review.reasons.contains(.objectiveCAccessible))
        #expect(review.reasons.contains(.externalBridge))
        #expect(review.externalEvidence == [evidence])
        #expect(review.externalEvidenceCount == nil)
        #expect(review.externalEvidenceOmitted == nil)
    }

    @Test("런타임 근거와 계약의 중첩 목록은 한도와 생략 수를 함께 보존한다")
    func capsNestedRuntimeEvidenceAndContracts() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("Dispatcher", kind: .function)
        builder.symbol("Handler", kind: .function, attributes: [.objc])
        let caller = { (index: Int) in
            ExternalRetention.Caller(platform: "dart", path: "lib/camera\(index).dart", line: index)
        }
        let evidence = (1...3).map { index in
            ExternalRetention.Evidence(
                channel: "camera-\(index)", method: "takePhoto", caller: caller(index),
                callers: (1...3).map(caller), callersOmitted: 1
            )
        }
        let retentions = [
            ExternalRetention(
                symbol: .init(usr: "Handler", qualifiedName: nil), reason: "bridge", evidence: nil
            ),
        ] + evidence.map {
            ExternalRetention(
                symbol: .init(usr: "Handler", qualifiedName: nil), reason: "bridge", evidence: $0
            )
        }
        let context = AnalysisContext(
            snapshot: builder.build(), externalRetentions: .init(retentions: retentions)
        )
        let contracts = RuntimeContractsDocument(contracts: (1...3).map { index in
            .init(
                id: "route-\(index)", source: "Dispatcher", target: "Handler", mechanism: .callback,
                requiredScenarios: ["launch"]
            )
        })

        let document = try service.impactDocument(
            symbols: ["Handler"], limit: 1, runtimeContracts: contracts, in: context
        )
        let handler = try #require(document.runtimeReview.first { $0.symbol.usr == "Handler" })
        let affectedDispatcher = try #require(document.affected.first { $0.symbol.usr == "Dispatcher" })
        let shownEvidence = try #require(handler.externalEvidence.first)

        #expect(handler.externalEvidence.count == 1)
        #expect(handler.externalEvidenceCount == 3)
        #expect(handler.externalEvidenceOmitted == 2)
        #expect(shownEvidence.channel == "camera-1")
        #expect(shownEvidence.callers?.count == 1)
        #expect(shownEvidence.callersOmitted == 3)
        #expect(handler.runtimeContracts == ["route-1"])
        #expect(handler.runtimeContractsCount == 3)
        #expect(handler.runtimeContractsOmitted == 2)
        #expect(affectedDispatcher.runtimeContracts == ["route-1"])
        #expect(affectedDispatcher.runtimeContractsCount == 3)
        #expect(affectedDispatcher.runtimeContractsOmitted == 2)
        #expect(document.truncated.sections.contains("runtimeEvidence"))
        #expect(document.truncated.sections.contains("runtimeContracts"))
    }

    @Test("호출자 생략 수가 정수 범위를 넘으면 출력에서 포화시키지 않고 거부한다")
    func rejectsCallerCountOverflow() throws {
        let (service, _) = fixture()
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("Handler", kind: .function, attributes: [.objc])
        let caller = ExternalRetention.Caller(platform: "dart", path: "lib/camera.dart", line: 1)
        let context = AnalysisContext(
            snapshot: builder.build(),
            externalRetentions: .init(retentions: [
                .init(
                    symbol: .init(usr: "Handler", qualifiedName: nil), reason: "bridge",
                    evidence: .init(
                        channel: "camera", method: "takePhoto", caller: caller,
                        callers: [caller, caller], callersOmitted: .max
                    )
                ),
            ])
        )

        #expect(throws: CartographError.self) {
            _ = try service.impactDocument(symbols: ["Handler"], limit: 1, in: context)
        }
    }

    @Test("같은 스냅샷의 결과는 결정적이며 삭제 허가 필드를 내지 않는다")
    func deterministicFactDocument() throws {
        let (service, context) = fixture()
        let first = try service.impactDocument(symbols: ["Storage"], in: context)
        let second = try service.impactDocument(symbols: ["Storage"], in: context)
        #expect(first == second)
        let json = String(decoding: try JSONEncoder.cartographDefault().encode(first), as: UTF8.self)
        #expect(json.contains("change-impact"))
        #expect(!json.contains("deletable"))
        #expect(!json.contains(":null"))
    }
}
