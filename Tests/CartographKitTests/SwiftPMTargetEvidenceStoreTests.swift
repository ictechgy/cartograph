import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
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
        "source", "manifest", "resolved", "description", "snapshot", "missing", "version", "producer-drift"
    ])
    func rejectsChangedInputs(mode: String) throws {
        let (fileSystem, original, receipt) = try fixture()
        var snapshot = original
        let store = SwiftPMTargetEvidenceStore(fileSystem: fileSystem)
        switch mode {
        case "source": try fileSystem.write(text: "changed", to: "/p/Sources/Probe.swift")
        case "manifest": try fileSystem.write(text: "changed", to: "/p/Package.swift")
        case "resolved": try fileSystem.write(text: "new resolution", to: "/p/Package.resolved")
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

    @Test("스냅샷 배열 순서는 지문을 바꾸지 않되 모듈 관찰 변경은 바꾼다")
    func snapshotFingerprintTracksContent() throws {
        let (_, snapshot, _) = try fixture()
        var reordered = snapshot
        reordered.symbols.reverse()
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot)
            == SwiftPMTargetEvidenceStore.snapshotIdentity(reordered))
        reordered.symbols.removeLast()
        #expect(try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot)
            != SwiftPMTargetEvidenceStore.snapshotIdentity(reordered))
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
