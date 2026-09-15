import CartographCore
import Foundation

/// 과거 인덱스와 그 문맥을 다시 분석하기 위한 자체 포함 스냅샷.
public struct AnalysisSnapshotDocument: Sendable, Equatable, Codable {
    public static let format = "analysis-snapshot"
    public static let version = 2
    public static let maximumByteCount = 128 * 1024 * 1024
    public static let missingRuntimeDiscoveryLimitation =
        "historical-runtime-discovery: this snapshot has no captured automatic runtime discovery input"

    public let format: String
    public let version: Int
    public let projectRoot: String
    public let toolVersion: String
    public let revision: String?
    public let snapshot: IndexSnapshot
    public let edgeKinds: [EdgeKind]
    public let limitations: [String]
    public let externalRetentions: ExternalRetentionsDocument?
    /// 영향 비교에 필요한 동적 계약. expectedValue는 과거 문서에 저장하지 않는다.
    public let runtimeContracts: RuntimeContractsDocument?
    /// 캡처 당시 구문과 리소스에서 본 자동 런타임 발견 입력.
    public let runtimeFiles: [RuntimeFileFacts]?
    /// 런타임 사실과 같은 시점의 파일별 인덱스 신선도.
    public let runtimeFreshness: [String: RuntimeFreshness]
    /// 캡처 당시 구문 보강에서 제외한 함수. 오래된 문서에는 없을 수 있다.
    public let localFunctionDiagnostics: [LocalFunctionDiagnostic]?

    public init(
        projectRoot: String,
        toolVersion: String = Cartograph.version,
        revision: String? = nil,
        snapshot: IndexSnapshot,
        edgeKinds: Set<EdgeKind> = [],
        limitations: [String] = [],
        externalRetentions: ExternalRetentionsDocument? = nil,
        runtimeContracts: RuntimeContractsDocument? = nil,
        runtimeFiles: [RuntimeFileFacts]? = nil,
        runtimeFreshness: [String: RuntimeFreshness] = [:],
        localFunctionDiagnostics: [LocalFunctionDiagnostic]? = nil
    ) {
        self.format = Self.format
        self.version = Self.version
        self.projectRoot = projectRoot
        self.toolVersion = toolVersion
        self.revision = revision
        self.snapshot = snapshot
        self.edgeKinds = edgeKinds.sorted()
        self.runtimeFiles = runtimeFiles.map(Self.normalizedRuntimeFiles)
        self.runtimeFreshness = runtimeFiles == nil ? [:] : runtimeFreshness
        self.localFunctionDiagnostics = localFunctionDiagnostics.flatMap { $0.isEmpty ? nil : $0 }
        self.limitations = Self.normalizedLimitations(limitations, runtimeFiles: runtimeFiles)
        self.externalRetentions = externalRetentions
        self.runtimeContracts = runtimeContracts.map(Self.withoutExpectedValues)
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, projectRoot, toolVersion, revision, snapshot, edgeKinds, limitations
        case externalRetentions, runtimeContracts, runtimeFiles, runtimeFreshness
        case localFunctionDiagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        toolVersion = try container.decode(String.self, forKey: .toolVersion)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        snapshot = try container.decode(IndexSnapshot.self, forKey: .snapshot)
        edgeKinds = try container.decode([EdgeKind].self, forKey: .edgeKinds)
        externalRetentions = try container.decodeIfPresent(
            ExternalRetentionsDocument.self,
            forKey: .externalRetentions
        )
        runtimeContracts = try container.decodeIfPresent(RuntimeContractsDocument.self, forKey: .runtimeContracts)

        // v1에는 이 계약이 없었다. 새 이름의 필드를 임의로 주입한 v1도 과거
        // 근거로 승격하지 않는다.
        let decodedFiles = version == 1
            ? nil
            : try container.decodeIfPresent([RuntimeFileFacts].self, forKey: .runtimeFiles)
        runtimeFiles = decodedFiles.map(Self.normalizedRuntimeFiles)
        runtimeFreshness = decodedFiles == nil
            ? [:]
            : try container.decodeIfPresent([String: RuntimeFreshness].self, forKey: .runtimeFreshness) ?? [:]
        let decodedLimitations = try container.decodeIfPresent([String].self, forKey: .limitations) ?? []
        limitations = Self.normalizedLimitations(decodedLimitations, runtimeFiles: decodedFiles)
        localFunctionDiagnostics = try container.decodeIfPresent(
            [LocalFunctionDiagnostic].self, forKey: .localFunctionDiagnostics
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(projectRoot, forKey: .projectRoot)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(edgeKinds, forKey: .edgeKinds)
        try container.encode(limitations, forKey: .limitations)
        try container.encodeIfPresent(externalRetentions, forKey: .externalRetentions)
        try container.encodeIfPresent(runtimeContracts, forKey: .runtimeContracts)
        try container.encodeIfPresent(runtimeFiles, forKey: .runtimeFiles)
        if runtimeFiles != nil { try container.encode(runtimeFreshness, forKey: .runtimeFreshness) }
        try container.encodeIfPresent(localFunctionDiagnostics, forKey: .localFunctionDiagnostics)
    }

    /// 문서의 형식과 입력 크기 제한을 검사한다.
    public func validate() throws {
        guard format == Self.format, version == 1 || version == Self.version else {
            throw CartographError.invalidConfiguration(
                path: projectRoot,
                reason: "Analysis snapshot must use analysis-snapshot v1 or v2."
            )
        }
        guard !projectRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CartographError.invalidConfiguration(path: projectRoot, reason: "Snapshot projectRoot is empty.")
        }
        guard projectRoot.hasPrefix("/"),
              URL(fileURLWithPath: projectRoot).standardizedFileURL.path == projectRoot else {
            throw CartographError.invalidConfiguration(
                path: projectRoot,
                reason: "Snapshot projectRoot must be a normalized absolute path."
            )
        }
        guard Set(edgeKinds).count == edgeKinds.count else {
            throw CartographError.invalidConfiguration(
                path: projectRoot,
                reason: "Snapshot edgeKinds contains duplicates."
            )
        }
        if let runtimeContracts {
            try RuntimeEvidenceStore.validateContracts(runtimeContracts, path: "snapshot runtime contracts")
        }
        if let runtimeFiles, Set(runtimeFiles.map(\.path)).count != runtimeFiles.count {
            throw CartographError.invalidConfiguration(
                path: projectRoot,
                reason: "Snapshot runtimeFiles contains duplicate paths."
            )
        }
    }

    /// 현재 프로젝트 루트로 로컬 인덱스 경로만 옮긴다.
    public func rebased(to currentProjectRoot: String) -> AnalysisSnapshotDocument {
        let symbols = snapshot.symbols.map { symbol in
            IndexedSymbol(
                usr: symbol.usr,
                name: symbol.name,
                kind: symbol.kind,
                module: symbol.module,
                location: .init(
                    path: symbol.isExternal
                        ? symbol.location.path
                        : Self.rebase(symbol.location.path, from: projectRoot, to: currentProjectRoot),
                    line: symbol.location.line,
                    column: symbol.location.column
                ),
                parentUSR: symbol.parentUSR,
                isExternal: symbol.isExternal,
                accessibility: symbol.accessibility,
                attributes: symbol.attributes
            )
        }
        let externalUSRs = Set(snapshot.symbols.filter(\.isExternal).map(\.usr))
        let references = snapshot.references.map { reference in
            IndexedReference(
                sourceUSR: reference.sourceUSR,
                targetUSR: reference.targetUSR,
                kind: reference.kind,
                location: reference.location.map {
                    .init(path: externalUSRs.contains(reference.sourceUSR)
                        ? $0.path : Self.rebase($0.path, from: projectRoot, to: currentProjectRoot),
                          line: $0.line, column: $0.column)
                },
                origin: reference.origin
            )
        }
        let dates = snapshot.indexedFileDates.map { values in
            Dictionary(values.sorted { $0.key < $1.key }.map { path, date in
                (Self.rebase(path, from: projectRoot, to: currentProjectRoot), date)
            }, uniquingKeysWith: { first, _ in first })
        }
        return AnalysisSnapshotDocument(
            projectRoot: currentProjectRoot,
            toolVersion: toolVersion,
            revision: revision,
            snapshot: .init(symbols: symbols, references: references, indexedFileDates: dates),
            edgeKinds: Set(edgeKinds),
            limitations: limitations,
            externalRetentions: externalRetentions,
            runtimeContracts: runtimeContracts,
            runtimeFiles: runtimeFiles?.map {
                Self.rebase($0, from: projectRoot, to: currentProjectRoot)
            },
            runtimeFreshness: Dictionary(runtimeFreshness.sorted { $0.key < $1.key }.map { path, freshness in
                (Self.rebase(path, from: projectRoot, to: currentProjectRoot), freshness)
            }, uniquingKeysWith: { first, _ in first }),
            localFunctionDiagnostics: localFunctionDiagnostics?.map {
                LocalFunctionDiagnostic(name: $0.name,
                    location: .init(path: Self.rebase($0.location.path, from: projectRoot, to: currentProjectRoot),
                        line: $0.location.line, column: $0.location.column),
                    ownerName: $0.ownerName, ownerUSR: $0.ownerUSR, reason: $0.reason)
            }
        )
    }

    private static func rebase(_ path: String, from recordedRoot: String, to currentRoot: String) -> String {
        let old = URL(fileURLWithPath: recordedRoot).standardizedFileURL.path
        let new = URL(fileURLWithPath: currentRoot).standardizedFileURL.path
        guard path == old || path.hasPrefix(old + "/") else { return path }
        let suffix = String(path.dropFirst(old.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? new : (new as NSString).appendingPathComponent(suffix)
    }

    private static func withoutExpectedValues(_ document: RuntimeContractsDocument) -> RuntimeContractsDocument {
        RuntimeContractsDocument(
            format: document.format,
            version: document.version,
            contracts: document.contracts.map {
                RuntimeContract(
                    id: $0.id, source: $0.source, target: $0.target, mechanism: $0.mechanism,
                    requiredScenarios: $0.requiredScenarios, expectedValue: nil
                )
            }
        )
    }

    private static func rebase(
        _ facts: RuntimeFileFacts,
        from recordedRoot: String,
        to currentRoot: String
    ) -> RuntimeFileFacts {
        RuntimeFileFacts(
            path: rebase(facts.path, from: recordedRoot, to: currentRoot),
            declarations: facts.declarations.map {
                RuntimeDeclaration(
                    name: $0.name,
                    indexName: $0.indexName,
                    qualifiedName: $0.qualifiedName,
                    kind: $0.kind,
                    location: rebase($0.location, from: recordedRoot, to: currentRoot),
                    endLocation: rebase($0.endLocation, from: recordedRoot, to: currentRoot),
                    parentLocation: $0.parentLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    objectiveCName: $0.objectiveCName,
                    attributes: Set($0.attributes),
                    isTypeMember: $0.isTypeMember,
                    isStatic: $0.isStatic,
                    isImmutable: $0.isImmutable,
                    isSettable: $0.isSettable,
                    isFinal: $0.isFinal,
                    valueTypeName: $0.valueTypeName,
                    valueTypeLocation: $0.valueTypeLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    }
                )
            },
            boundaries: facts.boundaries.map {
                RuntimeBoundary(
                    kind: $0.kind,
                    api: $0.api,
                    location: rebase($0.location, from: recordedRoot, to: currentRoot),
                    calleeLocation: $0.calleeLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    enclosingDeclarationLocation: $0.enclosingDeclarationLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    name: $0.name,
                    nameOrigin: $0.nameOrigin,
                    receiverTypeName: $0.receiverTypeName,
                    receiverOrigin: $0.receiverOrigin,
                    receiverTypeLocation: $0.receiverTypeLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    referencedTargetLocation: $0.referencedTargetLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    targetMemberName: $0.targetMemberName,
                    targetUSR: $0.targetUSR,
                    resourceObjectID: $0.resourceObjectID,
                    coreDataCodeGeneration: $0.coreDataCodeGeneration,
                    coreDataModelName: $0.coreDataModelName,
                    coreDataSuperentityName: $0.coreDataSuperentityName,
                    coreDataContainerLocation: $0.coreDataContainerLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    coreDataContextLocation: $0.coreDataContextLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    coreDataRequestLocation: $0.coreDataRequestLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    coreDataResultTypeLocation: $0.coreDataResultTypeLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    registryDeclarationLocation: $0.registryDeclarationLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    registryReferenceLocation: $0.registryReferenceLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    notificationName: $0.notificationName,
                    notificationNameLocation: $0.notificationNameLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    notificationCenterLocation: $0.notificationCenterLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    notificationCenterOwnerLocation: $0.notificationCenterOwnerLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    notificationObjectIsNil: $0.notificationObjectIsNil,
                    notificationObjectLocation: $0.notificationObjectLocation.map {
                        rebase($0, from: recordedRoot, to: currentRoot)
                    },
                    notificationRemovalReferences: $0.notificationRemovalReferences?.map {
                        RuntimeNotificationRemovalReference(
                            registrationLocation: rebase($0.registrationLocation,
                                from: recordedRoot, to: currentRoot),
                            removalLocation: rebase($0.removalLocation,
                                from: recordedRoot, to: currentRoot),
                            notificationCenterLocation: rebase($0.notificationCenterLocation,
                                from: recordedRoot, to: currentRoot),
                            notificationCenterOwnerLocation: $0.notificationCenterOwnerLocation.map {
                                rebase($0, from: recordedRoot, to: currentRoot)
                            }
                        )
                    },
                    notificationCancellationReferences: $0.notificationCancellationReferences?.map {
                        RuntimeNotificationCancellationReference(
                            registrationLocation: rebase($0.registrationLocation,
                                from: recordedRoot, to: currentRoot),
                            cancellationLocation: rebase($0.cancellationLocation,
                                from: recordedRoot, to: currentRoot)
                        )
                    },
                    keyPaths: $0.keyPaths,
                    nameAPIReferences: $0.nameAPIReferences?.map {
                        RuntimeNameAPIReference(api: $0.api,
                            location: rebase($0.location, from: recordedRoot, to: currentRoot))
                    },
                    subscriptionConsumer: $0.subscriptionConsumer.map {
                        RuntimeSubscriptionConsumerReference(
                            api: $0.api,
                            location: rebase($0.location, from: recordedRoot, to: currentRoot)
                        )
                    },
                    reason: $0.reason
                )
            },
            limitations: facts.limitations
        )
    }

    private static func rebase(
        _ location: SourceLocation,
        from recordedRoot: String,
        to currentRoot: String
    ) -> SourceLocation {
        SourceLocation(
            path: rebase(location.path, from: recordedRoot, to: currentRoot),
            line: location.line,
            column: location.column
        )
    }

    private static func normalizedRuntimeFiles(_ files: [RuntimeFileFacts]) -> [RuntimeFileFacts] {
        files.map { facts in
            RuntimeFileFacts(
                path: facts.path,
                declarations: facts.declarations.sorted {
                    ($0.location, $0.kind.rawValue, $0.indexName)
                        < ($1.location, $1.kind.rawValue, $1.indexName)
                },
                boundaries: facts.boundaries.sorted {
                    ($0.id, $0.name ?? "", $0.targetMemberName ?? "")
                        < ($1.id, $1.name ?? "", $1.targetMemberName ?? "")
                },
                limitations: Array(Set(facts.limitations)).sorted()
            )
        }.sorted { $0.path < $1.path }
    }

    private static func normalizedLimitations(
        _ limitations: [String],
        runtimeFiles: [RuntimeFileFacts]?
    ) -> [String] {
        var result = Set(limitations)
        if runtimeFiles == nil { result.insert(missingRuntimeDiscoveryLimitation) }
        return result.sorted()
    }
}

extension CartographService {
    /// 현재 보강된 인덱스 문맥을 다시 읽지 않고 분석 스냅샷으로 기록한다.
    public func captureSnapshot(
        revision: String? = nil,
        runtimeContracts: RuntimeContractsDocument? = nil,
        in existingContext: AnalysisContext? = nil
    ) throws -> AnalysisSnapshotDocument {
        if let runtimeContracts {
            try RuntimeEvidenceStore.validateContracts(runtimeContracts)
        }
        let context = try existingContext ?? loadContext()
        let built = context.buildGraph(level: .symbol)
        let graph = built.graph
        let includedUSRs = Set(built.nodeIDByUSR.keys)
        let capturedSymbols = context.snapshot.symbols.filter { includedUSRs.contains($0.usr) }
            .sorted { $0.usr < $1.usr }
        let includedSourcePaths = Set(capturedSymbols.filter { !$0.isExternal }.map(\.location.path))
        let capturedReferences = context.snapshot.references.filter {
            includedUSRs.contains($0.sourceUSR)
        }.sorted { left, right in
            let leftKey = Self.referenceOrderKey(left)
            let rightKey = Self.referenceOrderKey(right)
            return leftKey == rightKey ? left.origin.rawValue < right.origin.rawValue : leftKey < rightKey
        }
        let capturedDates = context.snapshot.indexedFileDates.map { dates in
            dates.filter { includedSourcePaths.contains($0.key) }
        }
        let capturedSnapshot = IndexSnapshot(
            symbols: capturedSymbols,
            references: capturedReferences,
            indexedFileDates: capturedDates
        )
        let supplementalPaths = context.supplementalRuntimeSourcePaths
        let capturedRuntimeFiles = context.runtimeFiles?.filter { facts in
            guard configuration.pathFilter.allows(facts.path) || supplementalPaths.contains(facts.path) else {
                return false
            }
            return includedSourcePaths.contains(facts.path)
                || RuntimeResourcePath.isSupported(facts.path)
        }
        let capturedFreshness = context.runtimeFreshness.filter {
            includedSourcePaths.contains($0.key)
                && (configuration.pathFilter.allows($0.key) || supplementalPaths.contains($0.key))
        }
        return AnalysisSnapshotDocument(
            projectRoot: projectPath,
            revision: revision,
            snapshot: capturedSnapshot,
            edgeKinds: configuration.edgeKinds,
            limitations: analysisLimitations(context: context, symbolGraph: graph),
            externalRetentions: context.externalRetentions,
            runtimeContracts: runtimeContracts,
            runtimeFiles: capturedRuntimeFiles,
            runtimeFreshness: capturedFreshness,
            localFunctionDiagnostics: context.localFunctionDiagnostics.filter {
                configuration.pathFilter.allows($0.location.path) || supplementalPaths.contains($0.location.path)
            }
        )
    }

    private static func referenceOrderKey(_ reference: IndexedReference)
        -> (String, String, String, String, Int, Int) {
        (
            reference.sourceUSR,
            reference.targetUSR,
            reference.kind.rawValue,
            reference.location?.path ?? "",
            reference.location?.line ?? 0,
            reference.location?.column ?? 0
        )
    }
}
