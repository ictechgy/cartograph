import CartographCore
@testable import CartographKit
import Foundation
import Testing

@Suite("Core Data 빌드 근거")
struct CoreDataBuildEvidenceTests {
    @Test("앱 번들의 exact 모델과 생성 소스·USR를 하나의 검증 가능한 문서로 만든다")
    func createsEvidenceForExactBundleMember() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let evidence = try store.create(request: fixture.request())

        #expect(evidence.bundle.identifier == "dev.cartograph.BuildEvidenceProbe")
        #expect(evidence.bundle.compiledModelRelativePath == "Store.mom")
        #expect(evidence.model.entities == [
            CoreDataBuildEntityEvidence(
                name: "Record", representedClassName: "Probe.Record",
                managedObjectClassName: "Probe.Record", codeGenerationType: "class"
            ),
        ])
        #expect(evidence.declaredGeneratedMappings.first?.module == "Probe")
        #expect(evidence.declaredGeneratedMappings.first?.declarationUSRs == ["s:5Probe6RecordC"])
        #expect(evidence.declaredGeneratedMappings.first?.linkedBinarySymbols == [
            "_$s5Probe6RecordCMn", "_$s5Probe6RecordCN",
        ])

        let output = fixture.root.appendingPathComponent("evidence.json").path
        _ = try store.writeVerified(request: fixture.request(), to: output)
        #expect(try store.readAndVerify(at: output) == evidence)
    }

    @Test("근거를 만든 뒤 모델·바이너리·생성 소스 중 하나라도 바뀌면 거부한다")
    func rejectsChangedArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let evidence = try store.create(request: fixture.request())

        try Data("// changed".utf8).write(to: fixture.generatedSource)
        #expect(throws: CartographError.self) { try store.verify(evidence) }
    }

    @Test("같은 persistent container 이름의 mom과 momd가 함께 있으면 선택을 추측하지 않는다")
    func rejectsDuplicateCompiledModels() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let duplicate = fixture.resources.appendingPathComponent("Store.momd")
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try Data("duplicate".utf8).write(to: duplicate.appendingPathComponent("Store.mom"))

        #expect(throws: CartographError.self) { try fixture.store().create(request: fixture.request()) }
    }

    @Test("번들 식별자·링크 탈출·컴파일 모델 클래스 불일치를 fail closed로 거부한다")
    func rejectsUntrustedBundleAndModelMetadata() throws {
        let malformed = try Fixture(bundleIdentifier: "invalid bundle id")
        defer { malformed.remove() }
        #expect(throws: CartographError.self) {
            try malformed.store().create(request: malformed.request())
        }

        let mismatch = try Fixture()
        defer { mismatch.remove() }
        #expect(throws: CartographError.self) {
            try mismatch.store(className: "Wrong.Record").create(request: mismatch.request())
        }
        #expect(throws: CartographError.self) {
            try mismatch.store(linkedSymbols: []).create(request: mismatch.request())
        }

        let escaped = try Fixture()
        defer { escaped.remove() }
        let model = escaped.resources.appendingPathComponent("Store.mom")
        try FileManager.default.removeItem(at: model)
        let external = escaped.root.appendingPathComponent("external.mom")
        try Data("compiled".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: external)
        #expect(throws: CartographError.self) {
            try escaped.store().create(request: escaped.request())
        }
    }

    @Test("자동 생성 모델에는 알려진 엔티티의 유효한 모듈·고유 USR 매핑이 필요하다")
    func validatesDeclaredMappings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let missing = CoreDataBuildEvidenceRequest(
            executablePath: fixture.executable.path,
            sourceModelPath: fixture.sourceModel.path,
            persistentContainerName: "Store"
        )
        #expect(throws: CartographError.self) { try store.create(request: missing) }

        let unknown = CoreDataBuildEvidenceRequest(
            executablePath: fixture.executable.path,
            sourceModelPath: fixture.sourceModel.path,
            persistentContainerName: "Store",
            declaredGeneratedMappings: [
                CoreDataDeclaredGeneratedMappingInput(
                    entityName: "Unknown", sourcePath: fixture.generatedSource.path,
                    module: "bad-module", declarationUSRs: ["short"]
                ),
            ]
        )
        #expect(throws: CartographError.self) { try store.create(request: unknown) }
    }

    @Test("중복·이름 없는 엔티티와 DTD가 있는 소스 모델을 거부한다")
    func rejectsUnsafeSourceModels() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.sourceModel.appendingPathComponent("contents")

        try Data(Fixture.duplicateModelXML.utf8).write(to: contents)
        #expect(throws: CartographError.self) { try fixture.store().create(request: fixture.request()) }
        try Data(Fixture.unnamedModelXML.utf8).write(to: contents)
        #expect(throws: CartographError.self) { try fixture.store().create(request: fixture.request()) }
        try Data(("<!DOCTYPE model>\n" + Fixture.modelXML).utf8).write(to: contents)
        #expect(throws: CartographError.self) { try fixture.store().create(request: fixture.request()) }
    }

    @Test("근거 출력이 입력 파일을 덮어쓰거나 손상된 문서를 검증하지 못하게 한다")
    func protectsInputsAndRejectsMalformedDocuments() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let original = try Data(contentsOf: fixture.generatedSource)
        #expect(throws: CartographError.self) {
            try store.writeVerified(request: fixture.request(), to: fixture.generatedSource.path)
        }
        #expect(try Data(contentsOf: fixture.generatedSource) == original)

        let malformed = fixture.root.appendingPathComponent("malformed.json")
        try Data("{}".utf8).write(to: malformed)
        #expect(throws: CartographError.self) { try store.readAndVerify(at: malformed.path) }
        try Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1).write(to: malformed)
        #expect(throws: CartographError.self) { try store.readAndVerify(at: malformed.path) }
    }

    @Test("represented class가 없는 수동 모델은 NSManagedObject 기본값으로만 받아들인다")
    func acceptsCoreDataDefaultManagedObjectClass() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("<model><entity name=\"Record\"/></model>".utf8).write(
            to: fixture.sourceModel.appendingPathComponent("contents")
        )
        let request = CoreDataBuildEvidenceRequest(
            executablePath: fixture.executable.path,
            sourceModelPath: fixture.sourceModel.path,
            persistentContainerName: "Store"
        )
        let evidence = try fixture.store(className: "NSManagedObject").create(request: request)
        #expect(evidence.model.entities.first?.representedClassName == nil)
        #expect(evidence.model.entities.first?.managedObjectClassName == "NSManagedObject")
        #expect(throws: CartographError.self) {
            try fixture.store(className: "Probe.Record").create(request: request)
        }
    }

    @Test("category 코드 생성은 기존 수동 클래스이므로 class 생성 매핑을 강제하지 않는다")
    func categoryDoesNotRequireClassMapping() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let xml = """
            <model>
                <entity name="Record" representedClassName="Probe.Record" codeGenerationType="category"/>
            </model>
            """
        try Data(xml.utf8).write(to: fixture.sourceModel.appendingPathComponent("contents"))
        let request = CoreDataBuildEvidenceRequest(
            executablePath: fixture.executable.path,
            sourceModelPath: fixture.sourceModel.path,
            persistentContainerName: "Store"
        )
        let evidence = try fixture.store().create(request: request)
        #expect(evidence.declaredGeneratedMappings.isEmpty)
    }

    @Test("손상된 enum 원문은 증거 문서 오류에 다시 출력하지 않는다")
    func doesNotEchoMalformedDocumentValues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let evidence = try store.create(request: fixture.request())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let valid = String(decoding: try encoder.encode(evidence), as: UTF8.self)
        let sensitive = "credential-like-private-value"
        let invalid = valid.replacingOccurrences(
            of: #""kind":"file""#,
            with: #""kind":"\#(sensitive)""#,
            options: [],
            range: valid.range(of: #""kind":"file""#)
        )
        let path = fixture.root.appendingPathComponent("invalid.json")
        try Data(invalid.utf8).write(to: path)
        do {
            _ = try store.readAndVerify(at: path.path)
            Issue.record("손상된 kind를 거부해야 한다")
        } catch {
            #expect(!String(describing: error).contains(sensitive))
            #expect(String(describing: error).contains("prepare-coredata"))
        }
    }

    @Test("소스와 compiled model의 parent entity 계층을 대조하고 cycle을 거부한다")
    func validatesEntityHierarchy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.sourceModel.appendingPathComponent("contents")
        let hierarchy = """
            <model>
                <entity name="Parent" representedClassName="Probe.Parent"/>
                <entity name="Child" representedClassName="Probe.Child" parentEntity="Parent"/>
            </model>
            """
        try Data(hierarchy.utf8).write(to: contents)
        let request = CoreDataBuildEvidenceRequest(
            executablePath: fixture.executable.path,
            sourceModelPath: fixture.sourceModel.path,
            persistentContainerName: "Store"
        )
        let matching = fixture.store(metadata: [
            .init(name: "Parent", managedObjectClassName: "Probe.Parent"),
            .init(name: "Child", managedObjectClassName: "Probe.Child", superentityName: "Parent"),
        ])
        let evidence = try matching.create(request: request)
        #expect(evidence.model.entities.first { $0.name == "Child" }?.superentityName == "Parent")

        let mismatch = fixture.store(metadata: [
            .init(name: "Parent", managedObjectClassName: "Probe.Parent"),
            .init(name: "Child", managedObjectClassName: "Probe.Child"),
        ])
        #expect(throws: CartographError.self) { try mismatch.create(request: request) }

        let cycle = hierarchy.replacingOccurrences(
            of: "name=\"Parent\" representedClassName=\"Probe.Parent\"",
            with: "name=\"Parent\" representedClassName=\"Probe.Parent\" parentEntity=\"Child\""
        )
        try Data(cycle.utf8).write(to: contents)
        #expect(throws: CartographError.self) {
            try fixture.store(metadata: [
                .init(name: "Parent", managedObjectClassName: "Probe.Parent", superentityName: "Child"),
                .init(name: "Child", managedObjectClassName: "Probe.Child", superentityName: "Parent"),
            ]).create(request: request)
        }
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    let resources: URL
    let sourceModel: URL
    let generatedSource: URL

    init(bundleIdentifier: String = "dev.cartograph.BuildEvidenceProbe") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Probe.app")
        executable = bundle.appendingPathComponent("Contents/MacOS/Probe")
        resources = bundle.appendingPathComponent("Contents/Resources")
        sourceModel = root.appendingPathComponent("Store.xcdatamodel")
        generatedSource = root.appendingPathComponent("Generated/Record+CoreDataClass.swift")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: generatedSource.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("compiled".utf8).write(to: resources.appendingPathComponent("Store.mom"))
        try Data(Self.modelXML.utf8).write(to: sourceModel.appendingPathComponent("contents"))
        try Data("public final class Record {}".utf8).write(to: generatedSource)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Probe",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    func request() -> CoreDataBuildEvidenceRequest {
        CoreDataBuildEvidenceRequest(
            executablePath: executable.path,
            sourceModelPath: sourceModel.path,
            persistentContainerName: "Store",
            declaredGeneratedMappings: [
                CoreDataDeclaredGeneratedMappingInput(
                    entityName: "Record", sourcePath: generatedSource.path,
                    module: "Probe", declarationUSRs: ["s:5Probe6RecordC"]
                ),
            ]
        )
    }

    func store(
        className: String = "Probe.Record",
        linkedSymbols: Set<String> = ["_$s5Probe6RecordCMn", "_$s5Probe6RecordCN"]
    ) -> CoreDataBuildEvidenceStore {
        CoreDataBuildEvidenceStore(
            fileSystem: LocalFileSystem(),
            modelLoader: { _ in
                [CoreDataCompiledEntityMetadata(name: "Record", managedObjectClassName: className)]
            },
            linkedSymbolsLoader: { _ in linkedSymbols }
        )
    }

    func store(metadata: [CoreDataCompiledEntityMetadata]) -> CoreDataBuildEvidenceStore {
        CoreDataBuildEvidenceStore(
            fileSystem: LocalFileSystem(),
            modelLoader: { _ in metadata },
            linkedSymbolsLoader: { _ in ["_$s5Probe6RecordCMn", "_$s5Probe6RecordCN"] }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" sourceLanguage="Swift">
            <entity name="Record" representedClassName="Probe.Record" codeGenerationType="class"/>
        </model>
        """

    static let duplicateModelXML = """
        <model>
            <entity name="Record" representedClassName="Probe.Record" codeGenerationType="class"/>
            <entity name="Record" representedClassName="Probe.Record" codeGenerationType="class"/>
        </model>
        """

    static let unnamedModelXML = """
        <model>
            <entity representedClassName="Probe.Record" codeGenerationType="class"/>
            <entity name="Record" representedClassName="Probe.Record" codeGenerationType="class"/>
        </model>
        """
}
