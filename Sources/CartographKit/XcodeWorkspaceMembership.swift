import CartographCore
import Foundation

/// workspace 경로로 PBX 신원을 이름공간화하고, 원문 proxy가 가리키는 실제 target/product를 연결한다.
struct XcodeWorkspaceMembership {
    let project: XcodeProjectMembership

    init(workspace: String, projects expected: [String], root: String,
         packages: [XcodeLocalPackageEvidence], fileSystem: any FileSystem) throws {
        let data = try Self.read(root + "/" + workspace + "/contents.xcworkspacedata", fileSystem: fileSystem)
        let paths = try WorkspaceXML.read(data)
        guard paths == expected, paths.count <= 32, packages.count <= 16,
              Set(packages.compactMap(\.project)).count == packages.count else {
            throw Self.invalid("Workspace projects or local package project identities are duplicated or changed.")
        }
        var plists: [String: [String: Any]] = [:]
        var consumers: Set<String> = []
        for path in paths {
            let bytes = try Self.read(root + "/" + path + "/project.pbxproj", fileSystem: fileSystem)
            guard var plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                throw Self.invalid("Invalid workspace project metadata.")
            }
            if let package = packages.first(where: { $0.project == path }) {
                let result = try Self.removePackage(package, plist: plist, project: path)
                plist = result.0
                consumers.formUnion(result.1)
            }
            plists[path] = plist
        }
        guard packages.allSatisfy({ $0.project.map(paths.contains) == true }) else {
            throw Self.invalid("A local package belongs to a project outside this workspace.")
        }
        let merged = try Self.merge(plists)
        let bytes = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
        let checked = try XcodeProjectMembership(data: bytes, root: root)
        self.project = .init(targets: checked.targets, frameworks: checked.frameworks, packageConsumers: consumers)
    }

    private static func read(_ path: String, fileSystem: any FileSystem) throws -> Data {
        guard try fileSystem.realPath(at: path) == path else { throw invalid("Workspace metadata must be canonical and local.") }
        return try XcodeLocalPackageIO.bounded(path, maximum: 4 * 1_024 * 1_024, fileSystem: fileSystem)
    }

    private static func removePackage(_ package: XcodeLocalPackageEvidence, plist: [String: Any],
                                      project path: String) throws -> ([String: Any], Set<String>) {
        guard var objects = plist["objects"] as? [String: [String: Any]], let rootID = plist["rootObject"] as? String,
              var main = objects[rootID], main["packageReferences"] as? [String] == [package.referenceID],
              let reference = objects[package.referenceID], Set(reference.keys) == ["isa", "relativePath"],
              reference["isa"] as? String == "XCLocalSwiftPackageReference",
              let relative = reference["relativePath"] as? String, XcodeProjectMembership.relative(relative),
              let product = objects[package.productReferenceID], Set(product.keys) == ["isa", "package", "productName"],
              product["isa"] as? String == "XCSwiftPackageProductDependency",
              product["package"] as? String == package.referenceID,
              product["productName"] as? String == package.product else {
            throw invalid("Workspace local package declaration differs from its captured product.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard [parent, relative].filter({ !$0.isEmpty }).joined(separator: "/") == package.path else {
            throw invalid("Workspace local package path differs from its project-relative declaration.")
        }
        var consumers: Set<String> = [], links: Set<String> = []
        for id in main["targets"] as? [String] ?? [] {
            guard var target = objects[id] else { throw invalid("Missing workspace native target.") }
            let uses = target["packageProductDependencies"] as? [String] ?? []
            guard uses.isEmpty || uses == [package.productReferenceID] else { throw invalid("Unsupported package dependency.") }
            var targetLinks: [String] = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard var phase = objects[phaseID] else { throw invalid("Missing native build phase.") }
                let files = phase["files"] as? [String] ?? []
                for fileID in files {
                    guard let file = objects[fileID] else { throw invalid("Missing native build file.") }
                    if file["productRef"] != nil {
                        guard phase["isa"] as? String == "PBXFrameworksBuildPhase", Set(file.keys) == ["isa", "productRef"],
                              file["isa"] as? String == "PBXBuildFile", file["productRef"] as? String == package.productReferenceID,
                              links.insert(fileID).inserted else { throw invalid("Ambiguous workspace package link.") }
                        targetLinks.append(fileID)
                    }
                }
                phase["files"] = files.filter { !targetLinks.contains($0) }
                objects[phaseID] = phase
            }
            guard uses.isEmpty == targetLinks.isEmpty, targetLinks.count <= 1 else {
                throw invalid("Workspace package declaration and native link disagree.")
            }
            if !uses.isEmpty { consumers.insert(path + "::" + id) }
            target["packageProductDependencies"] = []
            objects[id] = target
        }
        guard !consumers.isEmpty, consumers == Set(package.consumers), package.consumers.count == consumers.count,
              Set(objects.filter { $0.value["productRef"] != nil }.keys) == links,
              objects.allSatisfy({ id, value in
                  !(value["isa"] as? String ?? "").contains("SwiftPackage") || [package.referenceID, package.productReferenceID].contains(id)
              }) else { throw invalid("Workspace package consumers or product objects are not exact.") }
        for id in links.union([package.referenceID, package.productReferenceID]) { objects.removeValue(forKey: id) }
        main["packageReferences"] = []
        objects[rootID] = main
        var result = plist
        result["objects"] = objects
        return (result, consumers)
    }

    private static let referenceKeys: Set<String> = ["children", "files", "buildPhases", "dependencies", "targets",
        "buildConfigurationList", "buildConfigurations", "productReference", "mainGroup", "productRefGroup", "fileRef",
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
        let text = String(decoding: data, as: UTF8.self).uppercased()
        guard data.count <= 1_024 * 1_024, !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw XcodeProjectMembership.invalid("Workspace XML byte/entity boundary exceeded.") }
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
