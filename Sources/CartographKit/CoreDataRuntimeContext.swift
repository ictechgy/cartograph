import CartographCore
import CartographSyntax
import Foundation

extension CartographService {
    /// 생성 소스의 현재 인덱스 선언을 검증해 사용자가 JSON을 직접 쓰지 않게 한다.
    public func prepareCoreDataBuildEvidence(
        executablePath: String,
        sourceModelPath: String,
        persistentContainerName: String,
        generatedSourcePaths: [String],
        module: String?,
        outputPath: String
    ) throws -> CommandOutcome {
        let initialInput = try sessionInputFingerprint()
        let store = CoreDataBuildEvidenceStore(fileSystem: environment.fileSystem)
        let requirements = try store.entityRequirements(
            executablePath: executablePath,
            sourceModelPath: sourceModelPath,
            persistentContainerName: persistentContainerName,
            module: module
        )
        let base = try loadContext()
        let sources = try canonicalGeneratedSources(generatedSourcePaths)
        let supplemental = try supplementalSnapshot(sourcePaths: sources)
        let generatedRequirements = requirements.filter { $0.codeGenerationType == "class" }
        let generatedModule = try requiredModule(module, hasGeneratedClasses: !generatedRequirements.isEmpty)
        let mappings = try verifiedGeneratedMappings(
            requirements: generatedRequirements,
            allEntities: requirements,
            sourcePaths: sources,
            module: generatedModule,
            snapshot: supplemental,
            baseContext: base
        )
        let request = CoreDataBuildEvidenceRequest(
            executablePath: executablePath,
            sourceModelPath: sourceModelPath,
            persistentContainerName: persistentContainerName,
            declaredGeneratedMappings: mappings
        )
        let preview = try store.create(request: request)
        try validateSourceModelScope(preview)
        try store.verify(preview)
        let finalSupplemental = try supplementalSnapshot(sourcePaths: sources)
        guard sameSupplementalIndex(supplemental, finalSupplemental),
              initialInput == (try sessionInputFingerprint()) else {
            throw coreDataError(
                projectPath,
                "Source or compiler index inputs changed during Core Data preparation."
            )
        }
        let evidence = try store.writeVerified(request: request, to: outputPath)
        let writtenSupplemental = try supplementalSnapshot(sourcePaths: sources)
        let writtenMappings = try verifiedGeneratedMappings(
            requirements: generatedRequirements,
            allEntities: requirements,
            sourcePaths: sources,
            module: generatedModule,
            snapshot: writtenSupplemental,
            baseContext: base
        )
        guard sameSupplementalIndex(finalSupplemental, writtenSupplemental),
              Set(writtenMappings) == Set(mappings),
              initialInput == (try sessionInputFingerprint()) else {
            throw coreDataError(
                projectPath,
                "Source or compiler index inputs changed while writing Core Data evidence."
            )
        }
        try store.verify(evidence)
        return CommandOutcome(
            output: "Wrote Core Data build evidence for \(mappings.count) generated class(es) "
                + "to \(outputPath)\n"
        )
    }

    /// 명시적 근거가 현재 파일·인덱스와 일치할 때만 생성 클래스를
    /// 런타임 문맥에 추가한다.
    public func coreDataRuntimeContext(
        evidencePath: String,
        in existingContext: AnalysisContext? = nil
    ) throws -> AnalysisContext {
        let initialInput = try sessionInputFingerprint()
        let store = CoreDataBuildEvidenceStore(fileSystem: environment.fileSystem)
        let evidence = try store.readAndVerify(at: evidencePath)
        try validateSourceModelScope(evidence)
        let base = try existingContext ?? loadContext()
        let sources = evidence.declaredGeneratedMappings.map(\.source.path)
        let supplemental = try supplementalSnapshot(sourcePaths: sources)
        let requirements = evidence.model.entities.filter { $0.codeGenerationType == "class" }
        let inputs = evidence.declaredGeneratedMappings.map {
            CoreDataDeclaredGeneratedMappingInput(
                entityName: $0.entityName,
                sourcePath: $0.source.path,
                module: $0.module,
                declarationUSRs: $0.declarationUSRs
            )
        }
        let verified = try verifiedGeneratedMappings(
            requirements: requirements,
            allEntities: evidence.model.entities,
            sourcePaths: sources,
            module: try requiredModule(
                inputs.isEmpty ? nil : singleModule(in: inputs),
                hasGeneratedClasses: !requirements.isEmpty
            ),
            snapshot: supplemental,
            baseContext: base
        )
        guard Set(verified) == Set(inputs) else {
            throw coreDataError(
                evidencePath,
                "Declared generated mappings differ from the current compiler index."
            )
        }
        let context = try augmentedCoreDataContext(base: base, supplemental: supplemental, evidence: evidence)
        let finalSupplemental = try supplementalSnapshot(sourcePaths: sources)
        guard sameSupplementalIndex(supplemental, finalSupplemental),
              initialInput == (try sessionInputFingerprint()) else {
            throw coreDataError(
                projectPath,
                "Source or compiler index inputs changed while loading Core Data evidence."
            )
        }
        try store.verify(evidence)
        return context
    }

    private func canonicalGeneratedSources(_ paths: [String]) throws -> [String] {
        guard paths.count <= 1_000 else {
            throw coreDataError(projectPath, "Pass at most 1000 exact generated Swift class source paths.")
        }
        let resolved = try paths.map { path -> String in
            guard path.hasSuffix(".swift") else {
                throw coreDataError(path, "Generated Core Data declarations must be Swift source files.")
            }
            do { return try environment.fileSystem.realPath(at: path) }
            catch { throw coreDataError(path, "The generated source path could not be resolved: \(error)") }
        }
        guard Set(resolved).count == resolved.count else {
            throw coreDataError(projectPath, "Generated source paths must be unique after resolving symbolic links.")
        }
        return resolved.sorted()
    }

    /// 생성 소스와 class 생성 엔티티를 일대일로 짝짓고 현재 인덱스로 각 짝을 확인한다.
    ///
    /// 생성 소스는 경로마다 한 번 읽고 파싱해 클래스 이름이 같은 엔티티만 검사한다. 이름이 다른 짝은
    /// `inspect` 가 늘 거부하므로, 고르는 짝과 던지는 오류의 순서는 모든 짝을 검사할 때와 같다.
    /// 기본 문맥 색인은 짝마다가 아니라 호출마다 한 번 만든다.
    func verifiedGeneratedMappings(
        requirements: [CoreDataBuildEntityEvidence],
        allEntities: [CoreDataBuildEntityEvidence],
        sourcePaths: [String],
        module: String?,
        snapshot: IndexSnapshot,
        baseContext: AnalysisContext
    ) throws -> [CoreDataDeclaredGeneratedMappingInput] {
        guard requirements.count == sourcePaths.count,
              Set(requirements.map(\.managedObjectClassName)).count == requirements.count else {
            throw coreDataError(
                projectPath,
                "Pass exactly one generated class source for each unique class-generated Core Data entity."
            )
        }
        guard !requirements.isEmpty else { return [] }
        guard let module else {
            throw coreDataError(projectPath, "Class-generated entities require one exact Swift module.")
        }
        let verification = GeneratedClassVerification(module: module, snapshot: snapshot, base: baseContext)
        let entitiesByClassName = Dictionary(grouping: requirements, by: Self.generatedClassName)
        let matches = try sourcePaths.flatMap { path in
            let source = try generatedSource(at: path)
            let entities = CoreDataGeneratedClassScanner.topLevelClassName(source: source)
                .flatMap { entitiesByClassName[$0] } ?? []
            return try entities.compactMap { entity in
                try generatedMapping(
                    source: source,
                    sourcePath: path,
                    entity: entity,
                    expectedSuperclassName: Self.superclassName(of: entity, in: allEntities),
                    verification: verification
                )
            }
        }
        guard matches.count == requirements.count,
              Set(matches.map(\.entityName)).count == requirements.count,
              Set(matches.map(\.sourcePath)).count == sourcePaths.count else {
            throw coreDataError(projectPath, "Generated classes did not match entities one-to-one.")
        }
        return matches.sorted { ($0.entityName, $0.sourcePath) < ($1.entityName, $1.sourcePath) }
    }

    private func generatedMapping(
        source: String,
        sourcePath: String,
        entity: CoreDataBuildEntityEvidence,
        expectedSuperclassName: String,
        verification: GeneratedClassVerification
    ) throws -> CoreDataDeclaredGeneratedMappingInput? {
        let module = verification.module
        let className = Self.generatedClassName(entity)
        let inspection = CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: sourcePath,
            expectedClassName: className,
            expectedRuntimeName: entity.managedObjectClassName,
            module: module,
            expectedSuperclassName: expectedSuperclassName
        )
        guard inspection.isGeneratorCompatible, let location = inspection.location else { return nil }
        let candidates = verification.snapshot.symbols.filter {
            !$0.isExternal && $0.kind == .classType && $0.module == module
                && $0.name == className && $0.location == location
        }
        let usrs = Set(candidates.map(\.usr))
        guard !usrs.isEmpty,
              confirmsGeneratedSuperclass(
                classUSRs: usrs,
                expectedName: expectedSuperclassName,
                module: module,
                snapshot: verification.snapshot
              ) else {
            throw coreDataError(sourcePath, "The compiler index did not confirm the generated model superclass.")
        }
        try requireFreshIndex(path: sourcePath, indexedDates: verification.indexedDates)
        try rejectIdentityCollision(
            usrs: usrs,
            runtimeName: entity.managedObjectClassName,
            sourcePath: sourcePath,
            verification: verification
        )
        return CoreDataDeclaredGeneratedMappingInput(
            entityName: entity.name,
            sourcePath: sourcePath,
            module: module,
            declarationUSRs: usrs.sorted()
        )
    }

    /// 생성 소스를 4 MiB 상한 안에서 읽는다.
    ///
    /// 상한+1 바이트에서 읽기를 멈추므로 생성 소스 자리에 놓인 큰 파일도 크기 검사 전에 통째로 올리지 않는다.
    func generatedSource(at path: String) throws -> String {
        let limit = 4 * 1_024 * 1_024
        let data: Data
        do { data = try environment.fileSystem.readData(at: path, maximumBytes: limit) }
        catch { throw coreDataError(path, "The generated source could not be read: \(error)") }
        guard data.count <= limit, let source = String(data: data, encoding: .utf8) else {
            throw coreDataError(path, "Generated source must be UTF-8 and no larger than 4 MiB.")
        }
        return source
    }

    private func requireFreshIndex(path: String, indexedDates: [String: Date]) throws {
        guard let indexed = indexedDates[LocalFileSystem.canonicalPath(path)],
              let modified = environment.fileSystem.modificationDate(at: path),
              modified <= indexed else {
            throw coreDataError(path, "The generated source needs a current compiler index unit.")
        }
    }

    private func rejectIdentityCollision(
        usrs: Set<String>,
        runtimeName: String,
        sourcePath: String,
        verification: GeneratedClassVerification
    ) throws {
        let canonicalSource = LocalFileSystem.canonicalPath(sourcePath)
        guard !verification.declaresIdentity(usrs: usrs, runtimeName: runtimeName, outside: canonicalSource) else {
            throw coreDataError(sourcePath, "A different indexed declaration has the same USR or runtime class name.")
        }
    }

    /// momc 가 만드는 Swift 클래스 이름. 모델의 클래스 이름이 모듈로 한정돼 있으면 마지막 요소다.
    private static func generatedClassName(_ entity: CoreDataBuildEntityEvidence) -> String {
        entity.managedObjectClassName.split(separator: ".").last.map(String.init) ?? ""
    }

    /// 부모 엔티티의 생성 클래스 이름. 부모가 없거나 모델에서 찾지 못하면 NSManagedObject 다.
    private static func superclassName(
        of entity: CoreDataBuildEntityEvidence, in allEntities: [CoreDataBuildEntityEvidence]
    ) -> String {
        entity.superentityName.flatMap { parent in
            allEntities.first { $0.name == parent }?.managedObjectClassName
                .split(separator: ".").last.map(String.init)
        } ?? "NSManagedObject"
    }

    private func augmentedCoreDataContext(
        base: AnalysisContext,
        supplemental: IndexSnapshot,
        evidence: CoreDataBuildEvidenceDocument
    ) throws -> AnalysisContext {
        let includedBaseUSRs = Set(base.buildGraph(level: .symbol).nodeIDByUSR.keys)
        let baseSymbols = base.snapshot.symbols.filter { includedBaseUSRs.contains($0.usr) }
        let baseReferences = base.snapshot.references.filter { includedBaseUSRs.contains($0.sourceUSR) }
        let basePaths = Set(baseSymbols.filter { !$0.isExternal }.map(\.location.path))
        let baseDates = base.snapshot.indexedFileDates?.filter { basePaths.contains($0.key) } ?? [:]
        let baseUSRs = Set(baseSymbols.map(\.usr))
        let additions = supplemental.symbols.filter { !baseUSRs.contains($0.usr) }
        let references = Array(Set(baseReferences + supplemental.references))
        let dates = baseDates.merging(
            supplemental.indexedFileDates ?? [:], uniquingKeysWith: min
        )
        let oldestDates: [String: Date]? = base.snapshot.oldestIndexedFileDates == nil
            && supplemental.oldestIndexedFileDates == nil ? nil
            : (base.snapshot.sourceFreshnessDates ?? [:]).filter { configuration.pathFilter.allows($0.key) }
                .merging(supplemental.sourceFreshnessDates ?? [:], uniquingKeysWith: min)
        let snapshot = IndexSnapshot(
            symbols: baseSymbols + additions,
            references: references,
            indexedFileDates: dates,
            oldestIndexedFileDates: oldestDates,
            admittedHeaderPaths: base.snapshot.admittedHeaderPaths.flatMap { paths in
                supplemental.admittedHeaderPaths.map {
                    Set(paths.filter(configuration.pathFilter.allows)).intersection($0).sorted()
                }
            },
            enumImpactFiles: Self.augmentedEnumImpactFiles(
                base: base.snapshot, supplemental: supplemental, includedBasePaths: basePaths)
        )
        let generatedFacts = try evidence.declaredGeneratedMappings.map {
            RuntimeFactScanner().scan(source: try generatedSource(at: $0.source.path), path: $0.source.path)
        }
        let baseEntityTargets = Dictionary(uniqueKeysWithValues: (base.runtimeDiscovery()?.findings ?? [])
            .filter { $0.boundary.kind == .coreDataEntityClass && $0.status == .resolved && $0.targets.count == 1 }
            .compactMap { finding in finding.targets.first.map { (finding.boundary.id, $0) } })
        let runtimeFiles = augmentedRuntimeFiles(
            base.runtimeFiles ?? [],
            evidence: evidence,
            baseEntityTargets: baseEntityTargets
        ) + generatedFacts
        let supplementalPaths = Set(evidence.declaredGeneratedMappings.map(\.source.path))
        let freshness = base.runtimeFreshness.merging(
            Dictionary(uniqueKeysWithValues: supplementalPaths.map { ($0, RuntimeFreshness.fresh) }),
            uniquingKeysWith: { _, supplement in supplement }
        )
        return AnalysisContext(
            snapshot: snapshot,
            pathFilter: .passthrough,
            edgeKinds: configuration.edgeKinds,
            externalRetentions: base.externalRetentions,
            missingSourcePaths: base.missingSourcePaths,
            unreadableSourcePaths: base.unreadableSourcePaths,
            unresolvedLocalFunctionsByPath: base.unresolvedLocalFunctionsByPath.filter { basePaths.contains($0.key) },
            localFunctionDiagnostics: base.localFunctionDiagnostics.filter { basePaths.contains($0.location.path) },
            runtimeFiles: runtimeFiles,
            runtimeFreshness: freshness,
            supplementalRuntimeSourcePaths: supplementalPaths
        )
    }

    /// 이미 수집한 enum 근거를 보존하되 같은 파일의 미수집 보충 인덱스는 완전성으로 합치지 않는다.
    static func augmentedEnumImpactFiles(
        base: IndexSnapshot, supplemental: IndexSnapshot, includedBasePaths: Set<String>
    ) -> [EnumImpactFileFacts]? {
        let admitted = IndexSnapshot(
            symbols: base.symbols.filter { !$0.isExternal && includedBasePaths.contains($0.location.path) },
            enumImpactFiles: base.enumImpactFiles?.filter { includedBasePaths.contains($0.path) })
        return admitted.merging(supplemental).enumImpactFiles
    }

    private func augmentedRuntimeFiles(
        _ files: [RuntimeFileFacts],
        evidence: CoreDataBuildEvidenceDocument,
        baseEntityTargets: [String: NodeID]
    ) -> [RuntimeFileFacts] {
        let selected = LocalFileSystem.canonicalPath(evidence.model.selectedContents.path)
        let entities = Dictionary(uniqueKeysWithValues: evidence.model.entities.map { ($0.name, $0) })
        let mappings = Dictionary(grouping: evidence.declaredGeneratedMappings, by: \.entityName)
        return files.map { facts in
            guard LocalFileSystem.canonicalPath(facts.path) == selected else { return facts }
            let boundaries = facts.boundaries.map { boundary -> RuntimeBoundary in
                guard boundary.kind == .coreDataEntityClass,
                      let name = boundary.resourceObjectID,
                      let entity = entities[name] else { return boundary }
                let generatedUSR = mappings[name]?.first.flatMap { mapping in
                    mapping.declarationUSRs.first { !$0.hasPrefix("c:") }
                        ?? mapping.declarationUSRs.first
                }
                let targetUSR = generatedUSR ?? baseEntityTargets[boundary.id]?.rawValue
                guard let targetUSR else { return boundary }
                return RuntimeBoundary(
                    kind: .coreDataEntityClass,
                    api: boundary.api,
                    location: boundary.location,
                    name: entity.managedObjectClassName,
                    nameOrigin: .resource,
                    receiverTypeName: entity.managedObjectClassName,
                    receiverOrigin: .annotation,
                    targetUSR: targetUSR,
                    resourceObjectID: name,
                    coreDataCodeGeneration: boundary.coreDataCodeGeneration,
                    coreDataModelName: evidence.bundle.persistentContainerName,
                    coreDataSuperentityName: entity.superentityName
                )
            }
            return RuntimeFileFacts(
                path: facts.path,
                declarations: facts.declarations,
                boundaries: boundaries,
                limitations: facts.limitations
            )
        }
    }

    private func validateSourceModelScope(_ evidence: CoreDataBuildEvidenceDocument) throws {
        let root = LocalFileSystem.canonicalPath(projectPath)
        let container = LocalFileSystem.canonicalPath(evidence.model.container.path)
        let selected = LocalFileSystem.canonicalPath(evidence.model.selectedContents.path)
        let marker = evidence.model.currentVersionMarker?.path
        guard Self.contains(container, in: root), Self.contains(selected, in: root),
              configuration.pathFilter.allows(selected),
              marker.map(configuration.pathFilter.allows) ?? true else {
            throw coreDataError(
                evidence.model.container.path,
                "The selected source model and version marker must be inside the configured project scope."
            )
        }
    }

    private func singleModule(in mappings: [CoreDataDeclaredGeneratedMappingInput]) throws -> String {
        let modules = Set(mappings.map(\.module))
        guard modules.count == 1, let module = modules.first else {
            throw coreDataError(projectPath, "Core Data build evidence must use one exact generated-source module.")
        }
        return module
    }

    private func requiredModule(_ module: String?, hasGeneratedClasses: Bool) throws -> String? {
        guard hasGeneratedClasses else { return nil }
        guard let module, !module.isEmpty else {
            throw coreDataError(projectPath, "Class-generated entities require one exact Swift module.")
        }
        return module
    }

    private static func contains(_ child: String, in root: String) -> Bool {
        child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isManagedObjectUSR(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSManagedObject" || usr == "s:So15NSManagedObjectC"
    }

    private func confirmsGeneratedSuperclass(
        classUSRs: Set<String>,
        expectedName: String,
        module: String,
        snapshot: IndexSnapshot
    ) -> Bool {
        let inheritance = snapshot.references.filter {
            classUSRs.contains($0.sourceUSR) && $0.kind == .inheritance
        }
        if expectedName == "NSManagedObject" {
            return inheritance.contains { Self.isManagedObjectUSR($0.targetUSR) }
        }
        let symbols = snapshot.symbolsByUSR()
        return inheritance.contains { reference in
            guard let target = symbols[reference.targetUSR] else { return false }
            return target.kind == .classType && target.module == module && target.name == expectedName
        }
    }

    private func sameSupplementalIndex(_ lhs: IndexSnapshot, _ rhs: IndexSnapshot) -> Bool {
        Set(lhs.symbols) == Set(rhs.symbols)
            && Set(lhs.references) == Set(rhs.references)
            && lhs.indexedFileDates == rhs.indexedFileDates
            && lhs.oldestIndexedFileDates == rhs.oldestIndexedFileDates
            && lhs.admittedHeaderPaths == rhs.admittedHeaderPaths
    }

    private func coreDataError(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}

/// 생성 클래스 검증 한 번의 입력과, 짝마다 다시 쓰는 색인.
///
/// 예전에는 짝이 맞을 때마다 기본 스냅샷 전체를 USR 로 훑고 위치별로 다시 묶고 class 선언마다 경로를
/// 정규화했으며, 신선도 확인도 보충 인덱스 시각을 양쪽 정규화로 선형 탐색했다. 모두 검증 입력에만
/// 의존하므로 호출마다 한 번 만든다. 경로 정규화는 파일 시스템을 거치므로 경로당 한 번만 한다.
private struct GeneratedClassVerification {
    let module: String
    /// 생성 소스만 읽은 보충 인덱스.
    let snapshot: IndexSnapshot
    /// 보충 인덱스 신선도 시각의 정규 경로 사전. 같은 정규 경로가 여럿이면 먼저 본 시각을 쓴다.
    let indexedDates: [String: Date]
    /// 생성 클래스 후보 USR 마다, 기본 스냅샷에서 그 USR 을 가진 선언의 정규 경로.
    private let pathsByUSR: [String: Set<String>]
    /// 기본 문맥의 class 선언이 드러내는 런타임 클래스 이름마다, 그 선언의 정규 경로.
    private let pathsByRuntimeName: [String: Set<String>]

    init(module: String, snapshot: IndexSnapshot, base: AnalysisContext) {
        var canonical = CanonicalPathMemo()
        let candidates = Set(snapshot.symbols.lazy
            .filter { !$0.isExternal && $0.kind == .classType && $0.module == module }.map(\.usr))
        self.module = module
        self.snapshot = snapshot
        indexedDates = Dictionary(
            (snapshot.sourceFreshnessDates ?? [:]).map { (canonical.path($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        pathsByUSR = Self.pathsByUSR(base.snapshot.symbols, candidates: candidates, canonical: &canonical)
        pathsByRuntimeName = Self.pathsByRuntimeName(base, canonical: &canonical)
    }

    /// 다른 파일의 기본 선언이 같은 USR 이나 같은 런타임 클래스 이름을 쓰는지.
    func declaresIdentity(usrs: Set<String>, runtimeName: String, outside canonicalSource: String) -> Bool {
        let elsewhere = { (paths: Set<String>?) in paths?.contains { $0 != canonicalSource } ?? false }
        return usrs.contains { elsewhere(pathsByUSR[$0]) } || elsewhere(pathsByRuntimeName[runtimeName])
    }

    private static func pathsByUSR(
        _ symbols: [IndexedSymbol], candidates: Set<String>, canonical: inout CanonicalPathMemo
    ) -> [String: Set<String>] {
        var paths: [String: Set<String>] = [:]
        for symbol in symbols where candidates.contains(symbol.usr) {
            paths[symbol.usr, default: []].insert(canonical.path(symbol.location.path))
        }
        return paths
    }

    /// @objc 이름이 있으면 그 이름이, 없으면 같은 위치의 프로젝트 인덱스 선언 모듈로 한정한 이름이
    /// 런타임 클래스 이름이다. 위치별 묶음은 @objc 이름 없는 class 선언의 위치만 만든다.
    private static func pathsByRuntimeName(
        _ base: AnalysisContext, canonical: inout CanonicalPathMemo
    ) -> [String: Set<String>] {
        let declarations = (base.runtimeFiles ?? []).flatMap(\.declarations).filter { $0.kind == .classType }
        let unnamed = Set(declarations.lazy.filter { $0.objectiveCName == nil }.map(\.location))
        var modules: [CartographCore.SourceLocation: Set<String>] = [:]
        if !unnamed.isEmpty {
            for symbol in base.snapshot.symbols where !symbol.isExternal && unnamed.contains(symbol.location) {
                modules[symbol.location, default: []].insert(symbol.module)
            }
        }
        var paths: [String: Set<String>] = [:]
        for declaration in declarations {
            let names = declaration.objectiveCName.map { [$0] }
                ?? (modules[declaration.location] ?? []).map { "\($0).\(declaration.name)" }
            for name in names {
                paths[name, default: []].insert(canonical.path(declaration.location.path))
            }
        }
        return paths
    }
}

/// `LocalFileSystem.canonicalPath` 는 경로마다 파일 시스템을 거치므로 같은 경로는 한 번만 정규화한다.
private struct CanonicalPathMemo {
    private var resolved: [String: String] = [:]

    mutating func path(_ raw: String) -> String {
        if let known = resolved[raw] { return known }
        let path = LocalFileSystem.canonicalPath(raw)
        resolved[raw] = path
        return path
    }
}
