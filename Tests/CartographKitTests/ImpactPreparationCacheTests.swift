import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Dispatch
import Foundation
import Testing

@Suite("문맥별 영향 준비 캐시")
struct ImpactPreparationCacheTests {
    @Test("생명주기·파일·이름 준비는 독립적으로 한 번 만들고 같은 문맥의 값 복사만 공유한다")
    func constructsOnceAcrossContextCopies() {
        let context = AnalysisContext(snapshot: snapshot())
        let inventory = ProjectFileInventory(
            fileSystem: InMemoryFileSystem(), projectPath: "/p", pathFilter: .passthrough
        )
        let copy = context.bindingProjectFileInventory(inventory).bindingRuntimeInputFingerprint("captured")
        let graph = context.buildGraph(level: .symbol).graph
        var lifecycleBuilds = 0
        var fileBuilds = 0
        var nameBuilds = 0
        for value in [context, copy, context, copy] {
            let lifecycle = value.impactLifecycle {
                lifecycleBuilds += 1
                return XCTestLifecycleImpact(in: $0)
            }
            let files = value.impactRawNodesByFile {
                fileBuilds += 1
                return ImpactSelection.rawNodesByFile(in: $0)
            }
            let names = value.impactQueryIndex {
                nameBuilds += 1
                return GraphQueryIndex(graph: $0)
            }
            #expect(lifecycle == XCTestLifecycleImpact(in: graph))
            #expect(files == ImpactSelection.rawNodesByFile(in: graph))
            #expect(names.resolve("Storage") == .found(graph.node("Storage")!))
        }
        #expect(lifecycleBuilds == 1 && fileBuilds == 1 && nameBuilds == 1)

        // 같은 내용의 새 문맥도 새 세대다. 기존 준비 값을 전역으로 재사용하지 않는다.
        let fresh = AnalysisContext(snapshot: snapshot())
        _ = fresh.impactLifecycle { lifecycleBuilds += 1; return XCTestLifecycleImpact(in: $0) }
        _ = fresh.impactRawNodesByFile { fileBuilds += 1; return ImpactSelection.rawNodesByFile(in: $0) }
        _ = fresh.impactQueryIndex { nameBuilds += 1; return GraphQueryIndex(graph: $0) }
        #expect(lifecycleBuilds == 2 && fileBuilds == 2 && nameBuilds == 2)
    }

    @Test("실제 영향 요청은 필요한 준비만 채우고 파일·빈 입력에 이름 색인을 만들지 않는다")
    func serviceUsesIndependentLazyCaches() throws {
        let service = service()
        for (symbols, files) in [
            ([], []), ([], ["Storage.swift"]), (["Storage"], []), (["Storage"], ["Storage.swift"]),
        ] as [([String], [String])] {
            let context = AnalysisContext(snapshot: snapshot())
            let first = try service.impactDocument(symbols: symbols, files: files, in: context)
            #expect(first == (try service.impactDocument(symbols: symbols, files: files, in: context)))
            let affected = try service.affectedDocument(symbols: symbols, files: files, in: context)
            #expect(affected == (try service.affectedDocument(
                symbols: symbols, files: files, in: AnalysisContext(snapshot: snapshot())
            )))
            var lifecycleBuilds = 0
            var fileBuilds = 0
            var nameBuilds = 0
            // 실제 서비스가 채운 값은 팩토리를 호출하지 않는다. 빠진 연결은 여기서 실패한다.
            _ = context.impactLifecycle { lifecycleBuilds += 1; return XCTestLifecycleImpact(in: $0) }
            _ = context.impactRawNodesByFile { fileBuilds += 1; return ImpactSelection.rawNodesByFile(in: $0) }
            _ = context.impactQueryIndex { nameBuilds += 1; return GraphQueryIndex(graph: $0) }
            #expect(lifecycleBuilds == 0)
            #expect(fileBuilds == (files.isEmpty ? 1 : 0))
            #expect(nameBuilds == (symbols.isEmpty ? 1 : 0))
        }
    }

    @Test("affected 도 영향과 같은 생명주기·파일·이름 준비를 채우고 다시 쓰며, 답은 차가운 문맥과 같다")
    func affectedSharesImpactPreparation() throws {
        let service = service()
        for (symbols, files) in [
            ([], ["Storage.swift"]), (["Storage"], []), (["Child"], []), (["Storage", "Missing"], ["Missing.swift"]),
        ] as [([String], [String])] {
            let context = AnalysisContext(snapshot: snapshot())
            let first = try service.affectedDocument(symbols: symbols, files: files, in: context)
            var lifecycleBuilds = 0
            var fileBuilds = 0
            var nameBuilds = 0
            // affected 가 채운 값이면 팩토리를 부르지 않는다. 연결이 빠지면 여기서 1이 된다.
            _ = context.impactLifecycle { lifecycleBuilds += 1; return XCTestLifecycleImpact(in: $0) }
            _ = context.impactRawNodesByFile { fileBuilds += 1; return ImpactSelection.rawNodesByFile(in: $0) }
            _ = context.impactQueryIndex { nameBuilds += 1; return GraphQueryIndex(graph: $0) }
            #expect(lifecycleBuilds == 0)
            #expect(fileBuilds == (files.isEmpty ? 1 : 0))
            #expect(nameBuilds == (symbols.isEmpty ? 1 : 0))
            let cold = try service.affectedDocument(
                symbols: symbols, files: files, in: AnalysisContext(snapshot: snapshot())
            )
            #expect(first == cold)
            #expect(try service.affectedDocument(symbols: symbols, files: files, in: context) == cold)
            #expect(try JSONEncoder.cartographDefault().encode(first) == JSONEncoder.cartographDefault().encode(cold))
        }
        let inherited = try service.affectedDocument(symbols: ["Storage"], in: AnalysisContext(snapshot: snapshot()))
        #expect(inherited.tests.contains { $0.symbol.usr == "parameterized" })
        #expect(inherited.tests.contains { $0.symbol.usr == "asyncTest" })
    }

    @Test("동시 요청도 각 준비를 한 번만 만들고 완성된 불변 값을 공유한다")
    func concurrentConstructionIsSingle() {
        let context = AnalysisContext(snapshot: snapshot())
        _ = context.buildGraph(level: .symbol)
        let counts = PreparationCounts()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = context.impactLifecycle { counts.record(0); return XCTestLifecycleImpact(in: $0) }
            _ = context.impactRawNodesByFile { counts.record(1); return ImpactSelection.rawNodesByFile(in: $0) }
            _ = context.impactQueryIndex { counts.record(2); return GraphQueryIndex(graph: $0) }
        }
        #expect(counts.values == [1, 1, 1])
    }

    @Test("상속 테스트·익스텐션 훅·매개변수 이름과 깊이·표시 한도는 차가운 문맥과 완전히 같다")
    func warmDocumentsEqualFreshDocuments() throws {
        let service = service()
        let warm = AnalysisContext(snapshot: snapshot())
        let depths: [Int?] = [nil, 1]
        for depth in depths {
            for limit in [1, 200] {
                for (symbols, files) in [
                    (["Storage"], []), ([], ["Storage.swift"]), (["Child"], []),
                    (["Storage", "Missing"], ["Missing.swift"]),
                ] as [([String], [String])] {
                    let expected = try service.impactDocument(
                        symbols: symbols, files: files, maxDepth: depth, limit: limit,
                        in: AnalysisContext(snapshot: snapshot())
                    )
                    let actual = try service.impactDocument(
                        symbols: symbols, files: files, maxDepth: depth, limit: limit, in: warm
                    )
                    #expect(actual == expected)
                    #expect(try JSONEncoder.cartographDefault().encode(actual)
                        == JSONEncoder.cartographDefault().encode(expected))
                }
            }
        }
        let lifecycle = warm.impactLifecycle()
        #expect(lifecycle.testClasses == ["Base", "Child", "Grandchild"])
        #expect(lifecycle.dependencies.contains { $0.source == "Grandchild" && $0.target == "hook" })
        #expect(lifecycle.dependencies.contains { $0.source == "Child" && $0.target == "asyncTest" })
        #expect(!lifecycle.dependencies.contains { $0.target == "overload" || $0.target == "helper" })
        let document = try service.impactDocument(symbols: ["Storage"], in: warm)
        #expect(document.tests.contains { $0.usr == "parameterized" })
        #expect(document.tests.contains { $0.usr == "asyncTest" })
    }

    @Test("요청별 런타임 계약과 실행 trace는 준비 캐시에 남지 않는다")
    func runtimeInputsRemainRequestScoped() throws {
        let service = service()
        let context = AnalysisContext(snapshot: snapshot())
        let original = try service.makeImpactDocument(symbols: ["Storage"], in: context).document
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "route", source: "RuntimeCaller", target: "Storage", mechanism: .callback,
                  requiredScenarios: ["launch"]),
        ])
        let declared = try service.makeImpactDocument(
            symbols: ["Storage"], runtimeContracts: contracts, in: context
        ).document
        #expect(declared.affected.contains { $0.symbol.usr == "RuntimeCaller" && $0.relationship == "runtimeContract" })
        let event = RuntimeTraceEvent(api: "NSObject.performSelector", phase: "invocation-returned", result: true)
        let findings = [RuntimeTraceFinding(
            ordinal: 0, event: event, status: .observed, source: "RuntimeCaller", targets: ["Storage"]
        )]
        let observed = try service.makeImpactDocument(
            symbols: ["Storage"], runtimeTrace: RuntimeTraceReport(findings: findings), in: context
        ).document
        #expect(observed.affected.contains { $0.symbol.usr == "RuntimeCaller" })
        let stale = try service.makeImpactDocument(
            symbols: ["Storage"],
            runtimeTrace: RuntimeTraceReport(findings: findings, evidenceCurrent: false), in: context
        ).document
        #expect(!stale.affected.contains { $0.symbol.usr == "RuntimeCaller" })
        #expect(try service.makeImpactDocument(symbols: ["Storage"], in: context).document == original)
    }

    @Test("원래 경로의 정규화 충돌과 같은 경로의 리소스 대상은 합집합으로 남는다")
    func normalizedCollisionsAndResourceOverlapArePreserved() {
        var builder = SnapshotBuilder()
        builder.symbol("left", path: "/p/Folder/../Same.swift")
        builder.symbol("right", path: "/p/Same.swift")
        builder.symbol("resource", path: "/p/Other.swift")
        let context = AnalysisContext(snapshot: builder.build())
        let graph = context.buildGraph(level: .symbol).graph
        for _ in 0..<3 {
            let actual = ImpactSelection(
                symbols: [], files: ["Same.swift", "./Same.swift", "Missing.swift"],
                projectPath: "/p", graph: graph, artifactTargets: ["/p/Same.swift": ["resource", "right"]],
                makeRawFileIndex: { _ in context.impactRawNodesByFile() }
            )
            let expected = ImpactSelection(
                symbols: [], files: ["Same.swift", "./Same.swift", "Missing.swift"],
                projectPath: "/p", graph: graph, artifactTargets: ["/p/Same.swift": ["resource", "right"]]
            )
            #expect(actual.selected == ["left", "right", "resource"])
            #expect(actual.selected == expected.selected && actual.nodes == expected.nodes)
            #expect(actual.files == expected.files && actual.issues == expected.issues)
            #expect(actual.status == expected.status && actual.requestedSymbolCount == expected.requestedSymbolCount)
        }
    }

    @Test("파일 조회는 모든 원래 경로를 해석하지만 관련 없는 정점 배열은 결과에 복사하지 않는다")
    func materializesOnlySelectedFileIDs() {
        let noise = (0..<20_000).map { NodeID("noise-\($0)") }
        let raw: [String: [NodeID]] = [
            "/p/Folder/../Same.swift": ["left"],
            "/p/Same.swift": ["right"],
            "/p/Other.swift": noise,
        ]
        let selected = ImpactSelection.nodesBySelectedFile(raw, selecting: ["/p/Same.swift"])
        #expect(Set(selected.keys) == ["/p/Same.swift"])
        #expect(Set(selected["/p/Same.swift"] ?? []) == ["left", "right"])
        #expect(selected.values.reduce(0) { $0 + $1.count } == 2)
        #expect(ImpactSelection.nodesBySelectedFile(raw, selecting: ["/p/Missing.swift"]).isEmpty)
        #expect(ImpactSelection.nodesBySelectedFile(raw, selecting: ["/p/Other.swift"])["/p/Other.swift"] == noise)
    }

    @Test("같은 직접 문맥을 재사용해도 링크 재지정 뒤 파일 선택은 현재 링크 대상을 따른다")
    func symlinkRetargetIsNotFrozenByRawGrouping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.swift")
        let second = root.appendingPathComponent("Second.swift")
        let link = root.appendingPathComponent("Link.swift")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        var builder = SnapshotBuilder()
        builder.symbol("linked", path: link.path)
        let snapshot = builder.build()
        let context = AnalysisContext(snapshot: snapshot)
        let service = service(snapshot: snapshot, projectPath: root.path)
        let before = try service.impactDocument(files: [first.path], in: context)
        #expect(before.selected.compactMap(\.usr) == ["linked"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        let after = try service.impactDocument(files: [second.path], in: context)
        #expect(after.selected.compactMap(\.usr) == ["linked"])
        #expect(after == (try service.impactDocument(files: [second.path], in: AnalysisContext(snapshot: snapshot))))
        let old = try service.impactDocument(files: [first.path], in: context)
        #expect(old.status == "incomplete" && old.selected.isEmpty)
    }

    @Test("별도 보충 문맥의 새 심볼·파일·테스트 준비는 기본 문맥을 오염시키지 않는다")
    func supplementalContextHasIndependentPreparation() throws {
        let baseSnapshot = snapshot()
        let base = AnalysisContext(snapshot: baseSnapshot)
        let service = service()
        let before = try service.impactDocument(files: ["Generated.swift"], in: base)
        var builder = SnapshotBuilder(path: "/p/Generated.swift")
        builder.symbol("Generated", kind: .classType, attributes: [.unitTest])
        let extra = builder.build()
        let augmented = AnalysisContext(
            snapshot: IndexSnapshot(
                symbols: baseSnapshot.symbols + extra.symbols, references: baseSnapshot.references
            ),
            supplementalRuntimeSourcePaths: ["/p/Generated.swift"]
        )
        let supplemental = try service.impactDocument(files: ["Generated.swift"], in: augmented)
        #expect(supplemental.selected.compactMap(\.usr) == ["Generated"])
        #expect(augmented.impactLifecycle().testClasses.contains("Generated"))
        #expect(!base.impactLifecycle().testClasses.contains("Generated"))
        #expect(try service.impactDocument(files: ["Generated.swift"], in: base) == before)
        #expect(base.impactQueryIndex().resolve("Generated") == .notFound)
        #expect(augmented.impactQueryIndex().resolve("Generated") != .notFound)
    }


    @Test("준비된 이름 색인도 다른 모듈의 동명 타입·멤버를 합치지 않는다")
    func cachedSelectionsPreserveModuleIdentity() throws {
        var builder = SnapshotBuilder(path: "/p/Types.swift")
        for module in ["First", "Second"] {
            builder.symbol(module + "Type", name: "Shared", module: module)
            builder.symbol(module + "Member", name: "work()", kind: .method,
                           module: module, parent: module + "Type")
            builder.symbol(module + "Caller", name: "caller()", kind: .function, module: module)
            builder.reference(from: module + "Caller", to: module + "Member", kind: .call)
        }
        let snapshot = builder.build()
        let service = service(snapshot: snapshot)
        let warm = AnalysisContext(snapshot: snapshot)
        let graph = warm.buildGraph(level: .symbol).graph
        let subjects = ["Shared", "work()", "Shared.work", "FirstType", "SecondType",
                        "FirstMember", "SecondMember", "First.Shared.work", "Second.Shared.work"]
        for _ in 0..<3 {
            for subject in subjects {
                let actual = try service.impactDocument(symbols: [subject], in: warm)
                let expected = try service.impactDocument(
                    symbols: [subject], in: AnalysisContext(snapshot: snapshot))
                #expect(actual == expected)
                #expect(try JSONEncoder.cartographDefault().encode(actual)
                    == JSONEncoder.cartographDefault().encode(expected))
                if ["Shared", "work()", "Shared.work"].contains(subject) {
                    #expect(actual.status == "incomplete" && actual.selected.isEmpty && actual.changeScope.isEmpty)
                    #expect(actual.selectionIssues.count == 1)
                    let issue = try #require(actual.selectionIssues.first)
                    #expect(issue.status == "ambiguous")
                    let candidates = try #require(issue.candidates)
                    #expect(candidates.count == 2)
                    #expect(Set(candidates.compactMap(\.module)) == ["First", "Second"])
                    #expect(Set(candidates.compactMap(\.usr)) == (subject == "Shared"
                        ? ["FirstType", "SecondType"] : ["FirstMember", "SecondMember"]))
                } else {
                    let module = subject.hasPrefix("First") ? "First" : "Second"
                    let id = subject.contains(".") ? module + "Member" : subject
                    #expect(actual.status == "found" && actual.selectionIssues.isEmpty)
                    #expect(actual.selected.compactMap(\.usr) == [id])
                    #expect(actual.selected.compactMap(\.module) == [module])
                    #expect(actual.changeScope.allSatisfy { $0.module == module })
                    #expect(Set(actual.changeScope.compactMap(\.usr)) == (id.hasSuffix("Type")
                        ? [module + "Type", module + "Member"] : [module + "Member"]))
                    #expect(actual.affected.map { $0.symbol.usr } == [module + "Caller"])
                    #expect(graph.node(NodeID(id))?.module == module)
                }
            }
        }
    }

    private func snapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "App", path: "/p/Tests.swift")
        builder.symbol("Storage", kind: .function, path: "/p/Storage.swift")
        builder.symbol("RuntimeCaller", kind: .function, path: "/p/Runtime.swift")
        builder.symbol("Base", kind: .classType, attributes: [.unitTest])
        builder.symbol("Extension", kind: .extensionDeclaration)
        builder.reference(from: "Extension", to: "Base", kind: .extends)
        builder.symbol("hook", name: "setUpWithError()", kind: .method, parent: "Extension")
        builder.symbol("helper", name: "helper()", kind: .method, parent: "Base")
        builder.symbol("overload", name: "setUp(_:)", kind: .method, parent: "Base")
        builder.symbol("asyncTest", name: "testAsync()", kind: .method, parent: "Base", attributes: [.unitTest])
        builder.symbol("parameterized", name: "parameterized(_:)", kind: .function, attributes: [.testFunction])
        builder.symbol("Child", kind: .classType)
        builder.symbol("Grandchild", kind: .classType)
        builder.reference(from: "Child", to: "Base", kind: .inheritance)
        builder.reference(from: "Grandchild", to: "Child", kind: .inheritance)
        builder.reference(from: "hook", to: "Storage", kind: .call)
        builder.reference(from: "asyncTest", to: "Storage", kind: .call)
        builder.reference(from: "parameterized", to: "Storage", kind: .call)
        return builder.build()
    }

    private func service(snapshot: IndexSnapshot? = nil, projectPath: String = "/p") -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = projectPath
        return CartographService(
            configuration: configuration,
            environment: .init(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(snapshot ?? self.snapshot())
            )
        )
    }
}

private final class PreparationCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    func record(_ index: Int) { lock.withLock { counts[index] += 1 } }
    var values: [Int] { lock.withLock { counts } }
}
