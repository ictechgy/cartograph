import CartographCore
import CoreData
import CryptoKit
import Foundation

/// 인덱스에 대조할 생성 소스·모듈·USR 매핑 입력.
///
/// 이 값은 생산자의 주장이다. `CoreDataBuildEvidenceStore`는 파일 내용을 고정하지만,
/// 현재 인덱스에서 선언 신원과 클래스 형태를 검증하는 일은 해석 계층이 맡는다.
public struct CoreDataDeclaredGeneratedMappingInput: Sendable, Equatable, Hashable {
    public let entityName: String
    public let sourcePath: String
    public let module: String
    public let declarationUSRs: [String]

    /// 생성 소스 하나가 제공한다고 주장하는 exact 선언 신원을 보존한다.
    public init(entityName: String, sourcePath: String, module: String, declarationUSRs: [String]) {
        self.entityName = entityName
        self.sourcePath = sourcePath
        self.module = module
        self.declarationUSRs = declarationUSRs
    }
}

/// 현재 앱 번들과 소스 모델에서 Core Data 빌드 근거를 만드는 입력.
public struct CoreDataBuildEvidenceRequest: Sendable, Equatable {
    public let executablePath: String
    public let sourceModelPath: String
    public let persistentContainerName: String
    public let declaredGeneratedMappings: [CoreDataDeclaredGeneratedMappingInput]

    /// 앱·모델·container literal과 검증할 생성 소스 목록을 묶는다.
    public init(
        executablePath: String,
        sourceModelPath: String,
        persistentContainerName: String,
        declaredGeneratedMappings: [CoreDataDeclaredGeneratedMappingInput] = []
    ) {
        self.executablePath = executablePath
        self.sourceModelPath = sourceModelPath
        self.persistentContainerName = persistentContainerName
        self.declaredGeneratedMappings = declaredGeneratedMappings
    }
}

struct CoreDataCompiledEntityMetadata: Sendable, Equatable {
    let name: String
    let managedObjectClassName: String
    let superentityName: String?

    init(name: String, managedObjectClassName: String, superentityName: String? = nil) {
        self.name = name
        self.managedObjectClassName = managedObjectClassName
        self.superentityName = superentityName
    }
}

/// 소스 모델, main bundle 모델과 실행 파일을 같은 빌드 근거로 묶는다.
public struct CoreDataBuildEvidenceStore: Sendable {
    typealias ModelLoader = @Sendable (String) throws -> [CoreDataCompiledEntityMetadata]?
    typealias LinkedSymbolsLoader = @Sendable (String) throws -> Set<String>

    private static let maximumDocumentBytes = 4 * 1_024 * 1_024
    private static let maximumMetadataBytes = 256 * 1_024
    private static let maximumModelBytes = 64 * 1_024 * 1_024
    private static let maximumGeneratedSourceBytes = 4 * 1_024 * 1_024
    private static let maximumExecutableBytes = 2 * 1_024 * 1_024 * 1_024
    private static let maximumFiles = 10_000

    private let fileSystem: any FileSystem
    private let modelLoader: ModelLoader
    private let linkedSymbolsLoader: LinkedSymbolsLoader

    /// 실제 Core Data SDK가 컴파일된 모델을 열어 엔티티 클래스 메타데이터를 읽는다.
    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.init(fileSystem: fileSystem, modelLoader: Self.loadCompiledModel,
            linkedSymbolsLoader: { try CoreDataLinkedClassInspector().symbols(in: $0) })
    }

    init(
        fileSystem: any FileSystem,
        modelLoader: @escaping ModelLoader,
        linkedSymbolsLoader: @escaping LinkedSymbolsLoader
    ) {
        self.fileSystem = fileSystem
        self.modelLoader = modelLoader
        self.linkedSymbolsLoader = linkedSymbolsLoader
    }

    func entityRequirements(
        executablePath: String,
        sourceModelPath: String,
        persistentContainerName: String,
        module: String?
    ) throws -> [CoreDataBuildEntityEvidence] {
        try validateRequest(.init(
            executablePath: executablePath,
            sourceModelPath: sourceModelPath,
            persistentContainerName: persistentContainerName
        ))
        if let module, !validModule(module) {
            throw invalid(module, "The generated-source module is not a valid Swift module name.")
        }
        let layout = try bundleLayout(executablePath: executablePath)
        let compiled = try compiledModel(in: layout, named: persistentContainerName)
        let source = try sourceModel(at: sourceModelPath, compiledModel: compiled.artifact)
        let metadata = try compiledMetadata(at: compiled.artifact.path)
        let modules = Dictionary(uniqueKeysWithValues: source.entities.map {
            ($0.name, module.map { Set([$0]) } ?? [])
        })
        return try reconcile(source.entities, compiled: metadata, modulesByEntity: modules)
    }

    /// 입력 파일을 두 번 읽어 안정성을 확인한 뒤 메모리 문서를 만든다.
    public func create(request: CoreDataBuildEvidenceRequest) throws -> CoreDataBuildEvidenceDocument {
        try validateRequest(request)
        let layout = try bundleLayout(executablePath: request.executablePath)
        let executable = try stableArtifact(at: layout.executable, maximumBytes: Self.maximumExecutableBytes)
        let compiled = try compiledModel(in: layout, named: request.persistentContainerName)
        let source = try sourceModel(at: request.sourceModelPath, compiledModel: compiled.artifact)
        let metadata = try compiledMetadata(at: compiled.artifact.path)
        let modules = Dictionary(grouping: request.declaredGeneratedMappings, by: \.entityName)
            .mapValues { Set($0.map(\.module)) }
        let entities = try reconcile(source.entities, compiled: metadata, modulesByEntity: modules)
        let mappings = try declaredMappings(
            request.declaredGeneratedMappings,
            entities: entities,
            executablePath: executable.path
        )
        return CoreDataBuildEvidenceDocument(
            executable: executable,
            bundle: CoreDataBundleBuildEvidence(
                path: layout.bundle, identifier: layout.identifier, resourceRoot: layout.resources,
                persistentContainerName: request.persistentContainerName,
                compiledModelRelativePath: compiled.relativePath, compiledModel: compiled.artifact
            ),
            model: CoreDataSourceModelBuildEvidence(
                container: source.container, selectedContents: source.contents,
                selectedVersionName: source.versionName, currentVersionMarker: source.marker,
                entities: entities
            ),
            declaredGeneratedMappings: mappings
        )
    }

    /// 문서가 가리키는 현재 파일과 Core Data 메타데이터를 다시 읽어
    /// 완전히 같은지 확인한다.
    public func verify(_ document: CoreDataBuildEvidenceDocument) throws {
        try validateDocumentShape(document)
        let request = CoreDataBuildEvidenceRequest(
            executablePath: document.executable.path,
            sourceModelPath: document.model.container.path,
            persistentContainerName: document.bundle.persistentContainerName,
            declaredGeneratedMappings: document.declaredGeneratedMappings.map {
                CoreDataDeclaredGeneratedMappingInput(
                    entityName: $0.entityName, sourcePath: $0.source.path,
                    module: $0.module, declarationUSRs: $0.declarationUSRs
                )
            }
        )
        guard try create(request: request) == document else {
            throw invalid(document.model.container.path,
                          "Core Data build inputs changed. Rebuild the application and produce fresh evidence.")
        }
    }

    /// 검증된 문서만 정렬된 JSON으로 기록하고 기록 결과를 다시 읽어 확인한다.
    @discardableResult
    public func writeVerified(
        request: CoreDataBuildEvidenceRequest,
        to path: String
    ) throws -> CoreDataBuildEvidenceDocument {
        let document = try create(request: request)
        try verify(document)
        try validateOutputPath(path, against: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try fileSystem.write(encoder.encode(document), to: path) }
        catch { throw invalid(path, "Could not write Core Data build evidence: \(error)") }
        return try readAndVerify(at: path)
    }

    /// 크기와 스키마를 제한해 문서를 읽고 현재 빌드 입력과 다시 대조한다.
    public func readAndVerify(at path: String) throws -> CoreDataBuildEvidenceDocument {
        let data = try readBounded(path, maximumBytes: Self.maximumDocumentBytes)
        let document: CoreDataBuildEvidenceDocument
        do { document = try JSONDecoder().decode(CoreDataBuildEvidenceDocument.self, from: data) }
        catch {
            throw invalid(
                path,
                "Expected coredata-build-evidence v1 JSON. Run runtime prepare-coredata again."
            )
        }
        try verify(document)
        return document
    }

    private func validateRequest(_ request: CoreDataBuildEvidenceRequest) throws {
        guard validContainerName(request.persistentContainerName) else {
            throw invalid(request.persistentContainerName,
                          "Persistent container names must be printable path-free names of at most 255 bytes.")
        }
        guard request.declaredGeneratedMappings.count <= 10_000 else {
            throw invalid(request.sourceModelPath, "At most 10,000 generated-source mappings are accepted.")
        }
    }

    private func validateDocumentShape(_ document: CoreDataBuildEvidenceDocument) throws {
        let artifacts = [document.executable, document.bundle.compiledModel, document.model.container,
                         document.model.selectedContents]
            + [document.model.currentVersionMarker].compactMap { $0 }
            + document.declaredGeneratedMappings.map(\.source)
        guard document.format == "coredata-build-evidence", document.version == 1,
              validBundleIdentifier(document.bundle.identifier),
              validContainerName(document.bundle.persistentContainerName),
              artifacts.allSatisfy(Self.validArtifact),
              document.model.entities.count <= 10_000,
              document.declaredGeneratedMappings.count <= 10_000,
              document.declaredGeneratedMappings.allSatisfy({
                  (2...3).contains($0.linkedBinarySymbols.count)
                      && Set($0.linkedBinarySymbols).count == $0.linkedBinarySymbols.count
                      && $0.linkedBinarySymbols.allSatisfy {
                          validLabel($0) && $0.utf8.count <= 4_096
                      }
              }) else {
            throw invalid(document.model.container.path, "Expected a bounded coredata-build-evidence v1 document.")
        }
    }

    private func bundleLayout(executablePath: String) throws -> BundleLayout {
        let rawExecutable = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        guard let rawBundle = appAncestor(of: rawExecutable) else {
            throw invalid(executablePath, "The executable must be inside an explicit .app bundle.")
        }
        let rawContents = (rawBundle as NSString).appendingPathComponent("Contents")
        let isMacBundle = fileSystem.directoryExists(at: rawContents)
        let infoPath = isMacBundle
            ? (rawContents as NSString).appendingPathComponent("Info.plist")
            : (rawBundle as NSString).appendingPathComponent("Info.plist")
        try rejectDirectSymbolicLink(at: rawBundle)
        try rejectDirectSymbolicLink(at: infoPath)
        let info = try bundleInfo(at: infoPath)
        let rawExpectedExecutable = isMacBundle
            ? (rawContents as NSString).appendingPathComponent("MacOS/\(info.executable)")
            : (rawBundle as NSString).appendingPathComponent(info.executable)
        let rawResources = isMacBundle
            ? (rawContents as NSString).appendingPathComponent("Resources") : rawBundle
        let bundle = try resolved(rawBundle)
        let executable = try resolved(rawExecutable)
        let expectedExecutable = try resolved(rawExpectedExecutable)
        let resources = try resolved(rawResources)
        let resolvedInfo = try resolved(infoPath)
        guard executable == expectedExecutable,
              contained(executable, in: bundle),
              contained(resources, in: bundle),
              contained(resolvedInfo, in: bundle) else {
            throw invalid(executablePath, "The executable or resource root escapes the declared app bundle.")
        }
        try rejectSymbolicLink(at: rawExecutable)
        if fileSystem is LocalFileSystem, !FileManager.default.isExecutableFile(atPath: executable) {
            throw invalid(executablePath, "The app executable is not executable. Build the application first.")
        }
        return BundleLayout(bundle: bundle, executable: executable, resources: resources, identifier: info.identifier)
    }

    private func bundleInfo(at path: String) throws -> (identifier: String, executable: String) {
        let data = try readBounded(path, maximumBytes: Self.maximumMetadataBytes)
        if containsEntityDeclaration(data) {
            throw invalid(path, "Entity declarations are not accepted in app metadata.")
        }
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw invalid(path, "The app Info.plist is malformed: \(error)") }
        guard let dictionary = value as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let executable = dictionary["CFBundleExecutable"] as? String,
              validBundleIdentifier(identifier), validContainerName(executable) else {
            throw invalid(path, "Info.plist needs a valid CFBundleIdentifier and CFBundleExecutable.")
        }
        return (identifier, executable)
    }

    private func compiledModel(in layout: BundleLayout, named name: String) throws -> CompiledModel {
        let candidates = ["\(name).mom", "\(name).momd"].compactMap { relative -> CompiledModel? in
            let path = (layout.resources as NSString).appendingPathComponent(relative)
            guard fileSystem.fileExists(at: path) || fileSystem.directoryExists(at: path) else { return nil }
            return CompiledModel(relativePath: relative, artifact: CoreDataBuildArtifact(
                path: path, kind: .file, sha256: "", byteCount: 0, fileCount: 0
            ))
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw invalid(layout.resources,
                          "Expected exactly one main-bundle resource named \(name).mom or \(name).momd.")
        }
        let artifact = try stableArtifact(at: candidate.artifact.path, maximumBytes: Self.maximumModelBytes)
        guard (artifact.path as NSString).deletingLastPathComponent == layout.resources else {
            throw invalid(artifact.path, "The compiled model must be a direct member of the main bundle resources.")
        }
        return CompiledModel(relativePath: candidate.relativePath, artifact: artifact)
    }

    private func sourceModel(at path: String, compiledModel: CoreDataBuildArtifact) throws -> SourceModel {
        let resolvedPath = try resolved(path)
        let extensionName = (resolvedPath as NSString).pathExtension
        guard ["xcdatamodel", "xcdatamodeld"].contains(extensionName),
              fileSystem.directoryExists(at: resolvedPath) else {
            throw invalid(path, "Expected a source .xcdatamodel or .xcdatamodeld directory.")
        }
        let selection = try selectedSourceModel(at: resolvedPath, extensionName: extensionName)
        guard (compiledModel.kind == .directory) == (extensionName == "xcdatamodeld") else {
            throw invalid(
                compiledModel.path,
                "Versioned source models require .momd; direct source models require .mom."
            )
        }
        if let versionName = selection.versionName {
            try validateCompiledCurrentVersion(compiledModel.path, expected: versionName)
        }
        let container = try stableArtifact(at: resolvedPath, maximumBytes: Self.maximumModelBytes)
        let contents = try stableArtifact(at: selection.contentsPath, maximumBytes: Self.maximumModelBytes)
        let marker = try selection.markerPath.map {
            try stableArtifact(at: $0, maximumBytes: Self.maximumMetadataBytes)
        }
        let source = try readBounded(selection.contentsPath, maximumBytes: Self.maximumModelBytes)
        return SourceModel(
            container: container, contents: contents, marker: marker, versionName: selection.versionName,
            entities: try parseSourceEntities(source, path: selection.contentsPath)
        )
    }

    private func selectedSourceModel(
        at path: String,
        extensionName: String
    ) throws -> (contentsPath: String, markerPath: String?, versionName: String?) {
        if extensionName == "xcdatamodel" {
            let contents = (path as NSString).appendingPathComponent("contents")
            guard fileSystem.fileExists(at: contents) else {
                throw invalid(path, "The model contents file is missing.")
            }
            return (contents, nil, nil)
        }
        let models = (try? fileSystem.directoryEntries(at: path))?.filter {
            $0.isDirectory && ($0.path as NSString).pathExtension == "xcdatamodel"
        }.map(\.path).sorted() ?? []
        let contents = models.map { ($0 as NSString).appendingPathComponent("contents") }
        guard !contents.isEmpty, contents.allSatisfy(fileSystem.fileExists) else {
            throw invalid(path, "The versioned model has no complete .xcdatamodel versions.")
        }
        let marker = (path as NSString).appendingPathComponent(".xccurrentversion")
        let selected: String
        if fileSystem.fileExists(at: marker) {
            let result = CoreDataVersionSelection.read(markerPath: marker, modelPaths: contents, fileSystem: fileSystem)
            guard let value = result.selectedPath else {
                throw invalid(marker, result.reason ?? "The current model version could not be selected.")
            }
            selected = value
        } else if contents.count == 1 {
            selected = contents[0]
        } else {
            throw invalid(path, "A versioned model with multiple versions requires .xccurrentversion.")
        }
        let version = (((selected as NSString).deletingLastPathComponent as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return (selected, fileSystem.fileExists(at: marker) ? marker : nil, version)
    }

    private func validateCompiledCurrentVersion(_ path: String, expected: String) throws {
        let versionInfo = (path as NSString).appendingPathComponent("VersionInfo.plist")
        let data = try readBounded(versionInfo, maximumBytes: Self.maximumMetadataBytes)
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw invalid(versionInfo, "The compiled model version metadata is malformed: \(error)") }
        let actual = (value as? [String: Any])?["NSManagedObjectModel_CurrentVersionName"] as? String
        guard actual == expected else {
            throw invalid(
                path,
                "Compiled current version '\(actual ?? "<missing>")' does not match source '\(expected)'."
            )
        }
    }

    private func compiledMetadata(at path: String) throws -> [CoreDataCompiledEntityMetadata] {
        guard let metadata = try modelLoader(path), !metadata.isEmpty,
              metadata.count <= 10_000,
              Set(metadata.map(\.name)).count == metadata.count,
              metadata.allSatisfy({ validLabel($0.name) && validTypeName($0.managedObjectClassName) }) else {
            throw invalid(path, "Core Data could not load a bounded model with unique entity class metadata.")
        }
        return metadata.sorted { $0.name < $1.name }
    }

    private func reconcile(
        _ source: [SourceEntity],
        compiled: [CoreDataCompiledEntityMetadata],
        modulesByEntity: [String: Set<String>]
    ) throws -> [CoreDataBuildEntityEvidence] {
        guard Set(source.map(\.name)) == Set(compiled.map(\.name)), validEntityHierarchy(source) else {
            throw invalid("Core Data model", "Source and compiled model entity sets or hierarchy differ.")
        }
        return try source.sorted { $0.name < $1.name }.map { entity in
            guard let actual = compiled.first(where: { $0.name == entity.name }),
                  actual.superentityName == entity.superentityName,
                  classNameMatches(
                    entity,
                    actual: actual.managedObjectClassName,
                    modules: modulesByEntity[entity.name] ?? []
                  )
            else { throw invalid(entity.name, "Source represented class and compiled model class metadata differ.") }
            return CoreDataBuildEntityEvidence(
                name: entity.name, representedClassName: entity.representedClassName,
                managedObjectClassName: actual.managedObjectClassName,
                codeGenerationType: entity.codeGenerationType,
                superentityName: entity.superentityName
            )
        }
    }

    private func validEntityHierarchy(_ entities: [SourceEntity]) -> Bool {
        let names = Set(entities.map(\.name))
        let parents = Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0.superentityName) })
        for entity in entities {
            var visited: Set<String> = [entity.name]
            var current = entity.superentityName
            while let name = current {
                guard visited.insert(name).inserted, names.contains(name) else { return false }
                current = parents[name] ?? nil
            }
        }
        return true
    }

    private func declaredMappings(
        _ inputs: [CoreDataDeclaredGeneratedMappingInput],
        entities: [CoreDataBuildEntityEvidence],
        executablePath: String
    ) throws -> [CoreDataDeclaredGeneratedMapping] {
        let entityNames = Set(entities.map(\.name))
        let entitiesByName = Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0) })
        let linkedSymbols = try inputs.isEmpty ? Set<String>() : linkedSymbolsLoader(executablePath)
        var keys: Set<String> = []
        var allUSRs: Set<String> = []
        let mappings = try inputs.map { input -> CoreDataDeclaredGeneratedMapping in
            let key = "\(input.entityName)\u{0}\(input.module)\u{0}\(input.sourcePath)"
            guard entityNames.contains(input.entityName), validModule(input.module),
                  !input.declarationUSRs.isEmpty, input.declarationUSRs.count <= 100,
                  input.declarationUSRs.allSatisfy(validUSR), keys.insert(key).inserted,
                  input.declarationUSRs.allSatisfy({ allUSRs.insert($0).inserted }) else {
                throw invalid(
                    input.sourcePath,
                    "Generated-source mappings require a known entity, module and unique USRs."
                )
            }
            guard let entity = entitiesByName[input.entityName],
                  let witnessSymbols = linkedClassSymbols(
                    entity: entity,
                    module: input.module,
                    declarationUSRs: input.declarationUSRs,
                    symbols: linkedSymbols
                  ) else {
                throw invalid(
                    executablePath,
                    "The generated Core Data class is not defined in the supplied app executable."
                )
            }
            return CoreDataDeclaredGeneratedMapping(
                entityName: input.entityName,
                source: try stableArtifact(at: input.sourcePath, maximumBytes: Self.maximumGeneratedSourceBytes),
                module: input.module,
                declarationUSRs: input.declarationUSRs.sorted(),
                linkedBinarySymbols: witnessSymbols
            )
        }.sorted { ($0.entityName, $0.module, $0.source.path) < ($1.entityName, $1.module, $1.source.path) }
        let mappedEntities = Set(mappings.map(\.entityName))
        let generatedEntities = Set(entities.filter { $0.codeGenerationType == "class" }.map(\.name))
        guard generatedEntities.isSubset(of: mappedEntities) else {
            throw invalid("Core Data model", "Automatic code generation requires an explicit generated-source mapping.")
        }
        return mappings
    }

    private func classNameMatches(_ source: SourceEntity, actual: String, modules: Set<String>) -> Bool {
        let represented = source.representedClassName
        if represented == actual { return true }
        if represented == nil, source.codeGenerationType == nil || source.codeGenerationType == "none" {
            return actual == "NSManagedObject"
        }
        guard ["class", "category"].contains(source.codeGenerationType) else { return false }
        let base = represented?.split(separator: ".").last.map(String.init) ?? source.name
        if modules.isEmpty { return actual.split(separator: ".").last.map(String.init) == base }
        return modules.contains { "\($0).\(base)" == actual }
    }

    private func linkedClassSymbols(
        entity: CoreDataBuildEntityEvidence,
        module: String,
        declarationUSRs: [String],
        symbols: Set<String>
    ) -> [String]? {
        let className = entity.managedObjectClassName.split(separator: ".").last.map(String.init) ?? ""
        let swiftUSR = declarationUSRs.first { $0.hasPrefix("s:") && $0.hasSuffix("C") }
            ?? simpleSwiftClassUSR(module: module, className: className)
        guard let swiftUSR else { return nil }
        let swiftBase = "_$s" + String(swiftUSR.dropFirst(2))
        var required = [swiftBase + "Mn", swiftBase + "N"]
        if !entity.managedObjectClassName.contains(".") {
            required.append("_OBJC_CLASS_$_" + entity.managedObjectClassName)
        }
        return required.allSatisfy(symbols.contains) ? required.sorted() : nil
    }

    private func simpleSwiftClassUSR(module: String, className: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !module.isEmpty, !className.isEmpty,
              module.unicodeScalars.allSatisfy(allowed.contains),
              className.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "s:\(module.utf8.count)\(module)\(className.utf8.count)\(className)C"
    }

    private func parseSourceEntities(_ data: Data, path: String) throws -> [SourceEntity] {
        guard !containsUnsafeModelDeclaration(data) else {
            throw invalid(path, "DTDs and entity declarations are not accepted in source models.")
        }
        let collector = CoreDataSourceEntityCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), collector.isModel, collector.error == nil,
              !collector.foundExternalEntity, !collector.foundInvalidEntity,
              !collector.entities.isEmpty,
              Set(collector.entities.map(\.name)).count == collector.entities.count else {
            throw invalid(path, "The source model XML is malformed or has duplicate entities.")
        }
        return collector.entities
    }

    private func stableArtifact(at path: String, maximumBytes: Int) throws -> CoreDataBuildArtifact {
        let first = try artifact(at: path, maximumBytes: maximumBytes)
        let second = try artifact(at: path, maximumBytes: maximumBytes)
        guard first == second else { throw invalid(path, "The artifact changed while it was being read.") }
        return first
    }

    private func artifact(at path: String, maximumBytes: Int) throws -> CoreDataBuildArtifact {
        let resolvedPath = try resolved(path)
        try rejectSymbolicLink(at: path)
        if fileSystem.fileExists(at: resolvedPath) {
            let digest = try fileDigest(at: resolvedPath, maximumBytes: maximumBytes)
            return CoreDataBuildArtifact(
                path: resolvedPath, kind: .file, sha256: digest.hash,
                byteCount: digest.byteCount, fileCount: 1
            )
        }
        guard fileSystem.directoryExists(at: resolvedPath) else { throw invalid(path, "The artifact does not exist.") }
        return try directoryArtifact(at: resolvedPath, maximumBytes: maximumBytes)
    }

    private func directoryArtifact(at path: String, maximumBytes: Int) throws -> CoreDataBuildArtifact {
        let files = try completeFiles(under: path)
        guard !files.isEmpty, files.count <= Self.maximumFiles else {
            throw invalid(path, "The artifact directory is empty or exceeds 10,000 files.")
        }
        var hasher = SHA256()
        var total: UInt64 = 0
        for file in files {
            let resolvedFile = try resolved(file)
            guard contained(resolvedFile, in: path) else {
                throw invalid(file, "An artifact path escapes its directory.")
            }
            let remaining = maximumBytes - Int(min(total, UInt64(Int.max)))
            guard remaining >= 0 else { throw invalid(path, "The artifact exceeds its size limit.") }
            let digest = try fileDigest(at: resolvedFile, maximumBytes: remaining)
            total += digest.byteCount
            guard total <= UInt64(maximumBytes) else { throw invalid(path, "The artifact exceeds its size limit.") }
            let relative = String(resolvedFile.dropFirst(path.count + 1))
            update(&hasher, value: relative)
            update(&hasher, value: digest.hash)
            update(&hasher, value: String(digest.byteCount))
        }
        return CoreDataBuildArtifact(
            path: path, kind: .directory, sha256: hex(hasher.finalize()),
            byteCount: total, fileCount: files.count
        )
    }

    private func completeFiles(under root: String) throws -> [String] {
        var pending = [root]
        var visited: Set<String> = []
        var files: [String] = []
        while let directory = pending.popLast() {
            let resolvedDirectory = try resolved(directory)
            guard contained(resolvedDirectory, in: root), visited.insert(resolvedDirectory).inserted else {
                throw invalid(directory, "The artifact directory contains a cycle or path escape.")
            }
            let entries: [DirectoryEntry]
            do { entries = try fileSystem.directoryEntries(at: directory) }
            catch { throw invalid(directory, "The complete artifact directory could not be read: \(error)") }
            for entry in entries {
                if entry.isDirectory { pending.append(entry.path) }
                else if entry.isRegularFile { files.append(entry.path) }
                else { throw invalid(entry.path, "The artifact contains an unsupported filesystem entry.") }
            }
        }
        return files.sorted()
    }

    private func fileDigest(at path: String, maximumBytes: Int) throws -> (hash: String, byteCount: UInt64) {
        if fileSystem is LocalFileSystem {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                var hasher = SHA256()
                var count = 0
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    count += data.count
                    guard count <= maximumBytes else { throw invalid(path, "The artifact exceeds its size limit.") }
                    hasher.update(data: data)
                }
                return (hex(hasher.finalize()), UInt64(count))
            } catch let error as CartographError { throw error }
            catch { throw invalid(path, "The artifact could not be read: \(error)") }
        }
        let data = try readBounded(path, maximumBytes: maximumBytes)
        return (hex(SHA256.hash(data: data)), UInt64(data.count))
    }

    private func readBounded(_ path: String, maximumBytes: Int) throws -> Data {
        do {
            if fileSystem is LocalFileSystem {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                guard data.count <= maximumBytes else { throw invalid(path, "The file exceeds its size limit.") }
                return data
            }
            let data = try fileSystem.readData(at: path)
            guard data.count <= maximumBytes else { throw invalid(path, "The file exceeds its size limit.") }
            return data
        } catch let error as CartographError { throw error }
        catch { throw invalid(path, "The file could not be read: \(error)") }
    }

    private func resolved(_ path: String) throws -> String {
        do { return try fileSystem.realPath(at: path) }
        catch { throw invalid(path, "The path could not be resolved: \(error)") }
    }

    private func rejectSymbolicLink(at path: String) throws {
        guard fileSystem is LocalFileSystem else { return }
        try rejectDirectSymbolicLink(at: path)
        let url = URL(fileURLWithPath: path)
        guard fileSystem.directoryExists(at: path), let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return }
        for case let child as URL in enumerator {
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw invalid(child.path, "Symbolic links are not accepted as build evidence.")
            }
        }
    }

    private func rejectDirectSymbolicLink(at path: String) throws {
        guard fileSystem is LocalFileSystem else { return }
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw invalid(path, "Symbolic links are not accepted as build evidence.")
        }
    }

    private static func loadCompiledModel(at path: String) throws -> [CoreDataCompiledEntityMetadata]? {
        guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var result: [CoreDataCompiledEntityMetadata] = []
        for entity in model.entities {
            guard let name = entity.name, let className = entity.managedObjectClassName else { return nil }
            result.append(CoreDataCompiledEntityMetadata(
                name: name,
                managedObjectClassName: className,
                superentityName: entity.superentity?.name
            ))
        }
        return result
    }

    private func update(_ hasher: inout SHA256, value: String) {
        let data = Data(value.utf8)
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private func appAncestor(of path: String) -> String? {
        var current = path
        while current != "/" {
            if (current as NSString).pathExtension == "app" { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func contained(_ child: String, in root: String) -> Bool {
        child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func validContainerName(_ value: String) -> Bool {
        validLabel(value) && value.utf8.count <= 255 && !value.contains("/") && !value.contains("\\")
            && value != "." && value != ".."
    }

    private func validBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { part in
            let bytes = Array(part.utf8)
            guard let first = bytes.first, let last = bytes.last,
                  Self.asciiAlphanumeric(first), Self.asciiAlphanumeric(last) else { return false }
            return bytes.allSatisfy { Self.asciiAlphanumeric($0) || $0 == 45 }
        }
    }

    private func validModule(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_", value.utf8.count <= 255 else { return false }
        return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func validUSR(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && (value.hasPrefix("s:") || value.hasPrefix("c:")) && validLabel(value)
    }

    private func validTypeName(_ value: String) -> Bool {
        validLabel(value) && value.utf8.count <= 4_096
    }

    private func validLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func validArtifact(_ artifact: CoreDataBuildArtifact) -> Bool {
        !artifact.path.isEmpty && artifact.sha256.utf8.count == 64
            && artifact.sha256.allSatisfy(\.isHexDigit) && artifact.fileCount > 0
            && artifact.byteCount <= UInt64(Self.maximumExecutableBytes)
    }

    private func containsEntityDeclaration(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.range(of: "<!ENTITY", options: .caseInsensitive) != nil
    }

    private func containsUnsafeModelDeclaration(_ data: Data) -> Bool {
        guard let value = String(data: data, encoding: .utf8) else { return true }
        return value.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
            || value.range(of: "<!ENTITY", options: .caseInsensitive) != nil
    }

    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func validateOutputPath(_ path: String, against document: CoreDataBuildEvidenceDocument) throws {
        let absolute = path.hasPrefix("/")
            ? path : (fileSystem.currentDirectoryPath as NSString).appendingPathComponent(path)
        let output = (try? fileSystem.realPath(at: absolute)) ?? LocalFileSystem.canonicalPath(absolute)
        let protectedDirectories = [document.bundle.path, document.model.container.path]
        let protectedFiles = [document.executable.path, document.bundle.compiledModel.path]
            + document.declaredGeneratedMappings.map { $0.source.path }
        guard !protectedDirectories.contains(where: { contained(output, in: $0) }),
              !protectedFiles.contains(output) else {
            throw invalid(path, "Write build evidence outside the app bundle and model or generated-source inputs.")
        }
    }

    private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func invalid(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}

private struct BundleLayout {
    let bundle: String
    let executable: String
    let resources: String
    let identifier: String
}

private struct CompiledModel {
    let relativePath: String
    let artifact: CoreDataBuildArtifact
}

private struct SourceModel {
    let container: CoreDataBuildArtifact
    let contents: CoreDataBuildArtifact
    let marker: CoreDataBuildArtifact?
    let versionName: String?
    let entities: [SourceEntity]
}

private struct SourceEntity {
    let name: String
    let representedClassName: String?
    let codeGenerationType: String?
    let superentityName: String?
}

private final class CoreDataSourceEntityCollector: NSObject, XMLParserDelegate {
    private(set) var entities: [SourceEntity] = []
    private(set) var isModel = false
    private(set) var error: Error?
    private(set) var foundExternalEntity = false
    private(set) var foundInvalidEntity = false
    private var elements: [String] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String]
    ) {
        defer { elements.append(elementName) }
        if elements.isEmpty { isModel = elementName == "model" }
        guard elementName == "entity", elements == ["model"] else { return }
        guard let name = nonempty(attributeDict["name"]) else {
            foundInvalidEntity = true
            return
        }
        entities.append(SourceEntity(
            name: name, representedClassName: nonempty(attributeDict["representedClassName"]),
            codeGenerationType: nonempty(attributeDict["codeGenerationType"]),
            superentityName: nonempty(attributeDict["parentEntity"])
        ))
    }

    func parser(
        _: XMLParser,
        didEndElement _: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if !elements.isEmpty { elements.removeLast() }
    }

    func parser(_: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }

    func parser(
        _: XMLParser,
        foundExternalEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        foundExternalEntity = true
    }

    func parser(_: XMLParser, resolveExternalEntityName _: String, systemID _: String?) -> Data? {
        foundExternalEntity = true
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }
}
