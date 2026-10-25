import CartographCore
import Foundation

/// 선언만으로 package를 범위에 넣지 않는다. 실제 source→unit→object→link owner를 함께 확인한다.
struct XcodeLocalPackageEvidence: Codable {
    let path: String
    let referenceID: String
    let productReferenceID: String
    let name: String
    let product: String
    let module: String
    let inventory: [String: String]
    let generatedMetadataOrigin: GeneratedMetadataOrigin
    let consumers: [String]
    let indexStore: String
    let files: [String: XcodeLocalPackageProofFile]
    let compilations: [Compilation]
    let records: [Record]
    let aggregate: Link
    let links: [ConsumerLink]
    var project: String? = nil
    var declarations: [ProjectDeclaration]? = nil
    var aggregateCandidateFileLists: [String]? = nil
    var dynamicProduct: DynamicProduct? = nil

    /// 같은 물리 package를 소비하는 각 프로젝트의 원문 PBX 신원을 보존한다.
    struct ProjectDeclaration: Codable {
        let project: String
        let referenceID: String
        let productReferenceID: String
        let consumers: [String]
    }

    /// 서명되지 않은 capture 생산자의 관측이며, 과거 생성 주체의 독립 증명이 아니다.
    enum GeneratedMetadataOrigin: String, Codable {
        case absent
        case preexisting
        case captureCreated = "capture-created"
    }

    struct Compilation: Codable {
        let source: String
        let argv: [String]
        let outputMap: String
        let sourceFileList: String
        let object: String
        let unitOutputIdentity: String
        let targetTriple: String
    }
    struct Record: Codable, Hashable {
        let source: String
        let unit: String
        let record: String
        let unitOutputIdentity: String
        let targetTriple: String
        let path: String
    }
    struct Link: Codable {
        let argv: [String]
        let fileList: String
        let output: String
        let linkMap: String
        var fileListMode: String? = nil
    }
    struct ConsumerLink: Codable { let targetID: String; let link: Link; var packageInput: String? = nil }
    struct DynamicProduct: Codable {
        let link: Link
        let bundle: String
        let infoPlist: String
        let installName: String
    }

    var declaration: XcodeProjectMembership.LocalPackage {
        .init(path: path, referenceID: referenceID, productReferenceID: productReferenceID, product: product)
    }

    func sourcePaths(root: String) -> Set<String> {
        Set(inventory.filter { $0.key.hasPrefix("Sources/" + module + "/") && $0.value != "directory" }
            .keys.map { root + "/" + path + "/" + $0 })
    }

    /// 주입 provider의 과거 snapshot을 이 검사만으로 native fresh read로 인증하지 않는다.
    func validateAdmissions(_ admissions: [SourceRecordAdmission], root: String,
                            fileSystem: any FileSystem) throws {
        let sources = sourcePaths(root: root)
        let actual = admissions.map { $0.rebased { XcodeEvidencePath.physicalTemporaryAlias($0, fileSystem: fileSystem) } }
            .filter { sources.contains($0.path) }
        guard actual.count == records.count else { throw XcodeLocalPackageIO.invalid("Package source record contexts differ from the capture.") }
        for record in records {
            guard let modified = fileSystem.modificationDate(at: record.source), actual.contains(where: {
                $0.path == record.source && $0.module == module && $0.unit == record.unit && $0.record == record.record
                    && $0.unitOutputIdentity == record.unitOutputIdentity && $0.unitTargetTriple == record.targetTriple
                    && $0.timestamp >= modified
            }) else { throw XcodeLocalPackageIO.invalid("Missing, stale or conflicting actual package source record admission.") }
        }
    }

    /// 호출 전후 동일 receipt를 검증한다. 이 관측 사이의 원자적 filesystem snapshot을 주장하지 않는다.
    func validate(root: String, buildRoot: String, architecture: String, project: XcodeProjectMembership,
                  closure: Set<String>, products: [String: String], nativeProducts: [String: String],
                  nativeModules: Set<String>, fileSystem: any FileSystem, iosSimulator: Bool = false) throws {
        guard XcodeProjectMembership.relative(path), !nativeModules.contains(module),
              consumers.count <= 1_000, Set(consumers).count == consumers.count,
              Set(consumers) == project.packageConsumers, !Set(consumers).isDisjoint(with: closure),
              buildRoot.hasSuffix("/DerivedData/Build"),
              [String(buildRoot.dropLast("/Build".count)) + "/Index/DataStore",
               String(buildRoot.dropLast("/Build".count)) + "/Index.noindex/DataStore"].contains(indexStore),
              try fileSystem.realPath(at: indexStore) == indexStore else {
            throw XcodeLocalPackageIO.invalid("Package identity, native consumer closure or index store boundary is unsupported.")
        }
        let packageRoot = root + "/" + path
        let currentInventory = try XcodeLocalPackageInputs.inventory(root: packageRoot, module: module, fileSystem: fileSystem)
        let manifestBytes = try XcodeLocalPackageIO.bounded(packageRoot + "/Package.swift", maximum: 64 * 1_024, fileSystem: fileSystem)
        let manifest = try XcodeLocalPackageInputs.manifest(manifestBytes)
        guard manifest == .init(name: name, product: product, module: module), currentInventory == inventory else {
            throw XcodeLocalPackageIO.invalid("Package literal manifest or complete subtree bytes changed.")
        }
        let metadataPresent = try XcodeLocalPackageInputs.generatedMetadataIsPresent(in: inventory)
        guard metadataPresent == (generatedMetadataOrigin != .absent) else {
            throw XcodeLocalPackageIO.invalid("Package metadata origin differs from its complete captured inventory.")
        }
        let sources = sourcePaths(root: root)
        let nativeSources = Set(project.targets.values.flatMap { $0.sources.map { root + "/" + $0 } })
        guard sources.isDisjoint(with: nativeSources),
              (1...256).contains(sources.count), compilations.count == sources.count,
              Set(compilations.map(\.source)) == sources, Set(compilations.map(\.object)).count == sources.count,
              Set(compilations.map(\.targetTriple)).count == 1, Set(compilations.map(\.outputMap)).count == 1,
              Set(compilations.map(\.sourceFileList)).count == 1,
              Set(compilations.map { XcodeLocalPackageIO.normalizedCommand($0.argv) }).count == 1,
              records.count == sources.count, Set(records.map(\.source)) == sources,
              Set(records.map(\.record)).count == records.count, Set(records).count == records.count,
              files.count <= 1_024, !files.isEmpty, links.count == consumers.count,
              Set(links.map(\.targetID)) == Set(consumers) else {
            throw XcodeLocalPackageIO.invalid("Package compilation/record/link sets are missing, shared or ambiguous.")
        }
        var reader = try XcodeLocalPackageReader(files: files, buildRoot: buildRoot, indexStore: indexStore, fileSystem: fileSystem)
        for compilation in compilations {
            try Self.validateCompilation(compilation, sources: sources, module: module, architecture: architecture, iosSimulator: iosSimulator, reader: &reader)
        }
        try Self.validateRecords(records, compilations: compilations, indexStore: indexStore, reader: &reader, fileSystem: fileSystem)
        let objects = Set(compilations.map(\.object))
        let candidates = aggregateCandidateFileLists ?? [aggregate.fileList]
        guard (1...256).contains(candidates.count), Set(candidates).count == candidates.count,
              candidates.contains(aggregate.fileList) else { throw XcodeLocalPackageIO.invalid("Aggregate candidate file-list identities are invalid.") }
        var matches: Set<String> = [], wrapperLists: Set<String> = []
        for candidate in candidates {
            let inputs = Set(try reader.fileList(candidate))
            if inputs == objects { matches.insert(candidate) }
            if inputs == [aggregate.output] { wrapperLists.insert(candidate) }
        }
        guard matches == [aggregate.fileList] else { throw XcodeLocalPackageIO.invalid("Package aggregate object membership is ambiguous.") }
        let aggregateInputs = try Self.validateLink(aggregate, required: objects, architecture: architecture,
            relocatable: true, iosSimulator: iosSimulator, reader: &reader)
        guard aggregateInputs == objects, products[aggregate.output] == files[aggregate.output]?.sha256 else {
            throw XcodeLocalPackageIO.invalid("Package aggregate contains unbound objects or is absent from captured products.")
        }
        if let wrapper = dynamicProduct {
            guard wrapperLists == [wrapper.link.fileList], wrapper.link.fileListMode == "response",
                  links.contains(where: { $0.packageInput == wrapper.link.output }),
                  Set(try Self.validateLink(wrapper.link, required: [aggregate.output], architecture: architecture,
                    relocatable: false, iosSimulator: iosSimulator, reader: &reader)) == [aggregate.output],
                  products[wrapper.link.output] == files[wrapper.link.output]?.sha256 else {
                throw XcodeLocalPackageIO.invalid("Dynamic package product lacks a unique positive aggregate link.")
            }
            try validateDynamicProduct(wrapper, buildRoot: buildRoot, products: products, reader: &reader)
        } else if !wrapperLists.isEmpty {
            throw XcodeLocalPackageIO.invalid("Unbound dynamic package product candidates remain.")
        }
        for consumer in links {
            guard nativeProducts[consumer.targetID] == consumer.link.output,
                  products[consumer.link.output] == files[consumer.link.output]?.sha256 else {
                throw XcodeLocalPackageIO.invalid("Package consumer link does not target its actual native executable.")
            }
            let input = consumer.packageInput ?? aggregate.output
            guard input == aggregate.output || input == dynamicProduct?.link.output else {
                throw XcodeLocalPackageIO.invalid("Native package input differs from its proved aggregate/product.")
            }
            _ = try Self.validateLink(consumer.link, required: [input], architecture: architecture,
                relocatable: false, iosSimulator: iosSimulator, reader: &reader)
        }
        guard reader.used == Set(files.keys) else { throw XcodeLocalPackageIO.invalid("Unexpected or unused package proof file identities.") }
    }

    private func validateDynamicProduct(_ wrapper: DynamicProduct, buildRoot: String, products: [String: String],
                                        reader: inout XcodeLocalPackageReader) throws {
        let name = ((wrapper.bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        let allowedOutputs = [wrapper.bundle + "/" + name, wrapper.bundle + "/Versions/A/" + name]
        let allowedInfo = [wrapper.bundle + "/Info.plist", wrapper.bundle + "/Versions/A/Resources/Info.plist"]
        guard wrapper.bundle.hasPrefix(buildRoot + "/Products/"), wrapper.bundle.hasSuffix(".framework"),
              try reader.fileSystem.realPath(at: wrapper.bundle) == wrapper.bundle,
              allowedOutputs.contains(wrapper.link.output), allowedInfo.contains(wrapper.infoPlist),
              products[wrapper.infoPlist] == files[wrapper.infoPlist]?.sha256,
              let info = try PropertyListSerialization.propertyList(from: reader.read(wrapper.infoPlist, kind: "document"), format: nil) as? [String: Any],
              info["CFBundleExecutable"] as? String == name, info["CFBundlePackageType"] as? String == "FMWK" else {
            throw XcodeLocalPackageIO.invalid("Dynamic package bundle/executable metadata identity is unsupported.")
        }
        let argv = try reader.arguments(wrapper.link.argv, sourceFileList: wrapper.link.fileList)
        let parent = (wrapper.bundle as NSString).deletingLastPathComponent
        guard wrapper.installName == "@rpath/" + String(wrapper.link.output.dropFirst(parent.count + 1)),
              try XcodeLocalPackageIO.argument("-install_name", in: argv) == wrapper.installName else {
            throw XcodeLocalPackageIO.invalid("Dynamic package product install identity differs from its actual link.")
        }
    }

    static func validateCompilation(_ compilation: Compilation, sources: Set<String>, module: String, architecture: String,
                                     iosSimulator: Bool = false, reader: inout XcodeLocalPackageReader) throws {
        let argv = try reader.arguments(compilation.argv, sourceFileList: compilation.sourceFileList)
        guard try XcodeLocalPackageIO.argument("-module-name", in: argv) == module,
              try XcodeLocalPackageIO.argument("-output-file-map", in: argv) == compilation.outputMap,
              try XcodeLocalPackageIO.argument("-index-store-path", in: argv) == reader.indexStore,
              try XcodeLocalPackageIO.argument("-target", in: argv) == compilation.targetTriple,
              XcodeIOSScopeEvidence.validTriple(compilation.targetTriple, architecture: architecture, iosSimulator: iosSimulator),
              argv.filter({ $0 == "@" + compilation.sourceFileList }).count == 1,
              Set(try reader.fileList(compilation.sourceFileList)) == sources else {
            throw XcodeLocalPackageIO.invalid("Compiler module, target, source file list or output-map identity is inconsistent.")
        }
        let data = try reader.read(compilation.outputMap, kind: "document")
        let rawMap = try JSONDecoder().decode([String: [String: String]].self, from: data)
        let pairs = rawMap.map { (XcodeEvidencePath.physicalTemporaryAlias($0.key, fileSystem: reader.fileSystem), $0.value) }
        guard Set(pairs.map(\.0)).count == pairs.count else { throw XcodeLocalPackageIO.invalid("Duplicate physical compiler source identity.") }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        guard Set(map.keys.filter { !$0.isEmpty }) == sources,
              let mapObject = map[compilation.source]?["object"],
              XcodeEvidencePath.physicalTemporaryAlias(mapObject, fileSystem: reader.fileSystem) == compilation.object,
              map[compilation.source]?["index-unit-output-path"] == compilation.unitOutputIdentity,
              !compilation.unitOutputIdentity.isEmpty else {
            throw XcodeLocalPackageIO.invalid("Actual compiler output map differs from package source/unit/object identities.")
        }
        _ = try reader.read(compilation.object, kind: "object")
    }

    static func validateRecords(_ records: [Record], compilations: [Compilation], indexStore: String, reader: inout XcodeLocalPackageReader, fileSystem: any FileSystem) throws {
        // record 이름으로 shard path를 추정하지 않는다. 전체 후보를 유한하게 열거해 유일성을 확인한다.
        let recordRoot = indexStore + "/v5/records"
        guard try fileSystem.realPath(at: recordRoot) == recordRoot,
              fileSystem.directoryExists(at: recordRoot) else {
            throw XcodeLocalPackageIO.invalid("Only the observed v5 backing record directory is supported.")
        }
        var found: [String: [String]] = [:], pending = [(recordRoot, 0)], count = 0
        let wanted = Set(records.map(\.record))
        while let (directory, depth) = pending.popLast() {
            guard depth <= 8 else { throw XcodeLocalPackageIO.invalid("Index record discovery depth exceeds budget.") }
            for entry in try fileSystem.directoryEntries(at: directory, maximumEntries: 50_000 - count) {
                count += 1
                guard !entry.isSymbolicLink, entry.path.hasPrefix(directory + "/"),
                      !entry.path.dropFirst(directory.count + 1).contains("/"),
                      try fileSystem.realPath(at: entry.path) == entry.path else {
                    throw XcodeLocalPackageIO.invalid("Index record discovery encountered a noncanonical or symlinked entry.")
                }
                if entry.isDirectory { pending.append((entry.path, depth + 1)) }
                else if wanted.contains((entry.path as NSString).lastPathComponent) {
                    guard entry.isRegularFile else { throw XcodeLocalPackageIO.invalid("Package backing record is not a regular file.") }
                    found[(entry.path as NSString).lastPathComponent, default: []].append(entry.path)
                }
            }
        }
        for record in records {
            guard !record.unit.isEmpty, !record.record.isEmpty, !record.record.contains("/"),
                  found[record.record] == [record.path], let compilation = compilations.first(where: { $0.source == record.source }),
                  compilation.unitOutputIdentity == record.unitOutputIdentity, compilation.targetTriple == record.targetTriple else {
                throw XcodeLocalPackageIO.invalid("Package backing record is missing, duplicated or disagrees with its compiler unit.")
            }
            _ = try reader.read(record.path, kind: "record")
        }
    }

    static func validateLink(_ link: Link, required: Set<String>, architecture: String,
                              relocatable: Bool, iosSimulator: Bool = false, reader: inout XcodeLocalPackageReader) throws -> Set<String> {
        let mode = link.fileListMode ?? "operand"
        guard ["operand", "response"].contains(mode) else { throw XcodeLocalPackageIO.invalid("Unknown linker file-list mode.") }
        let argv = try reader.arguments(link.argv, sourceFileList: mode == "response" ? link.fileList : nil)
        if mode == "response" {
            guard !relocatable, argv.contains("-emit-library"), !argv.contains("-filelist"),
                  argv.filter({ $0 == "@" + link.fileList }).count == 1 else { throw XcodeLocalPackageIO.invalid("Ambiguous linker response file-list identity.") }
        } else if try XcodeLocalPackageIO.argument("-filelist", in: argv) != link.fileList {
            throw XcodeLocalPackageIO.invalid("Linker file-list operand differs.")
        }
        guard try XcodeLocalPackageIO.argument("-o", in: argv) == link.output,
              try XcodeLocalPackageIO.argument("-map", in: argv) == link.linkMap,
              argv.contains("-r") == relocatable,
              XcodeIOSScopeEvidence.validTriple(try XcodeLocalPackageIO.argument("-target", in: argv), architecture: architecture, iosSimulator: iosSimulator) else {
            throw XcodeLocalPackageIO.invalid("Actual linker operands differ from the recorded link step.")
        }
        var inputs = Set(try reader.fileList(link.fileList))
        for input in required.subtracting(inputs) {
            guard !relocatable, argv.contains(input) else { throw XcodeLocalPackageIO.invalid("Required package input is absent from actual linker operands.") }
            inputs.insert(input)
        }
        for input in inputs { _ = try reader.read(input, kind: "object") }
        _ = try reader.read(link.output, kind: "object")
        try XcodeLinkMapEvidence.validate(try reader.read(link.linkMap, kind: "document"),
            output: link.output, architecture: architecture, required: required, fileSystem: reader.fileSystem)
        return inputs
    }

}
