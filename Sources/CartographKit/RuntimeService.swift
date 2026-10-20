import CartographAnalysis
import CartographCore
import CryptoKit
import Foundation

extension CartographService {
    /// 코드·인덱스·계약이 같은 실행 관측만 비교할 수 있도록 준비 계획에
    /// 지문을 붙인다.
    public func runtimePlan(
        contracts: RuntimeContractsDocument,
        executablePath: String
    ) throws -> RuntimePlanDocument {
        try RuntimeEvidenceStore.validateContracts(contracts)
        let prepared = try prepareRuntime(contracts: contracts, executablePath: executablePath)
        let report = RuntimeContractValidator().validate(
            contracts: contracts.contracts,
            freshness: prepared.freshness,
            in: prepared.graph
        )
        let bindings = runtimeBindings(report, contracts: contracts, graph: prepared.graph)
        try verifyRuntimeInputs(prepared, executablePath: executablePath)
        return RuntimePlanDocument(
            project: projectPath,
            fingerprint: prepared.fingerprint,
            inputFingerprint: prepared.inputFingerprint,
            graphFingerprint: prepared.graphFingerprint,
            executableFingerprint: prepared.executableFingerprint,
            bindings: bindings,
            limitations: prepared.limitations
        )
    }

    /// 외부 테스트가 기록한 관측을 검사한다. 같은 시나리오의 실패는
    /// 성공 기록에 가려지지 않는다.
    public func runtimeCheck(
        contracts: RuntimeContractsDocument,
        observations: RuntimeObservationsDocument,
        executablePath: String
    ) throws -> RuntimeCheckDocument {
        try RuntimeEvidenceStore.validateContracts(contracts)
        try RuntimeEvidenceStore.validateObservations(observations)
        let prepared = try prepareRuntime(contracts: contracts, executablePath: executablePath)
        let planMatches = prepared.fingerprint == observations.planFingerprint
        let executableMatches = prepared.executableFingerprint == observations.executableFingerprint
        let matches = planMatches && executableMatches
        let report = RuntimeContractValidator().validate(
            contracts: contracts.contracts,
            observations: observations.observations,
            observationsMatchPlan: matches,
            freshness: prepared.freshness,
            in: prepared.graph
        )
        var limitations = prepared.limitations
        if !planMatches {
            limitations.append("stale-runtime-observations: plan inputs (source, index, contract or executable) differ; "
                + "prepare a new plan and rerun the required scenarios")
        }
        if !executableMatches {
            limitations.append(
                "stale-runtime-executable: observations came from a different executable; rebuild the application "
                    + "and rerun the runtime scenarios"
            )
        }
        let document = RuntimeCheckDocument(
            project: projectPath,
            planFingerprint: prepared.fingerprint,
            executableFingerprint: prepared.executableFingerprint,
            observations: observations,
            bindings: runtimeBindings(report, contracts: contracts, graph: prepared.graph),
            unexpectedContracts: report.unexpectedContracts,
            limitations: limitations
        )
        try verifyRuntimeInputs(prepared, executablePath: executablePath)
        return document
    }

    /// 파일의 형식 오류는 인덱스보다 먼저 확인하고 계획을 JSON으로 내보낸다.
    public func planRuntime(contractsPath: String, executablePath: String) throws -> CommandOutcome {
        let contracts = try RuntimeEvidenceStore(fileSystem: environment.fileSystem).contracts(at: contractsPath)
        let plan = try runtimePlan(contracts: contracts, executablePath: executablePath)
        return CommandOutcome(output: try Self.encodeSortedJSON(plan), findingCount: plan.bindings.count {
            $0.status != .declared
        })
    }

    /// CI에서 사용 가능한 종료 의미를 만든다. 낡은 관측은 실행 실패와 구별되는
    /// 분석 불완전이다.
    public func checkRuntime(
        contractsPath: String,
        observationsPath: String,
        executablePath: String
    ) throws -> CommandOutcome {
        let store = RuntimeEvidenceStore(fileSystem: environment.fileSystem)
        let contracts = try store.contracts(at: contractsPath)
        let observations = try store.observations(at: observationsPath)
        let document = try runtimeCheck(
            contracts: contracts,
            observations: observations,
            executablePath: executablePath
        )
        return CommandOutcome(
            output: try Self.encodeSortedJSON(document),
            findingCount: document.failureCount + document.unverifiedCount,
            incompleteAnalysis: document.status == "stale"
                ? "Runtime observations belong to a different plan or executable. Prepare a new plan and rerun "
                    + "the scenarios." : nil
        )
    }

    private struct PreparedRuntime {
        let graph: CodeGraph
        let fingerprint: String
        let inputFingerprint: String
        let graphFingerprint: String
        let executableFingerprint: String
        let freshness: [NodeID: RuntimeFreshness]
        let limitations: [String]
    }

    private func prepareRuntime(
        contracts: RuntimeContractsDocument,
        executablePath: String
    ) throws -> PreparedRuntime {
        let before = try sessionInputFingerprint()
        let executableFingerprint = try hashExecutable(at: executablePath)
        let context = try loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let after = try sessionInputFingerprint()
        guard before == after else {
            throw runtimeInputsChanged()
        }
        let graphChunks = try Self.encodedGraphChunks(graph)
        let indexedDateFingerprint = try Self.digest(context.snapshot.sourceFreshnessDates ?? [:])
        let graphFingerprint = Self.digest(chunkedParts: [
            graphChunks,
            [Data(indexedDateFingerprint.utf8)],
        ])
        let contractData = try JSONEncoder.cartographDefault(prettyPrinted: false).encode(contracts)
        let fingerprint = Self.digest(parts: [
            Data("runtime-plan-v2".utf8),
            Data(before.utf8),
            Data(graphFingerprint.utf8),
            Data(executableFingerprint.utf8),
            contractData,
        ])
        return .init(graph: graph, fingerprint: fingerprint, inputFingerprint: before,
            graphFingerprint: graphFingerprint,
            executableFingerprint: executableFingerprint,
            freshness: runtimeFreshness(in: context, graph: graph),
            limitations: analysisLimitations(context: context, symbolGraph: graph))
    }

    private func hashExecutable(at path: String) throws -> String {
        let resolved = path.hasPrefix("/")
            ? path
            : (environment.fileSystem.currentDirectoryPath as NSString).appendingPathComponent(path)
        guard !Self.isSensitiveExecutablePath(resolved) else {
            throw CartographError.invalidConfiguration(
                path: resolved,
                reason: "The executable path points to a credential-like file; pass the built application binary."
            )
        }
        guard environment.fileSystem.fileExists(at: resolved) else {
            throw CartographError.invalidConfiguration(
                path: resolved,
                reason: "The executable does not exist. Build the application and pass --executable <path>."
            )
        }
        // 계획 문서와 실행 producer가 같은 표준 SHA-256 바이트 지문을 교환해야
        // 실행 파일을 바꿔치기한 관측을 정확히 구분할 수 있다. 계획·그래프 지문에
        // 쓰는 길이 프레이밍 해시를 재사용하면 producer와 항상 다른 값이 된다.
        do {
            return try executableSHA256(at: resolved)
        } catch {
            throw CartographError.invalidConfiguration(
                path: resolved,
                reason: "The executable could not be read. Check its path and permissions."
            )
        }
    }

    /// 실행 파일 내용의 표준 SHA-256(소문자 16진).
    ///
    /// 디버그 실행 파일은 수백 MB 가 되고 계획·검사마다 두 번 해시한다. 조각 읽기를 지원하는 파일 시스템은
    /// 세션 입력 지문과 같은 조각 읽기로 1 MiB 씩 해시해 메모리를 조각 크기로 묶는다. 조각 읽기도
    /// 통째 읽기(`Data(contentsOf:)`)처럼 정규 파일만 받으므로 장치·FIFO 경로는 예전과 같은 읽기 오류가 된다.
    private func executableSHA256(at path: String) throws -> String {
        let fileSystem = environment.fileSystem
        guard let chunked = fileSystem as? any ChunkedFileReading else {
            return Self.rawSHA256(try fileSystem.readData(at: path))
        }
        var hasher = SHA256()
        try chunked.readChunks(at: path, chunkSize: 1_048_576) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSensitiveExecutablePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let names: Set<String> = [
            ".env", "auth.json", "auth.plist", "credentials.json", "credentials.plist",
            "secrets.json", "secrets.plist", "secrets.yml", "secrets.yaml",
        ]
        return names.contains(name)
            || name.hasPrefix(".env.")
            || [".pem", ".key", ".p12", ".p8", ".mobileprovision"].contains {
                name.hasSuffix($0)
            }
    }

    private func verifyRuntimeInputs(
        _ prepared: PreparedRuntime,
        executablePath: String
    ) throws {
        let input = try sessionInputFingerprint()
        let executable = try hashExecutable(at: executablePath)
        guard input == prepared.inputFingerprint, executable == prepared.executableFingerprint else {
            throw runtimeInputsChanged()
        }
    }

    private func runtimeInputsChanged() -> CartographError {
        .invalidConfiguration(
            path: projectPath,
            reason: "Source, index, configuration or executable inputs changed during runtime analysis; "
                + "rerun after the build is idle."
        )
    }

    private func runtimeFreshness(
        in context: AnalysisContext,
        graph: CodeGraph
    ) -> [NodeID: RuntimeFreshness] {
        let fileSystem = environment.fileSystem
        let indexedDates = Dictionary(
            (context.snapshot.sourceFreshnessDates ?? [:]).map {
                (fileSystem.canonicalPath($0.key), $0.value)
            },
            uniquingKeysWith: min
        )
        let missing = Set(context.missingSourcePaths.map(fileSystem.canonicalPath))
        let unreadable = Set(context.unreadableSourcePaths.map(fileSystem.canonicalPath))
        // 판정은 파일의 성질인데 한 파일에 정점이 수십 개다. 경로마다 한 번만 디스크에 묻고 정점은 조회만 한다.
        var byPath: [String: RuntimeFreshness] = [:]
        return graph.sortedNodes.reduce(into: [:]) { result, node in
            guard let path = node.location?.path else {
                result[node.id] = .unknownIndexDate
                return
            }
            if let known = byPath[path] {
                result[node.id] = known
                return
            }
            let freshness = runtimeFreshness(
                ofFile: path, indexedDates: indexedDates, missing: missing, unreadable: unreadable
            )
            byPath[path] = freshness
            result[node.id] = freshness
        }
    }

    /// 파일 하나의 런타임 신선도. 없는 파일 → 읽기 실패 → 인덱스 시각 비교 순서로 판정한다.
    private func runtimeFreshness(
        ofFile path: String,
        indexedDates: [String: Date],
        missing: Set<String>,
        unreadable: Set<String>
    ) -> RuntimeFreshness {
        let fileSystem = environment.fileSystem
        let canonical = fileSystem.canonicalPath(path)
        if missing.contains(canonical) || !fileSystem.fileExists(at: path) { return .missingFile }
        if unreadable.contains(canonical) { return .unreadableFile }
        guard let indexed = indexedDates[canonical], let modified = fileSystem.modificationDate(at: path) else {
            return .unknownIndexDate
        }
        return modified > indexed ? .sourceNewerThanIndex : .fresh
    }

    private static func encodedData<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.cartographDefault(prettyPrinted: false).encode(value)
    }

    /// `encodedData(graph)` 와 같은 바이트를 조각 목록으로 만든다. 이어 붙이면 그래프 전체 인코딩이다.
    ///
    /// 그래프 전체를 한 번에 인코딩하면 인코더가 정점·간선마다 중간 값을 만들어 출력과 함께 들고 있어, 정점 10만·
    /// 간선 53만에서 약 580 MB 를 더 쓴다(이 방식은 약 190 MB). 이 바이트의 해시는 저장된 관측의 계획 지문과
    /// 비교되므로 값을 바꿀 수 없다. 비압축 JSON 은 배열 원소를 따로 인코딩해 쉼표로 이어도 같은 바이트이므로,
    /// 간선·정점을 4096개씩 배열로 인코딩해 대괄호를 떼고 잇는다. 최상위 키는 `.sortedKeys` 가 쓰는 순서
    /// (edges·level·nodes)로 둔다. 길이 접두사 해시에 전체 길이가 먼저 필요해 출력 바이트는 들고 있되, 인코더
    /// 중간 값은 4096개 몫만 남는다.
    static func encodedGraphChunks(_ graph: CodeGraph) throws -> [Data] {
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        var chunks = [Data(#"{"edges":["#.utf8)]
        try appendEncodedElements(graph.edges, encoder: encoder, to: &chunks)
        chunks.append(Data(#"],"level":"#.utf8))
        chunks.append(try encoder.encode(graph.level))
        chunks.append(Data(#","nodes":["#.utf8))
        try appendEncodedElements(graph.sortedNodes, encoder: encoder, to: &chunks)
        chunks.append(Data("]}".utf8))
        return chunks
    }

    private static func appendEncodedElements<Element: Encodable>(
        _ elements: [Element], encoder: JSONEncoder, to chunks: inout [Data]
    ) throws {
        for start in stride(from: 0, to: elements.count, by: 4096) {
            let encoded = try encoder.encode(Array(elements[start..<min(start + 4096, elements.count)]))
            if start > 0 { chunks.append(Data(",".utf8)) }
            chunks.append(encoded.dropFirst().dropLast())
        }
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        digest(try encodedData(value))
    }

    private static func digest(_ data: Data) -> String {
        digest(parts: [data])
    }

    private static func rawSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(parts: [Data]) -> String {
        digest(chunkedParts: parts.map { [$0] })
    }

    /// 부분마다 전체 길이(big-endian UInt64)를 앞에 두고 내용을 잇는 SHA-256. 한 부분을 여러 조각으로 넘겨도
    /// 조각을 이은 한 부분을 넘긴 것과 같은 값이다.
    private static func digest(chunkedParts parts: [[Data]]) -> String {
        var hasher = SHA256()
        for chunks in parts {
            var length = UInt64(chunks.reduce(0) { $0 + $1.count }).bigEndian
            let prefix = withUnsafeBytes(of: &length) { Data($0) }
            hasher.update(data: prefix)
            chunks.forEach { hasher.update(data: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func runtimeBindings(
        _ report: RuntimeContractReport, contracts: RuntimeContractsDocument, graph: CodeGraph
    ) -> [RuntimeBinding] {
        let byID = Dictionary(contracts.contracts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return report.results.compactMap { result in
            guard let contract = byID[result.contractID] else { return nil }
            return RuntimeBinding(
                contractID: result.contractID, mechanism: contract.mechanism,
                requiredScenarios: contract.requiredScenarios.sorted(),
                source: result.source.map(Self.describe), target: result.target.map(Self.describe),
                status: result.status,
                sourceFreshness: result.sourceFreshness,
                targetFreshness: result.targetFreshness,
                sourceCandidates: Self.candidates(Array(result.sourceCandidates.prefix(20)), in: graph),
                targetCandidates: Self.candidates(Array(result.targetCandidates.prefix(20)), in: graph),
                sourceCandidateCount: result.sourceCandidates.count,
                targetCandidateCount: result.targetCandidates.count,
                observedScenarios: result.observedScenarios, missingScenarios: result.missingScenarios,
                failedScenarios: result.failedScenarios
            )
        }
    }
}
