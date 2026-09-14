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
        let graphData = try Self.encodedData(graph)
        let indexedDateFingerprint = try Self.digest(context.snapshot.indexedFileDates ?? [:])
        let graphFingerprint = Self.digest(parts: [
            graphData,
            Data(indexedDateFingerprint.utf8),
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
        let data: Data
        do {
            data = try environment.fileSystem.readData(at: resolved)
        } catch {
            throw CartographError.invalidConfiguration(
                path: resolved,
                reason: "The executable could not be read. Check its path and permissions."
            )
        }
        // 계획 문서와 실행 producer가 같은 표준 SHA-256 바이트 지문을 교환해야
        // 실행 파일을 바꿔치기한 관측을 정확히 구분할 수 있다. 계획·그래프 지문에
        // 쓰는 길이 프레이밍 해시를 재사용하면 producer와 항상 다른 값이 된다.
        return Self.rawSHA256(data)
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
            (context.snapshot.indexedFileDates ?? [:]).map {
                (fileSystem.canonicalPath($0.key), $0.value)
            },
            uniquingKeysWith: min
        )
        let missing = Set(context.missingSourcePaths.map(fileSystem.canonicalPath))
        let unreadable = Set(context.unreadableSourcePaths.map(fileSystem.canonicalPath))
        return graph.sortedNodes.reduce(into: [:]) { result, node in
            guard let path = node.location?.path else {
                result[node.id] = .unknownIndexDate
                return
            }
            let canonical = fileSystem.canonicalPath(path)
            if missing.contains(canonical) || !fileSystem.fileExists(at: path) {
                result[node.id] = .missingFile
                return
            }
            if unreadable.contains(canonical) {
                result[node.id] = .unreadableFile
                return
            }
            guard let indexed = indexedDates[canonical],
                  let modified = fileSystem.modificationDate(at: path)
            else {
                result[node.id] = .unknownIndexDate
                return
            }
            result[node.id] = modified > indexed ? .sourceNewerThanIndex : .fresh
        }
    }

    private static func encodedData<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.cartographDefault(prettyPrinted: false).encode(value)
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
        var hasher = SHA256()
        for part in parts {
            var length = UInt64(part.count).bigEndian
            let prefix = withUnsafeBytes(of: &length) { Data($0) }
            hasher.update(data: prefix)
            hasher.update(data: part)
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
