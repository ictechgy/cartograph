import CartographCore
import Foundation

/// 실제 Xcode 캡처의 범위와 입력을 대조한다. 서명이나 동적 테스트 완전성 증명은 아니다.
struct XcodeTargetScopeStore {
    let fileSystem: any FileSystem

    struct Receipt: Codable {
        let format: String
        let version: Int
        let projectRoot: String
        let project: String
        let scheme: String
        let schemePath: String
        let testPlan: String?
        let configuration: String
        let destination: String
        let architecture: String
        let inputFingerprint: String
        let before: [String: String]
        let after: [String: String]
        let buildSettingsJSON: String
        let testRunPath: String
        let testRunSHA256: String
        let products: [String: String]
        let productLinks: [String: String]
        let targets: [Target]
        let selectedTargetIDs: [String]
        let frameworks: [SystemFramework]
        let testHosts: [String: String]
        let buildExitCode: Int
    }

    struct Target: Codable, Equatable {
        let id: String
        let name: String
        let module: String
        let productType: String
        let sources: [String]
        let dependencies: [String]
    }

    struct SystemFramework: Codable {
        let sourceTree: String
        let path: String
        let root: String
        let developerRoot: String
        let resolvedPath: String
        let files: [String: String]
        let links: [String: String]
    }

    struct Verified {
        let receipt: Receipt
        let closure: Set<String>
        let owners: [String: String]
        let selectorTargets: [String: String]
        let testBundles: [String: String]
    }

    /// raw 프로젝트를 다시 해석하여 receipt의 파생 소속이 원문과 일치하는지 확인한다.
    func read(path: String, root: String, fingerprint: String) throws -> Verified {
        let bytes = try bounded(path, maximum: 8 * 1_024 * 1_024)
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.format == "cartograph-xcode-target-scope", receipt.version == 1,
              receipt.projectRoot == root, receipt.inputFingerprint == fingerprint,
              receipt.buildExitCode == 0, receipt.before == receipt.after,
              receipt.after == (try inventory(root: root)), receipt.targets.count <= 1_000,
              !receipt.targets.isEmpty, !receipt.selectedTargetIDs.isEmpty,
              Set(receipt.selectedTargetIDs).count == receipt.selectedTargetIDs.count,
              validName(receipt.scheme), validName(receipt.configuration),
              ["arm64", "x86_64"].contains(receipt.architecture),
              receipt.destination == "platform=macOS,arch=" + receipt.architecture,
              relative(receipt.project), !receipt.project.contains("/"), receipt.project.hasSuffix(".xcodeproj"),
              receipt.schemePath == receipt.project + "/xcshareddata/xcschemes/" + receipt.scheme + ".xcscheme"
        else { throw invalid("Capture identity, inventory or supported destination does not match.") }
        let projectData = try bounded(root + "/" + receipt.project + "/project.pbxproj", maximum: 4 * 1_024 * 1_024)
        let project = try XcodeProjectMembership(data: projectData, root: root)
        let settings = try JSONDecoder().decode([Settings].self, from: Data(receipt.buildSettingsJSON.utf8))
        guard settings.count <= 1_000 else { throw invalid("Build settings exceed the target budget.") }
        let byID = Dictionary(receipt.targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard byID.count == receipt.targets.count, Set(receipt.targets.map(\.name)).count == byID.count,
              receipt.targets.allSatisfy({ validName($0.name) && validName($0.module) }),
              Set(receipt.targets.map(\.module)).count == byID.count,
              Set(receipt.targets.map(\.id)) == Set(project.targets.keys) else {
            throw invalid("Target identities are duplicated or differ from the project.")
        }
        for target in receipt.targets {
            guard let actual = project.targets[target.id], actual.name == target.name,
                  actual.productType == target.productType, actual.sources == target.sources,
                  actual.dependencies == target.dependencies else {
                throw invalid("Source phase or dependency membership differs from the captured project.")
            }
        }
        let schemeData = try bounded(root + "/" + receipt.schemePath, maximum: 1_024 * 1_024)
        let scheme = try XcodeSchemeMembership.read(schemeData, project: receipt.project)
        guard scheme.configuration == receipt.configuration else { throw invalid("Scheme configuration changed.") }
        let selected = try selectedTargets(scheme: scheme, receipt: receipt, root: root)
        guard selected == Set(receipt.selectedTargetIDs), selected.allSatisfy({
            byID[$0]?.productType == "com.apple.product-type.bundle.unit-test"
        }) else { throw invalid("Scheme/test-plan test targets do not match the captured universe.") }
        var closure: Set<String> = []
        var pending = Array(selected)
        while let id = pending.popLast() {
            guard let target = byID[id] else { throw invalid("A target dependency is outside this project.") }
            if closure.insert(id).inserted { pending += target.dependencies }
        }
        var owners: [String: String] = [:]
        for target in receipt.targets {
            for source in target.sources {
                guard relative(source), receipt.after[source] != nil,
                      owners.updateValue(target.id, forKey: root + "/" + source) == nil else {
                    throw invalid("A source is absent, outside the root or owned by multiple targets.")
                }
            }
        }
        var modules: [String: String] = [:]
        for target in receipt.targets {
            guard let setting = settings.first(where: { $0.target == target.name }),
                  settings.filter({ $0.target == target.name }).count == 1,
                  setting.buildSettings["PRODUCT_MODULE_NAME"] == target.module,
                  setting.buildSettings["PROJECT_FILE_PATH"] == root + "/" + receipt.project,
                  setting.buildSettings["CONFIGURATION"] == receipt.configuration,
                  setting.buildSettings["ARCHS"] == receipt.architecture,
                  setting.buildSettings["EXCLUDED_SOURCE_FILE_NAMES", default: ""].isEmpty,
                  setting.buildSettings["INCLUDED_SOURCE_FILE_NAMES", default: ""].isEmpty,
                  setting.buildSettings["SWIFT_OBJC_BRIDGING_HEADER", default: ""].isEmpty,
                  setting.buildSettings["TEST_HOST", default: ""].isEmpty,
                  setting.buildSettings["BUNDLE_LOADER", default: ""].isEmpty,
                  XcodeProjectMembership.validRunpaths(setting.buildSettings["LD_RUNPATH_SEARCH_PATHS", default: ""]),
                  modules.updateValue(target.name, forKey: target.module) == nil else {
                throw invalid("The captured compiler module/configuration/architecture is ambiguous or filtered.")
            }
        }
        try validateFrameworks(receipt.frameworks, references: project.frameworks, settings: settings)
        guard !receipt.products.isEmpty, receipt.products.count <= 10_000,
              receipt.products[receipt.testRunPath] == receipt.testRunSHA256 else {
            throw invalid("Build product and test-run identities are missing.")
        }
        guard let productRootRange = receipt.testRunPath.range(of: "/DerivedData/Build/Products/"),
              receipt.testRunPath.hasSuffix(".xctestrun") else { throw invalid("Unexpected test-run capture location.") }
        let productRoot = String(receipt.testRunPath[..<productRootRange.upperBound].dropLast())
        try validateProducts(receipt, root: productRoot)
        let testRun = try bounded(receipt.testRunPath, maximum: 8 * 1_024 * 1_024)
        let closureProducts = try validateClosureProducts(closure.compactMap { byID[$0]?.name }, settings: settings,
            receipt: receipt, productRoot: productRoot)
        let bundles = try validateTestRun(testRun, selected: selected.compactMap { byID[$0]?.name },
            settings: settings, productRoot: productRoot, closureProducts: closureProducts, testHosts: receipt.testHosts)
        var selectorTargets: [String: String] = [:], testBundles: [String: String] = [:]
        for id in selected {
            guard let target = byID[id], let bundle = bundles[target.name], validName(bundle), validName(target.name) else {
                throw invalid("A selected test bundle identity is unavailable.")
            }
            // Xcode는 제품 파일명이 아니라 scheme/xctestrun의 target 이름으로 선택한다.
            selectorTargets[target.module] = target.name
            testBundles[target.module] = bundle
        }
        try validateProducts(receipt, root: productRoot)
        for (host, digest) in receipt.testHosts {
            guard TargetScopeStore.digest(try bounded(host, maximum: 16 * 1_024 * 1_024)) == digest else {
                throw invalid("XCTest system host bytes changed.")
            }
        }
        try validateFrameworks(receipt.frameworks, references: project.frameworks, settings: settings)
        guard receipt.after == (try inventory(root: root)), bytes == (try bounded(path, maximum: 8 * 1_024 * 1_024))
        else { throw invalid("Inputs changed while Xcode membership was being verified.") }
        return .init(receipt: receipt, closure: closure, owners: owners,
            selectorTargets: selectorTargets, testBundles: testBundles)
    }

    private struct Settings: Decodable { let target: String; let buildSettings: [String: String] }

    private func selectedTargets(scheme: XcodeSchemeMembership, receipt: Receipt, root: String) throws -> Set<String> {
        guard !scheme.hasUnsupportedActions else { throw invalid("Scheme execution actions or partial test selection are unsupported.") }
        if scheme.plans.isEmpty {
            guard receipt.testPlan == nil else { throw invalid("Unexpected test plan selection.") }
            return scheme.targets
        }
        guard let plan = receipt.testPlan, relative(plan), scheme.plans.contains(plan),
              let object = try JSONSerialization.jsonObject(with: bounded(root + "/" + plan, maximum: 1_024 * 1_024)) as? [String: Any],
              let targets = object["testTargets"] as? [[String: Any]], targets.count <= 1_000,
              let configurations = object["configurations"] as? [[String: Any]], configurations.count == 1,
              (configurations[0]["options"] as? [String: Any] ?? [:]).isEmpty,
              (object["defaultOptions"] as? [String: Any] ?? [:]).isEmpty else {
            throw invalid("An explicit single-configuration test plan without runtime options is required.")
        }
        var result: Set<String> = []
        for item in targets {
            guard item["enabled"] as? Bool != false, item["selectedTests"] == nil, item["skippedTests"] == nil,
                  let target = item["target"] as? [String: String], let id = target["identifier"],
                  target["containerPath"] == "container:" + receipt.project, result.insert(id).inserted else {
                throw invalid("Partial, disabled, duplicate or external plan targets are unsupported.")
            }
        }
        return result
    }

    private func validateClosureProducts(_ names: [String], settings: [Settings], receipt: Receipt,
        productRoot: String) throws -> Set<String> {
        var products: Set<String> = []
        for name in names {
            guard let values = settings.first(where: { $0.target == name })?.buildSettings,
                  let directory = values["TARGET_BUILD_DIR"], let product = values["FULL_PRODUCT_NAME"],
                  let executable = values["EXECUTABLE_PATH"], relative(product), relative(executable),
                  directory.hasPrefix(productRoot + "/"), try fileSystem.realPath(at: directory) == directory else {
                throw invalid("A dependency target product lies outside the captured product tree.")
            }
            let path = directory + "/" + product
            let binary = try fileSystem.realPath(at: directory + "/" + executable)
            guard try fileSystem.realPath(at: path) == path,
                  binary == path || binary.hasPrefix(path + "/"), receipt.products[binary] != nil else {
                throw invalid("A dependency target's actual product bytes were not captured.")
            }
            products.insert(path)
        }
        return products
    }

    private func validateTestRun(_ data: Data, selected: [String], settings: [Settings], productRoot: String,
        closureProducts: Set<String>, testHosts: [String: String]) throws -> [String: String] {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw invalid("Invalid Xcode test-run artifact.")
        }
        let rows: [[String: Any]]
        if let configurations = object["TestConfigurations"] as? [[String: Any]] {
            guard configurations.count == 1 else { throw invalid("Multiple test-run configurations are unsupported.") }
            rows = configurations[0]["TestTargets"] as? [[String: Any]] ?? []
        } else {
            rows = object.filter { !$0.key.hasPrefix("__") }.values.compactMap { $0 as? [String: Any] }
        }
        guard rows.count == selected.count, Set(rows.compactMap { $0["BlueprintName"] as? String }) == Set(selected),
              rows.allSatisfy({ $0["SkipTestIdentifiers"] == nil && $0["OnlyTestIdentifiers"] == nil
                  && ($0["TestBundlePath"] as? String)?.hasSuffix(".xctest") == true }) else {
            throw invalid("Built test targets or partial selectors disagree with the scheme universe.")
        }
        var bundles: [String: String] = [:], observedHosts: Set<String> = []
        for row in rows {
            guard row["IsAppHostedTestBundle"] as? Bool != true, row["IsUITestBundle"] as? Bool != true else {
                throw invalid("App-hosted and UI test bundles are outside this capture boundary.")
            }
            if let rawDependencies = row["DependentProductPaths"] {
                guard let dependencies = rawDependencies as? [String], dependencies.count <= 1_000,
                      dependencies.allSatisfy({ closureProducts.contains($0.replacingOccurrences(of: "__TESTROOT__", with: productRoot)) }) else {
                    throw invalid("Test-run dependency products are outside the verified target closure.")
                }
            }
            let name = row["BlueprintName"] as! String
            guard let settings = settings.first(where: { $0.target == name })?.buildSettings,
                  let directory = settings["TARGET_BUILD_DIR"], let product = settings["FULL_PRODUCT_NAME"],
                  let executable = settings["EXECUTABLE_PATH"], relative(product), relative(executable),
                  directory.hasPrefix(productRoot + "/") else { throw invalid("Test bundle build paths are missing.") }
            if let rawHost = row["TestHostPath"] {
                guard let host = rawHost as? String, let developer = settings["DEVELOPER_DIR"] else {
                    throw invalid("Unknown test host identity.")
                }
                let expected = developer + "/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
                let resolved = host.replacingOccurrences(of: "__PLATFORMS__", with: developer + "/Platforms")
                guard resolved == expected, try fileSystem.realPath(at: resolved) == expected,
                      testHosts[expected] == TargetScopeStore.digest(try bounded(expected, maximum: 16 * 1_024 * 1_024)) else {
                    throw invalid("Test host is not the captured standard non-app XCTest runner.")
                }
                observedHosts.insert(expected)
            }
            let declared = row["TestBundlePath"] as! String
            let resolved = declared.replacingOccurrences(of: "__TESTROOT__", with: productRoot)
            guard resolved == directory + "/" + product,
                  fileSystem.fileExists(at: directory + "/" + executable),
                  try fileSystem.realPath(at: directory + "/" + executable) == directory + "/" + executable else {
                throw invalid("The test-run bundle differs from its captured target product.")
            }
            bundles[name] = product
        }
        guard observedHosts == Set(testHosts.keys) else { throw invalid("Unexpected captured test host inputs.") }
        return bundles
    }

    /// SDKROOT 이름만으로 외부 파일을 신뢰하지 않는다. 선언·실제 경계·기여 바이트를 함께 대조한다.
    private func validateFrameworks(_ frameworks: [SystemFramework],
        references: Set<XcodeProjectMembership.FrameworkReference>, settings: [Settings]) throws {
        let declared = Set(frameworks.map { XcodeProjectMembership.FrameworkReference(sourceTree: $0.sourceTree, path: $0.path) })
        guard frameworks.count <= 64, frameworks.count == declared.count, declared == references else {
            throw invalid("System framework declarations differ from the captured project.")
        }
        var total = 0, entries = 0
        for framework in frameworks {
            guard XcodeProjectMembership.systemFrameworkPath(tree: framework.sourceTree, path: framework.path),
                  try fileSystem.realPath(at: framework.root) == framework.root,
                  try fileSystem.realPath(at: framework.developerRoot) == framework.developerRoot,
                  !framework.files.isEmpty, framework.files.count <= 10_000,
                  (framework.sourceTree == "SDKROOT"
                    ? framework.root.hasPrefix(framework.developerRoot + "/Platforms/MacOSX.platform/Developer/SDKs/")
                        && framework.root.hasSuffix(".sdk")
                    : framework.root == framework.developerRoot) else {
                throw invalid("SDK/developer framework roots are not a supported Xcode toolchain boundary.")
            }
            let resolved = try fileSystem.realPath(at: framework.root + "/" + framework.path)
            guard resolved == framework.resolvedPath, resolved.hasPrefix(framework.root + "/"),
                  settings.allSatisfy({ setting in
                    guard let developer = setting.buildSettings["DEVELOPER_DIR"],
                          (try? fileSystem.realPath(at: developer)) == framework.developerRoot else { return false }
                    if framework.sourceTree == "SDKROOT" {
                        guard let sdk = setting.buildSettings["SDKROOT"] else { return false }
                        return (try? fileSystem.realPath(at: sdk)) == framework.root
                    }
                    return true
                  }) else { throw invalid("Framework resolution differs from captured compiler SDK/developer settings.") }
            var pending = [resolved], files: [String: String] = [:], links: [String: String] = [:]
            while let directory = pending.popLast() {
                for entry in try fileSystem.directoryEntries(at: directory) {
                    entries += 1
                    guard entries <= 10_000, entry.path.hasPrefix(resolved + "/") else {
                        throw invalid("System framework entry budget exceeded.")
                    }
                    if entry.isSymbolicLink {
                        let destination = try fileSystem.realPath(at: entry.path)
                        guard destination.hasPrefix(resolved + "/") else { throw invalid("System framework symlink escapes its bundle.") }
                        links[entry.path] = destination
                    } else if entry.isDirectory { pending.append(entry.path) }
                    else {
                        let data = try bounded(entry.path, maximum: 16 * 1_024 * 1_024)
                        total += data.count
                        guard entry.isRegularFile, total <= 128 * 1_024 * 1_024 else {
                            throw invalid("System framework byte budget exceeded.")
                        }
                        files[entry.path] = TargetScopeStore.digest(data)
                    }
                }
            }
            guard files == framework.files, links == framework.links else {
                throw invalid("System framework bytes or symlink identities changed.")
            }
        }
    }

    /// bundle 메타데이터와 새 파일까지 모든 일반 파일 바이트 및 symlink 대상을 묶는다.
    private func validateProducts(_ receipt: Receipt, root: String) throws {
        var pending = [root], products: [String: String] = [:], links: [String: String] = [:]
        var entries = 0, total = 0
        while let directory = pending.popLast() {
            for entry in try fileSystem.directoryEntries(at: directory) {
                entries += 1
                guard entries <= 10_000, entry.path.hasPrefix(root + "/") else { throw invalid("Product entry budget exceeded.") }
                if entry.isSymbolicLink {
                    let destination = try fileSystem.realPath(at: entry.path)
                    guard destination.hasPrefix(root + "/") else { throw invalid("Product symlink escapes the capture.") }
                    links[entry.path] = destination
                } else if entry.isDirectory {
                    pending.append(entry.path)
                } else {
                    let data = try bounded(entry.path, maximum: 128 * 1_024 * 1_024)
                    total += data.count
                    guard entry.isRegularFile, total <= 512 * 1_024 * 1_024 else { throw invalid("Product byte budget exceeded.") }
                    products[entry.path] = TargetScopeStore.digest(data)
                }
            }
        }
        guard products == receipt.products, links == receipt.productLinks else {
            throw invalid("Build product bytes, membership or symlink identities changed.")
        }
    }

    /// 분석 filter/ignore를 적용하지 않는다. 새 소스와 설정도 이전 증명을 무효화한다.
    func inventory(root: String) throws -> [String: String] {
        var pending = [root], result: [String: String] = [:]
        var entries = 0, total = 0
        let suffixes = ["swift", "m", "mm", "h", "xib", "storyboard", "pbxproj", "xcscheme", "xctestplan",
                        "xcconfig", "plist", "entitlements", "resolved"]
        while let directory = pending.popLast() {
            for entry in try fileSystem.directoryEntries(at: directory) {
                entries += 1
                guard entries <= 50_000, !entry.isSymbolicLink else { throw invalid("Inventory budget or symlink boundary exceeded.") }
                let name = (entry.path as NSString).lastPathComponent
                if entry.isDirectory {
                    if ![".git", ".build"].contains(name) { pending.append(entry.path) }
                    continue
                }
                guard suffixes.contains((entry.path as NSString).pathExtension) else { continue }
                guard entry.path.hasPrefix(root + "/"), entry.isRegularFile else { throw invalid("Nonregular project input.") }
                let data = try bounded(entry.path, maximum: 4 * 1_024 * 1_024)
                total += data.count
                guard result.count < 10_000, total <= 64 * 1_024 * 1_024 else { throw invalid("Project input byte budget exceeded.") }
                result[String(entry.path.dropFirst(root.count + 1))] = TargetScopeStore.digest(data)
            }
        }
        return result
    }

    private func bounded(_ path: String, maximum: Int) throws -> Data {
        guard !isSensitiveAnalysisEvidencePath(path), try fileSystem.realPath(at: path) == path,
              fileSystem.fingerprintStamp(at: path)?.isRegularFile != false else {
            throw invalid("Sensitive, symlinked or noncanonical receipt input.")
        }
        let data = try fileSystem.readData(at: path, maximumBytes: maximum)
        guard data.count <= maximum else { throw invalid("Receipt input exceeds its byte budget.") }
        return data
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.contains("/") && !name.contains(":")
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func relative(_ path: String) -> Bool { XcodeProjectMembership.relative(path) }
    private func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "xcode-target-scope", reason: reason)
    }
}
