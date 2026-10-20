import CartographCore
@testable import CartographKit
import CartographTestSupport
import CryptoKit
import Foundation
import Testing

@Suite("런타임 실행 근거")
struct RuntimeServiceTests {
    private func fixture() -> (CartographService, InMemoryFileSystem, RuntimeContractsDocument) {
        let source = "func caller() {}\nfunc target() {}\n"
        let fileSystem = InMemoryFileSystem(
            files: ["/p/Runtime.swift": source, "/p/RuntimeProbe": "binary"]
        )
        let indexedDate = Date(timeIntervalSinceReferenceDate: 100)
        fileSystem.setModificationDate(indexedDate, for: "/p/Runtime.swift")
        fileSystem.setModificationDate(indexedDate, for: "/p/RuntimeProbe")
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("caller", name: "caller()", kind: .function, line: 1)
        builder.symbol("TargetType", kind: .classType, line: 2)
        builder.symbol(
            "target", name: "target()", kind: .method, line: 3, parent: "TargetType", attributes: [.objc]
        )
        var snapshot = builder.build()
        snapshot.indexedFileDates = ["/p/Runtime.swift": indexedDate]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)
        ))
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "open", source: "caller", target: "target", mechanism: .selector,
                  requiredScenarios: ["launch"], expectedValue: "opened"),
        ])
        return (service, fileSystem, contracts)
    }

    @Test("계획과 같은 입력의 실행은 검증하고 비어 있는 실행은 미확인으로 남긴다")
    func verifiesOnlyObservedScenarios() throws {
        let (service, fileSystem, contracts) = fixture()
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        #expect(plan.isResolved)
        #expect(plan.fingerprint.count == 64)
        #expect(plan.graphFingerprint.count == 64)
        #expect(plan.executableFingerprint.count == 64)
        let executableData = try fileSystem.readData(at: "/p/RuntimeProbe")
        let expectedExecutableFingerprint = SHA256.hash(data: executableData)
            .map { String(format: "%02x", $0) }.joined()
        #expect(plan.executableFingerprint == expectedExecutableFingerprint)
        let observed = RuntimeObservationsDocument(
            planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: [
                .init(contract: "open", scenario: "launch", outcome: .observed, value: "opened"),
            ]
        )
        let checked = try service.runtimeCheck(
            contracts: contracts, observations: observed, executablePath: "/p/RuntimeProbe"
        )
        #expect(checked.status == "verified")
        #expect(checked.verifiedCount == 1)
        let empty = try service.runtimeCheck(contracts: contracts, observations: .init(
            planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: []
        ), executablePath: "/p/RuntimeProbe")
        #expect(empty.status == "incomplete")
        #expect(empty.unverifiedCount == 1)
    }

    @Test("주입 provider가 같은 파일에서 다른 그래프를 주면 계획 지문도 달라진다")
    func planFingerprintIncludesLoadedGraph() throws {
        let (service, fileSystem, contracts) = fixture()
        let first = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("caller", name: "caller()", kind: .function, line: 1)
        builder.symbol("TargetType", kind: .classType, line: 2)
        builder.symbol(
            "target", name: "target()", kind: .method, line: 3, parent: "TargetType", attributes: [.objc]
        )
        builder.symbol("extra", name: "extra()", kind: .function, line: 4)
        let changed = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: .init(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
        let second = try changed.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")

        #expect(first.inputFingerprint == second.inputFingerprint)
        #expect(first.graphFingerprint != second.graphFingerprint)
        #expect(first.fingerprint != second.fingerprint)

        var changedDates = try service.loadSnapshot()
        changedDates.indexedFileDates = [
            "/p/Runtime.swift": Date(timeIntervalSinceReferenceDate: 200),
        ]
        let dateChanged = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: .init(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(changedDates)
            )
        )
        let third = try dateChanged.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        #expect(first.inputFingerprint == third.inputFingerprint)
        #expect(first.graphFingerprint != third.graphFingerprint)
        #expect(first.fingerprint != third.fingerprint)
    }

    @Test("소스 unit 날짜가 불명확하거나 낡으면 계획을 resolved로 표시하지 않는다")
    func rejectsUnknownOrStaleBindingFiles() throws {
        let (service, fileSystem, contracts) = fixture()
        fileSystem.setModificationDate(Date(timeIntervalSinceReferenceDate: 101), for: "/p/Runtime.swift")
        let stale = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        #expect(stale.bindings.first?.status == .unverifiedSource)
        #expect(stale.bindings.first?.sourceFreshness == .sourceNewerThanIndex)
        #expect(!stale.isResolved)

        fileSystem.setReadError(.fileReadNoSuchFile, for: "/p/Runtime.swift")
        let missing = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        #expect(missing.bindings.first?.status == .unverifiedSource)
        #expect(missing.bindings.first?.sourceFreshness == .missingFile)
    }

    @Test("실행 파일 지문이 다르면 현재 계획 지문을 복사해도 stale로 남긴다")
    func rejectsDifferentExecutable() throws {
        let (service, fileSystem, contracts) = fixture()
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        try fileSystem.write(text: "new binary", to: "/p/RuntimeProbe")
        let copiedPlanFingerprint = RuntimeObservationsDocument(
            planFingerprint: try service.runtimePlan(
                contracts: contracts, executablePath: "/p/RuntimeProbe"
            ).fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: [
                .init(contract: "open", scenario: "launch", outcome: .observed, value: "opened"),
            ]
        )

        let checked = try service.runtimeCheck(
            contracts: contracts,
            observations: copiedPlanFingerprint,
            executablePath: "/p/RuntimeProbe"
        )

        #expect(checked.status == "stale")
        #expect(checked.executableFingerprint != checked.observationExecutableFingerprint)

        // 과거 관측을 그대로 넘기는 일반 경로도 실행 파일 변경을 특정 소스 변경으로 단정하지 않는다.
        let oldObservations = RuntimeObservationsDocument(planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint, producer: "test",
            observations: copiedPlanFingerprint.observations)
        let oldChecked = try service.runtimeCheck(contracts: contracts, observations: oldObservations,
            executablePath: "/p/RuntimeProbe")
        #expect(oldChecked.status == "stale")
        #expect(oldChecked.limitations.contains { $0.hasPrefix("stale-runtime-executable:") })
        #expect(oldChecked.limitations.contains { $0.hasPrefix("stale-runtime-observations:") && $0.contains("executable") })
    }

    @Test("한 파일에 선언이 많아도 런타임 신선도는 파일마다 한 번만 디스크에 묻는다")
    func freshnessQueriesEachFileOnce() throws {
        // 판정은 파일의 성질이다. 정점마다 물으면 선언 수만큼 같은 존재 확인·시각 조회를 되풀이한다.
        let few = try freshnessQueries(extraDeclarations: 0)
        let many = try freshnessQueries(extraDeclarations: 30)
        #expect(many.existenceChecks == few.existenceChecks)
        #expect(many.dateQueries == few.dateQueries)
        // 같은 파일의 정점은 모두 같은 판정을 받는다. 계약의 양 끝이 같은 파일에 있다.
        #expect(many.binding?.sourceFreshness == .sourceNewerThanIndex)
        #expect(many.binding?.targetFreshness == .sourceNewerThanIndex)
        #expect(few.binding?.targetFreshness == .sourceNewerThanIndex)
    }

    private func freshnessQueries(extraDeclarations: Int) throws
        -> (existenceChecks: Int, dateQueries: Int, binding: RuntimeBinding?) {
        let base = InMemoryFileSystem(files: [
            "/p/Runtime.swift": "func caller() {}\nfunc target() {}\n", "/p/RuntimeProbe": "binary",
        ])
        base.setModificationDate(Date(timeIntervalSinceReferenceDate: 101), for: "/p/Runtime.swift")
        base.setModificationDate(Date(timeIntervalSinceReferenceDate: 100), for: "/p/RuntimeProbe")
        let fileSystem = QueryCountingRuntimeFileSystem(base: base)
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("caller", name: "caller()", kind: .function, line: 1)
        builder.symbol("TargetType", kind: .classType, line: 2)
        builder.symbol(
            "target", name: "target()", kind: .method, line: 3, parent: "TargetType", attributes: [.objc]
        )
        for index in 0..<extraDeclarations {
            builder.symbol("helper\(index)", name: "helper\(index)()", kind: .function, line: 4 + index)
        }
        var snapshot = builder.build()
        snapshot.indexedFileDates = ["/p/Runtime.swift": Date(timeIntervalSinceReferenceDate: 100)]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)
        ))
        let contracts = RuntimeContractsDocument(contracts: [
            .init(id: "open", source: "caller", target: "target", mechanism: .selector,
                  requiredScenarios: ["launch"], expectedValue: "opened"),
        ])
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        let counts = fileSystem.queries(of: "/p/Runtime.swift")
        return (counts.existenceChecks, counts.dateQueries, plan.bindings.first)
    }

    @Test("결과 평가 중 입력이 바뀌면 계획을 검증된 것으로 반환하지 않는다")
    func rejectsInputChangedDuringFinalVerification() throws {
        let base = InMemoryFileSystem(files: [
            "/p/Runtime.swift": "func caller() {}\nfunc target() {}\n",
            "/p/RuntimeProbe": "binary",
        ])
        let fileSystem = MutatingRuntimeFileSystem(base: base, sourcePath: "/p/Runtime.swift")
        let (service, contracts) = makeService(fileSystem: fileSystem)

        #expect(throws: CartographError.self) {
            _ = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        }
    }

    @Test("코드나 계약이 바뀌면 예전 관측을 현재 실행 근거로 인정하지 않는다")
    func rejectsChangedSourceAndContract() throws {
        let (service, fileSystem, contracts) = fixture()
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        let observations = RuntimeObservationsDocument(
            planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: [
                .init(contract: "open", scenario: "launch", outcome: .observed, value: "opened"),
            ]
        )
        try fileSystem.write(text: "func caller() {}\nfunc target() { print(1) }", to: "/p/Runtime.swift")
        #expect(
            try service.runtimeCheck(
                contracts: contracts, observations: observations, executablePath: "/p/RuntimeProbe"
            ).status == "stale"
        )
        let changed = RuntimeContractsDocument(contracts: [
            .init(id: "open", source: "caller", target: "target", mechanism: .selector,
                  requiredScenarios: ["launch", "resume"], expectedValue: "opened"),
        ])
        #expect(
            try service.runtimeCheck(
                contracts: changed, observations: observations, executablePath: "/p/RuntimeProbe"
            ).status == "stale"
        )
    }

    @Test("실패 결과와 예상 값을 출력에 반향하지 않는다")
    func reportsFailureWithoutReflectingValues() throws {
        let (service, _, contracts) = fixture()
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        let checked = try service.runtimeCheck(contracts: contracts, observations: .init(
            planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: [
                .init(contract: "open", scenario: "launch", outcome: .observed, value: "unexpected-private-payload"),
            ]
        ), executablePath: "/p/RuntimeProbe")
        #expect(checked.status == "failed")
        let json = String(decoding: try JSONEncoder.cartographDefault().encode(checked), as: UTF8.self)
        #expect(!json.contains("unexpected-private-payload"))
        #expect(!json.contains("opened"))
    }

    @Test("손상된 문서와 비어 있는 계약은 인덱스 조회 전에 거부한다")
    func validatesRuntimeFilesBeforeAnalysis() throws {
        let (_, fileSystem, _) = fixture()
        try fileSystem.write(text: "{ broken", to: "/p/broken.json")
        try fileSystem.write(
            text: "{\"format\":\"runtime-contracts\",\"version\":1,\"contracts\":[]}",
            to: "/p/empty.json"
        )
        let store = RuntimeEvidenceStore(fileSystem: fileSystem)
        #expect(throws: CartographError.self) { try store.contracts(at: "/p/broken.json") }
        #expect(throws: CartographError.self) { try store.contracts(at: "/p/empty.json") }
        #expect(throws: CartographError.self) { try store.observations(at: "/p/missing.json") }
    }

    @Test("메모리 API도 파일 입력과 같은 계약·관측 스키마를 검증한다")
    func validatesDirectRuntimeInputs() throws {
        let (service, _, contracts) = fixture()
        let malformedContracts = RuntimeContractsDocument(format: "wrong", version: 1, contracts: contracts.contracts)
        #expect(throws: CartographError.self) {
            _ = try service.runtimePlan(contracts: malformedContracts, executablePath: "/p/RuntimeProbe")
        }

        let malformedObservations = RuntimeObservationsDocument(
            planFingerprint: "short",
            executableFingerprint: "short",
            producer: "",
            observations: []
        )
        #expect(throws: CartographError.self) {
            _ = try service.runtimeCheck(
                contracts: contracts,
                observations: malformedObservations,
                executablePath: "/p/RuntimeProbe"
            )
        }
    }

    @Test("CLI 결과는 낡은 관측을 일반 시나리오 실패와 다른 오류로 알린다")
    func commandPreservesFailureCategories() throws {
        let (service, fileSystem, contracts) = fixture()
        let encoder = JSONEncoder.cartographDefault()
        try fileSystem.write(encoder.encode(contracts), to: "/p/contracts.json")
        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")
        try fileSystem.write(encoder.encode(RuntimeObservationsDocument(
            planFingerprint: plan.fingerprint,
            executableFingerprint: plan.executableFingerprint,
            producer: "test",
            observations: []
        )), to: "/p/observations.json")
        let incomplete = try service.checkRuntime(
            contractsPath: "/p/contracts.json",
            observationsPath: "/p/observations.json",
            executablePath: "/p/RuntimeProbe"
        )
        #expect(incomplete.findingCount == 1)
        #expect(incomplete.incompleteAnalysis == nil)
        try fileSystem.write(text: "func caller() {}\nfunc target() { print(2) }", to: "/p/Runtime.swift")
        let stale = try service.checkRuntime(
            contractsPath: "/p/contracts.json",
            observationsPath: "/p/observations.json",
            executablePath: "/p/RuntimeProbe"
        )
        #expect(stale.incompleteAnalysis != nil)
    }

    @Test("계획의 그래프 지문은 예전 값 그대로라 저장된 관측이 낡은 것으로 바뀌지 않는다")
    func keepsGraphFingerprintValue() throws {
        let (service, _, contracts) = fixture()

        let plan = try service.runtimePlan(contracts: contracts, executablePath: "/p/RuntimeProbe")

        // 그래프 전체를 한 번에 JSON 으로 인코딩하던 구현이 이 픽스처에 낸 값. 바뀌면 관측이 모두 stale 이 된다.
        #expect(plan.graphFingerprint == "93994066960ca152262e7264ec432374eeb598ea2f74bb26a8811b36f5e45b1b")
    }

    @Test("그래프 지문 조각을 이으면 그래프 전체 JSON 과 같은 바이트이고 원소 4096개 단위로 나뉜다")
    func graphChunksMatchWholeEncoding() throws {
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        // 간선 3만 개가 인코딩의 대부분이다. 배열을 한 조각으로 두면 그 조각이 전체의 절반을 넘는다.
        let large = Self.richGraph(nodeCount: 3_000, edgesPerNode: 10)
        let small = Self.richGraph(nodeCount: 3, edgesPerNode: 2)
        for graph in [CodeGraph(level: .module, nodes: [], edges: []), small, large] {
            let chunks = try CartographService.encodedGraphChunks(graph)
            #expect(chunks.reduce(Data(), +) == (try encoder.encode(graph)))
        }
        let chunks = try CartographService.encodedGraphChunks(large)
        let whole = try encoder.encode(large)
        #expect(chunks.count > 10)
        #expect(chunks.allSatisfy { $0.count < whole.count / 2 })
    }

    /// 정점의 선택 필드 조합과 이스케이프가 필요한 이름·경로를 담은 그래프. 겹치는 간선은 가중치 2가 된다.
    private static func richGraph(nodeCount: Int, edgesPerNode: Int) -> CodeGraph {
        // 따옴표·슬래시·역슬래시·탭·é. 소스에 이스케이프를 쓰지 않고 바이트로 만든다.
        let awkward = String(decoding: [0x22, 0x2F, 0x5C, 0x09, 0xC3, 0xA9], as: UTF8.self)
        let nodes = (0..<nodeCount).map { index in
            GraphNode(
                id: NodeID("s:App\(index)" + awkward), name: "run(\(index))" + awkward,
                kind: SymbolKind.allCases[index % SymbolKind.allCases.count],
                module: index % 4 == 0 ? nil : "App", usr: index % 5 == 0 ? nil : "s:App\(index)",
                location: index % 6 == 0
                    ? nil : SourceLocation(path: "/p/A b/F\(index).swift", line: index + 1, column: 3),
                accessibility: Accessibility.allCases[index % Accessibility.allCases.count],
                attributes: index % 3 == 0 ? [.objc, .implicit] : [], isExternal: index % 7 == 0
            )
        }
        let kinds = EdgeKind.allCases
        let edges = nodes.indices.flatMap { index in
            (0...edgesPerNode).map { step in
                // 마지막 걸음은 첫 걸음과 같은 간선이라 합쳐져 가중치 2가 된다.
                let hop = step == edgesPerNode ? 0 : step
                return GraphEdge(source: nodes[index].id, target: nodes[(index + hop * 7 + 1) % nodeCount].id,
                    kind: kinds[hop % kinds.count])
            }
        }
        return CodeGraph(level: .symbol, nodes: nodes, edges: edges)
    }

    private func makeService(fileSystem: any FileSystem) -> (CartographService, RuntimeContractsDocument) {
        let indexedDate = Date(timeIntervalSinceReferenceDate: 100)
        var builder = SnapshotBuilder(path: "/p/Runtime.swift")
        builder.symbol("caller", name: "caller()", kind: .function, line: 1)
        builder.symbol("TargetType", kind: .classType, line: 2)
        builder.symbol(
            "target", name: "target()", kind: .method, line: 3, parent: "TargetType", attributes: [.objc]
        )
        var snapshot = builder.build()
        snapshot.indexedFileDates = ["/p/Runtime.swift": indexedDate]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: .init(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(snapshot)
            )
        )
        let contracts = RuntimeContractsDocument(contracts: [
            .init(
                id: "open", source: "caller", target: "target", mechanism: .selector,
                requiredScenarios: ["launch"], expectedValue: "opened"
            ),
        ])
        return (service, contracts)
    }
}

private final class MutatingRuntimeFileSystem: FileSystem, @unchecked Sendable {
    private let base: InMemoryFileSystem
    private let sourcePath: String
    private let lock = NSLock()
    private var sourceReads = 0

    init(base: InMemoryFileSystem, sourcePath: String) {
        self.base = base
        self.sourcePath = sourcePath
    }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data {
        let data = try base.readData(at: path)
        let shouldMutate = lock.withLock {
            guard path == sourcePath else { return false }
            sourceReads += 1
            return sourceReads == 3
        }
        if shouldMutate {
            try base.write(text: "func caller() {}\nfunc target() { print(1) }\n", to: sourcePath)
        }
        return data
    }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] {
        try base.contentsOfDirectory(at: path)
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}

/// 경로별 존재 확인과 수정 시각 조회를 세는 파일 시스템. 판정이 정점마다 디스크를 묻는지 드러낸다.
private final class QueryCountingRuntimeFileSystem: FileSystem, @unchecked Sendable {
    private let base: InMemoryFileSystem
    private let lock = NSLock()
    private var existenceChecks: [String: Int] = [:]
    private var dateQueries: [String: Int] = [:]

    init(base: InMemoryFileSystem) {
        self.base = base
    }

    func queries(of path: String) -> (existenceChecks: Int, dateQueries: Int) {
        lock.withLock { (existenceChecks[path, default: 0], dateQueries[path, default: 0]) }
    }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool {
        lock.withLock { existenceChecks[path, default: 0] += 1 }
        return base.fileExists(at: path)
    }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] {
        try base.contentsOfDirectory(at: path)
    }
    func modificationDate(at path: String) -> Date? {
        lock.withLock { dateQueries[path, default: 0] += 1 }
        return base.modificationDate(at: path)
    }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
