import CartographAnalysis
import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("SwiftPM 생산자 근거의 입력 검증")
struct SwiftPMTargetEvidenceStoreTests {
    @Test("원시 JSON은 근거를 승격하지 않고 검증된 소속은 파일과 모듈에 묶인다")
    func verifiesBoundReceipt() throws {
        let (fileSystem, snapshot, receipt) = try fixture()
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        #expect(try store.read(at: nil, snapshot: snapshot) == nil)
        #expect(throws: (any Error).self) {
            try store.read(at: "/p/description.json", snapshot: snapshot)
        }
        let targets = try store.verify(receipt, snapshot: snapshot)
        let facts = TestTargetMembershipFacts(snapshot: snapshot, targets: targets)
        #expect(facts.ordinaryUSRs == ["ordinary"])
        #expect(facts.testUSRs == ["test"])
        #expect(facts.unknownUSRs.isEmpty)
        let data = try JSONEncoder().encode(receipt)
        try fileSystem.write(data, to: "/p/receipt.json")
        #expect(try store.read(at: "/p/receipt.json", snapshot: snapshot) == targets)
        #expect(try JSONDecoder().decode(SwiftPMTargetEvidenceDocument.self, from: data) == receipt)
    }

    @Test("생산 뒤 소스·매니페스트·설명·인덱스가 바뀌면 거부한다", arguments: [
        "source", "manifest", "resolved", "resolved-directory", "description", "snapshot", "missing",
        "version", "producer-drift"
    ])
    func rejectsChangedInputs(mode: String) throws {
        let (fileSystem, original, receipt) = try fixture()
        var snapshot = original
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        switch mode {
        case "source": try fileSystem.write(text: "changed", to: "/p/Sources/Probe.swift")
        case "manifest": try fileSystem.write(text: "changed", to: "/p/Package.swift")
        case "resolved": try fileSystem.write(text: "new resolution", to: "/p/Package.resolved")
        case "resolved-directory": try fileSystem.write(text: "entry", to: "/p/Package.resolved/file")
        case "description": try fileSystem.write(text: "{}", to: "/p/description.json")
        case "snapshot": snapshot.symbols.removeLast()
        case "missing": try fileSystem.removeItem(at: "/p/Sources/Probe.swift")
        default:
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            if mode == "version" { object["version"] = 99 }
            else { object["snapshotBefore"] = "different-producer-generation" }
            let changed = try JSONDecoder().decode(SwiftPMTargetEvidenceDocument.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) { try store.verify(changed, snapshot: snapshot) }
            return
        }
        #expect(throws: (any Error).self) { try store.verify(receipt, snapshot: snapshot) }
    }

    @Test("경로 탈출과 다른 패키지 루트는 생산자 입력 단계에서도 거부한다",
          arguments: ["../Outside.swift", "/Outside.swift", "Sources//Probe.swift"])
    func rejectsUnsafePaths(path: String) throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/Package.swift": "", "/Outside.swift": ""])
        let object: [String: Any] = ["path": "/p", "targets": [
            ["name": "Probe", "type": "test", "c99name": "Probe", "module_type": "SwiftTarget",
             "path": "Sources", "sources": [path]]
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try SwiftPMTargetEvidenceStore(fileSystem: fileSystem).inputs(description: bytes, root: "/p")
        }
    }

    @Test("대표 선택에 쓰는 심볼 순서는 보존하고 참조 순서만 정규화한다")
    func snapshotFingerprintTracksContent() throws {
        let (_, snapshot, _) = try fixture()
        var reordered = snapshot
        reordered.symbols.reverse()
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot)
            != SwiftPMTargetEvidenceStore.snapshotIdentity(reordered))
        var conflicting = snapshot
        conflicting.symbols.append(.init(usr: "ordinary", name: "different()", kind: .method, module: "Other",
            location: .init(path: "/p/Other.swift", line: 1, column: 1)))
        var reversed = conflicting
        reversed.symbols.reverse()
        #expect(conflicting.symbolsByUSR()["ordinary"] != reversed.symbolsByUSR()["ordinary"])
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(conflicting)
            != SwiftPMTargetEvidenceStore.snapshotIdentity(reversed))

        var modules = snapshot
        modules.fileModuleUsages = ["/p/Sources/Probe.swift": .init(
            owningModule: "Probe", referencedModules: Set(["Foundation", "XCTest", "Swift"]))]
        var reversedModules = modules
        reversedModules.fileModuleUsages["/p/Sources/Probe.swift"] = .init(
            owningModule: "Probe", referencedModules: Set(["Swift", "XCTest", "Foundation"]))
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(modules)
            == SwiftPMTargetEvidenceStore.snapshotIdentity(reversedModules))
        reversedModules.fileModuleUsages["/p/Sources/Probe.swift"]?.referencedModules.insert("Different")
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(modules)
            != SwiftPMTargetEvidenceStore.snapshotIdentity(reversedModules))
        var references = snapshot
        references.references = [
            .init(sourceUSR: "test", targetUSR: "ordinary", kind: .call),
            .init(sourceUSR: "ordinary", targetUSR: "test", kind: .reference),
        ]
        var reversedReferences = references
        reversedReferences.references.reverse()
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(references)
            == SwiftPMTargetEvidenceStore.snapshotIdentity(reversedReferences))
    }


    @Test("소스 상한에는 고정 매니페스트 두 항목을 별도로 더한다", arguments: [10_000, 10_001])
    func sourceCountBoundary(count: Int) throws {
        let names = (0..<count).map { "Source\($0).swift" }
        var files = Dictionary(uniqueKeysWithValues: names.map { ("/p/Sources/" + $0, "") })
        files["/p/Package.swift"] = ""
        let description = try JSONSerialization.data(withJSONObject: [
            "path": "/p", "targets": [
                ["name": "Probe", "type": "library", "c99name": "Probe",
                 "module_type": "SwiftTarget", "path": "Sources", "sources": names]
            ]
        ])
        files["/p/description.json"] = String(decoding: description, as: UTF8.self)
        let fileSystem = InMemoryFileSystem(files: files)
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        if count > 10_000 {
            #expect(throws: (any Error).self) { try store.inputs(description: description, root: "/p") }
            return
        }
        let snapshot = IndexSnapshot(symbols: [])
        let inputs = try store.inputs(description: description, root: "/p")
        #expect(inputs.files.count == count + 2)
        let receipt = try boundReceipt(root: "/p", inputs: inputs, snapshot: snapshot)
        #expect(try store.verify(receipt, snapshot: snapshot).first?.sourcePaths.count == count)
    }

    @Test("실제 파일 시스템의 디렉터리와 끊어진 링크를 해결 파일의 부재로 오인하지 않는다",
          arguments: ["directory", "dangling-link"])
    func rejectsNonregularResolutionState(mode: String) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let fileSystem = LocalFileSystem()
        let root = try fileSystem.realPath(at: temporary.path)
        let description = try JSONSerialization.data(withJSONObject: [
            "path": root, "targets": [
                ["name": "Probe", "type": "library", "c99name": "Probe",
                 "module_type": "SwiftTarget", "path": "Sources", "sources": ["Probe.swift"]]
            ]
        ])
        try fileSystem.write(text: "", to: root + "/Package.swift")
        try fileSystem.write(text: "", to: root + "/Sources/Probe.swift")
        try fileSystem.write(description, to: root + "/description.json")
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        let snapshot = IndexSnapshot(symbols: [])
        let inputs = try store.inputs(description: description, root: root)
        let receipt = try boundReceipt(root: root, inputs: inputs, snapshot: snapshot)
        #expect(try store.verify(receipt, snapshot: snapshot).count == 1)
        let path = root + "/Package.resolved"
        if mode == "directory" {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else {
            try manager.createSymbolicLink(atPath: path, withDestinationPath: root + "/absent")
        }
        #expect(try fileSystem.contentsOfDirectory(at: root).contains(path))
        #expect(throws: (any Error).self) { try store.verify(receipt, snapshot: snapshot) }
        #expect(throws: (any Error).self) { try store.inputs(description: description, root: root) }
    }


    @Test("POSIX private 루트의 철자를 Foundation 별칭으로 바꾸지 않는다",
          arguments: ["/private/var/tmp/probe", "/private/tmp/probe"])
    func preservesPrivateRoot(root: String) throws {
        let description = try JSONSerialization.data(withJSONObject: [
            "path": root, "targets": [
                ["name": "Probe", "type": "library", "c99name": "Probe",
                 "module_type": "SwiftTarget", "path": "Sources", "sources": ["Probe.swift"]]
            ]
        ])
        let fileSystem = InMemoryFileSystem(files: [
            root + "/Package.swift": "", root + "/Sources/Probe.swift": "",
            root + "/description.json": String(decoding: description, as: UTF8.self)
        ])
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        let snapshot = IndexSnapshot(symbols: [])
        let inputs = try store.inputs(description: description, root: root)
        let receipt = try boundReceipt(root: root, inputs: inputs, snapshot: snapshot)
        #expect(try store.verify(receipt, snapshot: snapshot).first?.packageRoot == root)
        for suffix in ["/.", "/..", "//child"] {
            #expect(throws: (any Error).self) {
                try store.inputs(description: description, root: root + suffix)
            }
        }
    }

    private func boundReceipt(
        root: String, inputs: SwiftPMTargetEvidenceDocument.Inputs, snapshot: IndexSnapshot
    ) throws -> SwiftPMTargetEvidenceDocument {
        let identity = try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot)
        return .init(
            packageRoot: root, descriptionPath: root + "/description.json", toolchain: "controlled fixture",
            configuration: "debug", describeArguments: ["swift", "package", "describe", "--type", "json"],
            buildArguments: ["swift", "build", "--package-path", root, "--scratch-path", root + "/.build",
                "--configuration", "debug", "--build-tests", "--enable-index-store", "--jobs", "2"],
            before: inputs, after: inputs, snapshotBefore: identity, snapshotAfter: identity
        )
    }

    private func fixture() throws -> (InMemoryFileSystem, IndexSnapshot, SwiftPMTargetEvidenceDocument) {
        let description = """
        {"path":"/p","targets":[
          {"name":"Probe","type":"library","c99name":"Probe","module_type":"SwiftTarget",
           "path":"Sources","sources":["Probe.swift"]},
          {"name":"ProbeTests","type":"test","c99name":"ProbeTests","module_type":"SwiftTarget",
           "path":"Tests","sources":["Probe.swift"]}
        ]}
        """
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Package.swift": "fixture manifest", "/p/description.json": description,
            "/p/Sources/Probe.swift": "ordinary source", "/p/Tests/Probe.swift": "test source"
        ])
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "ordinary", name: "testShared()", kind: .method, module: "Probe",
                  location: .init(path: "/p/Sources/Probe.swift", line: 1, column: 1)),
            .init(usr: "test", name: "testShared()", kind: .method, module: "ProbeTests",
                  location: .init(path: "/p/Tests/Probe.swift", line: 1, column: 1)),
        ])
        let inputs = try SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
            .inputs(description: Data(description.utf8), root: "/p")
        let identity = try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot)
        let receipt = SwiftPMTargetEvidenceDocument(
            packageRoot: "/p", descriptionPath: "/p/description.json", toolchain: "controlled fixture",
            configuration: "debug", describeArguments: ["swift", "package", "describe", "--type", "json"],
            buildArguments: ["swift", "build", "--package-path", "/p", "--scratch-path", "/p/.build",
                "--configuration", "debug", "--build-tests", "--enable-index-store", "--jobs", "2"],
            before: inputs, after: inputs, snapshotBefore: identity, snapshotAfter: identity
        )
        return (fileSystem, snapshot, receipt)
    }
}
