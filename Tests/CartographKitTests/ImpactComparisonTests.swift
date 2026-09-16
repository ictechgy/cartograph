import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("과거 영향 비교")
struct ImpactComparisonTests {
    private static let missingRuntimeDiscovery =
        "historical-runtime-discovery: this snapshot has no captured automatic runtime discovery input"

    @Test("비교도 하나의 타입과 그 익스텐션을 같은 의미의 선택으로 해석한다")
    func comparisonUsesSemanticTypeSelection() throws {
        var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
        builder.symbol("T", name: "Thing")
        builder.symbol("E", name: "Thing", kind: .extensionDeclaration)
        builder.reference(from: "E", to: "T", kind: .extends)
        let snapshot = builder.build()
        let (document, outcome) = try comparison(current: snapshot,
            before: .init(projectRoot: "/current", snapshot: snapshot), symbols: ["Thing"])
        #expect(document.status == "found")
        #expect(!outcome.subjectNotFound)
        #expect(document.current.selected.compactMap(\.usr) == ["T"])
    }

    @Test("과거 한계를 불러와도 현재 소스의 읽기 실패 한계를 지우지 않는다")
    func retainsCurrentLimitations() throws {
        let current = snapshot(symbols: [("Root", "Root")])
        let (document, _) = try comparison(current: current,
            before: .init(projectRoot: "/current", snapshot: current, limitations: ["old-only-limit"]))
        // 빈 파일 시스템에서는 현재 인덱스의 소스를 읽지 못한다. 과거의 한계로 덮으면 이 사실이 사라진다.
        #expect(document.current.limitations.contains { $0.hasPrefix("missing-sources:") })
        #expect(document.before.limitations.contains("old-only-limit"))
        #expect(!document.current.limitations.contains("old-only-limit"))
    }

    private func service(snapshot: IndexSnapshot, fileSystem: InMemoryFileSystem = InMemoryFileSystem()) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/current"
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(snapshot)
            ),
            allowsEmptyIndex: true
        )
    }

    private func snapshot(symbols: [(String, String)], edges: [(String, String)] = []) -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
        for (usr, name) in symbols {
            builder.symbol(usr, name: name, kind: .structType)
        }
        for (source, target) in edges {
            builder.reference(from: source, to: target, kind: .call)
        }
        return builder.build()
    }

    private func writeSnapshot(
        _ document: AnalysisSnapshotDocument,
        to path: String,
        in fileSystem: InMemoryFileSystem
    ) throws {
        let data = try JSONEncoder.cartographDefault().encode(document)
        try fileSystem.write(data, to: path)
    }

    private func runtimeSnapshot(root: String) -> AnalysisSnapshotDocument {
        let sourcePath = "\(root)/Sources/App.swift"
        let declarationLocation = SourceLocation(path: sourcePath, line: 5, column: 1)
        let callLocation = SourceLocation(path: sourcePath, line: 2, column: 5)
        let symbols = [
            IndexedSymbol(usr: "caller", name: "load()", kind: .method, module: "App",
                location: .init(path: sourcePath, line: 1, column: 1)),
            IndexedSymbol(usr: "screen", name: "Screen", kind: .classType, module: "App",
                location: declarationLocation),
        ]
        let references = [
            IndexedReference(sourceUSR: "caller", targetUSR: "c:@F@NSClassFromString", kind: .call,
                location: callLocation),
        ]
        let facts = RuntimeFileFacts(
            path: sourcePath,
            declarations: [
                .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                    location: declarationLocation,
                    endLocation: .init(path: sourcePath, line: 7, column: 2),
                    objectiveCName: "App.Screen"),
            ],
            boundaries: [
                .init(kind: .classLookup, api: "NSClassFromString", location: callLocation,
                    calleeLocation: callLocation, name: "App.Screen", nameOrigin: .literal),
            ]
        )
        return AnalysisSnapshotDocument(
            projectRoot: root,
            snapshot: .init(symbols: symbols, references: references,
                indexedFileDates: [sourcePath: Date(timeIntervalSince1970: 100)]),
            runtimeFiles: [facts],
            runtimeFreshness: [sourcePath: .fresh]
        )
    }

    private func discovery(in document: AnalysisSnapshotDocument) -> RuntimeDiscoveryReport? {
        AnalysisContext(
            snapshot: document.snapshot,
            edgeKinds: Set(document.edgeKinds),
            externalRetentions: document.externalRetentions,
            runtimeFiles: document.runtimeFiles,
            runtimeFreshness: document.runtimeFreshness
        ).runtimeDiscovery()
    }

    private func comparison(
        current: IndexSnapshot,
        before: AnalysisSnapshotDocument,
        symbols: [String] = ["Root"],
        files: [String] = [],
        fileSelectionIsDerived: Bool = false,
        limit: Int = 200,
        runtimeContracts: RuntimeContractsDocument? = nil
    ) throws -> (ImpactComparisonDocument, CommandOutcome) {
        let fileSystem = InMemoryFileSystem(files: [:])
        try writeSnapshot(before, to: "/current/before.json", in: fileSystem)
        if let runtimeContracts {
            try fileSystem.write(JSONEncoder.cartographDefault().encode(runtimeContracts),
                to: "/current/contracts.json")
        }
        let outcome = try service(snapshot: current, fileSystem: fileSystem).compareImpact(
            symbols: symbols,
            files: files,
            beforePath: "/current/before.json",
            maxDepth: nil,
            limit: limit,
            format: "json",
            fileSelectionIsDerived: fileSelectionIsDerived,
            runtimeContractsPath: runtimeContracts == nil ? nil : "/current/contracts.json"
        )
        let document = try JSONDecoder().decode(ImpactComparisonDocument.self, from: Data(outcome.output.utf8))
        return (document, outcome)
    }

    @Test("삭제 선택이 과거에서 해소되어도 현재 계약이 삭제 대상을 요구하면 불완전이다")
    func historicalSelectionDoesNotHideBrokenCurrentContract() throws {
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "callback", target: "Root", mechanism: .callback, requiredScenarios: ["launch"])
        ])
        let before = AnalysisSnapshotDocument(projectRoot: "/current",
            snapshot: snapshot(symbols: [("Root", "Root")]), runtimeContracts: contracts)
        let (document, outcome) = try comparison(current: snapshot(symbols: []), before: before,
            runtimeContracts: contracts)
        #expect(document.status == "incomplete")
        #expect(document.unresolvedInputs.contains { $0.kind == "runtimeContract" && $0.status == "missingTarget" })
        #expect(outcome.incompleteAnalysis != nil)
        #expect(!outcome.subjectNotFound)
    }

    @Test("v2 왕복과 루트 이동 뒤에도 양쪽 클래스 조회의 외부 API 근거를 보존한다")
    func runtimeDiscoverySurvivesRoundTripAndRelocation() throws {
        let before = runtimeSnapshot(root: "/old")
        let encoded = try JSONEncoder.cartographDefault().encode(before)
        let decoded = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: encoded)
        try decoded.validate()
        let historical = decoded.rebased(to: "/current")
        let current = runtimeSnapshot(root: "/current")

        #expect(decoded.version == 2)
        #expect(decoded.runtimeFiles == before.runtimeFiles)
        #expect(decoded.snapshot.references.first?.targetUSR == "c:@F@NSClassFromString")
        #expect(discovery(in: current)?.findings.first?.status == .resolved)
        #expect(discovery(in: historical)?.findings.first?.status == .resolved)
        #expect(historical.runtimeFreshness["/current/Sources/App.swift"] == .fresh)
    }

    @Test("런타임 사실의 모든 위치를 옮기되 compiler USR과 리소스 ID는 유지한다")
    func rebasesEveryRuntimeLocationWithoutChangingIdentity() throws {
        let local = "/old/Sources/App.swift"
        let boundary = RuntimeBoundary(
            kind: .notificationObserver,
            api: "addObserver",
            location: .init(path: local, line: 10, column: 1),
            calleeLocation: .init(path: local, line: 10, column: 3),
            enclosingDeclarationLocation: .init(path: local, line: 8, column: 1),
            name: "event",
            receiverTypeName: "App.Screen",
            receiverTypeLocation: .init(path: local, line: 2, column: 1),
            referencedTargetLocation: .init(path: local, line: 10, column: 20),
            targetMemberName: "handle:",
            targetUSR: "s:exact-target",
            resourceObjectID: "ib-object",
            notificationName: "event",
            notificationNameLocation: .init(path: local, line: 10, column: 30),
            notificationCenterLocation: .init(path: local, line: 10, column: 40),
            notificationCenterOwnerLocation: .init(path: local, line: 10, column: 45),
            notificationObjectLocation: .init(path: local, line: 9, column: 5),
            notificationRemovalReferences: [
                .init(
                    registrationLocation: .init(path: local, line: 10, column: 20),
                    removalLocation: .init(path: local, line: 11, column: 3),
                    notificationCenterLocation: .init(path: local, line: 11, column: 1),
                    notificationCenterOwnerLocation: .init(path: local, line: 11, column: 2)
                ),
            ],
            notificationCancellationReferences: [
                .init(
                    registrationLocation: .init(path: local, line: 10, column: 20),
                    cancellationLocation: .init(path: local, line: 11, column: 8)
                ),
            ],
            keyPaths: ["leaf.text"],
            nameAPIReferences: [
                .init(api: "Notification.Name", location: .init(path: local, line: 4, column: 5)),
                .init(api: "External", location: .init(path: "/SDK/Foundation.swift", line: 1, column: 1)),
            ],
            subscriptionConsumer: .init(
                api: "onReceive", location: .init(path: local, line: 10, column: 50)
            )
        )
        let declaration = RuntimeDeclaration(
            name: "handle", indexName: "handle(_:)", qualifiedName: "Screen.handle", kind: .method,
            location: .init(path: local, line: 8, column: 1),
            endLocation: .init(path: local, line: 12, column: 2),
            parentLocation: .init(path: local, line: 2, column: 1),
            isFinal: true,
            valueTypeName: "App.Event",
            valueTypeLocation: .init(path: local, line: 8, column: 20)
        )
        let document = AnalysisSnapshotDocument(
            projectRoot: "/old",
            snapshot: .init(),
            runtimeFiles: [.init(path: local, declarations: [declaration], boundaries: [boundary])],
            runtimeFreshness: [local: .fresh]
        ).rebased(to: "/new")

        let facts = try #require(document.runtimeFiles?.first)
        let movedDeclaration = try #require(facts.declarations.first)
        let movedBoundary = try #require(facts.boundaries.first)
        #expect(facts.path == "/new/Sources/App.swift")
        let declarationPaths = [
            movedDeclaration.location.path,
            movedDeclaration.endLocation.path,
            movedDeclaration.parentLocation?.path,
        ]
        let boundaryPaths = [
            movedBoundary.location.path,
            movedBoundary.calleeLocation?.path,
            movedBoundary.enclosingDeclarationLocation?.path,
            movedBoundary.receiverTypeLocation?.path,
            movedBoundary.referencedTargetLocation?.path,
            movedBoundary.notificationNameLocation?.path,
            movedBoundary.notificationCenterLocation?.path,
            movedBoundary.notificationCenterOwnerLocation?.path,
            movedBoundary.notificationObjectLocation?.path,
            movedBoundary.notificationRemovalReferences?.first?.registrationLocation.path,
            movedBoundary.notificationRemovalReferences?.first?.removalLocation.path,
            movedBoundary.notificationRemovalReferences?.first?.notificationCenterLocation.path,
            movedBoundary.notificationRemovalReferences?.first?.notificationCenterOwnerLocation?.path,
            movedBoundary.notificationCancellationReferences?.first?.registrationLocation.path,
            movedBoundary.notificationCancellationReferences?.first?.cancellationLocation.path,
            movedBoundary.nameAPIReferences?.first?.location.path,
            movedBoundary.subscriptionConsumer?.location.path,
        ]
        #expect(declarationPaths.allSatisfy { $0 == "/new/Sources/App.swift" })
        #expect(boundaryPaths.allSatisfy { $0 == "/new/Sources/App.swift" })
        #expect(movedBoundary.nameAPIReferences?.last?.location.path == "/SDK/Foundation.swift")
        #expect(movedBoundary.targetUSR == "s:exact-target")
        #expect(movedBoundary.resourceObjectID == "ib-object")
        #expect(movedBoundary.keyPaths == ["leaf.text"])
        #expect(movedDeclaration.isFinal)
        #expect(movedDeclaration.valueTypeName == "App.Event")
        #expect(movedDeclaration.valueTypeLocation?.path == "/new/Sources/App.swift")
        #expect(document.runtimeFreshness == ["/new/Sources/App.swift": .fresh])
    }

    @Test("v1 스냅샷은 주입된 새 필드를 믿지 않고 런타임 발견 근거 부재를 알린다")
    func legacySnapshotReportsMissingRuntimeDiscovery() throws {
        let data = try JSONEncoder.cartographDefault().encode(runtimeSnapshot(root: "/old"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 1
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let legacy = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: legacyData)
        try legacy.validate()

        #expect(legacy.version == 1)
        #expect(legacy.runtimeFiles == nil)
        #expect(legacy.runtimeFreshness.isEmpty)
        #expect(legacy.limitations.contains(Self.missingRuntimeDiscovery))
    }

    @Test("초기 v2 선언에 새 보수적 Bool 키가 없어도 스냅샷을 읽는다")
    func decodesRuntimeDeclarationsBeforeFinalAndSettableEvidence() throws {
        let data = try JSONEncoder.cartographDefault().encode(runtimeSnapshot(root: "/old"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var files = try #require(object["runtimeFiles"] as? [[String: Any]])
        var declarations = try #require(files[0]["declarations"] as? [[String: Any]])
        declarations[0].removeValue(forKey: "isFinal")
        declarations[0].removeValue(forKey: "isSettable")
        files[0]["declarations"] = declarations
        object["runtimeFiles"] = files

        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: legacyData)
        let declaration = try #require(decoded.runtimeFiles?.first?.declarations.first)

        #expect(declaration.isFinal == false)
        #expect(declaration.isSettable == false)
    }

    @Test("논리적으로 같은 런타임 입력은 순서가 달라도 같은 JSON이다")
    func runtimeSnapshotEncodingIsDeterministic() throws {
        let a = RuntimeFileFacts(path: "/p/A.swift", limitations: ["z", "a"])
        let b = RuntimeFileFacts(path: "/p/B.swift", limitations: ["b"])
        let snapshot = snapshot(symbols: [("0", "Root"), ("1", "Root")])
        let first = AnalysisSnapshotDocument(projectRoot: "/p", snapshot: snapshot,
            limitations: ["second", "first"], runtimeFiles: [b, a],
            runtimeFreshness: ["/p/B.swift": .fresh, "/p/A.swift": .unknownIndexDate])
        let second = AnalysisSnapshotDocument(projectRoot: "/p", snapshot: snapshot,
            limitations: ["first", "second"], runtimeFiles: [a, b],
            runtimeFreshness: ["/p/A.swift": .unknownIndexDate, "/p/B.swift": .fresh])

        #expect(try JSONEncoder.cartographDefault().encode(first)
            == JSONEncoder.cartographDefault().encode(second))
    }

    @Test("선택이 모두 해소되어도 한쪽 영향 목록이 잘리면 비교 전체에 표시한다")
    func childTruncationPropagates() throws {
        let current = snapshot(symbols: [("Root", "Root"), ("A", "A"), ("B", "B")],
            edges: [("A", "Root"), ("B", "Root")])
        let (document, _) = try comparison(current: current,
            before: .init(projectRoot: "/current", snapshot: current), limit: 1)
        #expect(document.unresolvedCount == 0)
        #expect(document.current.summary.affectedSymbols == 2)
        #expect(document.current.affected.count == 1)
        #expect(document.truncated)
    }

    @Test("빈 직접 API 선택보다 미해결 런타임 계약을 먼저 불완전으로 표시한다")
    func emptySelectionWithBrokenRuntimeContractIsIncomplete() throws {
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "callback", target: "Missing", mechanism: .callback, requiredScenarios: ["launch"])
        ])
        let snapshot = snapshot(symbols: [("Root", "Root")])
        let (document, outcome) = try comparison(current: snapshot,
            before: .init(projectRoot: "/current", snapshot: snapshot), symbols: [],
            runtimeContracts: contracts)
        #expect(document.status == "incomplete")
        #expect(!document.unresolvedInputs.isEmpty)
        #expect(outcome.incompleteAnalysis != nil)
    }

    @Test("삭제된 과거 심볼은 현재에 없어도 비교 입력으로 해소된다")
    func oldOnlyDeletedInputIsResolved() throws {
        let before = AnalysisSnapshotDocument(projectRoot: "/current", snapshot: snapshot(symbols: [("Root", "Root")]))
        let current = snapshot(symbols: [])
        let (document, outcome) = try comparison(current: current, before: before)
        #expect(document.status == "found")
        #expect(document.unresolvedInputs.isEmpty)
        #expect(document.current.selectionIssues.count == 1)
        #expect(outcome.subjectNotFound == false)
    }

    @Test("새로 추가된 현재 심볼은 과거에 없어도 비교 입력으로 해소된다")
    func newOnlyAddedInputIsResolved() throws {
        let before = AnalysisSnapshotDocument(projectRoot: "/current", snapshot: snapshot(symbols: []))
        let current = snapshot(symbols: [("Root", "Root")])
        let (document, outcome) = try comparison(current: current, before: before)
        #expect(document.status == "found")
        #expect(document.before.selectionIssues.count == 1)
        #expect(outcome.subjectNotFound == false)
    }

    @Test("이름 변경 입력은 양쪽 문서의 한쪽에서 해소되면 미해결이 아니다")
    func renamedInputResolvesFromEitherSide() throws {
        let before = AnalysisSnapshotDocument(projectRoot: "/current", snapshot: snapshot(symbols: [("old", "Old")]))
        let current = snapshot(symbols: [("new", "New")])
        let (document, outcome) = try comparison(current: current, before: before, symbols: ["Old"])
        #expect(document.status == "found")
        #expect(document.current.selectionIssues.count == 1)
        #expect(document.before.selectionIssues.isEmpty)
        #expect(outcome.subjectNotFound == false)
    }

    @Test("어느 한쪽이라도 모호한 입력이면 임의로 고르지 않는다")
    func ambiguityRemainsUnresolved() throws {
        let before = AnalysisSnapshotDocument(projectRoot: "/current", snapshot: snapshot(symbols: [("old", "Root")]))
        let current = snapshot(symbols: [("a", "Root"), ("b", "Root")])
        let (document, outcome) = try comparison(current: current, before: before)
        #expect(document.status == "incomplete")
        #expect(document.unresolvedInputs.count == 1)
        #expect(outcome.subjectNotFound)
    }

    @Test("양쪽 모두 없는 입력은 derived 선택이면 분석 불완전으로 끝난다")
    func absentBothIsIncompleteForDerivedSelection() throws {
        let before = AnalysisSnapshotDocument(projectRoot: "/current", snapshot: snapshot(symbols: []))
        let (document, outcome) = try comparison(
            current: snapshot(symbols: []), before: before, fileSelectionIsDerived: true
        )
        #expect(document.status == "incomplete")
        #expect(outcome.incompleteAnalysis != nil)
        #expect(!outcome.subjectNotFound)
    }

    @Test("기록 루트가 달라도 과거 로컬 위치를 현재 루트로 옮긴다")
    func rebasesLocalLocations() throws {
        var oldBuilder = SnapshotBuilder(path: "/old/Sources/App.swift")
        oldBuilder.symbol("Root", name: "Root", kind: .structType)
        let before = AnalysisSnapshotDocument(projectRoot: "/old", snapshot: oldBuilder.build(), limitations: ["captured-limit"])
        var currentBuilder = SnapshotBuilder(path: "/current/Sources/App.swift")
        currentBuilder.symbol("Root", name: "Root", kind: .structType)
        let (document, _) = try comparison(current: currentBuilder.build(), before: before)
        #expect(document.before.selected.first?.location?.path == "/current/Sources/App.swift")
        #expect(document.before.limitations.contains("captured-limit"))
    }

    @Test("서로 다른 시점의 간선을 합쳐 허위 경로를 만들지 않는다")
    func doesNotCreateCrossSnapshotPath() throws {
        let before = AnalysisSnapshotDocument(
            projectRoot: "/current",
            snapshot: snapshot(symbols: [("Root", "Root"), ("Middle", "Middle"), ("OldCaller", "OldCaller"),
                                         ("Before", "Before")], edges: [("OldCaller", "Middle"), ("Before", "Root")])
        )
        let current = snapshot(symbols: [("Root", "Root"), ("Middle", "Middle"), ("OldCaller", "OldCaller"),
                                         ("After", "After")], edges: [("Middle", "Root"), ("After", "Root")])
        let (document, _) = try comparison(current: current, before: before)
        #expect(document.current.affected.map { $0.symbol.name }.contains("After"))
        #expect(document.before.affected.map { $0.symbol.name }.contains("Before"))
        #expect(!document.current.affected.map { $0.symbol.name }.contains("Before"))
        #expect(!document.before.affected.map { $0.symbol.name }.contains("After"))
        #expect(!document.current.affected.map { $0.symbol.name }.contains("OldCaller"))
        #expect(!document.before.affected.map { $0.symbol.name }.contains("OldCaller"))
    }

    @Test("잘못된 스냅샷 형식은 인덱스를 읽기 전에 거부한다")
    func rejectsInvalidSnapshot() throws {
        let fileSystem = InMemoryFileSystem(files: ["/current/before.json": "{\"format\":\"wrong\"}"])
        let service = service(snapshot: snapshot(symbols: [("Root", "Root")]), fileSystem: fileSystem)
        #expect(throws: CartographError.self) {
            try service.compareImpact(
                symbols: ["Root"], files: [], beforePath: "/current/before.json",
                maxDepth: nil, limit: 200, format: "json"
            )
        }
    }

    @Test("캡처는 현재 그래프 범위 밖의 주석 심볼을 과거 스냅샷에 되살리지 않는다")
    func captureRespectsConfiguredPathScope() throws {
        var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
        builder.symbol("Included", name: "Included", kind: .structType, path: "/current/Sources/App.swift")
        builder.symbol("Excluded", name: "Excluded", kind: .structType, path: "/current/Generated/Excluded.swift")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/current"
        configuration.include = [GlobPattern("Sources/**")]
        builder.reference(from: "Included", to: "c:@F@NSClassFromString", kind: .call,
            path: "/current/Sources/App.swift", line: 1)
        builder.reference(from: "Excluded", to: "c:@F@NSClassFromString", kind: .call,
            path: "/current/Generated/Excluded.swift", line: 1)
        let fileSystem = InMemoryFileSystem(files: [
            "/current/Sources/App.swift": "let live = NSClassFromString(\"App.Included\")",
            "/current/Generated/Excluded.swift": "let hidden = NSClassFromString(\"App.Excluded\")",
            "/current/Sources/Model.xcdatamodel/contents":
                "<model><entity name=\"Included\" representedClassName=\"Included\"/></model>",
            "/current/Sources/Documentation/contents": "not a model",
        ])
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
        let captured = try service.captureSnapshot()
        #expect(captured.snapshot.symbols.map(\.usr) == ["Included"])
        #expect(!captured.snapshot.symbols.map(\.usr).contains("Excluded"))
        #expect(captured.snapshot.references.map(\.sourceUSR) == ["Included"])
        #expect(captured.snapshot.references.map(\.targetUSR) == ["c:@F@NSClassFromString"])
        #expect(captured.runtimeFiles?.map(\.path) == [
            "/current/Sources/App.swift", "/current/Sources/Model.xcdatamodel/contents",
        ])
        #expect(captured.runtimeFreshness.keys.sorted() == ["/current/Sources/App.swift"])
    }

    @Test("주입한 문맥의 exact supplemental 경로만 snapshot 필터 예외로 보존한다")
    func capturePreservesOnlySupplementalGeneratedRuntimeSources() throws {
        var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
        builder.symbol("Included", name: "Included", path: "/current/Sources/App.swift")
        builder.symbol("Generated", name: "Generated", path: "/current/Generated/Record.swift")
        builder.symbol("Other", name: "Other", path: "/current/Generated/Other.swift")
        let runtimeFiles = [
            RuntimeFileFacts(path: "/current/Sources/App.swift"),
            RuntimeFileFacts(path: "/current/Generated/Record.swift"),
            RuntimeFileFacts(path: "/current/Generated/Other.swift"),
        ]
        let context = AnalysisContext(
            snapshot: builder.build(),
            pathFilter: .passthrough,
            runtimeFiles: runtimeFiles,
            runtimeFreshness: Dictionary(uniqueKeysWithValues: runtimeFiles.map { ($0.path, .fresh) }),
            supplementalRuntimeSourcePaths: ["/current/Generated/Record.swift"]
        )
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/current"
        configuration.include = [GlobPattern("Sources/**")]
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(.init())
            )
        )

        let captured = try service.captureSnapshot(in: context)

        #expect(captured.runtimeFiles?.map(\.path) == [
            "/current/Generated/Record.swift", "/current/Sources/App.swift",
        ])
        #expect(captured.runtimeFreshness.keys.sorted() == [
            "/current/Generated/Record.swift", "/current/Sources/App.swift",
        ])
    }

    @Test("스냅샷은 외부 심볼 경로를 보존하고 상대 프로젝트 루트를 거부한다")
    func preservesExternalPathsAndRejectsRelativeRoot() throws {
        var builder = SnapshotBuilder(path: "/old/Sources/App.swift")
        builder.symbol("Local", name: "Local", path: "/old/Sources/App.swift")
        builder.symbol("External", name: "External", path: "/old/SDK/External.swift", isExternal: true)
        let document = AnalysisSnapshotDocument(projectRoot: "/old", snapshot: builder.build())
        let moved = document.rebased(to: "/new")
        #expect(moved.snapshot.symbols.first(where: { $0.usr == "Local" })?.location.path == "/new/Sources/App.swift")
        #expect(moved.snapshot.symbols.first(where: { $0.usr == "External" })?.location.path == "/old/SDK/External.swift")

        let invalid = AnalysisSnapshotDocument(projectRoot: "relative", snapshot: builder.build())
        #expect(throws: CartographError.self) { try invalid.validate() }
    }

    @Test("스냅샷 캡처는 대상 종류만 다른 참조도 입력 순서와 무관하게 정렬한다")
    func captureOrdersSameKeyReferencesDeterministically() throws {
        // 옛 캡처와 새 인덱스가 섞이면 소스·대상·위치·출처는 같고 대상 종류만 다른
        // 참조가 생길 수 있다. 종류를 정렬 키에 넣지 않으면 입력 순서가 출력에 남아
        // 스냅샷 diff 가 실행마다 흔들린다.
        func capture(_ targetKinds: [SymbolKind]) throws -> [IndexedReference] {
            var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
            builder.symbol("Source", name: "Source")
            for kind in targetKinds {
                builder.reference(from: "Source", to: "Target", kind: .reference,
                    targetKind: kind, origin: .compiler)
            }
            let context = AnalysisContext(snapshot: builder.build(), pathFilter: .passthrough)
            return try service(snapshot: .init()).captureSnapshot(in: context).snapshot.references
        }
        let forward = try capture([.structType, .function])
        let reversed = try capture([.function, .structType])
        #expect(forward == reversed)
        #expect(forward.map(\.targetKind) == [.function, .structType])
    }

    @Test("스냅샷 재기준화가 import 위치와 모듈 사용 근거의 경로도 옮긴다")
    func rebaseMovesImportFacts() {
        var builder = SnapshotBuilder(path: "/old/Sources/App.swift")
        builder.symbol("Local", name: "Local", path: "/old/Sources/App.swift")
        builder.importDecl("Foundation", path: "/old/Sources/App.swift", line: 1)
        builder.fileModuleUsage(path: "/old/Sources/App.swift", owningModule: "App",
            referencedModules: ["App", "Foundation"])
        // 프로젝트 밖 경로(브리징 헤더 등)의 근거는 그대로 둔다.
        builder.fileModuleUsage(path: "/sdk/Bridging.h", owningModule: "MyLib",
            referencedModules: ["MyLib"], hasUnattributedReferences: true)
        let document = AnalysisSnapshotDocument(projectRoot: "/old", snapshot: builder.build())
        let moved = document.rebased(to: "/new")
        #expect(moved.snapshot.imports.first?.location.path == "/new/Sources/App.swift")
        #expect(moved.snapshot.fileModuleUsages["/new/Sources/App.swift"]?.referencedModules
            == ["App", "Foundation"])
        #expect(moved.snapshot.fileModuleUsages["/old/Sources/App.swift"] == nil)
        #expect(moved.snapshot.fileModuleUsages["/sdk/Bridging.h"]?.hasUnattributedReferences == true)
    }

    @Test("스냅샷 캡처는 잘린 파일의 import와 모듈 사용 근거를 담지 않는다")
    func captureDropsImportFactsOfExcludedFiles() throws {
        // 남은 정점이 없는 파일의 import는 판정 재료가 못 된다 — 그대로 담으면
        // --before 비교가 어느 import가 잘렸는지 모른 채 보고한다.
        var builder = SnapshotBuilder(path: "/current/Sources/App.swift")
        builder.symbol("Included", name: "Included", path: "/current/Sources/App.swift")
        builder.importDecl("Foundation", path: "/current/Sources/App.swift", line: 1)
        builder.fileModuleUsage(path: "/current/Sources/App.swift", owningModule: "App",
            referencedModules: ["App"])
        builder.importDecl("Combine", path: "/current/Generated/Record.swift", line: 1)
        builder.fileModuleUsage(path: "/current/Generated/Record.swift", owningModule: "App",
            referencedModules: ["Combine"])
        let context = AnalysisContext(snapshot: builder.build(), pathFilter: .passthrough)
        let captured = try service(snapshot: .init()).captureSnapshot(in: context)
        #expect(captured.snapshot.imports.map(\.module) == ["Foundation"])
        #expect(captured.snapshot.fileModuleUsages.keys.sorted() == ["/current/Sources/App.swift"])
    }
}
