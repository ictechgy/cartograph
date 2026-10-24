import CartographCore
import Foundation

/// 지원하는 명시 PBX source phase만 해석한다. 동기화 그룹과 조건부 입력은 추정하지 않는다.
struct XcodeProjectMembership {
    struct Target {
        let name: String
        let productType: String
        let sources: [String]
        let dependencies: [String]
    }
    struct FrameworkReference: Hashable { let sourceTree: String; let path: String }
    struct LocalPackage {
        let path: String
        let referenceID: String
        let productReferenceID: String
        let product: String
    }
    let targets: [String: Target]
    let frameworks: Set<FrameworkReference>
    let packageConsumers: Set<String>

    init(targets: [String: Target], frameworks: Set<FrameworkReference>, packageConsumers: Set<String>) {
        self.targets = targets
        self.frameworks = frameworks
        self.packageConsumers = packageConsumers
    }

    init(data: Data, root: String, localPackage: LocalPackage? = nil) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]], objects.count <= 50_000,
              let rootID = plist["rootObject"] as? String, let project = objects[rootID],
              project["isa"] as? String == "PBXProject", let main = project["mainGroup"] as? String,
              let targetIDs = project["targets"] as? [String], !targetIDs.isEmpty, targetIDs.count <= 1_000,
              (project["packageReferences"] as? [String] ?? []) == (localPackage.map({ [$0.referenceID] }) ?? []),
              (project["projectReferences"] as? [Any] ?? []).isEmpty,
              (project["projectDirPath"] as? String ?? "").isEmpty,
              (project["projectRoot"] as? String ?? "").isEmpty else {
            throw Self.invalid("Only bounded single-project target membership is supported.")
        }
        if let package = localPackage {
            guard Self.relative(package.path), package.referenceID != package.productReferenceID,
                  let reference = objects[package.referenceID], reference["isa"] as? String == "XCLocalSwiftPackageReference",
                  Set(reference.keys) == ["isa", "relativePath"],
                  reference["relativePath"] as? String == package.path,
                  let product = objects[package.productReferenceID], product["isa"] as? String == "XCSwiftPackageProductDependency",
                  Set(product.keys) == ["isa", "package", "productName"],
                  product["package"] as? String == package.referenceID,
                  product["productName"] as? String == package.product else {
                throw Self.invalid("The local package declaration differs from the captured literal product.")
            }
        }
        // 첫 build 이전에도 같은 unsupported 입력을 생산자가 거부한다. 소비자는 원문을 다시 확인한다.
        for (id, object) in objects {
            let isa = object["isa"] as? String ?? ""
            if isa.contains("SwiftPackage") {
                guard let package = localPackage,
                      (id == package.referenceID && isa == "XCLocalSwiftPackageReference")
                        || (id == package.productReferenceID && isa == "XCSwiftPackageProductDependency") else {
                    throw Self.invalid("Additional, remote or unsupported package declarations are not allowed.")
                }
            }
            guard !["PBXShellScriptBuildPhase", "PBXBuildRule", "PBXAggregateTarget",
                     "PBXFileSystemSynchronizedRootGroup"].contains(isa),
                  object["platformFilter"] == nil, object["platformFilters"] == nil else {
                throw Self.invalid("Scripts, synchronized groups, packages or platform-filtered membership are unsupported.")
            }
            if let settings = object["buildSettings"] as? [String: Any] {
                guard !settings.keys.contains(where: { key in
                    key.contains("[") || (key == "SDKROOT" && settings[key] as? String != "macosx")
                        || (key == "LD_RUNPATH_SEARCH_PATHS" && !Self.validRunpaths(settings[key]!))
                        || ["EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES",
                        "SWIFT_OBJC_BRIDGING_HEADER", "GCC_PREFIX_HEADER", "SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
                        "CC", "CXX", "LD", "OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS", "SWIFT_INCLUDE_PATHS",
                        "HEADER_SEARCH_PATHS", "FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "DEVELOPER_DIR",
                         "CONFIGURATION_BUILD_DIR", "CONFIGURATION_TEMP_DIR", "BUILD_DIR", "BUILD_ROOT", "BUILT_PRODUCTS_DIR", "OBJROOT", "SYMROOT", "DSTROOT", "TARGET_BUILD_DIR", "TARGET_TEMP_DIR", "TEMP_DIR", "DERIVED_FILE_DIR", "SHARED_PRECOMPS_DIR", "INDEX_DATA_STORE_DIR", "TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME", "LD_DYLIB_INSTALL_NAME", "DYLIB_INSTALL_NAME_BASE", "INFOPLIST_FILE", "INFOPLIST_PREFIX_HEADER", "CODE_SIGN_ENTITLEMENTS", "MODULEMAP_FILE", "MODULEMAP_PRIVATE_FILE"].contains(key)
                        && !["", "$(inherited)"].contains(String(describing: settings[key]!))
                }) else { throw Self.invalid("Conditional build settings or source filters leave membership unknown.") }
            }
            guard object["baseConfigurationReference"] == nil else {
                throw Self.invalid("External xcconfig evaluation is unsupported in this receipt version.")
            }
        }
        var paths: [String: String] = [:], seen: Set<String> = []
        var pending = [(main, "", 0)]
        while let (id, parent, depth) = pending.popLast() {
            guard depth <= 128, seen.insert(id).inserted, let object = objects[id] else {
                throw Self.invalid("Project group ownership is cyclic, shared or missing.")
            }
            let kind = object["isa"] as? String
            let tree = object["sourceTree"] as? String ?? "<group>"
            let path = object["path"] as? String ?? ""
            if !["<group>", "SOURCE_ROOT"].contains(tree) { continue }
            guard path.isEmpty || Self.relative(path) else { throw Self.invalid("Project paths must remain inside the root.") }
            let combined = [tree == "SOURCE_ROOT" ? "" : parent, path].filter { !$0.isEmpty }.joined(separator: "/")
            if kind == "PBXGroup" {
                for child in object["children"] as? [String] ?? [] { pending.append((child, combined, depth + 1)) }
            } else if kind == "PBXFileReference", !combined.isEmpty { paths[id] = combined }
        }
        var targets: [String: Target] = [:]
        let productOwners = Dictionary(targetIDs.compactMap { id in
            (objects[id]?["productReference"] as? String).map { ($0, id) }
        }, uniquingKeysWith: { _, _ in "" })
        var linkedTargets: [String: Set<String>] = [:]
        var frameworks: Set<FrameworkReference> = []
        var packageConsumers: Set<String> = [], packageLinks: Set<String> = []
        for id in targetIDs {
            guard let target = objects[id], target["isa"] as? String == "PBXNativeTarget",
                  let name = target["name"] as? String, let type = target["productType"] as? String,
                  ["com.apple.product-type.framework", "com.apple.product-type.library.static",
                   "com.apple.product-type.application", "com.apple.product-type.bundle.unit-test"].contains(type),
                  (target["buildRules"] as? [String] ?? []).isEmpty,
                  (target["packageProductDependencies"] as? [String] ?? []).isEmpty
                    || (target["packageProductDependencies"] as? [String]) == localPackage.map({ [$0.productReferenceID] }) else {
                throw Self.invalid("Unsupported native target or build rule.")
            }
            if !(target["packageProductDependencies"] as? [String] ?? []).isEmpty { packageConsumers.insert(id) }
            var sources: [String] = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = objects[phaseID], let kind = phase["isa"] as? String,
                      ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase", "PBXHeadersBuildPhase"].contains(kind)
                else { throw Self.invalid("Unsupported build phase.") }
                let files = phase["files"] as? [String] ?? []
                if ["PBXResourcesBuildPhase", "PBXHeadersBuildPhase"].contains(kind), !files.isEmpty {
                    throw Self.invalid("Resource and header build phases are not modeled by this Swift-only receipt.")
                }
                for file in files {
                    if let product = objects[file]?["productRef"] as? String {
                        guard kind == "PBXFrameworksBuildPhase", product == localPackage?.productReferenceID,
                              let buildFile = objects[file], buildFile["isa"] as? String == "PBXBuildFile",
                              Set(buildFile.keys) == ["isa", "productRef"],
                              packageLinks.insert(id).inserted else {
                            throw Self.invalid("Ambiguous or unsupported local package link declaration.")
                        }
                        continue
                    }
                    guard let buildFile = objects[file], let ref = buildFile["fileRef"] as? String,
                          buildFile["settings"] == nil else { throw Self.invalid("Conditional or generated build inputs are unsupported.") }
                    if kind == "PBXSourcesBuildPhase" {
                        guard let path = paths[ref], path.hasSuffix(".swift") else {
                            throw Self.invalid("Source phase contains an external, generated or non-Swift file.")
                        }
                        sources.append(path)
                    } else if kind == "PBXFrameworksBuildPhase" {
                        guard let tree = objects[ref]?["sourceTree"] as? String,
                              ["SDKROOT", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR"].contains(tree) else {
                            throw Self.invalid("Unbound local binary framework input.")
                        }
                        guard let path = objects[ref]?["path"] as? String, Self.relative(path) else {
                            throw Self.invalid("Absolute, escaping or macro framework paths are unsupported.")
                        }
                        if tree != "BUILT_PRODUCTS_DIR" {
                            guard Self.systemFrameworkPath(tree: tree, path: path) else {
                                throw Self.invalid("Unsupported SDK/developer framework path.")
                            }
                            frameworks.insert(.init(sourceTree: tree, path: path))
                        }
                        if tree == "BUILT_PRODUCTS_DIR" {
                            guard let owner = productOwners[ref], !owner.isEmpty else {
                                throw Self.invalid("Built framework has no unique local producer.")
                            }
                            linkedTargets[id, default: []].insert(owner)
                        }
                    }
                }
            }
            let dependencies = try (target["dependencies"] as? [String] ?? []).map { dependency -> String in
                guard let dependency = objects[dependency], let target = dependency["target"] as? String,
                      targetIDs.contains(target) else { throw Self.invalid("External or missing dependency target.") }
                return target
            }
            guard !sources.isEmpty, Set(sources).count == sources.count else {
                throw Self.invalid("Each target must have nonempty, unique explicit Swift sources.")
            }
            targets[id] = .init(name: name, productType: type, sources: sources.sorted(), dependencies: dependencies.sorted())
        }
        for (id, links) in linkedTargets {
            var closure: Set<String> = [], pending = targets[id]?.dependencies ?? []
            while let dependency = pending.popLast() {
                if closure.insert(dependency).inserted { pending += targets[dependency]?.dependencies ?? [] }
            }
            guard links.isSubset(of: closure) else { throw Self.invalid("Implicit target dependencies must be declared explicitly.") }
        }
        guard frameworks.count <= 64 else { throw Self.invalid("System framework count budget exceeded.") }
        guard packageLinks == packageConsumers, localPackage == nil || !packageConsumers.isEmpty else {
            throw Self.invalid("Package product dependencies and framework product links disagree.")
        }
        self.targets = targets
        self.frameworks = frameworks
        self.packageConsumers = packageConsumers
    }

    static func validRunpaths(_ value: Any) -> Bool {
        let values: [String]?
        if let string = value as? String { values = string.split(whereSeparator: \.isWhitespace).map(String.init) }
        else { values = value as? [String] }
        let allowed: Set<String> = ["$(inherited)", "@loader_path/Frameworks", "@loader_path/../Frameworks",
            "@loader_path/../../../", "@executable_path/Frameworks", "@executable_path/../Frameworks"]
        return values.map { $0.allSatisfy(allowed.contains) } ?? false
    }

    static func systemFrameworkPath(tree: String, path: String) -> Bool {
        let prefix = tree == "SDKROOT" ? "System/Library/Frameworks/"
            : "Platforms/MacOSX.platform/Developer/Library/Frameworks/"
        return relative(path) && path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")
            && path.hasSuffix(".framework")
    }

    static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.contains("$(") && !path.contains("${")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "xcode-target-scope", reason: reason)
    }
}

/// 외부 XML entity와 부분 테스트 선택을 실행하지 않고 명시 scheme 신원만 읽는다.
final class XcodeSchemeMembership: NSObject, XMLParserDelegate {
    var targets: Set<String> = []
    var plans: Set<String> = []
    var configuration = ""
    var hasUnsupportedActions = false
    private var inTestable = false
    private var project = ""
    private var projects: Set<String>? = nil

    static func read(_ data: Data, project: String, projects: [String]? = nil) throws -> XcodeSchemeMembership {
        let text = String(decoding: data, as: UTF8.self).uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw XcodeProjectMembership.invalid("XML entities are unsupported.")
        }
        let collector = XcodeSchemeMembership()
        collector.project = project
        collector.projects = projects.map(Set.init)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), !collector.configuration.isEmpty else {
            throw XcodeProjectMembership.invalid("Invalid shared Xcode scheme.")
        }
        return collector
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if ["ExecutionAction", "SkippedTests", "SelectedTests", "EnvironmentVariable", "CommandLineArgument"].contains(name) { hasUnsupportedActions = true }
        if name == "TestAction" {
            if !configuration.isEmpty { hasUnsupportedActions = true }
            configuration = attributes["buildConfiguration"] ?? ""
        }
        if name == "TestableReference" {
            inTestable = true
            if attributes["skipped"] != "NO" { hasUnsupportedActions = true }
        }
        let container = attributes["ReferencedContainer"] ?? ""
        let path = container.hasPrefix("container:") ? String(container.dropFirst("container:".count)) : ""
        let validContainer = projects?.contains(path) ?? (container == "container:" + project)
        if name == "BuildableReference", !validContainer { hasUnsupportedActions = true }
        if name == "BuildableReference", inTestable {
            guard validContainer, let id = attributes["BlueprintIdentifier"],
                  targets.insert(projects == nil ? id : path + "::" + id).inserted else {
                hasUnsupportedActions = true
                return
            }
        }
        if name == "TestPlanReference" {
            guard let value = attributes["reference"], value.hasPrefix("container:") else {
                hasUnsupportedActions = true
                return
            }
            plans.insert(String(value.dropFirst("container:".count)))
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "TestableReference" { inTestable = false }
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) { hasUnsupportedActions = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
