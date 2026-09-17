import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("재사용 가능한 분석 세션")
struct AnalysisSessionTests {
    @Test("같은 입력에서는 문맥과 인덱스를 재사용하고 질의 세션은 첫 질의 때 만든다")
    func reusesPreparedContextAndLazyQuerySession() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)

        #expect(state.factoryCount == 1)
        #expect(state.indexLoadCount == 1)
        #expect(session.metadata?.generation == 1)

        let first = try session.query(symbols: ["App"])
        let second = try session.query(symbols: ["Service"])
        let impact = try session.impact(symbols: ["App"])
        let check = try session.check()

        #expect(first.format == "symbol-query-batch")
        #expect(first.version == 1)
        #expect(first.results.first?.requested == "App")
        #expect(first.results.first?.level == "symbol")
        #expect(second.results.first?.status == "found")
        #expect(impact.status == "found")
        #expect(check.format == "project-check")
        #expect(state.factoryCount == 1)
        #expect(state.indexLoadCount == 1)
        #expect(session.metadata?.nodeCount == 2)
        #expect(session.metadata?.fileCount == 2)
        #expect(try session.status().generation == 1)
    }

    @Test("지문이 바뀌면 새 서비스와 문맥으로 교체한다")
    func reloadsWhenFingerprintChanges() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)
        state.snapshot = makeSnapshot(extra: "NewService")
        state.fingerprint = "second"

        let batch = try session.query(symbols: ["NewService"])

        #expect(batch.results.first?.status == "found")
        #expect(state.factoryCount == 2)
        #expect(state.indexLoadCount == 2)
        #expect(session.metadata?.generation == 2)
        #expect(session.metadata?.fingerprint == "second")
    }

    @Test("명시적 refresh 는 같은 지문이어도 세대를 새로 만든다")
    func explicitRefreshCreatesNewGeneration() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)

        let metadata = try session.refresh()

        #expect(metadata.generation == 2)
        #expect(metadata.fingerprint == "first")
        #expect(state.factoryCount == 2)
        #expect(state.indexLoadCount == 2)
    }

    @Test("serviceFactory 초기화는 새 서비스의 설정과 문맥을 다시 읽는다")
    func factoryConvenienceReloadsFreshService() throws {
        let fileSystem = InMemoryFileSystem(
            currentDirectoryPath: "/p",
            files: [
                "/p/App.swift": "struct App {}",
                "/p/Service.swift": "func service() {}",
                "/p/.cartograph.yml": "level: module\n",
            ]
        )
        let state = FactoryReloadState(fileSystem: fileSystem, snapshot: makeSnapshot())
        let session = try AnalysisSession(serviceFactory: { state.makeService() })
        try fileSystem.write(text: "struct Reloaded {}", to: "/p/Reloaded.swift")
        try fileSystem.write(text: "level: symbol\n", to: "/p/.cartograph.yml")
        state.snapshot = makeSnapshot(extra: "Reloaded")

        let result = try session.query(symbols: ["Reloaded"])

        #expect(result.results.first?.status == "found")
        #expect(session.metadata?.generation == 2)
        #expect(state.factoryCount == 6)
        #expect(state.indexLoadCount == 2)
    }

    @Test("로드 중 입력이 바뀌면 안정된 지문을 얻을 때까지 다시 읽는다")
    func retriesUntilFingerprintIsStable() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)
        state.snapshot = makeSnapshot(extra: "Reloaded")
        state.fingerprint = "stable"
        state.fingerprintValues = ["second", "changed-during-load", "stable"]

        let batch = try session.query(symbols: ["Reloaded"])

        #expect(batch.results.first?.status == "found")
        // 초기 문맥 한 번 뒤, 두 번 바뀐 입력이 세 번째 읽기에서 안정된다.
        #expect(state.factoryCount == 4)
        #expect(state.indexLoadCount == 4)
        #expect(session.metadata?.fingerprint == "stable")
    }

    @Test("새로고침이 실패하면 이전 문맥과 메타데이터를 남기지 않는다")
    func discardsStateAfterRefreshFailure() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)
        state.fingerprintValues = ["second", "changed-1", "changed-2", "changed-3"]

        #expect(throws: AnalysisSessionError.self) {
            _ = try session.query(symbols: ["App"])
        }
        #expect(session.metadata == nil)

        state.fingerprintValues = ["recovered", "recovered"]
        state.snapshot = makeSnapshot(extra: "Recovered")
        let recovered = try session.query(symbols: ["Recovered"])
        #expect(recovered.results.first?.status == "found")
        #expect(session.metadata?.fingerprint == "recovered")
    }

    @Test("서비스 공장 실패도 이전 문맥을 사용할 수 없게 만든다")
    func discardsStateAfterFactoryFailure() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)
        state.fingerprint = "second"
        state.factoryShouldFail = true

        #expect(throws: SessionFactoryError.self) {
            _ = try session.query(symbols: ["App"])
        }
        #expect(session.metadata == nil)
    }

    @Test("입력 지문을 읽지 못해도 이전 문맥을 사용할 수 없게 만든다")
    func discardsStateAfterFingerprintFailure() throws {
        let state = SessionState(snapshot: makeSnapshot())
        let session = try makeSession(state)
        state.fingerprintShouldFail = true

        #expect(throws: SessionFingerprintError.self) {
            _ = try session.query(symbols: ["App"])
        }
        #expect(session.metadata == nil)
    }

    @Test("소스 내용은 수정 시각이 같아도 지문을 바꾼다")
    func sourceContentInvalidatesWithUnchangedModificationDate() throws {
        let firstFileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let secondFileSystem = fingerprintFileSystem(source: "struct App { let value: Int }", indexUnit: "one")
        let touchedFileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let date = Date(timeIntervalSinceReferenceDate: 123)
        firstFileSystem.setModificationDate(date, for: "/p/App.swift")
        secondFileSystem.setModificationDate(date, for: "/p/App.swift")
        touchedFileSystem.setModificationDate(date.addingTimeInterval(60), for: "/p/App.swift")
        let first = try fingerprintService(fileSystem: firstFileSystem).sessionInputFingerprint()
        let second = try fingerprintService(fileSystem: secondFileSystem).sessionInputFingerprint()
        let touched = try fingerprintService(fileSystem: touchedFileSystem).sessionInputFingerprint()

        #expect(first != second)
        // 수정 시각은 내용 외에 인덱스 신선도 보고에도 쓰이므로 지문의 일부다.
        #expect(first != touched)
    }

    @Test("Core Data 모델 추가 수정 삭제는 세션과 trace 지문을 바꾸고 일반 contents는 무시한다")
    func coreDataResourcesInvalidateFingerprintsAndSessions() throws {
        let withoutModel = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let firstModel = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let secondModel = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let unrelated = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let modelPath = "/p/Model.xcdatamodel/contents"
        try firstModel.write(text: "<model><entity name=\"A\" representedClassName=\"App.A\"/></model>", to: modelPath)
        try secondModel.write(text: "<model><entity name=\"B\" representedClassName=\"App.B\"/></model>", to: modelPath)
        try unrelated.write(text: "not a model", to: "/p/Documentation/contents")

        let without = fingerprintService(fileSystem: withoutModel)
        let first = fingerprintService(fileSystem: firstModel)
        let second = fingerprintService(fileSystem: secondModel)
        #expect(try without.sessionInputFingerprint() != first.sessionInputFingerprint())
        #expect(try first.sessionInputFingerprint() != second.sessionInputFingerprint())
        #expect(try without.sessionInputFingerprint()
            == fingerprintService(fileSystem: unrelated).sessionInputFingerprint())
        #expect(try first.runtimeTraceInputFingerprint() != second.runtimeTraceInputFingerprint())

        let session = try AnalysisSession(service: first)
        let generation = try #require(session.metadata?.generation)
        try firstModel.write(
            text: "<model><entity name=\"C\" representedClassName=\"App.C\"/></model>",
            to: modelPath
        )
        _ = try session.status()
        #expect(session.metadata?.generation == generation + 1)
    }

    @Test("모델 내용이 같아도 현재 버전 포인터 변경은 세션과 trace를 무효화한다")
    func coreDataVersionSelectionInvalidatesEvidence() throws {
        let fileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let marker = "/p/Store.xcdatamodeld/.xccurrentversion"
        let service = fingerprintService(fileSystem: fileSystem)
        let before = try service.sessionInputFingerprint()
        try fileSystem.write(text: "{ _XCCurrentVersionName = V1.xcdatamodel; }", to: marker)
        let first = try service.sessionInputFingerprint()
        #expect(before != first)
        let firstTrace = try service.runtimeTraceInputFingerprint()
        let session = try AnalysisSession(service: service)
        let generation = try #require(session.metadata?.generation)
        try fileSystem.write(text: "{ _XCCurrentVersionName = V2.xcdatamodel; }", to: marker)
        #expect(try service.sessionInputFingerprint() != first)
        #expect(try service.runtimeTraceInputFingerprint() != firstTrace)
        _ = try session.status()
        #expect(session.metadata?.generation == generation + 1)
    }

    @Test("SecretStore.swift 같은 정상 소스는 이름 때문에 fingerprint에서 빠지지 않는다")
    func fingerprintsSourceWhoseNameLooksSensitive() throws {
        let firstFileSystem = fingerprintFileSystem(
            source: "struct SecretStore {}", sourcePath: "/p/SecretStore.swift", indexUnit: "one"
        )
        let secondFileSystem = fingerprintFileSystem(
            source: "struct SecretStore { let value: Int }",
            sourcePath: "/p/SecretStore.swift",
            indexUnit: "one"
        )
        let first = try fingerprintService(fileSystem: firstFileSystem).sessionInputFingerprint()
        let second = try fingerprintService(fileSystem: secondFileSystem).sessionInputFingerprint()

        #expect(first != second)
    }

    @Test("index 라이브러리를 같은 수정 시각으로 교체해도 입력 지문이 바뀐다")
    func indexLibraryContentInvalidates() throws {
        let path = "/developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        let fileSystem = InMemoryFileSystem(files: [path: "old-library"])
        let date = Date(timeIntervalSinceReferenceDate: 123)
        fileSystem.setModificationDate(date, for: path)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: fileSystem, developerDirectory: "/developer"))
        let first = try service.sessionInputFingerprint()
        try fileSystem.write(text: "new-library", to: path)
        fileSystem.setModificationDate(date, for: path)
        #expect(try service.sessionInputFingerprint() != first)
    }

    @Test("실제 서비스 세션도 같은 시각의 소스 변경을 다시 읽는다")
    func sessionReloadsAfterSourceContentChange() throws {
        let fileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let service = fingerprintService(fileSystem: fileSystem)
        let session = try AnalysisSession(service: service)
        let initialGeneration = try #require(session.metadata?.generation)
        try fileSystem.write(text: "struct App { let value: Int }", to: "/p/App.swift")

        _ = try session.query(symbols: ["App"])

        #expect(session.metadata?.generation == initialGeneration + 1)
    }

    @Test("실제 index unit 변경도 준비된 세대를 무효화한다")
    func sessionReloadsAfterIndexUnitChange() throws {
        let fileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        let session = try AnalysisSession(service: fingerprintService(fileSystem: fileSystem))
        let initialGeneration = try #require(session.metadata?.generation)
        try fileSystem.write(text: "two", to: "/p/index-store/v5/units/unit-1")

        _ = try session.query(symbols: ["App"])

        #expect(session.metadata?.generation == initialGeneration + 1)
    }

    @Test("설정·베이스라인·외부 근거·소스 삭제·index unit 변경을 지문에 반영한다")
    func fingerprintsKnownInputsAndDeletions() throws {
        let base = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", includeBaseline: true
        )
        let changedConfiguration = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", includeBaseline: true,
            configuration: "level: type\n"
        )
        let changedExternal = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", includeBaseline: true,
            externalRetentions: "{\"format\":\"changed\"}"
        )
        let changedBaseline = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", includeBaseline: true,
            baseline: "{\"fingerprints\":[\"new\"]}"
        )
        let removedSource = fingerprintFileSystem(source: nil, indexUnit: "one", includeBaseline: true)
        let changedIndex = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "two", includeBaseline: true
        )
        let touchedIndex = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", includeBaseline: true
        )
        touchedIndex.setModificationDate(
            Date(timeIntervalSinceReferenceDate: 456),
            for: "/p/index-store/v5/units"
        )

        let first = try fingerprintService(fileSystem: base).sessionInputFingerprint()
        let config = try fingerprintService(fileSystem: changedConfiguration).sessionInputFingerprint()
        let external = try fingerprintService(fileSystem: changedExternal).sessionInputFingerprint()
        let baseline = try fingerprintService(fileSystem: changedBaseline).sessionInputFingerprint()
        let source = try fingerprintService(fileSystem: removedSource).sessionInputFingerprint()
        let index = try fingerprintService(fileSystem: changedIndex).sessionInputFingerprint()
        let touched = try fingerprintService(fileSystem: touchedIndex).sessionInputFingerprint()

        #expect(first != config)
        #expect(first != external)
        #expect(first != baseline)
        #expect(first != source)
        #expect(first != index)
        #expect(first != touched)
    }

    @Test("비밀 파일은 세션 지문 입력으로 읽지 않는다")
    func excludesSensitiveFilesFromFingerprint() throws {
        let firstFileSystem = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", sensitiveContents: ("one", "one", "one")
        )
        let secondFileSystem = fingerprintFileSystem(
            source: "struct App {}", indexUnit: "one", sensitiveContents: ("two", "two", "two")
        )

        let first = try fingerprintService(fileSystem: firstFileSystem).sessionInputFingerprint()
        let second = try fingerprintService(fileSystem: secondFileSystem).sessionInputFingerprint()

        #expect(first == second)
    }

    @Test("credential 파일을 실제 분석 입력으로 지정하면 조용히 누락하지 않는다")
    func rejectsSensitiveConfiguredInput() throws {
        let fileSystem = fingerprintFileSystem(source: "struct App {}", indexUnit: "one")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.baselinePath = "auth.json"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(makeSnapshot())
            )
        )

        do {
            _ = try service.sessionInputFingerprint()
            Issue.record("민감한 분석 입력은 거부되어야 한다")
        } catch let error as AnalysisSessionError {
            #expect(error == .sensitiveInput)
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("신뢰할 수 있는 stamp가 같으면 warm refresh에서 소스와 unit을 다시 읽지 않는다")
    func cachedFingerprintSkipsWarmContentReads() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: source)
        )

        fileSystem.resetContentReads()
        _ = try session.status()
        #expect(fileSystem.contentReadBytes == 0)

        fileSystem.resetContentReads()
        _ = try session.refresh()
        #expect(fileSystem.contentReadBytes == 0)
    }

    @Test("mtime를 복원한 내용 변경은 ctime stamp를 바꿔 다시 읽는다")
    func sameModificationDateStillInvalidatesCachedDigest() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        let service = makeLocalService(fileSystem: fileSystem, project: root, source: source)
        let session = try AnalysisSession(service: service)
        let before = try session.status()
        let originalDate = fileSystem.modificationDate(at: source)

        try fileSystem.write(text: "struct App { let value: Int }", to: source)
        if let originalDate {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: source)
        }
        fileSystem.resetContentReads()
        let after = try session.status()

        #expect(after.generation == before.generation + 1)
        #expect(after.fingerprint != before.fingerprint)
        #expect(fileSystem.contentReadBytes > 0)
    }

    @Test("내용이 같아도 소스 수정 시각이 바뀌면 신선도 메타데이터를 다시 계산한다")
    func sourceTimestampChangeInvalidatesFreshness() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        let session = try AnalysisSession(service: makeLocalService(
            fileSystem: fileSystem, project: root, source: source
        ))
        let before = try session.status()
        let date = try #require(fileSystem.modificationDate(at: source))
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(10)],
            ofItemAtPath: source)
        let after = try session.status()
        #expect(after.generation == before.generation + 1)
        #expect(after.fingerprint != before.fingerprint)
    }

    @Test("파일 이름 변경·삭제·추가는 캐시 항목과 지문을 갱신한다")
    func fileSetChangesInvalidateCachedDigest() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        let renamed = root + "/Renamed.m"
        try fileSystem.write(text: "struct App {}", to: source)
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: source)
        )
        var generation = try session.status().generation

        try FileManager.default.moveItem(atPath: source, toPath: renamed)
        fileSystem.resetContentReads()
        generation += 1
        #expect(try session.status().generation == generation)
        #expect(fileSystem.contentReadBytes > 0)

        try FileManager.default.removeItem(atPath: renamed)
        fileSystem.resetContentReads()
        generation += 1
        #expect(try session.status().generation == generation)
        #expect(fileSystem.contentReadBytes == 0)

        try fileSystem.write(text: "struct NewApp {}", to: root + "/New.m")
        fileSystem.resetContentReads()
        generation += 1
        #expect(try session.status().generation == generation)
        #expect(fileSystem.contentReadBytes > 0)
    }

    @Test("권한 stamp가 바뀌면 같은 내용이어도 cache digest를 재검증한다")
    func permissionStampInvalidatesCachedDigest() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: source)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source)
        fileSystem.resetContentReads()
        _ = try session.refresh()
        #expect(fileSystem.contentReadBytes > 0)
    }

    @Test("stamp를 제공하지 않는 파일 시스템은 warm refresh에서도 내용을 확인한다")
    func unstampedFileSystemStillHashesContent() throws {
        let root = "/p"
        let backing = InMemoryFileSystem(currentDirectoryPath: root, files: [
            "/p/App.m": "struct App {}",
            "/p/index-store/v5/units/App-unit": "unit",
        ])
        let fileSystem = CountingUnstampedFileSystem(backing: backing)
        let session = try AnalysisSession(service: makeLocalService(
            fileSystem: fileSystem, project: root, source: "/p/App.m"
        ))

        fileSystem.resetContentReads()
        _ = try session.refresh()
        #expect(fileSystem.contentReadBytes > 0)

        let before = try session.status()
        try backing.write(text: "struct App { let value: Int }", to: "/p/App.m")
        fileSystem.resetContentReads()
        let after = try session.status()
        #expect(after.generation == before.generation + 1)
        #expect(after.fingerprint != before.fingerprint)
        #expect(fileSystem.contentReadBytes > 0)
    }

    @Test("디렉터리 구조가 그대로면 warm 갱신은 열거를 반복하지 않고 항목이 생기면 다시 훑는다")
    func unchangedStructureSkipsEnumerationOnWarmStatus() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: source)
        )

        _ = try session.status()
        let settled = fileSystem.directoryEnumerations
        _ = try session.status()
        // 디렉터리 지문이 전부 그대로면 목록·글롭 대조·열거를 재사용한다.
        #expect(fileSystem.directoryEnumerations == settled)

        try fileSystem.write(text: "struct New {}", to: root + "/New.m")
        _ = try session.status()
        // 상위 디렉터리 지문이 바뀌었으므로 탐색을 다시 수행해 새 파일을 본다.
        #expect(fileSystem.directoryEnumerations > settled)
    }

    @Test("열거에 실패한 디렉터리의 지문도 감시해 읽을 수 있게 되면 다시 탐색한다")
    func unwalkableDirectoryIsWatchedForChanges() throws {
        let root = try makeTemporaryProject()
        let locked = root + "/Locked"
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: root)
        }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        try fileSystem.write(text: "struct App {}", to: source)
        try fileSystem.write(text: "struct Hidden {}", to: locked + "/Hidden.m")
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        // 소유자에게도 읽기·진입이 없으면 opendir 이 실패해 디렉터리가 탐색에서 빠진다.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)

        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: source)
        )
        let first = try session.status()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        let second = try session.status()
        // 권한 회복은 디렉터리의 mode·ctime 을 바꾼다 — 실패한 디렉터리도 지문을
        // 남겨 두었으므로 이 변경이 세대를 움직이고 새 탐색이 Hidden.m 을 본다.
        #expect(second.generation == first.generation + 1)
    }

    @Test("같은 파일을 가리켜 버려진 심볼릭 링크도 지문으로 감시해 재지정을 잡는다")
    func discardedLinkRetargetInvalidatesWalk() throws {
        let parent = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let root = parent + "/root"
        let other = parent + "/other"
        let mid = parent + "/mid"
        let fileSystem = CountingLocalFileSystem()
        try fileSystem.write(text: "struct App {}", to: root + "/F.m")
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        try fileSystem.write(text: "struct Other {}", to: other + "/F.m")
        // mid 는 root 를 가리키는 링크다 — l.m 은 mid 를 경유해 F.m 과 같은 파일을
        // 가리키므로 탐색 결과에는 들어가지 않고 버려진다.
        try FileManager.default.createSymbolicLink(atPath: mid, withDestinationPath: root)
        try FileManager.default.createSymbolicLink(atPath: root + "/l.m", withDestinationPath: mid + "/F.m")
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: root + "/F.m")
        )
        let first = try session.status()

        // mid 를 other 로 옮기면 l.m 은 다른 파일을 가리킨다. l.m 의 항목 자체와
        // root 의 구성은 그대로이므로, 버려진 링크의 지문이 없으면 이 변화가
        // 어떤 디렉터리 지문에도 드러나지 않는다.
        try FileManager.default.removeItem(atPath: mid)
        try FileManager.default.createSymbolicLink(atPath: mid, withDestinationPath: other)
        let second = try session.status()
        #expect(second.generation == first.generation + 1)
    }

    @Test("일시적으로 열거에 실패한 디렉터리가 낀 탐색 결과는 캐시하지 않는다")
    func transientEnumerationFailureIsNotCached() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // 지문은 정상으로 두고 열거만 실패한다 — 스탬프가 안 바뀌는 일시 오류를
        // 캐시하면 다음 지문이 다시 시도할 기회를 잃는다. 탐색이 realpath 철자로
        // 열거하므로 실패 대상은 마지막 경로 성분으로 맞춘다.
        let locked = root + "/Locked"
        let fileSystem = BlockedEnumerationFileSystem(blockedComponents: ["Locked"])
        try fileSystem.write(text: "struct App {}", to: root + "/App.m")
        try fileSystem.write(text: "struct Hidden {}", to: locked + "/Hidden.m")
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        let session = try AnalysisSession(
            service: makeLocalService(fileSystem: fileSystem, project: root, source: root + "/App.m")
        )
        let first = try session.status()

        // 스탬프는 그대로인 채 열거만 회복된다 — 실패한 탐색이 캐시돼 있으면
        // Hidden.m 이 영구히 빠진 지문이 재생된다.
        fileSystem.unblock()
        let second = try session.status()
        #expect(second.generation == first.generation + 1)
    }

    @Test("경로 필터가 바뀌면 이전 탐색 결과를 재사용하지 않는다")
    func pathFilterChangeInvalidatesWalkedSourceList() throws {
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileSystem = CountingLocalFileSystem()
        let source = root + "/App.m"
        let gated = root + "/Gated/Gated.m"
        try fileSystem.write(text: "struct App {}", to: source)
        try fileSystem.write(text: "struct Gated {}", to: gated)
        try fileSystem.write(text: "unit", to: root + "/index-store/v5/units/App-unit")
        let state = FilterSwitchState(fileSystem: fileSystem, project: root, source: source)
        let session = try AnalysisSession(serviceFactory: { state.makeService() })
        let first = try session.status()

        state.excludeGated = false
        let second = try session.status()
        #expect(second.generation == first.generation + 1)

        // 포함으로 전환된 뒤의 지문이 Gated.m 을 추적하고 있어야 한다 — 이전
        // 필터의 탐색 결과를 그대로 돌려주면 이 변경을 지문이 보지 못한다.
        // 제자리 쓰기라 부모 디렉터리 지문은 그대로이고 파일 지문만 바뀐다.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: gated))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("struct Gated { let value: Int }".utf8))
        try handle.close()
        let third = try session.status()
        #expect(third.generation == second.generation + 1)
    }

    private func makeSession(_ state: SessionState) throws -> AnalysisSession {
        try AnalysisSession(
            serviceFactory: { try state.makeService() },
            inputFingerprintProvider: { try state.nextFingerprint() }
        )
    }

    private func makeTemporaryProject() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-session-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func makeLocalService(fileSystem: any FileSystem, project: String, source: String) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = project
        configuration.indexStorePath = project + "/index-store"
        var builder = SnapshotBuilder(path: source)
        builder.symbol("App", kind: .structType, path: source)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
    }

    private func makeSnapshot(extra: String? = nil) -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/p/App.swift")
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Service", kind: .function, path: "/p/Service.swift")
        builder.reference(from: "App", to: "Service", kind: .call)
        if let extra {
            builder.symbol(extra, kind: .function, path: "/p/Extra.swift")
            builder.reference(from: "App", to: extra, kind: .call)
        }
        return builder.build()
    }

    private func fingerprintService(fileSystem: InMemoryFileSystem) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.indexStorePath = "/p/index-store"
        configuration.baselinePath = ".cartograph-baseline.json"
        configuration.externalRetentionsPath = ".isthmus/retentions.json"
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(makeSnapshot())
            )
        )
    }

    private func fingerprintFileSystem(
        source: String?,
        sourcePath: String = "/p/App.swift",
        indexUnit: String,
        includeBaseline: Bool = false,
        baseline: String = "{\"fingerprints\":[]}",
        configuration: String = "level: symbol\n",
        externalRetentions: String = "{\"format\":\"external-retentions\",\"version\":0,\"retentions\":[]}",
        sensitiveContents: (env: String, auth: String, secrets: String)? = nil
    ) -> InMemoryFileSystem {
        var files: [String: String] = [
            "/p/.cartograph.yml": configuration,
            "/p/.isthmus/retentions.json": externalRetentions,
            "/p/index-store/v5/units/unit-1": indexUnit,
        ]
        if let source { files[sourcePath] = source }
        if includeBaseline { files["/p/.cartograph-baseline.json"] = baseline }
        if let sensitiveContents {
            files["/p/.env"] = sensitiveContents.env
            files["/p/auth.json"] = sensitiveContents.auth
            files["/p/secrets.json"] = sensitiveContents.secrets
        }
        return InMemoryFileSystem(currentDirectoryPath: "/p", files: files)
    }
}

private final class SessionState: @unchecked Sendable {
    private let lock = NSLock()
    var fingerprint: String = "first"
    var fingerprintValues: [String] = []
    var snapshot: IndexSnapshot
    var factoryShouldFail = false
    var fingerprintShouldFail = false
    private(set) var factoryCount = 0
    private(set) var indexLoadCount = 0

    init(snapshot: IndexSnapshot) {
        self.snapshot = snapshot
    }

    func nextFingerprint() throws -> String {
        try lock.withLock {
            if fingerprintShouldFail { throw SessionFingerprintError.failed }
            if !fingerprintValues.isEmpty { return fingerprintValues.removeFirst() }
            return fingerprint
        }
    }

    func makeService() throws -> CartographService {
        try lock.withLock {
            factoryCount += 1
            if factoryShouldFail { throw SessionFactoryError.failed }
            let provider = CountingSessionIndexProvider(snapshot: snapshot) { [weak self] in
                self?.incrementIndexLoad()
            }
            var configuration = CartographConfiguration.default
            configuration.projectPath = "/p"
            return CartographService(
                configuration: configuration,
                environment: CartographEnvironment(
                    fileSystem: InMemoryFileSystem(), indexProviderOverride: provider
                )
            )
        }
    }

    private func incrementIndexLoad() {
        lock.withLock { indexLoadCount += 1 }
    }
}

private enum SessionFactoryError: Error {
    case failed
}

private enum SessionFingerprintError: Error {
    case failed
}

/// 서비스 공장이 내놓는 설정의 경로 필터를 세션 도중 바꾼다.
private final class FilterSwitchState: @unchecked Sendable {
    private let lock = NSLock()
    let fileSystem: CountingLocalFileSystem
    let project: String
    let source: String
    let snapshot: IndexSnapshot
    var excludeGated = true

    init(fileSystem: CountingLocalFileSystem, project: String, source: String) {
        self.fileSystem = fileSystem
        self.project = project
        self.source = source
        var builder = SnapshotBuilder(path: source)
        builder.symbol("App", kind: .structType, path: source)
        snapshot = builder.build()
    }

    func makeService() -> CartographService {
        lock.withLock {
            var configuration = CartographConfiguration.default
            configuration.projectPath = project
            configuration.indexStorePath = project + "/index-store"
            if excludeGated {
                configuration.exclude = [GlobPattern("Gated/**")]
            }
            return CartographService(
                configuration: configuration,
                environment: CartographEnvironment(
                    fileSystem: fileSystem,
                    indexProviderOverride: StaticIndexProvider(snapshot)
                )
            )
        }
    }
}

private final class FactoryReloadState: @unchecked Sendable {
    private let lock = NSLock()
    let fileSystem: InMemoryFileSystem
    var snapshot: IndexSnapshot
    private(set) var factoryCount = 0
    private(set) var indexLoadCount = 0

    init(fileSystem: InMemoryFileSystem, snapshot: IndexSnapshot) {
        self.fileSystem = fileSystem
        self.snapshot = snapshot
    }

    func makeService() -> CartographService {
        lock.withLock {
            factoryCount += 1
            var configuration = CartographConfiguration.default
            configuration.projectPath = "/p"
            return CartographService(
                configuration: configuration,
                environment: CartographEnvironment(
                    fileSystem: fileSystem,
                    indexProviderOverride: DynamicSessionIndexProvider(owner: self)
                )
            )
        }
    }

    func currentSnapshot() -> IndexSnapshot {
        lock.withLock { snapshot }
    }

    func recordIndexLoad() {
        lock.withLock { indexLoadCount += 1 }
    }
}

private final class DynamicSessionIndexProvider: IndexProviding, @unchecked Sendable {
    private weak var owner: FactoryReloadState?

    init(owner: FactoryReloadState) {
        self.owner = owner
    }

    func loadSnapshot() throws -> IndexSnapshot {
        guard let owner else { return IndexSnapshot() }
        owner.recordIndexLoad()
        return owner.currentSnapshot()
    }
}

private final class CountingSessionIndexProvider: IndexProviding, @unchecked Sendable {
    private let snapshot: IndexSnapshot
    private let onLoad: @Sendable () -> Void

    init(snapshot: IndexSnapshot, onLoad: @escaping @Sendable () -> Void) {
        self.snapshot = snapshot
        self.onLoad = onLoad
    }

    func loadSnapshot() throws -> IndexSnapshot {
        onLoad()
        return snapshot
    }
}

private final class CountingLocalFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private(set) var contentReadBytes = 0
    private(set) var directoryEnumerations = 0

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }

    func readData(at path: String) throws -> Data {
        let data = try base.readData(at: path)
        guard path.hasSuffix(".m") || path.contains("/index-store/") else { return data }
        lock.withLock { contentReadBytes += data.count }
        return data
    }

    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        lock.withLock { directoryEnumerations += 1 }
        return try base.directoryEntries(at: path)
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? { base.fingerprintStamp(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }

    func resetContentReads() { lock.withLock { contentReadBytes = 0 } }
}

/// 지정한 마지막 경로 성분의 디렉터리 열거를 `unblock` 전까지 실패시키는 래퍼.
/// 지문은 실제 파일 상태를 그대로 돌려주므로, 실패한 탐색 결과가 스탬프 변화
/// 없이 고정되는지를 검증한다. `status()` 가 지문을 여러 번 읽어 한 번의 실패는
/// 같은 호출 안에서 회복되므로, 명시적으로 풀 때까지 실패해야 한다. 탐색은
/// realpath 철자로 열거하므로 성분으로 맞춘다.
private final class BlockedEnumerationFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var blockedComponents: Set<String>

    init(blockedComponents: Set<String>) { self.blockedComponents = blockedComponents }

    func unblock() { lock.withLock { blockedComponents.removeAll() } }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        let component = (path as NSString).lastPathComponent
        if lock.withLock({ blockedComponents.contains(component) }) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        return try base.directoryEntries(at: path)
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? { base.fingerprintStamp(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}

private final class CountingUnstampedFileSystem: FileSystem, @unchecked Sendable {
    private let backing: InMemoryFileSystem
    private let lock = NSLock()
    private(set) var contentReadBytes = 0

    init(backing: InMemoryFileSystem) { self.backing = backing }

    func realPath(at path: String) throws -> String { try backing.realPath(at: path) }
    func fileExists(at path: String) -> Bool { backing.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { backing.directoryExists(at: path) }

    func readData(at path: String) throws -> Data {
        let data = try backing.readData(at: path)
        guard path.hasSuffix(".m") || path.contains("/index-store/") else { return data }
        lock.withLock { contentReadBytes += data.count }
        return data
    }

    func write(_ data: Data, to path: String) throws { try backing.write(data, to: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try backing.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] { try backing.directoryEntries(at: path) }
    func modificationDate(at path: String) -> Date? { backing.modificationDate(at: path) }
    var currentDirectoryPath: String { backing.currentDirectoryPath }

    func resetContentReads() { lock.withLock { contentReadBytes = 0 } }
}
