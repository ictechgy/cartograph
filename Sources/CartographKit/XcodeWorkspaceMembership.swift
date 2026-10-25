import CartographCore
import Foundation

/// workspace 경로로 PBX 신원을 이름공간화하고, 원문 proxy가 가리키는 실제 target/product를 연결한다.
struct XcodeWorkspaceMembership {
    let project: XcodeProjectMembership

    init(workspace: String, projects expected: [String], root: String,
         packages: [XcodeLocalPackageEvidence], fileSystem: any FileSystem, iosSimulator: Bool = false) throws {
        let data = try Self.read(root + "/" + workspace + "/contents.xcworkspacedata", fileSystem: fileSystem)
        let paths = try WorkspaceXML.read(data)
        let bindings = try Self.bindings(packages)
        guard paths == expected, paths.count <= 32, packages.count <= 16, bindings.count <= 256,
              Set(packages.map(\.path)).count == packages.count, Set(packages.map(\.module)).count == packages.count,
              Set(packages.map(\.name)).count == packages.count, Set(packages.map(\.product)).count == packages.count,
              bindings.allSatisfy({ paths.contains($0.declaration.project) }) else {
            throw Self.invalid("Workspace projects or local package declaration identities are duplicated or changed.")
        }
        var plists: [String: [String: Any]] = [:]
        var consumers: Set<String> = []
        for path in paths {
            let bytes = try Self.read(root + "/" + path + "/project.pbxproj", fileSystem: fileSystem)
            guard var plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                throw Self.invalid("Invalid workspace project metadata.")
            }
            let own = bindings.filter { $0.declaration.project == path }
            if !own.isEmpty {
                let result = try Self.removePackages(own, plist: plist, project: path, root: root, fileSystem: fileSystem)
                plist = result.0
                consumers.formUnion(result.1)
            }
            plists[path] = plist
        }
        let merged = try Self.merge(plists)
        let bytes = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
        let checked = try XcodeProjectMembership(data: bytes, root: root, iosSimulator: iosSimulator, fileSystem: fileSystem)
        self.project = .init(targets: checked.targets, frameworks: checked.frameworks, packageConsumers: consumers)
    }

    private static func read(_ path: String, fileSystem: any FileSystem) throws -> Data {
        guard try fileSystem.realPath(at: path) == path else { throw invalid("Workspace metadata must be canonical and local.") }
        return try XcodeLocalPackageIO.bounded(path, maximum: 4 * 1_024 * 1_024, fileSystem: fileSystem)
    }

    private struct Binding {
        let package: XcodeLocalPackageEvidence
        let declaration: XcodeLocalPackageEvidence.ProjectDeclaration
    }

    private static func bindings(_ packages: [XcodeLocalPackageEvidence]) throws -> [Binding] {
        var result: [Binding] = []
        for package in packages {
            let declarations: [XcodeLocalPackageEvidence.ProjectDeclaration]
            if let current = package.declarations {
                guard package.project == nil else { throw invalid("Mixed workspace package declaration formats.") }
                declarations = current
            } else if let project = package.project {
                // a214 v3 captures retain their single-project package identity.
                declarations = [.init(project: project, referenceID: package.referenceID,
                    productReferenceID: package.productReferenceID, consumers: package.consumers)]
            } else { throw invalid("Missing workspace package declaration identities.") }
            let consumers = declarations.flatMap(\.consumers)
            guard (1...32).contains(declarations.count), Set(declarations.map(\.project)).count == declarations.count,
                  declarations.first?.referenceID == package.referenceID,
                  declarations.first?.productReferenceID == package.productReferenceID,
                  !consumers.isEmpty, consumers.count <= 1_000, Set(consumers).count == consumers.count,
                  consumers.count == package.consumers.count, Set(consumers) == Set(package.consumers),
                  declarations.allSatisfy({ declaration in
                      XcodeProjectMembership.relative(declaration.project) && declaration.project.hasSuffix(".xcodeproj")
                          && declaration.referenceID != declaration.productReferenceID && !declaration.consumers.isEmpty
                          && declaration.consumers.allSatisfy { $0.hasPrefix(declaration.project + "::") }
                  }) else { throw invalid("Workspace package declarations and native consumers are not exact.") }
            result += declarations.map { Binding(package: package, declaration: $0) }
        }
        return result
    }

    /// ..은 workspace 안에서만 정규화한다. 임의 외부 root나 filesystem 별칭을 같은 package로 추측하지 않는다.
    private static func packagePath(project: String, reference: String) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 4_096, !reference.hasPrefix("/"),
              !reference.contains("\\"), !reference.contains(":"), !reference.contains("$"),
              reference.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("Workspace package path must be a literal relative path.")
        }
        var components = (project as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for part in reference.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { throw invalid("Empty workspace package path component.") }
            if part == ".." {
                guard !components.isEmpty else { throw invalid("Package path escapes the workspace root.") }
                components.removeLast()
            } else if part != "." { components.append(String(part)) }
            guard components.count <= 128 else { throw invalid("Workspace package path depth budget exceeded.") }
        }
        guard !components.isEmpty else { throw invalid("The workspace root is not a package subtree.") }
        return components.joined(separator: "/")
    }

    private static func removePackages(_ bindings: [Binding], plist: [String: Any], project path: String,
                                       root: String, fileSystem: any FileSystem) throws -> ([String: Any], Set<String>) {
        guard var objects = plist["objects"] as? [String: [String: Any]], let rootID = plist["rootObject"] as? String,
              var main = objects[rootID], let references = main["packageReferences"] as? [String],
              references.count == bindings.count, Set(references).count == references.count,
              Set(references) == Set(bindings.map { $0.declaration.referenceID }), bindings.count <= 16 else {
            throw invalid("Workspace project package references differ from their captured declarations.")
        }
        var products: [String: Binding] = [:]
        var allowed: Set<String> = []
        for binding in bindings {
            let package = binding.package, declaration = binding.declaration
            guard allowed.insert(declaration.referenceID).inserted, allowed.insert(declaration.productReferenceID).inserted,
                  let reference = objects[declaration.referenceID], Set(reference.keys) == ["isa", "relativePath"],
                  reference["isa"] as? String == "XCLocalSwiftPackageReference",
                  let relative = reference["relativePath"] as? String,
                  try packagePath(project: path, reference: relative) == package.path,
                  try fileSystem.realPath(at: root + "/" + package.path) == root + "/" + package.path,
                  let product = objects[declaration.productReferenceID], Set(product.keys) == ["isa", "package", "productName"],
                  product["isa"] as? String == "XCSwiftPackageProductDependency",
                  product["package"] as? String == declaration.referenceID,
                  product["productName"] as? String == package.product else {
                throw invalid("Workspace package path/product differs from its original project declaration.")
            }
            products[declaration.productReferenceID] = binding
        }
        guard objects.allSatisfy({ id, value in
            !(value["isa"] as? String ?? "").contains("Package") || allowed.contains(id)
        }) else { throw invalid("Additional or remote package objects are unsupported.") }
        var consumers: [String: Set<String>] = [:], links: Set<String> = []
        for id in main["targets"] as? [String] ?? [] {
            guard let target = objects[id], target["packageProductDependencies"] == nil || target["packageProductDependencies"] is [String] else {
                throw invalid("Missing workspace native target or malformed package dependencies.")
            }
            let uses = target["packageProductDependencies"] as? [String] ?? []
            guard Set(uses).count == uses.count, Set(uses).isSubset(of: Set(products.keys)) else {
                throw invalid("Unknown or duplicate workspace package dependency.")
            }
            var targetProducts: Set<String> = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = objects[phaseID], phase["files"] == nil || phase["files"] is [String] else {
                    throw invalid("Missing native build phase or malformed file membership.")
                }
                let files = phase["files"] as? [String] ?? []
                for fileID in files {
                    guard let file = objects[fileID] else { throw invalid("Missing native build file.") }
                    if file["productRef"] != nil {
                        guard phase["isa"] as? String == "PBXFrameworksBuildPhase", Set(file.keys) == ["isa", "productRef"],
                              file["isa"] as? String == "PBXBuildFile", let product = file["productRef"] as? String,
                              products[product] != nil, targetProducts.insert(product).inserted, links.insert(fileID).inserted else {
                            throw invalid("Ambiguous, shared or unknown workspace package link.")
                        }
                    }
                }
            }
            guard Set(uses) == targetProducts else { throw invalid("Workspace package dependencies and native framework links disagree.") }
            for product in uses { consumers[product, default: []].insert(path + "::" + id) }
        }
        guard Set(objects.filter { $0.value["productRef"] != nil }.keys) == links,
              products.allSatisfy({ id, binding in
                  let actual = consumers[id] ?? []
                  return !actual.isEmpty && actual == Set(binding.declaration.consumers)
              }) else { throw invalid("Workspace package product files or consumer identities are not exact.") }
        for id in main["targets"] as? [String] ?? [] {
            objects[id]?["packageProductDependencies"] = []
            for phaseID in objects[id]?["buildPhases"] as? [String] ?? [] {
                let files = objects[phaseID]?["files"] as? [String] ?? []
                objects[phaseID]?["files"] = files.filter { !links.contains($0) }
            }
        }
        for id in allowed.union(links) { objects.removeValue(forKey: id) }
        main["packageReferences"] = []
        objects[rootID] = main
        var result = plist
        result["objects"] = objects
        return (result, Set(consumers.values.flatMap { $0 }))
    }

    private static let referenceKeys: Set<String> = ["children", "files", "buildPhases", "dependencies", "targets",
        "buildConfigurationList", "buildConfigurations", "baseConfigurationReference", "productReference", "mainGroup", "productRefGroup", "fileRef",
        "productRef", "package", "containerPortal", "targetProxy", "target", "remoteRef"]

    private static func merge(_ plists: [String: [String: Any]]) throws -> [String: Any] {
        var combined: [String: [String: Any]] = [:], targetIDs: [String] = [], groups: [String] = []
        for path in plists.keys.sorted() {
            guard let plist = plists[path], let objects = plist["objects"] as? [String: [String: Any]], objects.count <= 50_000,
                  let rootID = plist["rootObject"] as? String, let main = objects[rootID],
                  main["isa"] as? String == "PBXProject", let mainGroup = main["mainGroup"] as? String,
                  let ids = main["targets"] as? [String], Set(ids).count == ids.count,
                  main["projectReferences"] == nil || main["projectReferences"] is [[String: String]],
                  (main["packageReferences"] as? [String] ?? []).isEmpty,
                  (main["projectDirPath"] as? String ?? "").isEmpty, (main["projectRoot"] as? String ?? "").isEmpty else {
                throw invalid("Unsupported workspace project source root or package declaration.")
            }
            let prefix = (path as NSString).deletingLastPathComponent
            let paths = try filePaths(objects: objects, main: mainGroup, prefix: prefix)
            var portals: [String: String] = [:]
            for ref in main["projectReferences"] as? [[String: String]] ?? [] {
                guard Set(ref.keys) == ["ProjectRef", "ProductGroup"], let id = ref["ProjectRef"], let remote = paths[id],
                      plists[remote] != nil, remote != path, portals.updateValue(remote, forKey: id) == nil,
                      ref["ProductGroup"].flatMap({ objects[$0]?["isa"] as? String }) == "PBXGroup" else {
                    throw invalid("Project reference is missing, duplicate, self-referential or outside the workspace.")
                }
            }
            var proxies: [String: (Int, String, [String: Any])] = [:]
            for (id, object) in objects where object["isa"] as? String == "PBXContainerItemProxy" {
                let portal = object["containerPortal"] as? String
                let remote = portal == rootID ? path : portal.flatMap { portals[$0] }
                let kind = Int(String(describing: object["proxyType"] ?? ""))
                guard let remote, let remotePlist = plists[remote], let remoteObjects = remotePlist["objects"] as? [String: [String: Any]],
                      let remoteRoot = remotePlist["rootObject"] as? String,
                      let remoteIDs = remoteObjects[remoteRoot]?["targets"] as? [String],
                      let remoteID = object["remoteGlobalIDString"] as? String, kind == 1 || kind == 2,
                      (kind == 1 ? remoteIDs : remoteIDs.compactMap { remoteObjects[$0]?["productReference"] as? String }).contains(remoteID),
                      let remoteObject = remoteObjects[remoteID] else { throw invalid("Unbound workspace target/product proxy.") }
                proxies[id] = (kind!, remote + "::" + remoteID, remoteObject)
            }
            var products: [String: String] = [:]
            for (id, object) in objects where object["isa"] as? String == "PBXReferenceProxy" {
                guard let ref = object["remoteRef"] as? String, let proxy = proxies[ref], proxy.0 == 2,
                      object["sourceTree"] as? String == "BUILT_PRODUCTS_DIR",
                      object["path"] as? String == proxy.2["path"] as? String else { throw invalid("Ambiguous workspace product proxy.") }
                products[id] = proxy.1
            }
            func remap(_ value: Any, key: String? = nil) -> Any {
                if let dictionary = value as? [String: Any] { return dictionary.reduce(into: [String: Any]()) { $0[$1.key] = remap($1.value, key: $1.key) } }
                if let array = value as? [Any] { return array.map { remap($0, key: key) } }
                if let string = value as? String, key.map(referenceKeys.contains) == true, objects[string] != nil {
                    return products[string] ?? path + "::" + string
                }
                return value
            }
            for (id, object) in objects {
                let kind = object["isa"] as? String ?? ""
                if ["PBXProject", "PBXContainerItemProxy", "PBXReferenceProxy"].contains(kind) { continue }
                var updated = remap(object) as! [String: Any]
                if kind == "PBXGroup" {
                    updated["children"] = (object["children"] as? [String] ?? []).filter {
                        objects[$0]?["isa"] as? String != "PBXReferenceProxy"
                    }.map { remap($0, key: "children") }
                }
                if kind == "PBXTargetDependency" {
                    let direct = object["target"] as? String
                    let proxy = (object["targetProxy"] as? String).flatMap { proxies[$0] }
                    guard direct.map(ids.contains) == true || proxy?.0 == 1 else { throw invalid("Missing explicit workspace dependency.") }
                    if let proxy {
                        guard direct == nil || path + "::" + direct! == proxy.1 else { throw invalid("Dependency target and proxy disagree.") }
                        updated["target"] = proxy.1
                    }
                    updated.removeValue(forKey: "targetProxy")
                }
                if id == mainGroup {
                    guard kind == "PBXGroup", (object["path"] as? String ?? "").isEmpty else { throw invalid("Unsupported project main-group source root.") }
                    if !prefix.isEmpty { updated["path"] = prefix; updated["sourceTree"] = "SOURCE_ROOT" }
                } else if object["sourceTree"] as? String == "SOURCE_ROOT", let component = object["path"] as? String, !component.isEmpty {
                    guard XcodeProjectMembership.relative(component) else { throw invalid("External source-root path.") }
                    updated["path"] = [prefix, component].filter { !$0.isEmpty }.joined(separator: "/")
                }
                combined[path + "::" + id] = updated
            }
            targetIDs += ids.map { path + "::" + $0 }
            groups.append(path + "::" + mainGroup)
        }
        guard combined.count <= 50_000, (1...1_000).contains(targetIDs.count) else { throw invalid("Combined workspace object/target budget exceeded.") }
        combined["workspace-root"] = ["isa": "PBXProject", "targets": targetIDs.sorted(), "mainGroup": "workspace-group"]
        combined["workspace-group"] = ["isa": "PBXGroup", "children": groups, "sourceTree": "<group>"]
        return ["rootObject": "workspace-root", "objects": combined]
    }

    private static func filePaths(objects: [String: [String: Any]], main: String, prefix: String) throws -> [String: String] {
        var result: [String: String] = [:], seen: Set<String> = [], pending = [(main, "", 0)]
        while let (id, parent, depth) = pending.popLast() {
            guard seen.insert(id).inserted, let object = objects[id], depth <= 128 else { throw invalid("Missing/shared/cyclic workspace project group.") }
            let tree = object["sourceTree"] as? String ?? "<group>", path = object["path"] as? String ?? ""
            if !["<group>", "SOURCE_ROOT"].contains(tree) { continue }
            guard path.isEmpty || XcodeProjectMembership.relative(path) else { throw invalid("External workspace project path.") }
            let joined = [tree == "SOURCE_ROOT" ? "" : parent, path].filter { !$0.isEmpty }.joined(separator: "/")
            if object["isa"] as? String == "PBXGroup" {
                pending += (object["children"] as? [String] ?? []).map { ($0, joined, depth + 1) }
            } else if object["isa"] as? String == "PBXFileReference", !joined.isEmpty {
                result[id] = [prefix, joined].filter { !$0.isEmpty }.joined(separator: "/")
            }
        }
        return result
    }

    private static func invalid(_ reason: String) -> CartographError { XcodeProjectMembership.invalid(reason) }
}

/// XML entity를 해석하지 않고 group/container 상대 신원만 열거한다.
private final class WorkspaceXML: NSObject, XMLParserDelegate {
    var projects: [String] = []
    var parents = [""]
    var invalid = false
    var entries = 0
    var nodes: [String] = []

    static func read(_ data: Data) throws -> [String] {
        _ = try XcodeXMLInput.text(data)
        let delegate = WorkspaceXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, (1...32).contains(delegate.projects.count),
              Set(delegate.projects).count == delegate.projects.count else { throw XcodeProjectMembership.invalid("Workspace requires 1...32 unique explicit local projects.") }
        return delegate.projects.sorted()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if nodes.isEmpty {
            if name != "Workspace" || entries != 0 { invalid = true }
            nodes.append(name); entries += 1; return
        }
        entries += 1
        let parent = nodes.last ?? ""
        nodes.append(name)
        guard ["Workspace", "Group"].contains(parent), entries <= 257,
              parents.count <= (name == "Group" ? 32 : 33), ["Group", "FileRef"].contains(name),
              let location = attributes["location"], let colon = location.firstIndex(of: ":") else { invalid = true; return }
        let kind = String(location[..<colon]), value = String(location[location.index(after: colon)...])
        guard ["group", "container"].contains(kind), XcodeProjectMembership.relative(value) else { invalid = true; return }
        let path = [kind == "group" ? parents.last! : "", value].filter { !$0.isEmpty }.joined(separator: "/")
        if name == "Group" { parents.append(path) }
        else if path.hasSuffix(".xcodeproj") { projects.append(path) }
        else { invalid = true }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Group", parents.count > 1 { parents.removeLast() }
        if !nodes.isEmpty { nodes.removeLast() }
    }
}
