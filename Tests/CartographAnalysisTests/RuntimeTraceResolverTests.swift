import CartographAnalysis
import CartographCore
import Testing

@Suite("실행 trace 연결 해석")
struct RuntimeTraceResolverTests {
    @Test("호출 중 구현이 바뀌면 이름이나 교체된 심볼로 실제 호출 대상을 추측하지 않는다")
    func changedDispatchCannotBecomeAnObservedConnection() {
        let changed = RuntimeTraceEvent(
            api: "NSObject.performSelector:withObject", phase: "invocation-returned", name: "open:", result: true,
            receiverClass: "ScreenAlias", receiverIsClass: false, callerSymbol: "$s4Test6calleryyF",
            callerImage: "/p/App", callerOffset: 0, dispatchUncertain: true
        )
        let resolved = report([changed])
        #expect(resolved.connections.isEmpty)
        #expect(resolved.findings.first?.status == .unresolved)
    }

    @Test("무효화한 실행 근거 문서는 관측 행을 보존해도 연결을 노출하지 않는다")
    func invalidReportCannotExposeConnections() {
        let observed = RuntimeTraceFinding(ordinal: 0,
            event: .init(api: "NSClassFromString", phase: "lookup", name: "ScreenAlias", result: true),
            status: .observed, source: NodeID("caller"), targets: [NodeID("screen")])
        let invalid = RuntimeTraceReport(findings: [observed], evidenceCurrent: false)
        #expect(invalid.findings == [observed])
        #expect(invalid.connections.isEmpty)
    }

    private let path = "/p/App.swift"
    private let callerUSR = "s:4Test6calleryyF"

    private func location(_ line: Int) -> CartographCore.SourceLocation {
        .init(path: path, line: line, column: 1)
    }

    private var snapshot: IndexSnapshot {
        .init(symbols: [
            .init(usr: callerUSR, name: "caller()", kind: .function, module: "Test", location: location(1)),
            .init(usr: "screen", name: "Screen", kind: .classType, module: "Test", location: location(10)),
            .init(usr: "open", name: "open(_:)", kind: .method, module: "Test", location: location(11),
                parentUSR: "screen", attributes: [.objc]),
            .init(usr: "classOpen", name: "classOpen()", kind: .method, module: "Test", location: location(12),
                parentUSR: "screen", attributes: [.objc]),
            .init(usr: "route", name: "route()", kind: .method, module: "Test", location: location(13),
                parentUSR: "screen", attributes: [.objc]),
            .init(usr: "s:4Test6ScreenC11hiddenValueyyF", name: "hiddenValue()", kind: .method,
                module: "Test", location: location(14), parentUSR: "screen", attributes: [.objc]),
            .init(usr: "protocol", name: "Routable", kind: .protocolType, module: "Test", location: location(20),
                attributes: [.objc]),
            .init(usr: "duplicate1", name: "DuplicateOne", kind: .classType,
                module: "Test", location: location(30)),
            .init(usr: "duplicate2", name: "DuplicateTwo", kind: .classType,
                module: "Test", location: location(40)),
        ], references: [])
    }

    private var declarations: [RuntimeDeclaration] {
        [
            .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                location: location(10), endLocation: location(15), objectiveCName: "ScreenAlias"),
            .init(name: "open", indexName: "open(_:)", qualifiedName: "Screen.open", kind: .method,
                location: location(11), endLocation: location(11), parentLocation: location(10),
                objectiveCName: "open:", attributes: [.objc]),
            .init(name: "classOpen", indexName: "classOpen()", qualifiedName: "Screen.classOpen", kind: .method,
                location: location(12), endLocation: location(12), parentLocation: location(10),
                objectiveCName: "classOpen", attributes: [.objc], isStatic: true),
            .init(name: "route", indexName: "route()", qualifiedName: "Screen.route", kind: .method,
                location: location(13), endLocation: location(13), parentLocation: location(10),
                objectiveCName: "route", attributes: [.objc]),
            .init(name: "hiddenValue", indexName: "hiddenValue()", qualifiedName: "Screen.hiddenValue",
                kind: .method, location: location(14), endLocation: location(14), parentLocation: location(10),
                attributes: [.objc]),
            .init(name: "Routable", indexName: "Routable", qualifiedName: "Routable", kind: .protocolType,
                location: location(20), endLocation: location(22), objectiveCName: "RoutableAlias",
                attributes: [.objc]),
            .init(name: "DuplicateOne", indexName: "DuplicateOne", qualifiedName: "DuplicateOne",
                kind: .classType, location: location(30), endLocation: location(31), objectiveCName: "Duplicate"),
            .init(name: "DuplicateTwo", indexName: "DuplicateTwo", qualifiedName: "DuplicateTwo",
                kind: .classType, location: location(40), endLocation: location(41), objectiveCName: "Duplicate"),
        ]
    }

    private func report(
        _ events: [RuntimeTraceEvent],
        freshness: RuntimeFreshness = .fresh,
        evidenceState: RuntimeTraceEvidenceState = .current
    ) -> RuntimeTraceReport {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return RuntimeTraceResolver().resolve(
            events: events,
            files: [.init(path: path, declarations: declarations)],
            snapshot: snapshot,
            graph: graph,
            freshness: [path: freshness],
            evidenceState: evidenceState
        )
    }

    private func event(
        api: String,
        phase: String,
        name: String,
        result: Bool = true,
        receiver: String? = nil,
        isClass: Bool? = nil,
        caller: String? = "$s4Test6calleryyF",
        callee: String? = nil
    ) -> RuntimeTraceEvent {
        .init(
            api: api,
            phase: phase,
            name: name,
            result: result,
            receiverClass: receiver,
            receiverIsClass: isClass,
            callerSymbol: caller,
            calleeSymbol: callee
        )
    }

    @Test("실패한 조회와 selector 토큰은 실행 간선을 만들지 않는다")
    func lookupFailuresAndTokensRemainFacts() {
        let result = report([
            event(api: "NSClassFromString", phase: "lookup", name: "ScreenAlias", result: false),
            event(api: "NSSelectorFromString", phase: "lookup", name: "open:"),
        ])

        #expect(result.findings.map(\.status) == [.lookupFailed, .lookupOnly])
        #expect(result.connections.isEmpty)
    }

    @Test("정확한 Swift mangled caller와 클래스 조회만 로컬 관계가 된다")
    func exactSwiftCallerCreatesConnection() throws {
        let lookup = event(api: "NSClassFromString", phase: "lookup", name: "ScreenAlias")
        let result = report([lookup, lookup])
        let connection = try #require(result.connections.first)

        #expect(result.findings.allSatisfy { $0.status == .observed })
        #expect(connection.source == NodeID(callerUSR))
        #expect(connection.target == NodeID("screen"))
        #expect(connection.kind == .classLookup)
        #expect(connection.count == 2)
        #expect(connection.evidenceOrdinals == [0, 1])
    }

    @Test("leading underscore가 있는 Swift mangled symbol도 정확한 USR로만 바꾼다")
    func exactUnderscoredSwiftCaller() {
        let lookup = event(
            api: "NSProtocolFromString",
            phase: "lookup",
            name: "RoutableAlias",
            caller: "_$s4Test6calleryyF"
        )
        let result = report([lookup])

        #expect(result.findings.first?.status == .observed)
        #expect(result.connections.first?.target == NodeID("protocol"))
    }

    @Test("instance와 class selector 호출은 정적 여부가 같은 메서드만 고른다")
    func separatesInstanceAndClassInvocation() {
        let result = report([
            event(api: "NSObject.performSelector:withObject", phase: "invocation-returned",
                name: "open:", receiver: "ScreenAlias", isClass: false),
            event(api: "NSObject.performSelector", phase: "invocation-returned",
                name: "classOpen", receiver: "ScreenAlias", isClass: true),
        ])

        #expect(Set(result.connections.map(\.target)) == [NodeID("open"), NodeID("classOpen")])
        #expect(result.findings.allSatisfy { $0.status == .observed })
    }

    @Test("등록 반환은 관찰 관계지만 callback 실행으로 표현하지 않는다")
    func registrationDoesNotClaimInvocation() {
        let registration = event(
            api: "NotificationCenter.addObserver",
            phase: "registration",
            name: "open:",
            receiver: "ScreenAlias",
            isClass: false
        )
        let result = report([registration])

        #expect(result.findings.first?.status == .observedRegistration)
        #expect(result.findings.first?.reason?.contains("does not prove") == true)
        #expect(result.connections.first?.kind == .selectorRegistration)
    }

    @Test("실제 IMP의 Swift thunk symbol은 정확한 기존 USR일 때 selector 이름보다 우선한다")
    func exactCalleeSymbolBindsUninferredObjectiveCName() {
        let withoutSymbol = event(
            api: "NSObject.performSelector",
            phase: "invocation-returned",
            name: "hiddenValue:",
            receiver: "ScreenAlias",
            isClass: false
        )
        let withSymbol = event(
            api: "NSObject.performSelector",
            phase: "invocation-returned",
            name: "hiddenValue:",
            receiver: "ScreenAlias",
            isClass: false,
            callee: "$s4Test6ScreenC11hiddenValueyyFTo"
        )
        let result = report([withoutSymbol, withSymbol])

        #expect(result.findings.map(\.status) == [.unresolved, .observed])
        #expect(result.connections.first?.target == NodeID("s:4Test6ScreenC11hiddenValueyyF"))
    }

    @Test("실제 IMP가 외부 구현이면 같은 selector의 로컬 메서드로 되돌아가지 않는다")
    func externalCalleeDoesNotFallBackToLocalName() {
        let invocation = event(
            api: "NSObject.performSelector:withObject",
            phase: "invocation-returned",
            name: "open:",
            receiver: "ScreenAlias",
            isClass: false,
            callee: "-[ExternalScreen open:]"
        )
        let result = report([invocation])

        #expect(result.findings.first?.status == .unresolved)
        #expect(result.connections.isEmpty)
    }

    @Test("모호한 수신자와 정확하지 않은 caller는 이름만으로 연결하지 않는다")
    func ambiguityAndUnknownCallerStayVisible() {
        let ambiguous = event(api: "NSObject.performSelector", phase: "invocation-returned",
            name: "description", receiver: "Duplicate", isClass: false)
        let unknownCaller = event(api: "NSClassFromString", phase: "lookup",
            name: "ScreenAlias", caller: "main")
        let result = report([ambiguous, unknownCaller])

        #expect(result.findings[0].status == .ambiguous)
        #expect(result.findings[0].candidates == [NodeID("duplicate1"), NodeID("duplicate2")])
        #expect(result.findings[1].status == .unindexed)
        #expect(result.findings[1].targets == [NodeID("screen")])
        #expect(result.connections.isEmpty)
    }

    @Test("Objective-C caller는 class와 selector가 모두 유일할 때만 source가 된다")
    func exactObjectiveCCaller() {
        let invocation = event(
            api: "NSObject.performSelector:withObject",
            phase: "invocation-returned",
            name: "open:",
            receiver: "ScreenAlias",
            isClass: false,
            caller: "-[ScreenAlias route]"
        )
        let result = report([invocation])

        #expect(result.connections.first?.source == NodeID("route"))
        #expect(result.connections.first?.target == NodeID("open"))
    }

    @Test("낡거나 불완전한 trace는 사건을 남겨도 관계를 만들지 않는다")
    func staleEvidenceNeverCreatesConnections() {
        let lookup = event(api: "NSClassFromString", phase: "lookup", name: "ScreenAlias")
        let stale = report([lookup], freshness: .sourceNewerThanIndex)
        let invalid = report([lookup], evidenceState: .invalid(reason: "trace input changed"))

        #expect(stale.findings.first?.status == .stale)
        #expect(stale.connections.isEmpty)
        #expect(invalid.findings.first?.status == .stale)
        #expect(invalid.connections.isEmpty)
        #expect(invalid.limitations == ["trace input changed"])
    }

    @Test("반복 실행 사건 2만 건은 하나의 관계와 전체 근거 순서로 접는다")
    func repeatedEventsStayLinear() throws {
        let lookup = event(api: "NSClassFromString", phase: "lookup", name: "ScreenAlias")
        let result = report(Array(repeating: lookup, count: 20_000))
        let connection = try #require(result.connections.first)

        #expect(result.findings.count == 20_000)
        #expect(connection.count == 20_000)
        #expect(connection.evidenceOrdinals.first == 0)
        #expect(connection.evidenceOrdinals.last == 19_999)
    }
}
