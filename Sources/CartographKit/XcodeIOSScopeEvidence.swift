import CartographCore
import Foundation

/// Store는 필요한 값만 전달하며, iOS proof는 Store의 receipt 타입을 다시 참조하지 않는다.
struct XcodeIOSScopeContext {
    let projectRoot: String
    let architecture: String
    let products: [String: String]
    let after: [String: String]
    let packages: [XcodeLocalPackageEvidence]
}

/// v4만 iOS Simulator를 허용한다. 앱 코드 이미지와 호스트 stub의 바이트·load edge를 별도로 묶는다.
struct XcodeIOSScopeEvidence: Codable {
    let platform: String
    let indexStore: String
    let files: [String: XcodeLocalPackageProofFile]
    let targets: [NativeTarget]
    let resources: [Resource]

    struct NativeTarget: Codable {
        let targetID: String
        let compilations: [XcodeLocalPackageEvidence.Compilation]
        let records: [XcodeLocalPackageEvidence.Record]
        let link: XcodeLocalPackageEvidence.Link
        let executable: String
        let infoPlist: String
        var hostLink: XcodeLocalPackageEvidence.Link? = nil
    }
    struct Resource: Codable, Hashable { let targetID: String; let source: String; let output: String }

    func validateAdmissions(_ admissions: [SourceRecordAdmission], root: String, fileSystem: any FileSystem) throws {
        for target in targets {
            for record in target.records {
                guard let modified = fileSystem.modificationDate(at: record.source), admissions.filter({
                    XcodeEvidencePath.physicalTemporaryAlias($0.path, fileSystem: fileSystem) == record.source
                }).count == 1, admissions.contains(where: {
                    XcodeEvidencePath.physicalTemporaryAlias($0.path, fileSystem: fileSystem) == record.source
                        && $0.unit == record.unit && $0.record == record.record && $0.unitTargetTriple == record.targetTriple
                        && $0.unitOutputIdentity == record.unitOutputIdentity && $0.timestamp >= modified
                }) else { throw XcodeLocalPackageIO.invalid("iOS native source admissions differ from the captured compiler/record join.") }
            }
        }
    }

    func validate(context: XcodeIOSScopeContext, project: XcodeProjectMembership, closure: Set<String>,
                  settings: [String: [String: String]], buildRoot: String, fileSystem: any FileSystem) throws {
        guard platform == "ios-simulator", !targets.isEmpty, targets.count <= 1_000,
              Set(targets.map(\.targetID)) == closure, Set(targets.map(\.targetID)).count == targets.count,
              resources.count <= 1_000, Set(resources).count == resources.count,
              [String(buildRoot.dropLast("/Build".count)) + "/Index.noindex/DataStore",
               String(buildRoot.dropLast("/Build".count)) + "/Index/DataStore"].contains(indexStore) else {
            throw XcodeLocalPackageIO.invalid("iOS platform, native target closure or index store identity differs.")
        }
        var reader = try XcodeLocalPackageReader(files: files, buildRoot: buildRoot, indexStore: indexStore, fileSystem: fileSystem)
        var expectedResources: Set<Resource> = []
        // test host 이미지의 OS 임시 경로 별칭은 서로 다른 linker owner 번호로 나타날 수 있다.
        // 이 이미지들은 아래에서 전체 native proof로 검증하며 source object의 중복에는 쓰지 않는다.
        let nativeAppImages = nativeAppImages(in: project)
        for native in targets {
            guard let target = project.targets[native.targetID], let values = settings[target.name],
                  let directory = values["TARGET_BUILD_DIR"], let executable = values["EXECUTABLE_PATH"],
                  let product = values["FULL_PRODUCT_NAME"], let sdk = values["SDK_VERSION"],
                  let minimum = values["IPHONEOS_DEPLOYMENT_TARGET"], let module = values["PRODUCT_MODULE_NAME"],
                  values["PLATFORM_NAME"] == "iphonesimulator", values["SDK_NAME"] == "iphonesimulator" + sdk,
                  native.executable == directory + "/" + executable,
                  native.infoPlist == directory + "/" + product + "/Info.plist",
                  Set(native.compilations.map(\.source)) == Set(target.sources.map { context.projectRoot + "/" + $0 }),
                  native.compilations.count == target.sources.count, native.records.count == target.sources.count,
                  Set(native.records.map(\.source)) == Set(native.compilations.map(\.source)),
                  Set(native.compilations.map(\.object)).count == native.compilations.count else {
                throw XcodeLocalPackageIO.invalid("iOS target compiler, SDK, source membership or executable binding differs.")
            }
            let sdkIdentity = try XcodeIOSSDKIdentity(settings: values, fileSystem: fileSystem)
            let triple = context.architecture + "-apple-ios" + minimum + "-simulator"
            for compilation in native.compilations {
                guard compilation.targetTriple == triple else { throw XcodeLocalPackageIO.invalid("iOS native compilation deployment target differs.") }
                try XcodeLocalPackageEvidence.validateCompilation(compilation,
                    sources: Set(native.compilations.map(\.source)), module: module, architecture: context.architecture,
                    iosSimulator: true, reader: &reader)
                let argv = try reader.arguments(compilation.argv, sourceFileList: compilation.sourceFileList)
                guard try sdkIdentity.matches(XcodeLocalPackageIO.argument("-sdk", in: argv), fileSystem: fileSystem) else {
                    throw XcodeLocalPackageIO.invalid("iOS compiler SDK differs from its effective settings.")
                }
            }
            try XcodeLocalPackageEvidence.validateRecords(native.records, compilations: native.compilations, indexStore: indexStore, reader: &reader, fileSystem: fileSystem)
            _ = try XcodeLocalPackageEvidence.validateLink(native.link, required: Set(native.compilations.map(\.object)),
                architecture: context.architecture, relocatable: false, iosSimulator: true,
                allowedRepeatedOwners: nativeAppImages, reader: &reader)
            let linkArgs = try reader.arguments(native.link.argv, sourceFileList: native.link.fileList)
            guard try XcodeLocalPackageIO.argument("-target", in: linkArgs) == triple,
                  try sdkIdentity.matches(XcodeLocalPackageIO.argument("-isysroot", in: linkArgs), fileSystem: fileSystem) else {
                throw XcodeLocalPackageIO.invalid("iOS linker SDK or deployment minimum differs from its target compilation.")
            }
            let info = try PropertyListSerialization.propertyList(from: reader.read(native.infoPlist, kind: "document"), format: nil) as? [String: Any]
            guard info?["CFBundleExecutable"] as? String == (executable as NSString).lastPathComponent,
                  info?["CFBundleIdentifier"] as? String == values["PRODUCT_BUNDLE_IDENTIFIER"],
                  context.products[native.infoPlist] == files[native.infoPlist]?.sha256 else {
                throw XcodeLocalPackageIO.invalid("iOS bundle metadata differs from its target executable identity.")
            }
            let codeImage = try image(native.link.output, context: context, reader: &reader)
            guard codeImage.minimum == XcodeIOSMachO.version(minimum), codeImage.sdk == XcodeIOSMachO.version(sdk) else {
                throw XcodeLocalPackageIO.invalid("iOS image build version differs from effective SDK/deployment settings.")
            }
            if let host = native.hostLink {
                let bundle = directory + "/" + product
                let name = (executable as NSString).lastPathComponent
                let identity = "@rpath/" + name + ".debug.dylib"
                guard target.productType == "com.apple.product-type.application", values["ENABLE_DEBUG_DYLIB"] == "YES",
                      native.link.output == bundle + "/" + name + ".debug.dylib", host.output == native.executable,
                      codeImage.fileType == 6, codeImage.installName == identity,
                      try XcodeLocalPackageIO.argument("-install_name", in: linkArgs) == identity else {
                    throw XcodeLocalPackageIO.invalid("iOS debug dylib code image is not the captured host's installed image.")
                }
                let argv = try reader.arguments(host.argv)
                guard try XcodeLocalPackageIO.argument("-o", in: argv) == native.executable,
                      try XcodeLocalPackageIO.argument("-target", in: argv) == triple,
                      try sdkIdentity.matches(XcodeLocalPackageIO.argument("-isysroot", in: argv), fileSystem: fileSystem),
                      try XcodeLocalPackageIO.argument("-map", in: argv) == host.linkMap,
                      try XcodeLocalPackageIO.argument("-filelist", in: argv) == host.fileList,
                      argv.filter({ $0 == native.link.output }).count == 1 else {
                    throw XcodeLocalPackageIO.invalid("iOS host stub actual linker operands differ from its code image.")
                }
                // executor archive는 source 범위 증거로 쓰지 않는다. filelist는 캡처 내부 문서로만 묶는다.
                _ = try reader.read(host.fileList, kind: "document")
                try XcodeLinkMapEvidence.validate(try reader.read(host.linkMap, kind: "document"), output: host.output,
                    architecture: context.architecture, required: [], fileSystem: fileSystem)
                let stub = try image(host.output, context: context, reader: &reader)
                guard stub.fileType == 2, stub.minimum == codeImage.minimum, stub.sdk == codeImage.sdk,
                      stub.loads.contains(identity), stub.runpaths.contains("@executable_path") || stub.runpaths.contains("@loader_path") else {
                    throw XcodeLocalPackageIO.invalid("iOS host stub lacks the bounded strong debug-dylib load edge.")
                }
            } else {
                guard native.link.output == native.executable,
                      codeImage.fileType == (target.productType == "com.apple.product-type.application" ? 2 : 8) else {
                    throw XcodeLocalPackageIO.invalid("iOS native executable link identity differs.")
                }
            }
            // 각 모듈의 배포 하한은 같을 필요가 없다. package 15 → host 18은 정상이며 반대는 거부한다.
            for package in context.packages where package.consumers.contains(native.targetID) {
                guard let value = package.compilations.first?.targetTriple,
                      XcodeScopeInputRules.validTriple(value, architecture: context.architecture, iosSimulator: true),
                      let packageMinimum = XcodeIOSMachO.version(String(value.dropFirst((context.architecture + "-apple-ios").count).dropLast("-simulator".count))),
                      packageMinimum <= codeImage.minimum else { throw XcodeLocalPackageIO.invalid("Package deployment minimum is incompatible with its native consumer.") }
            }
            for resource in target.resources {
                let output = directory + "/" + product + "/" + (resource as NSString).lastPathComponent
                let row = Resource(targetID: native.targetID, source: resource, output: output)
                guard context.after[resource] == context.products[output], context.products[output] != nil else {
                    throw XcodeLocalPackageIO.invalid("A plain resource copy differs from its complete captured input/bundle bytes.")
                }
                expectedResources.insert(row)
            }
            // 선언된 header를 Swift definition unit으로 세지 않는다. 전체 바이트는 입력 inventory에 묶는다.
        }
        guard Set(resources) == expectedResources, reader.used == Set(files.keys) else {
            throw XcodeLocalPackageIO.invalid("iOS auxiliary evidence or proof file accounting differs.")
        }
    }

    /// 이 경로들은 validate가 전체 앱 image proof를 확인한 뒤에만 최종 receipt로 인정된다.
    func nativeAppImages(in project: XcodeProjectMembership) -> Set<String> {
        Set(targets.filter {
            project.targets[$0.targetID]?.productType == "com.apple.product-type.application"
        }.map { $0.link.output })
    }

    private func image(_ path: String, context: XcodeIOSScopeContext, reader: inout XcodeLocalPackageReader) throws -> XcodeIOSMachO {
        _ = try reader.read(path, kind: "object")
        let data = try XcodeLocalPackageIO.bounded(path, maximum: 64 * 1_024 * 1_024, fileSystem: reader.fileSystem)
        guard context.products[path] == files[path]?.sha256, TargetScopeStore.digest(data) == files[path]?.sha256 else {
            throw XcodeLocalPackageIO.invalid("iOS image bytes differ from captured whole products and link proof.")
        }
        return try XcodeIOSMachO(data, architecture: context.architecture)
    }
}

/// SDKROOT와 SDK_DIR의 두 Xcode SDK 이름만 같은 실제 SDK 디렉터리에 묶는다.
struct XcodeIOSSDKIdentity {
    let canonicalRoot: String
    private let paths: Set<String>

    init(settings: [String: String], fileSystem: any FileSystem) throws {
        guard let developer = settings["DEVELOPER_DIR"], let version = settings["SDK_VERSION"],
              let root = settings["SDKROOT"], let directory = settings["SDK_DIR"],
              developer.hasPrefix("/"), XcodeIOSMachO.version(version) != nil else {
            throw XcodeLocalPackageIO.invalid("Missing effective iOS SDK identity settings.")
        }
        let prefix = developer + "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator"
        let allowed: Set<String> = [prefix + ".sdk", prefix + version + ".sdk"]
        let canonical = try fileSystem.realPath(at: root)
        guard allowed.contains(root), directory == prefix + version + ".sdk", allowed.contains(canonical),
              fileSystem.directoryExists(at: root), fileSystem.directoryExists(at: directory),
              try fileSystem.realPath(at: directory) == canonical else {
            throw XcodeLocalPackageIO.invalid("Effective iOS SDK aliases do not bind one versioned SDK directory.")
        }
        canonicalRoot = canonical
        paths = allowed
    }

    func matches(_ path: String, fileSystem: any FileSystem) throws -> Bool {
        guard paths.contains(path), fileSystem.directoryExists(at: path) else { return false }
        return try fileSystem.realPath(at: path) == canonicalRoot
    }
}
