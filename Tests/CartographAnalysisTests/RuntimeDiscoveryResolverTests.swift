import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("자동 런타임 연결 해석")
struct RuntimeDiscoveryResolverTests {
    private let path = "/p/App.swift"
    private func location(_ line: Int, _ column: Int = 1) -> CartographCore.SourceLocation {
        .init(path: path, line: line, column: column)
    }

    private func fixture(api: String = "c:@F@NSClassFromString") -> IndexSnapshot {
        .init(symbols: [
            .init(usr: "caller", name: "route()", kind: .function, module: "App", location: location(1)),
            .init(usr: "screen", name: "Screen", kind: .classType, module: "App", location: location(10)),
            .init(usr: "open", name: "open()", kind: .method, module: "App", location: location(11),
                parentUSR: "screen", attributes: [.objc]),
        ], references: [.init(sourceUSR: "caller", targetUSR: api, kind: .call, location: location(2, 5))])
    }

    private var declarations: [RuntimeDeclaration] {
        [
            .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                location: location(10), endLocation: location(13), objectiveCName: "ScreenAlias"),
            .init(name: "open", indexName: "open()", qualifiedName: "Screen.open", kind: .method,
                location: location(11), endLocation: location(12), parentLocation: location(10),
                objectiveCName: "open", attributes: [.objc]),
        ]
    }

    private func resolve(_ boundary: RuntimeBoundary, snapshot: IndexSnapshot? = nil,
                         fresh: RuntimeFreshness = .fresh) -> RuntimeDiscoveryReport {
        let snapshot = snapshot ?? fixture()
        return RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: declarations, boundaries: [boundary])],
            snapshot: snapshot, graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [path: fresh]
        )
    }

    @Test("컴파일러가 확인한 클래스 조회와 정확한 ObjC 별칭만 연결한다")
    func classLookup() throws {
        let report = resolve(.init(kind: .classLookup, api: "NSClassFromString", location: location(2),
            calleeLocation: location(2, 5), name: "ScreenAlias", nameOrigin: .literal))
        let finding = try #require(report.findings.first)
        #expect(finding.status == .resolved)
        #expect(finding.source == NodeID("caller"))
        #expect(finding.targets == [NodeID("screen")])
        #expect(report.connections.count == 1)
    }

    @Test("사용자 동명 함수는 런타임 API로 오인하지 않는다")
    func shadowedAPI() throws {
        var snapshot = fixture(api: "local")
        snapshot.symbols.append(.init(usr: "local", name: "NSClassFromString(_:)", kind: .function,
            module: "App", location: location(20)))
        let report = resolve(.init(kind: .classLookup, api: "NSClassFromString", location: location(2),
            calleeLocation: location(2, 5), name: "ScreenAlias", nameOrigin: .literal), snapshot: snapshot)
        #expect(report.findings.first?.status == .shadowed)
        #expect(report.connections.isEmpty)
    }

    @Test("동적 이름과 낡은 파일은 경계를 버리지 않고 미해결로 남긴다")
    func dynamicAndStale() {
        let boundary = RuntimeBoundary(kind: .classLookup, api: "NSClassFromString", location: location(2),
            calleeLocation: location(2, 5))
        #expect(resolve(boundary).findings.first?.status == .dynamic)
        #expect(resolve(boundary, fresh: .sourceNewerThanIndex).findings.first?.status == .stale)
        #expect(resolve(boundary, fresh: .unknownIndexDate).findings.first?.status == .unindexed)
        #expect(resolve(boundary).connections.isEmpty)
    }

    @Test("selector 생성만으로 메서드 호출 간선을 만들지 않는다")
    func selectorLookupIsNotInvocation() {
        let boundary = RuntimeBoundary(kind: .selectorLookup, api: "NSSelectorFromString", location: location(2),
            calleeLocation: location(2, 5), name: "open", nameOrigin: .literal)
        let report = resolve(boundary, snapshot: fixture(api: "c:@F@NSSelectorFromString"))
        #expect(report.findings.first?.status == .lookupOnly)
        #expect(report.connections.isEmpty)
    }

    @Test("수신자 타입과 전체 selector가 맞는 메서드를 연결한다")
    func selectorInvocation() {
        let boundary = RuntimeBoundary(kind: .selectorInvocation, api: "perform", location: location(2),
            calleeLocation: location(2, 5), name: "open", nameOrigin: .constant,
            receiverTypeName: "Screen", receiverOrigin: .construction)
        let snapshot = fixture(api: "c:objc(cs)NSObject(im)performSelector:")
        #expect(resolve(boundary, snapshot: snapshot).findings.first?.targets == [NodeID("open")])
        let arityMismatch = RuntimeBoundary(kind: .selectorInvocation, api: "perform", location: location(2),
            calleeLocation: location(2, 5), name: "open:", nameOrigin: .literal,
            receiverTypeName: "Screen", receiverOrigin: .construction)
        #expect(resolve(arityMismatch, snapshot: snapshot).connections.isEmpty)
    }

    @Test("수신자 없는 selector는 유일한 동명이 있어도 호출을 단정하지 않는다")
    func unknownReceiver() {
        let report = resolve(.init(kind: .selectorInvocation, api: "perform", location: location(2),
            calleeLocation: location(2, 5), name: "open", nameOrigin: .literal),
            snapshot: fixture(api: "c:objc(cs)NSObject(im)performSelector:"))
        #expect(report.findings.first?.status == .unresolved)
        #expect(report.findings.first?.candidates == [NodeID("open")])
        #expect(report.connections.isEmpty)
    }

    @Test("근처 선언을 고르는 대신 정확한 위치가 다르면 결합하지 않는다")
    func neverChoosesNearestDeclaration() {
        var snapshot = fixture()
        snapshot.symbols[1] = .init(usr: "screen", name: "Screen", kind: .classType,
            module: "App", location: location(10, 2))
        let report = resolve(.init(kind: .classLookup, api: "NSClassFromString", location: location(2),
            calleeLocation: location(2, 5), name: "ScreenAlias", nameOrigin: .literal), snapshot: snapshot)
        #expect(report.connections.isEmpty)
        #expect(report.findings.first?.status == .unresolved)
    }

    @Test("receivedBy 수신자 타입이 있어도 정확한 호출 함수만 소스로 고른다")
    func receivedByDoesNotReplaceCaller() {
        var snapshot = fixture(api: "c:objc(pl)NSObject(im)performSelector:")
        snapshot.references.append(.init(sourceUSR: "screen", targetUSR: "c:objc(pl)NSObject(im)performSelector:",
            kind: .call, location: location(2, 5)))
        let report = resolve(.init(kind: .selectorInvocation, api: "perform", location: location(2),
            calleeLocation: location(2, 5), enclosingDeclarationLocation: location(1), name: "open",
            nameOrigin: .literal, receiverTypeName: "Screen", receiverOrigin: .construction), snapshot: snapshot)
        #expect(report.findings.first?.source == NodeID("caller"))
        #expect(report.findings.first?.status == .resolved)
    }

    @Test("이름 생성자가 사용자 함수면 outer 시스템 호출도 추측한 이름으로 연결하지 않는다")
    func shadowedNameBuilder() {
        var snapshot = fixture(api: "c:objc(cs)NSObject(im)performSelector:")
        snapshot.symbols.append(.init(usr: "custom", name: "NSSelectorFromString(_:)", kind: .function,
            module: "App", location: location(20)))
        snapshot.references.append(.init(sourceUSR: "caller", targetUSR: "custom", kind: .call,
            location: location(2, 15)))
        let report = resolve(.init(kind: .selectorInvocation, api: "perform", location: location(2),
            calleeLocation: location(2, 5), name: "open", nameOrigin: .constant,
            receiverTypeName: "Screen", receiverOrigin: .construction,
            nameAPIReferences: [.init(api: "NSSelectorFromString", location: location(2, 15))]), snapshot: snapshot)
        #expect(report.findings.first?.status == .shadowed)
        #expect(report.connections.isEmpty)
    }

    @Test("순수 Swift 프로토콜 이름은 ObjC 프로토콜 조회와 연결하지 않는다")
    func pureSwiftProtocolIsNotObjectiveC() {
        let declaration = RuntimeDeclaration(name: "P", indexName: "P", qualifiedName: "P", kind: .protocolType,
            location: location(10), endLocation: location(12))
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "caller", name: "route()", kind: .function, module: "App", location: location(1)),
            .init(usr: "P", name: "P", kind: .protocolType, module: "App", location: location(10)),
        ], references: [.init(sourceUSR: "caller", targetUSR: "c:@F@NSProtocolFromString", kind: .call,
            location: location(2, 5))])
        let report = RuntimeDiscoveryResolver().resolve(files: [.init(path: path, declarations: [declaration],
            boundaries: [.init(kind: .protocolLookup, api: "NSProtocolFromString", location: location(2),
                calleeLocation: location(2, 5), name: "App.P", nameOrigin: .literal)])], snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh])
        #expect(report.connections.isEmpty)
        #expect(report.findings.first?.status == .unresolved)
    }

    @Test("같은 default center와 nil object 필터만 알림 게시자에 연결한다")
    func notificationIdentity() {
        var snapshot = fixture()
        snapshot.symbols.append(.init(usr: "poster", name: "publish()", kind: .function,
            module: "App", location: location(30)))
        snapshot.references = [
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSNotificationCenter(im)addObserver:selector:name:object:",
                kind: .call, location: location(2, 5)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                kind: .call, location: location(31, 5)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                kind: .reference, location: location(2, 1)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                kind: .reference, location: location(31, 1)),
        ]
        func run(
            center: CartographCore.SourceLocation?,
            objectIsNil: Bool,
            observerLocation: CartographCore.SourceLocation? = nil
        ) -> RuntimeDiscoveryReport {
            let observer = RuntimeBoundary(kind: .notificationObserver, api: "addObserver",
                location: observerLocation ?? location(2),
                calleeLocation: location(2, 5), name: "open", nameOrigin: .literal,
                receiverTypeName: "Screen", receiverOrigin: .explicitTarget, notificationName: "ready",
                notificationCenterLocation: center, notificationObjectIsNil: objectIsNil)
            let post = RuntimeBoundary(kind: .notificationPost, api: "post", location: location(31),
                calleeLocation: location(31, 5), name: "ready", nameOrigin: .literal,
                notificationName: "ready", notificationCenterLocation: location(31, 1), notificationObjectIsNil: true)
            return RuntimeDiscoveryResolver().resolve(files: [.init(path: path, declarations: declarations,
                boundaries: [observer, post])], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh])
        }
        #expect(run(center: location(2, 1), objectIsNil: true).connections.contains {
            $0.source == NodeID("poster") && $0.target == NodeID("open")
        })
        #expect(!run(center: nil, objectIsNil: true).connections.contains { $0.source == NodeID("poster") })
        #expect(!run(center: location(2, 1), objectIsNil: false).connections.contains { $0.source == NodeID("poster") })
        #expect(run(center: location(2, 1), objectIsNil: true, observerLocation: location(40)).connections.contains {
            $0.source == NodeID("poster") && $0.target == NodeID("open")
        })
    }

    @Test("SDK header로 등록한 알림 상수만 raw 문자열 없이 같은 신원으로 연결한다")
    func notificationSDKConstantIdentity() {
        func run(nameUSR: String, postNameUSR: String? = nil) -> RuntimeDiscoveryReport {
            let observer = IndexedSymbol(
                usr: "observer", name: "install()", kind: .function, module: "App", location: location(60)
            )
            let poster = IndexedSymbol(
                usr: "poster", name: "post()", kind: .function, module: "App", location: location(70)
            )
            let snapshot = IndexSnapshot(symbols: [observer, poster], references: [
                .init(sourceUSR: "observer",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)addObserverForName:object:queue:usingBlock:",
                    kind: .call, location: location(61, 5)),
                .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                    kind: .call, location: location(71, 5)),
                .init(sourceUSR: "observer", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(61, 1)),
                .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(71, 1)),
                .init(sourceUSR: "observer", targetUSR: nameUSR, kind: .reference, location: location(62, 9)),
                .init(sourceUSR: "poster", targetUSR: postNameUSR ?? nameUSR,
                    kind: .reference, location: location(72, 9)),
            ])
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationObserver, api: "addObserver", location: location(62),
                    calleeLocation: location(61, 5), enclosingDeclarationLocation: location(60),
                    notificationNameLocation: location(62, 9), notificationCenterLocation: location(61, 1),
                    notificationObjectIsNil: true
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(72),
                    calleeLocation: location(71, 5), enclosingDeclarationLocation: location(70),
                    notificationNameLocation: location(72, 9), notificationCenterLocation: location(71, 1),
                    notificationObjectIsNil: true
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        let supported = [
            "c:@NSApplicationDidBecomeActiveNotification",
            "c:@NSApplicationDidChangeScreenParametersNotification",
            "c:@NSWindowDidChangeScreenProfileNotification",
            "c:@NSWorkspaceDidLaunchApplicationNotification",
            "c:@AVCaptureSessionDidStartRunningNotification",
            "c:@AVCaptureSessionDidStopRunningNotification",
            "c:@UIApplicationDidReceiveMemoryWarningNotification",
        ]
        for nameUSR in supported {
            #expect(run(nameUSR: nameUSR).connections.contains {
                $0.kind == .notificationPost
                    && $0.source == NodeID("poster")
                    && $0.target == NodeID("observer")
            })
        }
        let legacyCaptureNames = [
            (
                "s:So18NSNotificationNamea12AVFoundationE31AVCaptureSessionDidStartRunningABvgZ",
                "c:@AVCaptureSessionDidStartRunningNotification"
            ),
            (
                "s:So18NSNotificationNamea12AVFoundationE31AVCaptureSessionDidStartRunningABvpZ",
                "c:@AVCaptureSessionDidStartRunningNotification"
            ),
            (
                "s:So18NSNotificationNamea12AVFoundationE30AVCaptureSessionDidStopRunningABvgZ",
                "c:@AVCaptureSessionDidStopRunningNotification"
            ),
            (
                "s:So18NSNotificationNamea12AVFoundationE30AVCaptureSessionDidStopRunningABvpZ",
                "c:@AVCaptureSessionDidStopRunningNotification"
            ),
        ]
        for (legacy, modern) in legacyCaptureNames {
            #expect(run(nameUSR: legacy, postNameUSR: modern).connections.contains {
                $0.kind == .notificationPost
                    && $0.source == NodeID("poster")
                    && $0.target == NodeID("observer")
            })
        }
        let unknown = run(nameUSR: "c:@ThirdPartyNotification")
        #expect(unknown.connections.isEmpty)
        #expect(unknown.findings.allSatisfy { $0.status == .dynamic })
    }

    @Test("NSWorkspace singleton center는 shared와 notificationCenter 두 compiler proof를 모두 요구한다")
    func workspaceNotificationCenterIdentity() {
        let observer = IndexedSymbol(
            usr: "observer", name: "install()", kind: .function, module: "App", location: location(80)
        )
        let poster = IndexedSymbol(
            usr: "poster", name: "post()", kind: .function, module: "App", location: location(90)
        )
        let references: [IndexedReference] = [
            .init(sourceUSR: "observer",
                targetUSR: "c:objc(cs)NSNotificationCenter(im)addObserverForName:object:queue:usingBlock:",
                kind: .call, location: location(81, 5)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                kind: .call, location: location(91, 5)),
            .init(sourceUSR: "observer", targetUSR: "c:objc(cs)NSWorkspace(py)notificationCenter",
                kind: .reference, location: location(81, 15)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSWorkspace(py)notificationCenter",
                kind: .reference, location: location(91, 15)),
            .init(sourceUSR: "observer", targetUSR: "c:objc(cs)NSWorkspace(cpy)sharedWorkspace",
                kind: .reference, location: location(81, 10)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSWorkspace(cpy)sharedWorkspace",
                kind: .reference, location: location(91, 10)),
        ]
        let snapshot = IndexSnapshot(symbols: [observer, poster], references: references)
        func run(ownerLocation: CartographCore.SourceLocation?) -> RuntimeDiscoveryReport {
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationObserver, api: "addObserver", location: location(82),
                    calleeLocation: location(81, 5), notificationName: "ready",
                    notificationCenterLocation: location(81, 15),
                    notificationCenterOwnerLocation: ownerLocation, notificationObjectIsNil: true
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(92),
                    calleeLocation: location(91, 5), notificationName: "ready",
                    notificationCenterLocation: location(91, 15),
                    notificationCenterOwnerLocation: location(91, 10), notificationObjectIsNil: true
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        #expect(run(ownerLocation: location(81, 10)).connections.contains {
            $0.source == NodeID("poster") && $0.target == NodeID("observer")
        })
        #expect(!run(ownerLocation: nil).connections.contains { $0.source == NodeID("poster") })
    }

    @Test("같은 선언의 검증된 지역 class 생성만 center와 object 필터 신원이 된다")
    func localNotificationCenterAndObjectIdentity() {
        let caller = IndexedSymbol(
            usr: "caller", name: "exercise()", kind: .function, module: "App", location: location(100)
        )
        func run(
            objectLocation: CartographCore.SourceLocation,
            objectKind: SymbolKind = .classType,
            postBeforeObserver: Bool = false
        ) -> RuntimeDiscoveryReport {
            let observerLine = postBeforeObserver ? 102 : 101
            let postLine = postBeforeObserver ? 101 : 102
            let objectType = IndexedSymbol(
                usr: "object-type", name: "Filter", kind: objectKind, module: "App", location: location(110)
            )
            let snapshot = IndexSnapshot(symbols: [caller, objectType], references: [
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)addObserverForName:object:queue:usingBlock:",
                    kind: .call, location: location(observerLine, 5)),
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                    kind: .call, location: location(postLine, 5)),
                .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSNotificationCenter", kind: .reference,
                    location: location(103, 5)),
                .init(sourceUSR: "caller", targetUSR: "object-type", kind: .reference,
                    location: location(104, 5)),
            ])
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationObserver, api: "addObserver", location: location(observerLine),
                    calleeLocation: location(observerLine, 5), enclosingDeclarationLocation: location(100),
                    notificationName: "ready", notificationCenterLocation: location(103, 5),
                    notificationObjectIsNil: false, notificationObjectLocation: location(104, 5)
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(postLine),
                    calleeLocation: location(postLine, 5), enclosingDeclarationLocation: location(100),
                    notificationName: "ready", notificationCenterLocation: location(103, 5),
                    notificationObjectIsNil: false, notificationObjectLocation: objectLocation
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        #expect(run(objectLocation: location(104, 5)).connections.contains {
            $0.kind == .notificationPost && $0.source == NodeID("caller") && $0.target == NodeID("caller")
        })
        #expect(!run(objectLocation: location(105, 5)).connections.contains { $0.kind == .notificationPost })
        #expect(!run(objectLocation: location(104, 5), objectKind: .structType).connections.contains {
            $0.kind == .notificationPost
        })
        #expect(!run(objectLocation: location(104, 5), postBeforeObserver: true).connections.contains {
            $0.kind == .notificationPost
        })
    }

    @Test("검증된 token 제거만 지역 observer의 이후 게시 연결을 끊는다")
    func notificationRemovalRequiresSystemAPIAndOrder() {
        func run(removalUSR: String, removalLine: Int = 94, postLine: Int = 95) -> RuntimeDiscoveryReport {
            let symbols = [
                IndexedSymbol(usr: "caller", name: "exercise()", kind: .function,
                    module: "App", location: location(90)),
                IndexedSymbol(usr: "filter", name: "Filter", kind: .classType,
                    module: "App", location: location(100)),
                IndexedSymbol(usr: "custom-removal", name: "removeObserver(_:)", kind: .method,
                    module: "App", location: location(110)),
            ]
            let snapshot = IndexSnapshot(symbols: symbols, references: [
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)addObserverForName:object:queue:usingBlock:",
                    kind: .call, location: location(93, 5)),
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                    kind: .call, location: location(postLine, 5)),
                .init(sourceUSR: "caller", targetUSR: removalUSR,
                    kind: .call, location: location(removalLine, 5)),
                .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSNotificationCenter",
                    kind: .reference, location: location(91, 5)),
                .init(sourceUSR: "caller", targetUSR: "filter",
                    kind: .reference, location: location(92, 5)),
            ])
            let removal = RuntimeNotificationRemovalReference(
                registrationLocation: location(93),
                removalLocation: location(removalLine, 5),
                notificationCenterLocation: location(91, 5)
            )
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationObserver, api: "addObserver", location: location(93),
                    calleeLocation: location(93, 5), enclosingDeclarationLocation: location(90),
                    notificationName: "ready", notificationCenterLocation: location(91, 5),
                    notificationObjectIsNil: false, notificationObjectLocation: location(92, 5)
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(postLine),
                    calleeLocation: location(postLine, 5), enclosingDeclarationLocation: location(90),
                    notificationName: "ready", notificationCenterLocation: location(91, 5),
                    notificationObjectIsNil: false, notificationObjectLocation: location(92, 5),
                    notificationRemovalReferences: [removal]
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        let system = "c:objc(cs)NSNotificationCenter(im)removeObserver:"
        #expect(!run(removalUSR: system).connections.contains { $0.kind == .notificationPost })
        #expect(run(removalUSR: "custom-removal").connections.contains { $0.kind == .notificationPost })
        #expect(run(removalUSR: system, removalLine: 96).connections.contains { $0.kind == .notificationPost })
    }

    @Test("검증된 AnyCancellable 취소만 notification publisher의 이후 post 연결을 끊는다")
    func notificationCancellationRequiresSystemAPIAndOrder() {
        func run(
            cancellationUSR: String,
            cancellationLine: Int = 94,
            registrationLocation: CartographCore.SourceLocation? = nil
        ) -> RuntimeDiscoveryReport {
            let symbols = [
                IndexedSymbol(usr: "caller", name: "exercise()", kind: .function,
                    module: "App", location: location(90)),
                IndexedSymbol(usr: "custom-cancel", name: "cancel()", kind: .method,
                    module: "App", location: location(110)),
            ]
            let publisher =
                "s:So20NSNotificationCenterC10FoundationE9publisher3for6objectAbCE9PublisherVSo0A4Namea_yXlSgtF"
            let sink = "s:7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValue"
            let snapshot = IndexSnapshot(symbols: symbols, references: [
                .init(sourceUSR: "caller", targetUSR: publisher, kind: .call, location: location(93, 5)),
                .init(sourceUSR: "caller", targetUSR: sink, kind: .call, location: location(93, 20)),
                .init(sourceUSR: "caller", targetUSR: cancellationUSR,
                    kind: .call, location: location(cancellationLine, 5)),
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(93, 1)),
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                    kind: .call, location: location(95, 5)),
                .init(sourceUSR: "caller",
                    targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(95, 1)),
            ])
            let cancellation = RuntimeNotificationCancellationReference(
                registrationLocation: registrationLocation ?? location(93),
                cancellationLocation: location(cancellationLine, 5)
            )
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationSubscription, api: "publisher", location: location(93),
                    calleeLocation: location(93, 5), enclosingDeclarationLocation: location(90),
                    notificationName: "ready", notificationCenterLocation: location(93, 1),
                    notificationObjectIsNil: true,
                    subscriptionConsumer: .init(api: "sink", location: location(93, 20))
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(95),
                    calleeLocation: location(95, 5), enclosingDeclarationLocation: location(90),
                    notificationName: "ready", notificationCenterLocation: location(95, 1),
                    notificationObjectIsNil: true, notificationCancellationReferences: [cancellation]
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        let system = "s:7Combine14AnyCancellableC6cancelyyF"
        #expect(!run(cancellationUSR: system).connections.contains { $0.kind == .notificationPost })
        #expect(run(cancellationUSR: "custom-cancel").connections.contains { $0.kind == .notificationPost })
        #expect(run(cancellationUSR: system, cancellationLine: 96).connections.contains {
            $0.kind == .notificationPost
        })
        #expect(run(cancellationUSR: system, registrationLocation: location(92)).connections.contains {
            $0.kind == .notificationPost
        })
    }

    @Test("NotificationCenter AsyncSequence는 direct for-await compiler proof가 모두 있어야 연결한다")
    func notificationAsyncSequenceRequiresIterationProof() {
        let listener = IndexedSymbol(
            usr: "listener", name: "listen()", kind: .function, module: "App", location: location(120)
        )
        let poster = IndexedSymbol(
            usr: "poster", name: "post()", kind: .function, module: "App", location: location(130)
        )
        let custom = IndexedSymbol(
            usr: "custom", name: "notifications(named:)", kind: .method,
            module: "App", location: location(140)
        )
        let notifications =
            "s:So20NSNotificationCenterC10FoundationE13notifications5named6objectAbCE13NotificationsCSo0A4Namea_yXlSgtF"
        let iterator =
            "s:So20NSNotificationCenterC10FoundationE13NotificationsC17makeAsyncIteratorAE0G0VyF"
        let next =
            "s:So20NSNotificationCenterC10FoundationE13NotificationsC8IteratorV4nextAC12NotificationVSgyYaF"
        func run(callUSR: String = notifications, includesNext: Bool = true) -> RuntimeDiscoveryReport {
            var references: [IndexedReference] = [
                .init(sourceUSR: "listener", targetUSR: callUSR, kind: .call, location: location(121, 10)),
                .init(sourceUSR: "listener", targetUSR: iterator, kind: .reference, location: location(121, 5)),
                .init(sourceUSR: "listener",
                    targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(121, 1)),
                .init(sourceUSR: "poster",
                    targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                    kind: .call, location: location(131, 5)),
                .init(sourceUSR: "poster",
                    targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                    kind: .reference, location: location(131, 1)),
            ]
            if includesNext {
                references.append(.init(
                    sourceUSR: "listener", targetUSR: next, kind: .reference, location: location(121, 5)
                ))
            }
            let snapshot = IndexSnapshot(symbols: [listener, poster, custom], references: references)
            let boundaries = [
                RuntimeBoundary(
                    kind: .notificationSubscription, api: "notifications", location: location(121),
                    calleeLocation: location(121, 10), enclosingDeclarationLocation: location(120),
                    notificationName: "ready", notificationCenterLocation: location(121, 1),
                    notificationObjectIsNil: true,
                    subscriptionConsumer: .init(api: "for-await", location: location(121, 5))
                ),
                RuntimeBoundary(
                    kind: .notificationPost, api: "post", location: location(131),
                    calleeLocation: location(131, 5), enclosingDeclarationLocation: location(130),
                    notificationName: "ready", notificationCenterLocation: location(131, 1),
                    notificationObjectIsNil: true
                ),
            ]
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, boundaries: boundaries)], snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            )
        }

        let supported = run()
        #expect(supported.findings.first?.status == .resolved)
        #expect(supported.connections.contains {
            $0.kind == .notificationPost && $0.source == NodeID("poster") && $0.target == NodeID("listener")
        })
        #expect(run(includesNext: false).findings.first?.status == .shadowed)
        #expect(!run(includesNext: false).connections.contains { $0.kind == .notificationPost })
        #expect(run(callUSR: "custom").findings.first?.status == .shadowed)
    }

    @Test("구독 경계는 컴파일러 신원만 확인하고 callback 실행 간선을 만들지 않는다")
    func notificationSubscriptionsDoNotInventCallbackTargets() {
        func run(consumerUSR: String? = nil) -> RuntimeDiscoveryReport {
            let publisherUSR = "s:So20NSNotificationCenterC10FoundationE9publisher3for6objectAbCE9PublisherVSo0A4Namea_yXlSgtF"
            var snapshot = fixture(api: publisherUSR)
            snapshot.references.append(.init(
                sourceUSR: "caller",
                targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                kind: .reference,
                location: location(2, 1)
            ))
            if let consumerUSR {
                snapshot.references.append(.init(
                    sourceUSR: "caller", targetUSR: consumerUSR, kind: .call,
                    location: location(3, 5)
                ))
            }
            let boundary = RuntimeBoundary(
                kind: .notificationSubscription,
                api: "publisher",
                location: location(2),
                calleeLocation: location(2, 5),
                notificationName: "ready",
                notificationCenterLocation: location(2, 1),
                notificationObjectIsNil: true,
                subscriptionConsumer: consumerUSR.map { _ in
                    .init(api: "sink", location: location(3, 5))
                }
            )
            return resolve(boundary, snapshot: snapshot)
        }

        #expect(run().findings.first?.status == .lookupOnly)
        let sink = run(consumerUSR: "s:7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValue")
        #expect(sink.findings.first?.status == .resolved)
        #expect(sink.findings.first?.targets.isEmpty == true)
        #expect(sink.connections.isEmpty)
        let custom = run(consumerUSR: "local-consumer")
        #expect(custom.findings.first?.status == .shadowed)
    }

    @Test("같은 알림의 확인된 publisher 소비 지점만 게시의 잠재 대상이 된다")
    func notificationPostConnectsToConfirmedPublisherConsumer() {
        let subscriber = IndexedSymbol(
            usr: "subscriber", name: "body", kind: .property, module: "App", location: location(40)
        )
        let poster = IndexedSymbol(
            usr: "poster", name: "post()", kind: .function, module: "App", location: location(50)
        )
        let publisherUSR = "s:So20NSNotificationCenterC10FoundationE9publisher3for6objectAbCE9PublisherVSo0A4Namea_yXlSgtF"
        let sinkUSR = "s:7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValue"
        let snapshot = IndexSnapshot(symbols: [subscriber, poster], references: [
            .init(sourceUSR: "subscriber", targetUSR: publisherUSR, kind: .call, location: location(41, 5)),
            .init(sourceUSR: "subscriber", targetUSR: sinkUSR, kind: .call, location: location(42, 5)),
            .init(sourceUSR: "subscriber", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                kind: .reference, location: location(41, 1)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(im)postNotificationName:object:",
                kind: .call, location: location(51, 5)),
            .init(sourceUSR: "poster", targetUSR: "c:objc(cs)NSNotificationCenter(cpy)defaultCenter",
                kind: .reference, location: location(51, 1)),
        ])
        let subscription = RuntimeBoundary(
            kind: .notificationSubscription, api: "publisher", location: location(41),
            calleeLocation: location(41, 5), notificationName: "ready",
            notificationCenterLocation: location(41, 1), notificationObjectIsNil: true,
            subscriptionConsumer: .init(api: "sink", location: location(42, 5))
        )
        let post = RuntimeBoundary(
            kind: .notificationPost, api: "post", location: location(51),
            calleeLocation: location(51, 5), notificationName: "ready",
            notificationCenterLocation: location(51, 1), notificationObjectIsNil: false
        )
        let report = RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, boundaries: [subscription, post])],
            snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [path: .fresh]
        )

        #expect(report.connections.contains {
            $0.kind == .notificationPost && $0.source == NodeID("poster") && $0.target == NodeID("subscriber")
        })
        // nonnil publisher filter는 동일 불변 객체라는 증거가 없어 연결하지 않는다.
        let filtered = RuntimeBoundary(
            kind: .notificationSubscription, api: "publisher", location: location(41),
            calleeLocation: location(41, 5), notificationName: "ready",
            notificationCenterLocation: location(41, 1), notificationObjectIsNil: false,
            subscriptionConsumer: .init(api: "sink", location: location(42, 5))
        )
        let filteredReport = RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, boundaries: [filtered, post])], snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh]
        )
        #expect(!filteredReport.connections.contains { $0.source == NodeID("poster") })
    }

    @Test("Core Data entity는 기존 NSManagedObject 하위 클래스에만 연결한다")
    func coreDataEntityRequiresManagedObjectSubclass() {
        let managed = IndexedSymbol(
            usr: "managed", name: "Person", kind: .classType, module: "App", location: location(60)
        )
        let plain = IndexedSymbol(
            usr: "plain", name: "Plain", kind: .classType, module: "App", location: location(70)
        )
        let snapshot = IndexSnapshot(symbols: [managed, plain], references: [
            .init(
                sourceUSR: "managed", targetUSR: "c:objc(cs)NSManagedObject",
                kind: .inheritance, location: location(60, 1)
            ),
        ])
        let declarations = [
            RuntimeDeclaration(
                name: "Person", indexName: "Person", qualifiedName: "Person", kind: .classType,
                location: location(60), endLocation: location(65)
            ),
            RuntimeDeclaration(
                name: "Plain", indexName: "Plain", qualifiedName: "Plain", kind: .classType,
                location: location(70), endLocation: location(75)
            ),
        ]
        func resolveClass(_ name: String) -> RuntimeDiscoveryFinding? {
            let boundary = RuntimeBoundary(
                kind: .coreDataEntityClass,
                api: "representedClassName",
                location: .init(path: "/p/Model.xcdatamodel/contents", line: 2, column: 1),
                name: name,
                nameOrigin: .resource,
                receiverTypeName: name,
                receiverOrigin: .annotation,
                resourceObjectID: name
            )
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, declarations: declarations, boundaries: [boundary])],
                snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            ).findings.first
        }

        #expect(resolveClass("App.Person")?.status == .resolved)
        #expect(resolveClass("App.Person")?.targets == [NodeID("managed")])
        #expect(resolveClass("App.Plain")?.status == .unresolved)
        #expect(resolveClass("Missing")?.status == .unresolved)
    }

    @Test("Core Data의 모듈 없는 동명 클래스와 자동 생성 entity는 임의로 고르지 않는다")
    func coreDataEntityRejectsAmbiguityAndGeneratedClasses() {
        let first = IndexedSymbol(
            usr: "first", name: "Record", kind: .classType, module: "A", location: location(80)
        )
        let second = IndexedSymbol(
            usr: "second", name: "Record", kind: .classType, module: "B", location: location(90)
        )
        let snapshot = IndexSnapshot(symbols: [first, second], references: [
            .init(sourceUSR: "first", targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance),
            .init(sourceUSR: "second", targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance),
        ])
        let declarations = [
            RuntimeDeclaration(name: "Record", indexName: "Record", qualifiedName: "Record", kind: .classType,
                location: location(80), endLocation: location(85)),
            RuntimeDeclaration(name: "Record", indexName: "Record", qualifiedName: "Record", kind: .classType,
                location: location(90), endLocation: location(95)),
        ]
        func report(reason: String? = nil) -> RuntimeDiscoveryFinding? {
            let boundary = RuntimeBoundary(
                kind: .coreDataEntityClass,
                api: "representedClassName",
                location: .init(path: "/p/Model.xcdatamodel/contents", line: 2, column: 1),
                name: "Record",
                nameOrigin: .resource,
                receiverTypeName: reason == nil ? "Record" : nil,
                resourceObjectID: "Record",
                reason: reason
            )
            return RuntimeDiscoveryResolver().resolve(
                files: [.init(path: path, declarations: declarations, boundaries: [boundary])],
                snapshot: snapshot,
                graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
                freshness: [path: .fresh]
            ).findings.first
        }

        #expect(report()?.status == .ambiguous)
        #expect(report()?.candidates == [NodeID("first"), NodeID("second")])
        #expect(report(reason: "entity 'Record' uses automatic code generation 'class'")?.status == .unresolved)
    }

    @Test("NSManagedObject의 로컬 하위 클래스를 상속한 entity도 관리 객체로 확인한다")
    func coreDataEntityFollowsIndexedManagedInheritance() {
        let base = IndexedSymbol(
            usr: "base", name: "ManagedBase", kind: .classType, module: "App", location: location(100)
        )
        let entity = IndexedSymbol(
            usr: "entity", name: "Event", kind: .classType, module: "App", location: location(110)
        )
        let snapshot = IndexSnapshot(symbols: [base, entity], references: [
            .init(sourceUSR: "base", targetUSR: "s:So15NSManagedObjectC", kind: .inheritance),
            .init(sourceUSR: "entity", targetUSR: "base", kind: .inheritance),
        ])
        let boundary = RuntimeBoundary(
            kind: .coreDataEntityClass,
            api: "representedClassName",
            location: .init(path: "/p/Model.xcdatamodel/contents", line: 2, column: 1),
            name: "App.Event",
            nameOrigin: .resource,
            receiverTypeName: "App.Event"
        )
        let report = RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: [
                .init(name: "ManagedBase", indexName: "ManagedBase", qualifiedName: "ManagedBase",
                    kind: .classType, location: location(100), endLocation: location(105)),
                .init(name: "Event", indexName: "Event", qualifiedName: "Event",
                    kind: .classType, location: location(110), endLocation: location(115)),
            ], boundaries: [boundary])],
            snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [path: .fresh]
        )

        #expect(report.connections.map(\.target) == [NodeID("entity")])
    }

    @Test("final NSObject의 명시적 objc property만 KVC read/write 대상으로 연결한다")
    func keyValueCodingLinksExplicitObjectiveCProperty() {
        let read = resolveKVC(kind: .keyValueRead)
        let write = resolveKVC(kind: .keyValueWrite)

        #expect(read.findings.first?.status == .resolved)
        #expect(read.connections.map(\.target) == [NodeID("title")])
        #expect(write.findings.first?.status == .resolved)
        #expect(write.connections.map(\.target) == [NodeID("title")])
    }

    @Test("KVC write는 let을 거부하고 nonfinal 수신자와 accessor 변형을 추측하지 않는다")
    func keyValueCodingRejectsUnsafeDispatchShapes() {
        #expect(resolveKVC(kind: .keyValueWrite, propertyIsImmutable: true).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueWrite, propertyIsSettable: false).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueRead, receiverIsFinal: false).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueRead, extraMethod: "getTitle()").connections.isEmpty)
        #expect(resolveKVC(
            kind: .keyValueRead,
            extraMethod: "alternateGetter()",
            extraObjectiveCName: "getTitle"
        ).connections.isEmpty)
        #expect(resolveKVC(
            kind: .keyValueRead,
            extraProperty: "alternateProperty",
            extraObjectiveCName: "getTitle"
        ).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueRead, extraMethod: "value(forKey:)").connections.isEmpty)
        #expect(resolveKVC(
            kind: .keyValueRead,
            extraMethod: "customRead(_:)",
            extraObjectiveCName: "valueForKey:"
        ).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueWrite, extraMethod: "setTitle(_:)").connections.isEmpty)
        #expect(resolveKVC(
            kind: .keyValueWrite,
            extraMethod: "alternateSetter(_:)",
            extraObjectiveCName: "setTitle:"
        ).connections.isEmpty)
        #expect(resolveKVC(kind: .keyValueWrite, extraMethod: "setValue(_:forKey:)").connections.isEmpty)
        #expect(resolveKVC(
            kind: .keyValueWrite,
            extraMethod: "customWrite(_:key:)",
            extraObjectiveCName: "setValue:forKey:"
        ).connections.isEmpty)
    }

    @Test("사용자 동명 value 함수와 불명확한 KVC key는 연결을 만들지 않는다")
    func keyValueCodingRequiresSystemAPIAndSimpleKey() {
        #expect(resolveKVC(kind: .keyValueRead, systemAPI: false).findings.first?.status == .shadowed)
        #expect(resolveKVC(kind: .keyValueRead, key: "profile.name").connections.isEmpty)
    }

    @Test("KVC key path는 exact intermediate type을 따라 모든 property를 순서대로 연결한다")
    func keyPathLinksEveryPropertyWithoutTreatingIntermediateAsWrite() {
        let read = resolveKeyPath(kind: .keyPathRead)
        let write = resolveKeyPath(kind: .keyPathWrite)

        #expect(read.findings.first?.targets == [NodeID("leaf-property"), NodeID("text-property")])
        #expect(write.findings.first?.targets == [NodeID("leaf-property"), NodeID("text-property")])
        #expect(write.findings.first?.reason?.contains("intermediate targets are not setter") == true)
    }

    @Test("KVC key path는 override와 불명확한 intermediate와 final setter를 부분 연결하지 않는다")
    func keyPathRejectsUnprovenSegments() {
        #expect(resolveKeyPath(kind: .keyPathRead, leafIsFinal: false).connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathRead, includesTypeReference: false).connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathRead, extraMethod: "value(forKeyPath:)").connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathWrite, extraMethod: "setValue(_:forKeyPath:)").connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathWrite, extraMethod: "value(forKeyPath:)").connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathRead, extraMethod: "getText()", methodOwner: "leaf").connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathWrite, textIsSettable: false).connections.isEmpty)
        #expect(resolveKeyPath(kind: .keyPathRead, systemAPI: false).findings.first?.status == .shadowed)
    }

    @Test("NSPredicate 경로는 constructor와 evaluate compiler proof를 모두 거쳐 같은 resolver를 쓴다")
    func predicateKeyPathsRequireConstructorAndEvaluationProof() {
        let supported = resolveKeyPath(kind: .keyPathRead, predicate: true)
        #expect(supported.findings.first?.status == .resolved)
        #expect(supported.findings.first?.targets == [NodeID("leaf-property"), NodeID("text-property")])
        #expect(resolveKeyPath(
            kind: .keyPathRead, predicate: true, constructorUSR: "custom-predicate"
        ).findings.first?.status == .shadowed)
        #expect(resolveKeyPath(
            kind: .keyPathRead, predicate: true, systemAPI: false
        ).findings.first?.status == .shadowed)
        #expect(resolveKeyPath(
            kind: .keyPathRead, extraMethod: "value(forKeyPath:)", predicate: true
        ).connections.isEmpty)
    }

    private func resolveKeyPath(
        kind: RuntimeBoundaryKind,
        leafIsFinal: Bool = true,
        includesTypeReference: Bool = true,
        textIsSettable: Bool = true,
        extraMethod: String? = nil,
        methodOwner: String = "root",
        predicate: Bool = false,
        constructorUSR: String = "s:So11NSPredicateC10FoundationE6format_ABSSh_s7CVarArg_pdtcfc",
        systemAPI: Bool = true
    ) -> RuntimeDiscoveryReport {
        let callUSR: String
        if predicate { callUSR = "c:objc(cs)NSPredicate(im)evaluateWithObject:" }
        else if kind == .keyPathWrite { callUSR = "c:objc(cs)NSObject(im)setValue:forKeyPath:" }
        else { callUSR = "c:objc(cs)NSObject(im)valueForKeyPath:" }
        var symbols = [
            IndexedSymbol(usr: "caller", name: "use()", kind: .function, module: "App", location: location(1)),
            IndexedSymbol(usr: "root", name: "Root", kind: .classType, module: "App", location: location(10)),
            IndexedSymbol(usr: "leaf", name: "Leaf", kind: .classType, module: "App", location: location(20)),
            IndexedSymbol(usr: "leaf-property", name: "leaf", kind: .property, module: "App",
                location: location(11), parentUSR: "root", attributes: [.objc]),
            IndexedSymbol(usr: "text-property", name: "text", kind: .property, module: "App",
                location: location(21), parentUSR: "leaf", attributes: [.objc]),
        ]
        var declarations = [
            RuntimeDeclaration(name: "Root", indexName: "Root", qualifiedName: "Root", kind: .classType,
                location: location(10), endLocation: location(15), isFinal: true),
            RuntimeDeclaration(name: "Leaf", indexName: "Leaf", qualifiedName: "Leaf", kind: .classType,
                location: location(20), endLocation: location(25), isFinal: leafIsFinal),
            RuntimeDeclaration(name: "leaf", indexName: "leaf", qualifiedName: "Root.leaf", kind: .property,
                location: location(11), endLocation: location(12), parentLocation: location(10),
                objectiveCName: "leaf", attributes: [.objc], isTypeMember: true, isImmutable: true,
                valueTypeName: "Leaf", valueTypeLocation: location(11, 20)),
            RuntimeDeclaration(name: "text", indexName: "text", qualifiedName: "Leaf.text", kind: .property,
                location: location(21), endLocation: location(22), parentLocation: location(20),
                objectiveCName: "text", attributes: [.objc], isTypeMember: true,
                isSettable: textIsSettable),
        ]
        if let extraMethod {
            let owner = methodOwner == "leaf" ? "leaf" : "root"
            let ownerLocation = methodOwner == "leaf" ? location(20) : location(10)
            symbols.append(.init(usr: "extra", name: extraMethod, kind: .method, module: "App",
                location: location(23), parentUSR: owner, attributes: [.objc]))
            declarations.append(.init(
                name: GraphNode.baseName(ofIndexName: extraMethod), indexName: extraMethod,
                qualifiedName: "Extra.\(GraphNode.baseName(ofIndexName: extraMethod))", kind: .method,
                location: location(23), endLocation: location(24), parentLocation: ownerLocation,
                objectiveCName: nil, attributes: [.objc], isTypeMember: true
            ))
        }
        if !systemAPI {
            symbols.append(.init(usr: "custom-call", name: predicate ? "evaluate(with:)" : "value(forKeyPath:)",
                kind: .method, module: "App", location: location(40)))
        }
        if constructorUSR == "custom-predicate" {
            symbols.append(.init(usr: constructorUSR, name: "NSPredicate(format:)",
                kind: .initializer, module: "App", location: location(41)))
        }
        var references: [IndexedReference] = [
            .init(sourceUSR: "root", targetUSR: "c:objc(cs)NSObject", kind: .inheritance),
            .init(sourceUSR: "leaf", targetUSR: "c:objc(cs)NSObject", kind: .inheritance),
            .init(sourceUSR: "caller", targetUSR: systemAPI ? callUSR : "custom-call",
                kind: .call, location: location(2, 5)),
            .init(sourceUSR: "caller", targetUSR: "root", kind: .reference, location: location(2, 20)),
        ]
        if includesTypeReference {
            references.append(.init(
                sourceUSR: "leaf-property", targetUSR: "leaf", kind: .reference, location: location(11, 20)
            ))
        }
        if predicate {
            references.append(.init(
                sourceUSR: "caller", targetUSR: constructorUSR, kind: .call, location: location(3, 5)
            ))
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: references)
        let boundary = RuntimeBoundary(
            kind: kind,
            api: predicate ? "evaluate" : (kind == .keyPathWrite ? "setValue" : "value"),
            location: location(2),
            calleeLocation: location(2, 5),
            enclosingDeclarationLocation: location(1),
            name: predicate ? nil : "leaf.text",
            nameOrigin: .literal,
            receiverTypeName: "App.Root",
            receiverOrigin: .annotation,
            receiverTypeLocation: location(2, 20),
            keyPaths: ["leaf.text"],
            nameAPIReferences: predicate ? [
                .init(api: "NSPredicate.format", location: location(3, 5)),
            ] : nil
        )
        return RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: declarations, boundaries: [boundary])],
            snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [path: .fresh]
        )
    }

    private func resolveKVC(
        kind: RuntimeBoundaryKind,
        key: String = "title",
        receiverIsFinal: Bool = true,
        propertyIsImmutable: Bool = false,
        propertyIsSettable: Bool = true,
        extraMethod: String? = nil,
        extraProperty: String? = nil,
        extraObjectiveCName: String? = nil,
        systemAPI: Bool = true
    ) -> RuntimeDiscoveryReport {
        let apiUSR = kind == .keyValueRead
            ? "c:objc(cs)NSObject(im)valueForKey:"
            : "c:objc(cs)NSObject(im)setValue:forKey:"
        var symbols = [
            IndexedSymbol(usr: "caller", name: "use()", kind: .function, module: "App", location: location(120)),
            IndexedSymbol(usr: "model", name: "Model", kind: .classType, module: "App", location: location(130)),
            IndexedSymbol(usr: "title", name: "title", kind: .property, module: "App", location: location(131),
                parentUSR: "model", attributes: [.objc]),
        ]
        var declarations = [
            RuntimeDeclaration(name: "Model", indexName: "Model", qualifiedName: "Model", kind: .classType,
                location: location(130), endLocation: location(140), isFinal: receiverIsFinal),
            RuntimeDeclaration(name: "title", indexName: "title", qualifiedName: "Model.title", kind: .property,
                location: location(131), endLocation: location(132), parentLocation: location(130),
                objectiveCName: "title", attributes: [.objc], isTypeMember: true,
                isImmutable: propertyIsImmutable, isSettable: propertyIsSettable),
        ]
        if let extraMethod {
            symbols.append(.init(usr: "extra", name: extraMethod, kind: .method, module: "App",
                location: location(133), parentUSR: "model", attributes: [.objc]))
            declarations.append(.init(
                name: GraphNode.baseName(ofIndexName: extraMethod), indexName: extraMethod,
                qualifiedName: "Model.\(GraphNode.baseName(ofIndexName: extraMethod))", kind: .method,
                location: location(133), endLocation: location(134), parentLocation: location(130),
                objectiveCName: extraObjectiveCName ?? GraphNode.baseName(ofIndexName: extraMethod),
                attributes: [.objc], isTypeMember: true
            ))
        }
        if let extraProperty {
            symbols.append(.init(usr: "extra-property", name: extraProperty, kind: .property, module: "App",
                location: location(135), parentUSR: "model", attributes: [.objc]))
            declarations.append(.init(
                name: extraProperty, indexName: extraProperty, qualifiedName: "Model.\(extraProperty)",
                kind: .property, location: location(135), endLocation: location(136),
                parentLocation: location(130), objectiveCName: extraObjectiveCName ?? extraProperty,
                attributes: [.objc], isTypeMember: true, isSettable: false
            ))
        }
        if !systemAPI {
            symbols.append(.init(usr: "custom", name: "value(forKey:)", kind: .method, module: "App",
                location: location(150)))
        }
        let target = systemAPI ? apiUSR : "custom"
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            .init(sourceUSR: "model", targetUSR: "c:objc(cs)NSObject", kind: .inheritance),
            .init(sourceUSR: "caller", targetUSR: target, kind: .call, location: location(121, 5)),
        ])
        let boundary = RuntimeBoundary(
            kind: kind,
            api: kind == .keyValueRead ? "value" : "setValue",
            location: location(121),
            calleeLocation: location(121, 5),
            name: key,
            nameOrigin: .literal,
            receiverTypeName: "App.Model",
            receiverOrigin: .annotation
        )
        return RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: declarations, boundaries: [boundary])],
            snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [path: .fresh]
        )
    }

}
