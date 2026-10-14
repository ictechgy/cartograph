import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("질의 단계 관측")
struct QueryPhaseTests {
    @Test("기존 환경은 관측 없이 시작하고 비활성 측정은 시계를 읽지 않는다")
    func disabledMeasurementCallsOnlyBody() {
        #expect(CartographEnvironment().queryPhaseObserver == nil)
        var clockReads = 0
        var bodyCalls = 0
        let value = measureQueryPhase(.answer, observer: nil, now: {
            clockReads += 1
            return ContinuousClock().now
        }) {
            bodyCalls += 1
            return 42
        }
        #expect(value == 42)
        #expect(bodyCalls == 1)
        #expect(clockReads == 0)
    }

    @Test("관측이 꺼진 오류 경로도 시계 없이 본문을 한 번 실행하고 같은 오류를 던진다")
    func disabledMeasurementPreservesError() {
        let failure = PhaseTestError()
        var clockReads = 0
        var bodyCalls = 0
        do {
            try measureQueryPhase(.answer, observer: nil, now: {
                clockReads += 1
                return ContinuousClock().now
            }) {
                bodyCalls += 1
                throw failure
            }
            Issue.record("원래 오류가 나와야 한다")
        } catch {
            #expect((error as? PhaseTestError) === failure)
        }
        #expect(clockReads == 0)
        #expect(bodyCalls == 1)
    }

    @Test("관측은 본문 반환 뒤 단조 시계의 차이를 한 번만 보고한다")
    func enabledMeasurementReportsDurationOnce() {
        let events = PhaseEvents()
        var instant = ContinuousClock().now
        var clockReads = 0
        var bodyCalls = 0
        let value = measureQueryPhase(.answer, observer: events.observer, now: {
            clockReads += 1
            return instant
        }) {
            bodyCalls += 1
            #expect(events.entries.isEmpty)
            instant = instant.advanced(by: .milliseconds(25))
            return "unchanged"
        }
        #expect(value == "unchanged")
        #expect(bodyCalls == 1)
        #expect(clockReads == 2)
        #expect(events.phases == [.answer])
        #expect(events.entries.map(\.duration) == [.milliseconds(25)])
    }

    @Test("관측은 오류에도 시간을 한 번 보고하고 원래 오류의 정체성을 보존한다")
    func enabledMeasurementPreservesError() {
        let failure = PhaseTestError()
        let events = PhaseEvents()
        var instant = ContinuousClock().now
        var clockReads = 0
        var bodyCalls = 0
        do {
            try measureQueryPhase(.rawSnapshot, observer: events.observer, now: {
                clockReads += 1
                return instant
            }) {
                bodyCalls += 1
                instant = instant.advanced(by: .nanoseconds(7))
                throw failure
            }
            Issue.record("원래 오류가 나와야 한다")
        } catch {
            #expect((error as? PhaseTestError) === failure)
        }
        #expect(bodyCalls == 1)
        #expect(clockReads == 2)
        #expect(events.phases == [.rawSnapshot])
        #expect(events.entries.map(\.duration) == [.nanoseconds(7)])
    }

    @Test("found·ambiguous·notFound의 모든 명령 결과는 관측 유무와 무관하다", arguments: [
        "Root", "Duplicate", "Missing",
    ])
    func singleOutcomeIsUnchanged(subject: String) throws {
        let expected = try makeService().query(symbol: subject)
        let events = PhaseEvents()
        let outcome = try makeService(observer: events.observer).query(symbol: subject)
        #expect(outcome == expected)
        let document = try JSONDecoder().decode(SymbolQueryDocument.self, from: Data(outcome.output.utf8))
        #expect(document.status == ["Root": "found", "Duplicate": "ambiguous", "Missing": "notFound"][subject])
        let found: [QueryPhase] = subject == "Root" ? [.foundFacts] : []
        #expect(events.phases == [.inputPreparation, .rawSnapshot, .syntaxContext, .graphQuerySetup]
            + found + [.answer, .serialization])
        #expect(events.entries.allSatisfy { $0.duration >= .zero })
    }

    @Test("혼합 중복 배치는 순서·오류 표시·바이트를 보존하며 준비와 found facts를 한 번만 만든다")
    func mixedBatchIsUnchanged() throws {
        let subjects = ["Root", "Duplicate", "Missing", "Root", "Missing"]
        let expected = try makeService().queryBatch(symbols: subjects)
        let events = PhaseEvents()
        let outcome = try makeService(observer: events.observer).queryBatch(symbols: subjects)
        #expect(outcome == expected)
        #expect(outcome.subjectNotFound)
        #expect(outcome.missingSubjects == ["Missing", "Missing"])
        let document = try JSONDecoder().decode(SymbolQueryBatchDocument.self, from: Data(outcome.output.utf8))
        #expect(document.results.map(\.requested) == subjects)
        #expect(document.results.map(\.status) == ["found", "ambiguous", "notFound", "found", "notFound"])
        #expect(document.results[0] == document.results[3])
        #expect(events.phases == [.inputPreparation, .rawSnapshot, .syntaxContext, .graphQuerySetup, .foundFacts]
            + Array(repeating: .answer, count: subjects.count) + [.serialization])
    }

    @Test("found가 없는 배치도 명령 결과를 보존하며 found facts 단계를 건너뛴다")
    func unresolvedBatchIsUnchanged() throws {
        let subjects = ["Missing", "Duplicate", "Missing"]
        let expected = try makeService().queryBatch(symbols: subjects)
        let events = PhaseEvents()
        let outcome = try makeService(observer: events.observer).queryBatch(symbols: subjects)
        #expect(outcome == expected)
        #expect(outcome.missingSubjects == ["Missing", "Missing"])
        #expect(events.phases == [.inputPreparation, .rawSnapshot, .syntaxContext, .graphQuerySetup]
            + Array(repeating: .answer, count: subjects.count) + [.serialization])
    }

    @Test("없는 이름과 모호한 이름의 배치에는 found facts 관측도 생성도 없다")
    func missingAndAmbiguousStayLazy() throws {
        let events = PhaseEvents()
        let service = makeService(observer: events.observer)
        let context = try service.loadContext()
        var session = try service.makeQuerySession(in: context, subjects: ["Missing", "Duplicate"])
        #expect(session.foundFacts == nil)
        #expect(session.foundFactsBuildCount == 0)
        #expect(!events.phases.contains(.foundFacts))
        for subject in ["Missing", "Duplicate"] {
            _ = try service.queryDocument(symbol: subject, depth: 1, limit: 50, in: session)
        }
        #expect(session.foundFactsBuildCount == 0)
        #expect(!events.phases.contains(.foundFacts))

        service.ensureFoundQueryFacts(in: context, subjects: ["Root"], session: &session)
        service.ensureFoundQueryFacts(in: context, subjects: ["Root"], session: &session)
        #expect(session.foundFactsBuildCount == 1)
        #expect(events.phases.filter { $0 == .foundFacts }.count == 1)
    }

    @Test("원시 인덱스 오류는 바꾸지 않고 실행한 단계까지만 관측한다")
    func rawFailureStopsLaterPhases() {
        let failure = PhaseTestError()
        let events = PhaseEvents()
        let provider = FailingPhaseIndexProvider(error: failure)
        do {
            _ = try makeService(observer: events.observer, provider: provider).query(symbol: "Root")
            Issue.record("원래 인덱스 오류가 나와야 한다")
        } catch {
            #expect((error as? PhaseTestError) === failure)
        }
        #expect(events.phases == [.inputPreparation, .rawSnapshot])
    }

    @Test("빈 인덱스 가드는 구문 문맥 단계에서 원래처럼 실패한다")
    func emptyIndexGuardIsPreserved() {
        let events = PhaseEvents()
        do {
            _ = try makeService(observer: events.observer, provider: StaticIndexProvider(IndexSnapshot()))
                .query(symbol: "Missing")
            Issue.record("빈 인덱스 가드가 실패해야 한다")
        } catch let error as CartographError {
            guard case .indexStoreEmpty = error else {
                Issue.record("빈 인덱스 오류여야 한다: \(error)")
                return
            }
        } catch {
            Issue.record("빈 인덱스 오류여야 한다: \(error)")
        }
        #expect(events.phases == [.inputPreparation, .rawSnapshot, .syntaxContext])
    }

    private func makeService(
        observer: QueryPhaseObserver? = nil, provider: (any IndexProviding)? = nil
    ) -> CartographService {
        var builder = SnapshotBuilder(module: "App", path: "/p/App.swift")
        builder.symbol("Root", attributes: [.entryPoint])
        builder.symbol("left", name: "Duplicate", path: "/p/Left.swift")
        builder.symbol("right", name: "Duplicate", path: "/p/Right.swift")
        builder.reference(from: "Root", to: "left", kind: .call)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        var environment = CartographEnvironment(
            fileSystem: InMemoryFileSystem(),
            indexProviderOverride: provider ?? StaticIndexProvider(builder.build()),
            usesSyntaxCache: false
        )
        environment.queryPhaseObserver = observer
        return CartographService(configuration: configuration, environment: environment)
    }
}

private final class PhaseTestError: Error {}

private struct FailingPhaseIndexProvider: IndexProviding {
    let error: PhaseTestError
    func loadSnapshot() throws -> IndexSnapshot { throw error }
}

private final class PhaseEvents: @unchecked Sendable {
    struct Entry: Sendable {
        let phase: QueryPhase
        let duration: Duration
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var observer: QueryPhaseObserver {
        { [self] phase, duration in
            lock.withLock { recorded.append(Entry(phase: phase, duration: duration)) }
        }
    }

    var entries: [Entry] { lock.withLock { recorded } }
    var phases: [QueryPhase] { entries.map(\.phase) }
}
