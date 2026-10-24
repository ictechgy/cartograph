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
    }
    struct ConsumerLink: Codable { let targetID: String; let link: Link }

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
        let actual = admissions.filter { sources.contains($0.path) }
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
                  nativeModules: Set<String>, fileSystem: any FileSystem) throws {
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
            try validateCompilation(compilation, sources: sources, architecture: architecture, reader: &reader)
        }
        try validateRecords(reader: &reader, fileSystem: fileSystem)
        let objects = Set(compilations.map(\.object))
        let aggregateInputs = try validateLink(aggregate, required: objects, architecture: architecture,
            relocatable: true, reader: &reader)
        guard aggregateInputs == objects, products[aggregate.output] == files[aggregate.output]?.sha256 else {
            throw XcodeLocalPackageIO.invalid("Package aggregate contains unbound objects or is absent from captured products.")
        }
        for consumer in links {
            guard nativeProducts[consumer.targetID] == consumer.link.output,
                  products[consumer.link.output] == files[consumer.link.output]?.sha256 else {
                throw XcodeLocalPackageIO.invalid("Package consumer link does not target its actual native executable.")
            }
            _ = try validateLink(consumer.link, required: [aggregate.output], architecture: architecture,
                relocatable: false, reader: &reader)
        }
        guard reader.used == Set(files.keys) else { throw XcodeLocalPackageIO.invalid("Unexpected or unused package proof file identities.") }
    }

    private func validateCompilation(_ compilation: Compilation, sources: Set<String>, architecture: String,
                                     reader: inout XcodeLocalPackageReader) throws {
        let argv = try reader.arguments(compilation.argv, sourceFileList: compilation.sourceFileList)
        guard try XcodeLocalPackageIO.argument("-module-name", in: argv) == module,
              try XcodeLocalPackageIO.argument("-output-file-map", in: argv) == compilation.outputMap,
              try XcodeLocalPackageIO.argument("-index-store-path", in: argv) == indexStore,
              try XcodeLocalPackageIO.argument("-target", in: argv) == compilation.targetTriple,
              compilation.targetTriple.range(of: "^" + architecture + #"-apple-macos[0-9]+(?:\.[0-9]+)*$"#,
                  options: .regularExpression) != nil,
              compilation.argv.filter({ $0 == "@" + compilation.sourceFileList }).count == 1,
              Set(try reader.fileList(compilation.sourceFileList)) == sources else {
            throw XcodeLocalPackageIO.invalid("Compiler module, target, source file list or output-map identity is inconsistent.")
        }
        let data = try reader.read(compilation.outputMap, kind: "document")
        let map = try JSONDecoder().decode([String: [String: String]].self, from: data)
        guard Set(map.keys.filter { !$0.isEmpty }) == sources,
              map[compilation.source]?["object"] == compilation.object,
              map[compilation.source]?["index-unit-output-path"] == compilation.unitOutputIdentity,
              !compilation.unitOutputIdentity.isEmpty else {
            throw XcodeLocalPackageIO.invalid("Actual compiler output map differs from package source/unit/object identities.")
        }
        _ = try reader.read(compilation.object, kind: "object")
    }

    private func validateRecords(reader: inout XcodeLocalPackageReader, fileSystem: any FileSystem) throws {
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

    private func validateLink(_ link: Link, required: Set<String>, architecture: String,
                              relocatable: Bool, reader: inout XcodeLocalPackageReader) throws -> Set<String> {
        let argv = try reader.arguments(link.argv)
        guard try XcodeLocalPackageIO.argument("-filelist", in: argv) == link.fileList,
              try XcodeLocalPackageIO.argument("-o", in: argv) == link.output,
              try XcodeLocalPackageIO.argument("-map", in: argv) == link.linkMap,
              argv.contains("-r") == relocatable,
              try XcodeLocalPackageIO.argument("-target", in: argv).range(
                of: "^" + architecture + #"-apple-macos[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else {
            throw XcodeLocalPackageIO.invalid("Actual linker operands differ from the recorded link step.")
        }
        let inputs = Set(try reader.fileList(link.fileList))
        guard required.isSubset(of: inputs) else { throw XcodeLocalPackageIO.invalid("Required package object is absent from the actual linker file list.") }
        for input in inputs { _ = try reader.read(input, kind: "object") }
        _ = try reader.read(link.output, kind: "object")
        try XcodeLinkMapEvidence.validate(try reader.read(link.linkMap, kind: "document"),
            output: link.output, architecture: architecture, required: required)
        return inputs
    }

}
