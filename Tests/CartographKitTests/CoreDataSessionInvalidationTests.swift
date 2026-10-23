import CartographCore
@testable import CartographKit
import CartographTestSupport
import CoreData
import Foundation
import Testing

@Suite("Core Data 최종 입력 관측과 세션 수명")
struct CoreDataSessionInvalidationTests {
    @Test("보강 뒤 마지막 지문 관측 실패·불일치는 준비된 문맥과 메타데이터를 모두 폐기한다",
          arguments: [false, true])
    func finalObservationInvalidates(throwsInsteadOfChanging: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        var calls = 0
        var failAt: Int?
        let session = try AnalysisSession(serviceFactory: { service }, inputFingerprintProvider: {
            calls += 1
            if calls == failAt {
                if throwsInsteadOfChanging { throw ObservationFailure.failed }
                return "changed"
            }
            return "stable"
        })
        _ = try session.query(symbols: ["App"])
        _ = try session.runtimeDiscovery(coreDataBuildEvidencePath: fixture.evidence.path)
        #expect(session.metadata?.generation == 1)
        #expect(session.querySession != nil)
        #expect(session.runtimeBuildEvidenceMetadata?.status == "verifiedCurrent")

        // ensurePrepared의 첫 관측은 성공하고 실제 모델 검증을 마친 마지막 관측만 실패한다.
        let before = calls
        failAt = before + 2
        if throwsInsteadOfChanging {
            #expect(throws: ObservationFailure.failed) {
                _ = try session.impact(symbols: ["App"], coreDataBuildEvidencePath: fixture.evidence.path)
            }
        } else {
            #expect(throws: AnalysisSessionError.inputChangedDuringRefresh(attempts: 1)) {
                _ = try session.runtimeDiscovery(coreDataBuildEvidencePath: fixture.evidence.path)
            }
        }
        #expect(calls == before + 2)
        #expect(session.metadata == nil)
        #expect(session.querySession == nil)
        #expect(session.runtimeBuildEvidenceMetadata == nil)

        failAt = nil
        #expect(try session.query(symbols: ["App"]).results.first?.status == "found")
        #expect(session.metadata?.generation == 2)
    }

    @Test("없는 보강 문서를 거부해도 검증된 기본 질의 문맥은 불필요하게 폐기하지 않는다")
    func missingEvidencePreservesBase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try AnalysisSession(service: fixture.service())
        _ = try session.query(symbols: ["App"])
        #expect(throws: CartographError.self) {
            _ = try session.runtimeDiscovery(coreDataBuildEvidencePath: "missing.json")
        }
        #expect(session.metadata?.generation == 1)
        #expect(session.querySession != nil)
        #expect(session.runtimeBuildEvidenceMetadata == nil)
        #expect(try session.query(symbols: ["App"]).results.first?.status == "found")
        #expect(session.metadata?.generation == 1)
    }
}

private enum ObservationFailure: Error, Equatable { case failed }

/// 실제 Core Data SDK가 읽을 수 있는 최소 수동 모델. 앱 실행/생성 클래스의 증거는 주장하지 않는다.
private struct Fixture {
    let root: URL
    let evidence: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-session-coredata-\(UUID().uuidString)")
        evidence = root.appendingPathComponent("evidence.json")
        source = root.appendingPathComponent("App.swift")
        let contents = root.appendingPathComponent("Probe.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let executable = contents.appendingPathComponent("MacOS/Probe")
        let modelSource = root.appendingPathComponent("Store.xcdatamodel")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelSource, withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("struct App {}".utf8).write(to: source)
        let info = ["CFBundleIdentifier": "dev.cartograph.SessionProbe", "CFBundleExecutable": "Probe"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("<model><entity name=\"Record\" representedClassName=\"NSManagedObject\"/></model>".utf8)
            .write(to: modelSource.appendingPathComponent("contents"))
        let entity = NSEntityDescription()
        entity.name = "Record"
        entity.managedObjectClassName = "NSManagedObject"
        let model = NSManagedObjectModel()
        model.entities = [entity]
        try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: false)
            .write(to: resources.appendingPathComponent("Store.mom"))
        try CoreDataBuildEvidenceStore().writeVerified(request: .init(
            executablePath: executable.path, sourceModelPath: modelSource.path,
            persistentContainerName: "Store"
        ), to: evidence.path)
    }

    func service() -> CartographService {
        var builder = SnapshotBuilder(path: source.path)
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        return CartographService(configuration: .init(projectPath: root.path), environment: .init(
            fileSystem: LocalFileSystem(), indexProviderOverride: StaticIndexProvider(builder.build())
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
