import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("여러 Xcode 프로젝트의 캡처 신원과 범위")
struct XcodeWorkspaceScopeTests {
    @Test("실제 임시 경로 별칭만 정규화하고 일반 private 접두어나 개별 링크는 가정하지 않는다")
    func physicalTemporaryAliases() throws {
        let path = "/tmp/cartograph-workspace-path-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let file = path + "/input.json", link = path + "/linked.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        let fs = LocalFileSystem()
        #expect(XcodeEvidencePath.physicalTemporaryAlias(file, fileSystem: fs) == (try fs.realPath(at: file)))
        #expect(XcodeEvidencePath.physicalTemporaryAlias(link, fileSystem: fs) == link)
        #expect(XcodeEvidencePath.physicalTemporaryAlias("/project/input.json", fileSystem: fs) == "/project/input.json")
    }

    func fixture() throws -> XcodeTargetScopeTests.Fixture {
        var fixture = try XcodeTargetScopeTests().fixture()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/xcode-workspace-projects.json"))
        let projects = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        for (path, value) in projects {
            try fixture.fs.write(PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), to: "/p/" + path + "/project.pbxproj")
        }
        try fixture.fs.write(Data("<Workspace><FileRef location=\"group:App.xcodeproj\"/><FileRef location=\"group:Core.xcodeproj\"/></Workspace>".utf8), to: "/p/Scope.xcworkspace/contents.xcworkspacedata")
        let original = String(decoding: try fixture.fs.readData(at: "/p/Scope.xcodeproj/xcshareddata/xcschemes/Scope.xcscheme"), as: UTF8.self)
        let scheme = original.replacingOccurrences(of: "container:Scope.xcodeproj", with: "container:App.xcodeproj")
            .replacingOccurrences(of: "BlueprintName=\"CoreBlueprint\" ReferencedContainer=\"container:App.xcodeproj\"",
                                  with: "BlueprintName=\"CoreBlueprint\" ReferencedContainer=\"container:Core.xcodeproj\"")
        try fixture.fs.write(Data(scheme.utf8), to: "/p/Scope.xcworkspace/xcshareddata/xcschemes/Scope.xcscheme")
        var targets = fixture.receipt["targets"] as! [[String: Any]]
        let idProjects = Dictionary(uniqueKeysWithValues: targets.map {
            ($0["id"] as! String, $0["name"] as! String == "CoreBlueprint" ? "Core.xcodeproj" : "App.xcodeproj")
        })
        for index in targets.indices {
            let id = targets[index]["id"] as! String
            targets[index]["id"] = idProjects[id]! + "::" + id
            targets[index]["dependencies"] = (targets[index]["dependencies"] as! [String]).map { idProjects[$0]! + "::" + $0 }
        }
        var settings = try JSONSerialization.jsonObject(with: Data((fixture.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
        for index in settings.indices {
            var values = settings[index]["buildSettings"] as! [String: String]
            values["PROJECT_FILE_PATH"] = "/p/" + (settings[index]["target"] as! String == "CoreBlueprint" ? "Core.xcodeproj" : "App.xcodeproj")
            settings[index]["buildSettings"] = values
        }
        fixture.receipt["version"] = 3
        fixture.receipt["project"] = "App.xcodeproj"
        fixture.receipt["workspace"] = "Scope.xcworkspace"
        fixture.receipt["projects"] = ["App.xcodeproj", "Core.xcodeproj"]
        fixture.receipt["localPackages"] = [[String: Any]]()
        fixture.receipt["schemePath"] = "Scope.xcworkspace/xcshareddata/xcschemes/Scope.xcscheme"
        fixture.receipt["targets"] = targets
        fixture.receipt["selectedTargetIDs"] = (fixture.receipt["selectedTargetIDs"] as! [String]).map { idProjects[$0]! + "::" + $0 }
        fixture.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys), as: UTF8.self)
        try refresh(&fixture)
        return fixture
    }

    func refresh(_ fixture: inout XcodeTargetScopeTests.Fixture) throws {
        let inventory = try XcodeTargetScopeStore(fileSystem: fixture.fs).inventory(root: "/p", workspace: true)
        fixture.receipt["before"] = inventory
        fixture.receipt["after"] = inventory
        fixture.receipt["inputFingerprint"] = try fixture.service.sessionInputFingerprint()
        try fixture.write()
    }

    @Test("다른 프로젝트의 같은 PBX ID를 경로로 구분하고 실제 의존 범위를 연결한다")
    func validWorkspace() throws {
        let fixture = try fixture()
        let result = fixture.scope()
        #expect(result.evidenceStatus == "matched-capture")
        #expect(result.xcode?.selectionStatus == "review-candidates")
        #expect(result.xcode?.workspace == "Scope.xcworkspace")
        #expect(result.xcode?.projects == ["App.xcodeproj", "Core.xcodeproj"])
        #expect(result.dependencyTargets.contains("CoreBlueprint"))
        #expect(result.xcode?.selectorTargetByModule["ChecksModule"] == "ChecksBlueprint")
        #expect(result.paths.contains { $0.path == "Unbuilt/Tool.swift" && $0.classification == "outside-selected-targets" })
    }

    @Test("workspace 신원과 원문 proxy 또는 선택 범위가 어긋나면 선택하지 않는다",
          arguments: ["missing-project", "unqualified", "foreign-proxy", "wrong-product", "wrong-settings-project", "duplicate-module", "workspace-edit", "nested-file-ref"])
    func refusesAmbiguity(kind: String) throws {
        var fixture = try fixture()
        switch kind {
        case "missing-project": fixture.receipt["projects"] = ["App.xcodeproj"]
        case "unqualified": fixture.receipt["selectedTargetIDs"] = ["000000000000000000000016"]
        case "foreign-proxy", "wrong-product":
            let path = "/p/App.xcodeproj/project.pbxproj"
            var plist = try PropertyListSerialization.propertyList(from: fixture.fs.readData(at: path), format: nil) as! [String: Any]
            var objects = plist["objects"] as! [String: [String: Any]]
            if kind == "foreign-proxy" { objects["workspace-target-proxy"]!["remoteGlobalIDString"] = "missing" }
            else { objects["workspace-product-proxy"]!["path"] = "Wrong.framework" }
            plist["objects"] = objects
            try fixture.fs.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: path)
        case "wrong-settings-project", "duplicate-module":
            var settings = try JSONSerialization.jsonObject(with: Data((fixture.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
            var values = settings[0]["buildSettings"] as! [String: String]
            values[kind == "duplicate-module" ? "PRODUCT_MODULE_NAME" : "PROJECT_FILE_PATH"] = kind == "duplicate-module" ? "ChecksModule" : "/p/Other.xcodeproj"
            settings[0]["buildSettings"] = values
            fixture.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        case "nested-file-ref":
            try fixture.fs.write(Data("<Workspace><FileRef location=\"group:App.xcodeproj\"><FileRef location=\"group:Core.xcodeproj\"/></FileRef></Workspace>".utf8), to: "/p/Scope.xcworkspace/contents.xcworkspacedata")
        default:
            try fixture.fs.write(Data("<Workspace><FileRef location=\"group:Other.xcodeproj\"/></Workspace>".utf8), to: "/p/Scope.xcworkspace/contents.xcworkspacedata")
        }
        try refresh(&fixture)
        #expect(fixture.scope().evidenceStatus == "unknown")
    }
}
