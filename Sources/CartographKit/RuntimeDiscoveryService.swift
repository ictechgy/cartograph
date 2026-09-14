import CartographAnalysis
import CartographCore
import CartographSyntax
import Foundation

extension CartographService {
    /// 계약 파일 없이 컴파일러·구문·리소스에서 발견한 런타임 연결을 제공한다.
    public func runtimeDiscoveryDocument(limit: Int = 200, in existingContext: AnalysisContext? = nil) throws
        -> RuntimeDiscoveryDocument {
        guard (1...10_000).contains(limit) else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Runtime discovery limit must be between 1 and 10000.")
        }
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        return RuntimeDiscoveryDocument(report: context.runtimeDiscovery(), files: context.runtimeFiles,
            graph: graph, limitations: analysisLimitations(context: context, symbolGraph: graph), limit: limit)
    }

    /// 실행 수집 전후에 같은 소스·인덱스인지 확인하고 인덱스 없는 수집을 막는다.
    public func runtimeTraceInputFingerprint() throws -> String {
        let context = try loadRuntimeEvidenceContext()
        guard let fingerprint = context.runtimeInputFingerprint else {
            throw AnalysisSessionError.unavailable
        }
        return fingerprint
    }

    /// 현재 소스와 인덱스의 같은 세대를 읽었는지 확인한 뒤 그 문맥을 실행 근거와 묶는다.
    func loadRuntimeEvidenceContext() throws -> AnalysisContext {
        let before = try sessionInputFingerprint()
        let context = try loadContext()
        guard before == (try sessionInputFingerprint()) else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Analysis inputs changed while preparing runtime collection. Retry after the build is idle.")
        }
        return context.bindingRuntimeInputFingerprint(before)
    }

    /// 리소스와 코드의 소유 관계를 경로 필터 안에서 수집한다. 기존 보존 규칙과 독립적이다.
    func runtimeResourceFacts() -> [RuntimeFileFacts] {
        let fs = environment.fileSystem
        let paths = fs.recursiveFiles(under: projectPath, isIncluded: {
            let path = $0.lowercased()
            return RuntimeResourcePath.isSupported(path)
                && configuration.pathFilter.allows($0)
        }, shouldDescend: BuildArtifactDirectories.shouldDescend(into:)).sorted()
        let modelPaths = paths.filter(RuntimeResourcePath.isCoreDataModelContents)
        let modelVersions = Dictionary(grouping: modelPaths, by: RuntimeResourcePath.coreDataModelContainer)
        let selections = Dictionary(uniqueKeysWithValues: paths.filter(RuntimeResourcePath.isCoreDataVersionSelection)
            .map { path in
                let container = RuntimeResourcePath.coreDataModelContainer(path)
                return (container, CoreDataVersionSelection.read(
                    markerPath: path, modelPaths: modelVersions[container] ?? [], fileSystem: fs
                ))
            })
        return paths.map { path in
            let container = RuntimeResourcePath.coreDataModelContainer(path)
            if RuntimeResourcePath.isCoreDataVersionSelection(path) {
                return .init(path: path, limitations: selections[container]?.reason.map { [$0] } ?? [])
            }
            do {
                let data = try fs.readData(at: path)
                guard data.count <= 8 * 1024 * 1024, let source = String(data: data, encoding: .utf8) else {
                    return .init(path: path, limitations: ["runtime-resource-unreadable: invalid or oversized XML at \(path)"])
                }
                if RuntimeResourcePath.isCoreDataModelContents(path) {
                    let selection = selections[container]
                    let reason: String?
                    if let selection {
                        reason = selection.reason ?? (selection.selectedPath == path ? nil
                            : "This is not the selected default model version; migration may still use it.")
                    } else if URL(fileURLWithPath: container).pathExtension.lowercased() == "xcdatamodeld" {
                        reason = "Core Data current version is unknown: .xccurrentversion is missing or excluded."
                    } else {
                        reason = nil
                    }
                    return CoreDataModelScanner.scan(
                        source: source,
                        path: path,
                        modelSelectionReason: reason
                    )
                }
                return RuntimeResourceScanner.scan(source: source, path: path)
            } catch {
                return .init(path: path, limitations: ["runtime-resource-unreadable: could not read \(path)"])
            }
        }
    }

    /// 파일별 unit을 확인하므로 다른 타깃을 빌드한 날짜로 낡은 소스를 가리지 않는다.
    func runtimeSourceFreshness(snapshot: IndexSnapshot, missing: [String], unreadable: [String])
        -> [String: RuntimeFreshness] {
        let absent = Set(missing)
        let failed = Set(unreadable)
        return Dictionary(uniqueKeysWithValues: snapshot.filePaths.map { path in
            let state: RuntimeFreshness
            if absent.contains(path) { state = .missingFile }
            else if failed.contains(path) { state = .unreadableFile }
            else if let indexed = snapshot.indexedFileDates?[path],
                    let modified = environment.fileSystem.modificationDate(at: path) {
                state = modified > indexed ? .sourceNewerThanIndex : .fresh
            } else { state = .unknownIndexDate }
            return (path, state)
        })
    }
}
