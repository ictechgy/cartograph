import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("공유 workspace package의 원문 선언과 소비자 신원")
struct XcodeWorkspaceSharedPackageTests {
    func fixture(kind: String? = nil) throws -> (InMemoryFileSystem, [XcodeLocalPackageEvidence]) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/xcode-workspace-shared-projects.json"))
        var projects = try JSONSerialization.jsonObject(with: bytes) as! [String: [String: Any]]
        let appPath = "Apps/App.xcodeproj", corePath = "Apps/Core.xcodeproj"
        var app = projects[appPath]!, objects = app["objects"] as! [String: [String: Any]]
        let coreObjects = projects[corePath]!["objects"] as! [String: [String: Any]]
        let coreRoot = projects[corePath]!["rootObject"] as! String
        let coreID = (coreObjects[coreRoot]!["targets"] as! [String])[0]
        let otherID = objects.first { $0.value["name"] as? String == "OtherBlueprint" && $0.value["isa"] as? String == "PBXNativeTarget" }!.key
        let checksID = objects.first { $0.value["name"] as? String == "ChecksBlueprint" && $0.value["isa"] as? String == "PBXNativeTarget" }!.key
        let coreReference = (coreObjects[coreRoot]!["packageReferences"] as! [String])[0]
        let coreProduct = coreObjects.first { $0.value["isa"] as? String == "XCSwiftPackageProductDependency" && $0.value["package"] as? String == coreReference }!.key
        let other = appPath + "::" + otherID, core = corePath + "::" + coreID
        func declaration(_ project: String, _ reference: String, _ product: String, _ consumers: [String]) -> [String: Any] {
            ["project": project, "referenceID": reference, "productReferenceID": product, "consumers": consumers]
        }
        func package(_ path: String, _ name: String, _ product: String, _ module: String, _ declarations: [[String: Any]]) -> [String: Any] {
            ["path": path, "name": name, "product": product, "module": module,
             "referenceID": declarations[0]["referenceID"]!, "productReferenceID": declarations[0]["productReferenceID"]!,
             "consumers": declarations.flatMap { $0["consumers"] as! [String] }, "declarations": declarations,
             "inventory": [String: String](), "generatedMetadataOrigin": "absent", "indexStore": "/capture/DerivedData/Index.noindex/DataStore",
             "files": [String: Any](), "compilations": [Any](), "records": [Any](), "links": [Any](),
             "aggregate": ["argv": [String](), "fileList": "", "output": "", "linkMap": ""]]
        }
        var payloads = [package("Packages/LocalMath", "LocalMath", "ArithmeticProduct", "ArithmeticCore", [
            declaration(appPath, "shared-package", "shared-product", [other]), declaration(corePath, coreReference, coreProduct, [core])]),
            package("Packages/OtherMath", "OtherMath", "OtherArithmeticProduct", "OtherArithmeticCore", [
                declaration(appPath, "second-package", "second-product", [other])])]
        switch kind {
        case "missing-declaration":
            payloads[0]["declarations"] = [declaration(appPath, "shared-package", "shared-product", [other])]
            payloads[0]["consumers"] = [other]
        case "forged-consumer":
            payloads[0]["declarations"] = [declaration(appPath, "shared-package", "shared-product", [appPath + "::" + checksID]),
                declaration(corePath, coreReference, coreProduct, [core])]
            payloads[0]["consumers"] = [appPath + "::" + checksID, core]
        case "external": objects["shared-package"]!["relativePath"] = "../../outside/LocalMath"
        case "duplicate-module": payloads[1]["module"] = "ArithmeticCore"
        case "duplicate-path": payloads[1]["path"] = "Packages/LocalMath"
        case "unknown-product":
            objects[otherID]!["packageProductDependencies"] = ["unknown-product"]
        case "shared-phase":
            let phases = objects[otherID]!["buildPhases"] as! [String]
            let framework = phases.first { objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }!
            var checksPhases = objects[checksID]!["buildPhases"] as! [String]
            checksPhases = checksPhases.filter { objects[$0]?["isa"] as? String != "PBXFrameworksBuildPhase" } + [framework]
            objects[checksID]!["buildPhases"] = checksPhases
        case "mixed-format": payloads[0]["project"] = appPath
        default: break
        }
        app["objects"] = objects
        projects[appPath] = app
        let fs = InMemoryFileSystem(currentDirectoryPath: "/p")
        try fs.write(Data("<Workspace><FileRef location=\"group:Apps/App.xcodeproj\"/><FileRef location=\"group:Apps/Core.xcodeproj\"/></Workspace>".utf8), to: "/p/Scope.xcworkspace/contents.xcworkspacedata")
        for (path, plist) in projects {
            try fs.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: "/p/" + path + "/project.pbxproj")
        }
        let packages = try JSONDecoder().decode([XcodeLocalPackageEvidence].self, from: JSONSerialization.data(withJSONObject: payloads))
        return (fs, packages)
    }

    @Test("project 밖 workspace 안의 공유 package와 한 target의 여러 product를 함께 대조한다")
    func sharedAndMultipleProducts() throws {
        let (fs, packages) = try fixture()
        let project = try XcodeWorkspaceMembership(workspace: "Scope.xcworkspace", projects: ["Apps/App.xcodeproj", "Apps/Core.xcodeproj"],
            root: "/p", packages: packages, fileSystem: fs).project
        #expect(project.targets.count == 4)
        #expect(project.packageConsumers.count == 2)
        #expect(packages[0].declarations?.count == 2)
    }

    @Test("누락 외부 중복 모듈 임의 소비자와 공유 phase의 package 주장은 거부한다",
          arguments: ["missing-declaration", "forged-consumer", "external", "duplicate-module", "duplicate-path", "unknown-product", "shared-phase", "mixed-format"])
    func refusesUnboundDeclarations(kind: String) throws {
        let (fs, packages) = try fixture(kind: kind)
        #expect(throws: (any Error).self) {
            try XcodeWorkspaceMembership(workspace: "Scope.xcworkspace", projects: ["Apps/App.xcodeproj", "Apps/Core.xcodeproj"],
                root: "/p", packages: packages, fileSystem: fs)
        }
    }

    @Test("UTF16과 다른 선언 인코딩의 DTD를 해석하지 않는다", arguments: ["utf8", "utf16", "utf16le", "utf16be", "utf32"])
    func refusesEncodedDTD(encoding: String) throws {
        let encodings: [String: String.Encoding] = ["utf8": .utf8, "utf16": .utf16, "utf16le": .utf16LittleEndian,
            "utf16be": .utf16BigEndian, "utf32": .utf32]
        let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE Scheme [<!ENTITY p \"untrusted\">]><Scheme/>"
        let data = text.data(using: encodings[encoding]!)!
        #expect(throws: (any Error).self) { try XcodeSchemeMembership.read(data, project: "App.xcodeproj") }
        #expect(throws: (any Error).self) { try XcodeXMLInput.text(data) }
    }

    @Test("XML encoding 선언도 UTF8만 허용하며 유효한 선언은 유지한다", arguments: ["UTF-16", "ISO-8859-1"])
    func xmlDeclarations(encoding: String) throws {
        let unsupported = "<?xml version=\"1.0\" encoding=\"" + encoding + "\"?><Workspace/>"
        #expect(throws: (any Error).self) { try XcodeXMLInput.text(Data(unsupported.utf8)) }
        let supported = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Workspace/>"
        #expect(try XcodeXMLInput.text(Data(supported.utf8)) == supported)
    }
}
