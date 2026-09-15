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

    private func verifiedGeneratedMappings(
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
        let matches = try sourcePaths.flatMap { path in
            try requirements.compactMap { entity in
                let superclass = entity.superentityName.flatMap { parent in
                    allEntities.first { $0.name == parent }?.managedObjectClassName
                        .split(separator: ".").last.map(String.init)
                } ?? "NSManagedObject"
                return try generatedMapping(
                    sourcePath: path,
                    entity: entity,
                    expectedSuperclassName: superclass,
                    module: module,
                    snapshot: snapshot,
                    baseContext: baseContext
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
        sourcePath: String,
        entity: CoreDataBuildEntityEvidence,
        expectedSuperclassName: String,
        module: String,
        snapshot: IndexSnapshot,
        baseContext: AnalysisContext
    ) throws -> CoreDataDeclaredGeneratedMappingInput? {
        let source = try generatedSource(at: sourcePath)
        let className = entity.managedObjectClassName.split(separator: ".").last.map(String.init) ?? ""
        let inspection = CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: sourcePath,
            expectedClassName: className,
            expectedRuntimeName: entity.managedObjectClassName,
            module: module,
            expectedSuperclassName: expectedSuperclassName
        )
        guard inspection.isGeneratorCompatible, let location = inspection.location else { return nil }
        let candidates = snapshot.symbols.filter {
            !$0.isExternal && $0.kind == .classType && $0.module == module
                && $0.name == className && $0.location == location
        }
        let usrs = Set(candidates.map(\.usr))
        guard !usrs.isEmpty,
              confirmsGeneratedSuperclass(
                classUSRs: usrs,
                expectedName: expectedSuperclassName,
                module: module,
                snapshot: snapshot
              ) else {
            throw coreDataError(sourcePath, "The compiler index did not confirm the generated model superclass.")
        }
        try requireFreshIndex(path: sourcePath, snapshot: snapshot)
        try rejectIdentityCollision(
            usrs: usrs,
            runtimeName: entity.managedObjectClassName,
            sourcePath: sourcePath,
            baseContext: baseContext
        )
        return CoreDataDeclaredGeneratedMappingInput(
            entityName: entity.name,
            sourcePath: sourcePath,
            module: module,
            declarationUSRs: usrs.sorted()
        )
    }

    private func generatedSource(at path: String) throws -> String {
        let data: Data
        do { data = try environment.fileSystem.readData(at: path) }
        catch { throw coreDataError(path, "The generated source could not be read: \(error)") }
        guard data.count <= 4 * 1_024 * 1_024, let source = String(data: data, encoding: .utf8) else {
            throw coreDataError(path, "Generated source must be UTF-8 and no larger than 4 MiB.")
        }
        return source
    }

    private func requireFreshIndex(path: String, snapshot: IndexSnapshot) throws {
        let indexed = snapshot.indexedFileDates?.first {
            LocalFileSystem.canonicalPath($0.key) == LocalFileSystem.canonicalPath(path)
        }?.value
        guard let indexed, let modified = environment.fileSystem.modificationDate(at: path),
              modified <= indexed else {
            throw coreDataError(path, "The generated source needs a current compiler index unit.")
        }
    }

    private func rejectIdentityCollision(
        usrs: Set<String>,
        runtimeName: String,
        sourcePath: String,
        baseContext: AnalysisContext
    ) throws {
        let canonicalSource = LocalFileSystem.canonicalPath(sourcePath)
        let usrCollision = baseContext.snapshot.symbols.contains {
            usrs.contains($0.usr) && LocalFileSystem.canonicalPath($0.location.path) != canonicalSource
        }
        let declarations = baseContext.runtimeFiles?.flatMap(\.declarations) ?? []
        let byLocation = Dictionary(grouping: baseContext.snapshot.symbols, by: \.location)
        let aliasCollision = declarations.contains { declaration in
            guard declaration.kind == .classType,
                  LocalFileSystem.canonicalPath(declaration.location.path) != canonicalSource else { return false }
            if declaration.objectiveCName == runtimeName { return true }
            guard declaration.objectiveCName == nil else { return false }
            return (byLocation[declaration.location] ?? []).contains {
                !$0.isExternal && "\($0.module).\(declaration.name)" == runtimeName
            }
        }
        guard !usrCollision, !aliasCollision else {
            throw coreDataError(sourcePath, "A different indexed declaration has the same USR or runtime class name.")
        }
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
        let snapshot = IndexSnapshot(
            symbols: baseSymbols + additions,
            references: references,
            indexedFileDates: dates
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
    }

    private func coreDataError(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}
