import CartographSyntax
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("브리지 사실 문서")
struct BridgeFactsTests {
    @Test("실제 구문으로 얻은 1000 handler가 자기 참조만 보존한다")
    func classifiesLargeSharedSetupWithoutCrossContamination() {
        let registrations = (0..<1000).map { index in
            "let c\(index) = FlutterBasicMessageChannel(name: \"c\(index)\", binaryMessenger: messenger)\n"
                + "c\(index).setMessageHandler { _, _ in helper() }"
        }.joined(separator: "\n")
        let scanned = BridgeFactScanner().scan(
            source: "func install() {\n\(registrations)\n}\nfunc helper() {}\n",
            path: "/tmp/large.swift", messages: true
        )
        let declaration = scanned.handlerScopes[0].declaration
        let scopes = scanned.handlerScopes[0].scopes
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:setup", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp/large.swift", line: 1, column: 6)),
            IndexedSymbol(usr: "s:helper", name: "helper()", kind: .function, module: "P",
                location: .init(path: "/tmp/large.swift", line: declaration.end!.line + 1, column: 6)),
        ], references: scopes.map { scope in
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:helper", kind: .call,
                location: .init(path: scope.end.path, line: scope.end.line, column: scope.end.column - 9))
        })
        let result = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp/large.swift"])
            .resolve(scanned.facts, handlerScopes: scanned.handlerScopes)
        #expect(result.count == 1000)
        #expect(result.allSatisfy { $0.handlerScope?.complete == true && $0.dependencies?.count == 1 })
        #expect(result.allSatisfy { $0.dependencies?.first?.scope == .handler })
        #expect(Set(result.compactMap { $0.dependencies?.first?.location }).count == 1000)
    }

    @Test("감싸는 선언이 없는 Basic callback도 소비 가능한 불완전 근거를 낸다")
    func topLevelMessageKeepsPairedExecutionEvidence() {
        let scanned = BridgeFactScanner().scan(source: """
            let channel = FlutterBasicMessageChannel(name: "top", binaryMessenger: messenger)
            channel.setMessageHandler { _, reply in reply(nil) }
            """, path: "/tmp/main.swift", messages: true)
        let facts = BridgeSymbolResolver(snapshot: IndexSnapshot()).resolve(
            scanned.facts, handlerScopes: scanned.handlerScopes
        )
        #expect(facts.count == 1)
        #expect(facts.first?.handlerScope?.complete == false)
        #expect(facts.first?.dependencies?.isEmpty == true)
    }

    @Test("두 번째 handler 시작 위치의 참조가 다른 handler의 등록 의존으로 새지 않는다")
    func referenceAtHandlerStartStaysInThatHandler() {
        let fixture = scopedFixture(referenceLines: [10], referenceColumn: 10)
        let result = fixture.resolver.resolve(fixture.facts, handlerScopes: fixture.scopes)
        #expect(result[0].dependencies?.isEmpty == true)
        #expect(result[1].dependencies?.map(\.scope) == [.handler])
        #expect(result.allSatisfy { $0.handlerScope?.complete == true })
    }

    @Test("생성 예산은 dispatch 비용과 다음 파일에 걸쳐 유지되고 부분 근거를 알린다")
    func generationBudgetIncludesDispatchAndSubsequentFiles() {
        let fixture = scopedFixture(referenceLines: [4, 10], referenceColumn: 11)
        var budget = 3
        let result = fixture.resolver.resolve(fixture.facts, handlerScopes: fixture.scopes, dependencyBudget: &budget)
        #expect(result[0].dependencies?.count == 1)
        #expect(result[0].dependencies?.first?.dispatchTargets.count == 1)
        #expect(result[0].handlerScope?.complete == true)
        #expect(result[1].dependencies?.isEmpty == true)
        #expect(result[1].handlerScope?.complete == false)
        #expect(budget == 1)
        let next = fixture.resolver.resolve(fixture.facts, handlerScopes: fixture.scopes, dependencyBudget: &budget)
        #expect(next.allSatisfy { $0.dependencies?.isEmpty == true && $0.handlerScope?.complete == false })
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-14T00:00:00Z",
            project: "/", facts: result, version: 2, transport: "basic-message-channel"
        )
        #expect(document.limitations.contains { $0.hasPrefix("incomplete-message-handler-scopes:") })
    }

    @Test("handler 목록이 없거나 일부만 전달되면 완전하다고 보고하지 않는다", arguments: [false, true])
    func missingScopeInventoryPreservesUncertainty(partial: Bool) {
        let fixture = scopedFixture(referenceLines: [4, 10], referenceColumn: 11)
        let inventory = partial ? [ScannedBridgeHandlerScopes(
            declaration: fixture.scopes[0].declaration, scopes: [fixture.scopes[0].scopes[0]]
        )] : []
        let result = fixture.resolver.resolve(fixture.facts, handlerScopes: inventory)
        #expect(result.allSatisfy { $0.handlerScope?.complete == false })
        #expect(result.allSatisfy { $0.dependencies?.count == 1 })
        #expect(result.allSatisfy { $0.dependencies?.first?.scope == .handler })
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-14T00:00:00Z",
            project: "/", facts: result, version: 2, transport: "basic-message-channel"
        )
        #expect(document.limitations.contains { $0.hasPrefix("incomplete-message-handler-scopes: 2 ") })
    }

    @Test("같은 선언과 handler의 경로 별칭 목록은 중복 없이 같은 의존성을 낸다")
    func duplicateCanonicalScopeInventoryIsMerged() {
        let fixture = scopedFixture(referenceLines: [4, 10], referenceColumn: 11)
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 1,
            start: .init(path: "/private/tmp", line: 1, column: 1),
            end: .init(path: "/private/tmp", line: 20, column: 1)
        )
        let aliases = fixture.scopes[0].scopes.map { scope in BridgeFact.HandlerScope(
            start: .init(path: "/private/tmp", line: scope.start.line, column: scope.start.column),
            end: .init(path: "/private/tmp", line: scope.end.line, column: scope.end.column), complete: false
        ) }
        let inventory = fixture.scopes + [ScannedBridgeHandlerScopes(declaration: declaration, scopes: aliases)]
        let result = fixture.resolver.resolve(fixture.facts, handlerScopes: inventory)
        #expect(result == fixture.resolver.resolve(fixture.facts, handlerScopes: fixture.scopes))
        #expect(result.allSatisfy { $0.handlerScope?.complete == true })
        #expect(result.allSatisfy { $0.dependencies?.count == 1 && $0.dependencies?.first?.scope == .handler })
    }

    @Test("클로저 캡처 초기화식의 참조는 핸들러가 아니라 등록 근거다")
    func captureListInitializerIsRegistrationEvidence() {
        let scanned = BridgeFactScanner().scan(source: """
            func install() {
                let c = BasicMessageChannel<Any?>(name: "c", binaryMessenger: m)
                c.setMessageHandler { [s = make()] _, _ in
                    s.run()
                }
            }
            """, path: "/tmp/c.swift", messages: true)
        guard let scope = scanned.facts.first?.fact.handlerScope else {
            Issue.record("handlerScope가 없다")
            return
        }
        // 캡처의 `make()` 는 `{` 와 `in` 사이, 본문의 `s.run()` 은 `in` 뒤다.
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:install", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp/c.swift", line: 1, column: 6)),
            IndexedSymbol(usr: "s:make", name: "make()", kind: .function, module: "P",
                location: .init(path: "/tmp/c.swift", line: 8, column: 6)),
            IndexedSymbol(usr: "s:run", name: "run()", kind: .method, module: "P",
                location: .init(path: "/tmp/c.swift", line: 9, column: 6)),
        ], references: [
            IndexedReference(sourceUSR: "s:install", targetUSR: "s:make", kind: .call,
                location: .init(path: "/tmp/c.swift", line: scope.start.line, column: scope.start.column - 3)),
            IndexedReference(sourceUSR: "s:install", targetUSR: "s:run", kind: .call,
                location: .init(path: "/tmp/c.swift", line: scope.start.line + 1, column: 5)),
        ])
        let result = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp/c.swift"])
            .resolve(scanned.facts, handlerScopes: scanned.handlerScopes)
        #expect(result.first?.handlerScope?.complete == true)
        #expect(result.first?.dependencies?.map(\.scope) == [.registration, .handler])
    }

    @Test("같은 라벨의 후보가 같은 거리에 여럿이면 USR을 추측하지 않는다")
    func equidistantLabelMatchesStayNameOnly() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp/a.swift", line: 10, column: 10),
            end: .init(path: "/tmp/a.swift", line: 12, column: 1), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 5,
            start: .init(path: "/tmp/a.swift", line: 5, column: 1),
            end: .init(path: "/tmp/a.swift", line: 15, column: 1)
        )
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "c", handlerScope: scope,
            location: .init(path: "/tmp/a.swift", line: 10, column: 5)
        )
        // 선언 줄(5)에서 거리가 4로 같은 두 후보 — 어느 쪽의 USR도 근거로 단정할 수 없다.
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:a", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp/a.swift", line: 1, column: 1)),
            IndexedSymbol(usr: "s:b", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp/a.swift", line: 9, column: 1)),
        ])
        let result = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp/a.swift"])
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration, handlerScopes: [scope])])
        #expect(result.first?.symbol?.usr == nil)
        #expect(result.first?.symbol?.qualifiedName == "P.install")
        #expect(result.first?.handlerScope?.complete == false)
    }

    @Test("외부 요구사항에 프로젝트 내 구현이 있으면 실행 근거를 완전하다고 보고하지 않는다")
    func externalRequirementWithInternalOverridesIsIncomplete() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp/e.swift", line: 4, column: 10),
            end: .init(path: "/tmp/e.swift", line: 6, column: 1), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/tmp/e.swift", line: 2, column: 1),
            end: .init(path: "/tmp/e.swift", line: 8, column: 1)
        )
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "c", handlerScope: scope,
            location: .init(path: "/tmp/e.swift", line: 4, column: 5)
        )
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:setup", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp/e.swift", line: 2, column: 1)),
            IndexedSymbol(usr: "s:ext", name: "requirement()", kind: .method, module: "Lib",
                location: .init(path: "/sdk/Lib.swiftinterface", line: 3, column: 1), isExternal: true),
            IndexedSymbol(usr: "s:impl", name: "requirement()", kind: .method, module: "P",
                location: .init(path: "/tmp/e.swift", line: 20, column: 1)),
        ], references: [
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:ext", kind: .call,
                location: .init(path: "/tmp/e.swift", line: 5, column: 5)),
            IndexedReference(sourceUSR: "s:impl", targetUSR: "s:ext", kind: .overrides),
        ])
        let result = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp/e.swift"])
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration, handlerScopes: [scope])])
        #expect(result.first?.handlerScope?.complete == false)
        #expect(result.first?.dependencies?.isEmpty == true)
    }

    @Test("범위는 있는데 의존성 배열이 없는 사실은 완전하다고 나가지 않는다")
    func scopeWithoutDependenciesIsNotEmittedComplete() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp/d.swift", line: 4, column: 10),
            end: .init(path: "/tmp/d.swift", line: 6, column: 1), complete: true
        )
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "c", handlerScope: scope,
            dependencies: nil, location: .init(path: "/tmp/d.swift", line: 4, column: 5)
        )
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-14T00:00:00Z",
            project: "/", facts: [fact], version: 2, transport: "basic-message-channel"
        )
        #expect(document.facts.first?.handlerScope?.complete == false)
        #expect(document.facts.first?.dependencies == [])
        #expect(document.limitations.contains { $0.hasPrefix("incomplete-message-handler-scopes:") })
    }

    @Test("최상위 등록은 파일의 가상 최상위 심볼을 소유자로 단다")
    func topLevelMessageAttachesVirtualTopLevelSymbol() {
        let scanned = BridgeFactScanner().scan(source: """
            let channel = FlutterBasicMessageChannel(name: "top", binaryMessenger: messenger)
            channel.setMessageHandler { _, reply in reply(nil) }
            """, path: "/tmp/main.swift", messages: true)
        let topLevelUSR = "cartograph:top-level-code:/tmp/main.swift"
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: topLevelUSR, name: "top-level code", kind: .function, module: "P",
                location: .init(path: "/tmp/main.swift", line: 1, column: 1))
        ])
        let facts = BridgeSymbolResolver(snapshot: snapshot).resolve(
            scanned.facts, handlerScopes: scanned.handlerScopes
        )
        #expect(facts.first?.symbol?.usr == topLevelUSR)
        #expect(facts.first?.symbol?.qualifiedName == "P.top-level code")
        #expect(facts.first?.handlerScope?.complete == false)
    }

    private func scopedFixture(referenceLines: [Int], referenceColumn: Int) -> (
        resolver: BridgeSymbolResolver, facts: [ScannedBridgeFact], scopes: [ScannedBridgeHandlerScopes]
    ) {
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 1,
            start: .init(path: "/tmp", line: 1, column: 1), end: .init(path: "/tmp", line: 20, column: 1)
        )
        let scopes = [4, 10].map { line in BridgeFact.HandlerScope(
            start: .init(path: "/tmp", line: line, column: 10),
            end: .init(path: "/tmp", line: line + 2, column: 1), complete: false
        ) }
        let facts = scopes.enumerated().map { index, scope in ScannedBridgeFact(
            fact: BridgeFact(kind: .messageHandle, target: .flutter, channel: "channel\(index)",
                handlerScope: scope, location: scope.start), declaration: declaration
        ) }
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:setup", name: "install()", kind: .function, module: "P",
                location: .init(path: "/tmp", line: 1, column: 1)),
            IndexedSymbol(usr: "s:helper", name: "helper()", kind: .function, module: "P",
                location: .init(path: "/tmp", line: 22, column: 1)),
            IndexedSymbol(usr: "s:implementation", name: "helper()", kind: .function, module: "Q",
                location: .init(path: "/tmp", line: 24, column: 1)),
        ], references: referenceLines.map { line in
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:helper", kind: .call,
                location: .init(path: "/tmp", line: line, column: referenceColumn))
        } + [IndexedReference(sourceUSR: "s:implementation", targetUSR: "s:helper", kind: .overrides)])
        return (BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp"]), facts,
            [ScannedBridgeHandlerScopes(declaration: declaration, scopes: scopes)])
    }

    @Test("브리지 의존성 범위는 같은 파일의 tmp 표기 차이에도 line/column으로 맞춘다")
    func executionDependencyRangeIgnoresPathSpelling() throws {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/private/tmp", line: 4, column: 20),
            end: .init(path: "/private/tmp", line: 6, column: 5), complete: false
        )
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "c", handlerScope: scope,
            location: .init(path: "/private/tmp", line: 4, column: 1)
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/private/tmp", line: 2, column: 1),
            end: .init(path: "/private/tmp", line: 8, column: 1)
        )
        let target = IndexedSymbol(
            usr: "s:target", name: "helper()", kind: .function, module: "App",
            location: .init(path: "/tmp", line: 20, column: 1)
        )
        let duplicateTarget = IndexedSymbol(
            usr: "s:target", name: "helper()", kind: .function, module: "App",
            location: .init(path: "/tmp", line: 20, column: 1)
        )
        let snapshot = IndexSnapshot(
            symbols: [IndexedSymbol(
                usr: "s:setup", name: "install()", kind: .function, module: "App",
                location: .init(path: "/tmp", line: 2, column: 1)
            ), target, duplicateTarget],
            references: [IndexedReference(
                sourceUSR: "s:setup", targetUSR: "s:target", kind: .call,
                location: .init(path: "/tmp", line: 5, column: 30)
            )]
        )
        let resolved = BridgeSymbolResolver(
            snapshot: snapshot, freshPaths: ["/private/tmp"]
        ).resolve([ScannedBridgeFact(fact: fact, declaration: declaration, handlerScopes: [scope])]).first
        #expect(resolved?.handlerScope?.complete == true)
        #expect(resolved?.dependencies?.count == 1)
        #expect(resolved?.dependencies?.first?.scope == .handler)
        #expect(resolved?.dependencies?.first?.location.path == "/tmp")
    }

    @Test("위치 없는 내부 미해석 참조는 실행 근거를 불완전하게 만든다")
    func unknownUnlocatedReferenceMakesExecutionEvidenceIncomplete() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp", line: 4, column: 20),
            end: .init(path: "/tmp", line: 5, column: 5), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/tmp", line: 2, column: 1), end: .init(path: "/tmp", line: 8, column: 1)
        )
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "c", handlerScope: scope,
            location: .init(path: "/tmp", line: 4, column: 1)
        )
        let snapshot = IndexSnapshot(
            symbols: [IndexedSymbol(
                usr: "s:setup", name: "install()", kind: .function, module: "App",
                location: .init(path: "/tmp", line: 2, column: 1)
            )],
            references: [IndexedReference(
                sourceUSR: "s:setup", targetUSR: "s:missing", kind: .call, location: nil
            )]
        )

        let resolved = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp"])
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration)]).first
        #expect(resolved?.handlerScope?.complete == false)
        #expect(resolved?.dependencies?.isEmpty == true)
    }

    @Test("같은 setup의 method reference는 다른 inline closure를 complete로 만들지 않는다")
    func unscopedHandlerMakesExecutionEvidenceIncomplete() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp", line: 4, column: 20),
            end: .init(path: "/tmp", line: 5, column: 5), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/tmp", line: 2, column: 1),
            end: .init(path: "/tmp", line: 8, column: 1)
        )
        let inline = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "one", handlerScope: scope,
            location: .init(path: "/tmp", line: 4, column: 1)
        )
        let methodReference = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "two",
            location: .init(path: "/tmp", line: 6, column: 1)
        )
        let setup = IndexedSymbol(
            usr: "s:setup", name: "install()", kind: .function, module: "App",
            location: .init(path: "/tmp", line: 2, column: 1)
        )
        let target = IndexedSymbol(
            usr: "s:target", name: "helper()", kind: .function, module: "App",
            location: .init(path: "/tmp", line: 20, column: 1)
        )
        let snapshot = IndexSnapshot(
            symbols: [setup, target],
            references: [IndexedReference(sourceUSR: "s:setup", targetUSR: "s:target", kind: .call,
                location: .init(path: "/tmp", line: 4, column: 30))]
        )
        let result = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp"]).resolve([
            ScannedBridgeFact(fact: inline, declaration: declaration),
            ScannedBridgeFact(fact: methodReference, declaration: declaration)
        ])
        #expect(result.first?.handlerScope?.complete == false)
        #expect(result.first?.dependencies?.count == 1)
    }

    @Test("SDK 참조 위치를 브리지의 감싸는 선언으로 사용하지 않는다")
    func externalOccurrenceIsNotADeclaration() {
        let site = SourceLocation(path: "/p/Plugin.swift", line: 3, column: 6)
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "A", method: "run", location: site)
        let declaration = EnclosingDeclaration(name: "install", indexName: "install()", qualifiedName: "install()", line: 3)
        let external = IndexedSymbol(usr: "sdk:install", name: "install()", kind: .function,
            module: "SDK", location: site, isExternal: true)
        let resolved = BridgeSymbolResolver(snapshot: .init(symbols: [external]))
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration)])
        #expect(resolved.first?.symbol?.usr == nil)
    }

    @Test("채널만 미해석인 핸들러를 동적 메서드 분기라고 단정하지 않는다")
    func dynamicChannelDoesNotImplyDynamicMethod() {
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "factoryName()", method: "run",
            isDynamic: true, location: .init(path: "/p/Plugin.swift", line: 3, column: 1))
        let document = BridgeFactsDocument(tool: .init(name: "cartograph", version: "test"),
            generatedAt: "t", project: "/p", facts: [fact])
        #expect(document.limitations.contains {
            $0.hasPrefix("dynamic-method-names: 1") && $0.contains("channel or method name")
        })
        #expect(!document.limitations.contains { $0.contains("branch on a non-literal name") })
    }

    @Test("Objective-C USR 은 유일한 Clang 선언에서만 붙이고 이름은 인덱스가 없어도 싣는다")
    func objectiveCIndexIdentity() {
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "A", method: "run",
            location: .init(path: "/p/Plugin.m", line: 8, column: 1), sourceLanguage: .objectiveC)
        let declaration = EnclosingDeclaration(name: "handle:", indexName: "handle:", qualifiedName: "P.handle:", line: 5)
        let scanned = [ScannedBridgeFact(fact: fact, declaration: declaration)]
        func symbol(_ usr: String, line: Int = 5) -> IndexedSymbol {
            IndexedSymbol(usr: usr, name: "handle:", kind: .method, module: "P",
                location: .init(path: "/p/Plugin.m", line: line, column: 1))
        }
        func resolve(_ symbols: [IndexedSymbol]) -> BridgeFact {
            BridgeSymbolResolver(snapshot: IndexSnapshot(symbols: symbols)).resolve(scanned)[0]
        }
        #expect(resolve([symbol("c:objc(cs)P(im)handle:")]).symbol?.usr == "c:objc(cs)P(im)handle:")
        // 인덱스가 없거나(후보 0), 줄이 어긋나거나, Swift USR 이거나, 후보가 모호하면 USR 없이
        // 구문의 이름만 싣는다. Swift 사실과 같은 대칭이고 틀린 USR 은 없는 것보다 나쁘다.
        func isNameOnly(_ symbols: [IndexedSymbol]) -> Bool {
            let symbol = resolve(symbols).symbol
            return symbol?.usr == nil && symbol?.qualifiedName == "P.handle:"
        }
        #expect(isNameOnly([]))
        #expect(isNameOnly([symbol("c:other", line: 4)]))
        #expect(isNameOnly([symbol("s:fake")]))
        #expect(isNameOnly([symbol("c:a"), symbol("c:b")]))
        // 여러 빌드 구성을 묶은 스토어에서 같은 선언이 같은 USR 로 두 번 기록될 수 있다.
        // USR 이 하나로 유일하면 중복 레코드 때문에 이름뿐 신원으로 떨어지지 않는다.
        #expect(resolve([symbol("c:objc(cs)P(im)handle:"), symbol("c:objc(cs)P(im)handle:")])
            .symbol?.usr == "c:objc(cs)P(im)handle:")
    }

    @Test("외부 핸들러 본문의 공백은 등록 채널을 확실히 알 때만 좁힌다")
    func scopesKnownOpaqueHandlers() throws {
        let source = """
            import Flutter
            func install() {
                let a = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                let b = FlutterMethodChannel(name: "B", binaryMessenger: messenger)
                a.setMethodCallHandler(other.handle)
                b.setMethodCallHandler { call, result in result(nil) }
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        let scope = try #require(document.limitationScopes?.first)
        #expect(scope.channels == ["A"])
        #expect(document.limitations[scope.limitationIndex].hasPrefix("opaque-handler-bodies: 1"))
        let unknown = source.replacingOccurrences(of: "name: \"A\"", with: "name: channelName")
        let unscoped = try makeService(files: ["/p/Plugin.swift": unknown], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(unscoped.limitationScopes == nil)
        #expect(unscoped.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 1") })
    }

    @Test("범위를 모르는 본문 하나가 있으면 알려진 채널 목록을 완전한 범위로 내지 않는다")
    func unknownOpaqueHandlerPreventsNarrowing() {
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-08T00:00:00Z", project: "/p",
            facts: [], opaqueHandlerChannels: ["A", nil]
        )
        #expect(document.limitationScopes == nil)
        #expect(document.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 2") })
    }

    @Test("RN만 선택하면 Flutter 본문 공백도 함께 제외한다")
    func targetFilterDropsOpaqueFlutterGaps() throws {
        let source = """
            func install() {
                let a = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                a.setMethodCallHandler(factory.makeHandler())
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source, "/p/RN.m": Self.moduleSource], snapshot: IndexSnapshot())
            .bridgeFacts(target: .reactNative)
        #expect(document.limitationScopes == nil)
        #expect(!document.limitations.contains { $0.hasPrefix("opaque-handler-bodies:") })
    }

    @Test("Expo DSL 사실은 mechanism expo 로 직렬화되고 나머지는 키를 생략한다")
    func expoMechanismSerialization() throws {
        let source = """
            import ExpoModulesCore

            class PhotoModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoPhoto")
                    View(PhotoView.self) { Prop("url") { view, url in } }
                    Function("pick") { (filter: String) in filter }
                }
            }
            """
        let document = try makeService(files: ["/p/Photo.swift": source], snapshot: IndexSnapshot())
            .bridgeFacts(generatedAt: fixedDate, target: .reactNative)
        let exports = document.facts.filter { $0.kind == "module-export" || $0.kind == "component-export" }
        #expect(exports.count == 2)
        #expect(exports.allSatisfy { $0.mechanism == "expo" && $0.channel == "ExpoPhoto" })
        // method-handle 은 이름 경계가 아니라 mechanism 을 싣지 않는다.
        #expect(document.facts.allSatisfy { $0.kind != "method-handle" || $0.mechanism == nil })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"mechanism\":\"expo\""))
        // 코어 RN 사실이나 메서드 사실에는 키가 없다.
        #expect(!text.contains("\"mechanism\":\"core\""))
        #expect(try JSONDecoder().decode(BridgeFactsDocument.self, from: data) == document)
    }

    @Test("ObjC 사실에 출처 언어를 싣고 일반 ObjC 공백은 채널 리터럴로 좁히지 않는다")
    func objectiveCEvidenceAndConservativeGap() throws {
        let source = """
            @implementation Plugin
            + (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
                FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"A" binaryMessenger:registrar.messenger];
                [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
                    if ([call.method isEqualToString:@"run"]) { result(nil); }
                }];
            }
            @end
            """
        var symbols = SnapshotBuilder()
        symbols.symbol("s:FakePlugin", name: "Plugin", kind: .classType, path: "/p/Plugin.swift")
        symbols.symbol("s:FakeHandler", name: "handle(_:result:)", kind: .method, path: "/p/Plugin.swift", parent: "s:FakePlugin")
        let document = try makeService(files: ["/p/Plugin.m": source], snapshot: symbols.build()).bridgeFacts()
        #expect(document.facts.map(\.kind) == ["channel-register", "method-handle"])
        // 인덱스에 .m 유닛이 없어도 구문 이름 신원은 남는다. USR 만 null 이다.
        #expect(document.facts.allSatisfy { $0.sourceLanguage == .objectiveC && $0.symbol?.usr == nil })
        #expect(document.facts.allSatisfy { $0.symbol?.qualifiedName == "Plugin.registerWithRegistrar:" })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-sources:") })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-handlers: 1") })
        // 이름뿐 심볼이 된 ObjC 핸들은 Swift 신선도 신호(missing-handler-usrs)에 섞이지 않는다.
        #expect(!document.limitations.contains { $0.hasPrefix("missing-handler-usrs") })
        #expect(document.limitationScopes == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        #expect(try JSONDecoder().decode(BridgeFactsDocument.self, from: data) == document)
        #expect(String(decoding: data, as: UTF8.self).contains("\"sourceLanguage\":\"objective-c\""))
    }

    @Test("FFI·Dart C API 표식은 채널 사실이 아니라 파일 수준 한계로 센다")
    func ffiInteropEvidenceBecomesFileLevelLimitation() throws {
        let swift = """
            @_cdecl("dart_native_add")
            func dartNativeAdd(_ a: Int32, _ b: Int32) -> Int32 { a + b }
            """
        let objc = "#import <dart_native_api.h>\nvoid forward(Dart_Port port) { Dart_PostCObject(port, nullptr); }\n"
        let plain = "struct Plain { let value = 1 }\n"
        let document = try makeService(
            files: ["/p/Native.swift": swift, "/p/Forward.m": objc, "/p/Plain.swift": plain],
            snapshot: IndexSnapshot()
        ).bridgeFacts()
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-ffi-interop: 2") })
        // 표식 없는 파일은 세지 않고, 채널 사실과 섞이지 않는다.
        #expect(!document.limitations.contains { $0.hasPrefix("unscanned-ffi-interop: 3") })
        let clean = try makeService(files: ["/p/Plain.swift": plain], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(!clean.limitations.contains { $0.hasPrefix("unscanned-ffi-interop:") })
    }

    @Test("저장된 클로저와 파일 밖 함수도 본문을 못 읽으면 채널 공백을 낸다")
    func scopesStoredClosureAndUnknownFunction() throws {
        for argument in ["handler", "fromSDK"] {
            let source = """
                func install() {
                    let channel = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                    let handler = { (call: FlutterMethodCall, result: FlutterResult) in result(nil) }
                    channel.setMethodCallHandler(\(argument))
                }
                """
            let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
            #expect(document.limitationScopes?.first?.channels == ["A"])
            #expect(document.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 1") })
        }
    }

    @Test("교환 형식에 담을 수 없는 이름을 가진 문서를 내보내지 않는다")
    func rejectsUnrepresentableBridgeNames() {
        let multiline = "\"\"\"\nA\nB\n\"\"\""
        for name in ["\"\"", "\"   \"", multiline] {
            let source = """
                func install() {
                    let channel = FlutterMethodChannel(name: \(name), binaryMessenger: messenger)
                    channel.setMethodCallHandler(other.handle)
                }
                """
            #expect(throws: (any Error).self) {
                try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
            }
        }
    }

    @Test("로컬 함수 본문을 읽었으면 이름 참조만으로 opaque 경고를 만들지 않는다")
    func readableLocalHandlerIsNotOpaque() throws {
        let source = """
            func install() {
                let channel = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                channel.setMethodCallHandler(handle)
            }
            func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                switch call.method { case "run": result(nil); default: break }
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(document.facts.contains { $0.method == "run" && $0.channel == "A" })
        #expect(!document.limitations.contains { $0.hasPrefix("opaque-handler-bodies:") })
    }

    @Test("Swift 이스케이프를 실제 채널 값으로 풀어 스코프가 잘못된 이름을 가리키지 않는다")
    func decodedLiteralScope() throws {
        let source = #"""
            func install() {
                let channel = FlutterMethodChannel(name: "c\u{61}mera", binaryMessenger: messenger)
                channel.setMethodCallHandler(other.handle)
            }
            """#
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(document.facts.first?.channel == "camera")
        #expect(document.limitationScopes?.first?.channels == ["camera"])
    }

    @Test("선행 한계 뒤의 스코프 인덱스와 다채널 합집합을 유지한다")
    func scopeIndexAndUnion() {
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-08T00:00:00Z", project: "/p",
            facts: [.init(kind: .channelRegister, target: .flutter, channel: "runtimeName", isDynamic: true,
                          location: .init(path: "/p/A.swift", line: 1, column: 1))],
            opaqueHandlerChannels: ["B", "A", "A"]
        )
        #expect(document.limitationScopes?.first?.limitationIndex == 1)
        #expect(document.limitationScopes?.first?.channels == ["A", "B"])
    }

    private static let pluginSource = """
        import Flutter
        public final class CameraPlugin: NSObject, FlutterPlugin {
            public static func register(with registrar: FlutterPluginRegistrar) {
                let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: registrar.messenger())
                registrar.addMethodCallDelegate(CameraPlugin(), channel: channel)
            }
            public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                switch call.method {
                case "takePhoto": result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            }
        }
        """

    private static let moduleSource = """
        @implementation RNCalendar
        RCT_EXPORT_MODULE(Calendar)
        RCT_EXPORT_METHOD(addEvent:(NSString *)name) {}
        @end
        """

    private func makeService(files: [String: String], snapshot: IndexSnapshot) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: files),
                indexProviderOverride: StaticIndexProvider(snapshot)
            )
        )
    }

    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:register", name: "register(with:)", kind: .method, line: 3, parent: "s:CameraPlugin")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        return builder.build()
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_788_480_000)

    @Test("교환 문서의 사실 위치는 프로젝트 상대 경로다")
    func bridgeFactLocationsAreProjectRelative() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )

        let document = try service.bridgeFacts(generatedAt: fixedDate)

        #expect(document.facts.map(\.location.path) == [
            "Sources/CameraPlugin.swift",
            "Sources/CameraPlugin.swift",
        ])
    }

    @Test("교환 문서의 생성 시각은 UTC 밀리초 형식이다")
    func bridgeFactsUseUTCMillisecondTimestamp() throws {
        let service = makeService(files: ["/p/Sources/A.swift": "struct A {}"], snapshot: IndexSnapshot())

        let document = try service.bridgeFacts(generatedAt: fixedDate)

        #expect(document.generatedAt == "2026-09-04T00:00:00.000Z")
    }

    @Test("구문에서 찾은 사실에 인덱스의 USR 이 붙는다")
    func attachesIndexUSRs() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        let handled = try #require(document.facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
        // 표기는 계약의 것(`CameraPlugin.register`)이다. 인덱스의 표기는 USR 이 대신한다.
        #expect(handled.symbol?.qualifiedName == "CameraPlugin.handle")
        #expect(handled.channel == "com.example/camera")
        #expect(handled.method == "takePhoto")

        let registered = try #require(document.facts.first { $0.kind == "channel-register" })
        #expect(registered.symbol?.usr == "s:register")
        // `addMethodCallDelegate(CameraPlugin(), channel:)` 이 타입을 말해 주므로 추측이 아니다.
        #expect(!document.limitations.contains { $0.hasPrefix("inferred-channels") })
        #expect(!document.limitations.contains { $0.hasPrefix("missing-handler-usrs") })
    }

    @Test("오버로드가 있으면 인자 라벨까지 같은 선언에 USR 을 붙인다")
    func prefersFullSelectorOverNearestLine() throws {
        // `handle(_:)` 이 줄로는 더 가깝다. 기본 이름만 보면 그쪽에 붙는다.
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handleOne", name: "handle(_:)", kind: .method, line: 6, parent: "s:CameraPlugin")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 20, parent: "s:CameraPlugin")
        let service = makeService(files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource], snapshot: builder.build())
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
    }

    @Test("인덱스에 없는 선언은 구문의 이름만 남고 한계로 센다")
    func reportsUnresolvedSymbols() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: IndexSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.allSatisfy { $0.symbol?.usr == nil })
        #expect(document.facts.first?.symbol?.qualifiedName == "CameraPlugin.register")
        #expect(document.limitations.contains { $0 == "missing-handler-usrs: 1 method handlers have only a qualified name" })
    }

    @Test("Objective-C 의 RN 매크로도 함께 담기고 대상은 다수결이다")
    func mergesObjectiveCFactsAndPicksMajorityTarget() throws {
        let service = makeService(
            files: [
                "/p/Sources/CameraPlugin.swift": Self.pluginSource,
                "/p/ios/RNCalendar.m": Self.moduleSource,
            ],
            snapshot: makeSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.map(\.kind) == ["channel-register", "method-handle", "module-export", "method-handle"])
        #expect(document.target == "flutter")
        #expect(document.limitations.contains {
            $0.hasPrefix("mixed-targets: ") && $0.contains("flutter 2, react-native 2") && $0.contains("counts tie")
        })
        // Objective-C 쪽 사실은 선언 정보 자체가 없다. "USR 없는 핸들러" 가 아니라 따로 센다.
        #expect(!document.limitations.contains { $0.hasPrefix("missing-handler-usrs") })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-handlers: 1") })
        // Objective-C 로 쓴 Flutter 핸들러는 여기 없다는 것도 문서가 말해야 isthmus 가 오류로 읽지 않는다.
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-sources: 1 Objective-C file(s)") })
    }

    @Test("target 필터가 제외한 사실 수를 빈 선택에도 알린다")
    func targetFilterReportsDroppedFacts() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )

        let document = try service.bridgeFacts(
            generatedAt: fixedDate,
            target: .reactNative
        )

        #expect(document.facts.isEmpty)
        #expect(document.target == nil)
        #expect(document.limitations == [
            "target-filter: 2 fact(s) did not match react-native",
        ])
    }

    @Test("사실이 없으면 대상은 null 로 적히고 한계는 없다")
    func emptyProjectIsQuiet() throws {
        let service = makeService(files: ["/p/Sources/A.swift": "struct A {}"], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.isEmpty)
        #expect(document.target == nil)
        #expect(document.limitations.isEmpty)
        // 계약은 키 생략이 아니라 null 이다.
        let json = try service.exportBridgeFacts(generatedAt: fixedDate).output
        #expect(json.contains("\"target\" : null"))
    }

    @Test("라벨이 안 맞고 기본 이름이 같은 후보가 여럿이면 USR 을 붙이지 않는다")
    func refusesAmbiguousBaseNameFallback() throws {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handleOne", name: "handle(_:)", kind: .method, line: 6, parent: "s:CameraPlugin")
        builder.symbol("s:handleTwo", name: "handle(_:reply:)", kind: .method, line: 20, parent: "s:CameraPlugin")
        let service = makeService(files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource], snapshot: builder.build())
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == nil)
        #expect(handled.symbol?.qualifiedName == "CameraPlugin.handle")
    }

    @Test("인덱스 경로와 디스크 경로의 표기가 달라도 USR 이 붙는다")
    func attachesUSRsAcrossPathSpellings() throws {
        // 인덱스는 `/private/tmp` 로, 디스크 걷기는 `/tmp` 로 같은 곳을 가리킨다. macOS 의 실제 상황이다.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("CameraPlugin.swift")
        try Self.pluginSource.write(to: file, atomically: true, encoding: .utf8)
        let resolved = file.resolvingSymlinksInPath().path
        guard resolved != file.path else { return }

        var builder = SnapshotBuilder(module: "App", path: resolved)
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        var configuration = CartographConfiguration.default
        configuration.projectPath = directory.path
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(indexProviderOverride: StaticIndexProvider(builder.build()))
        )
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
    }

    @Test("브리지 프로젝트는 tmp 표기와 사용자 링크에 무관한 realpath이며 사실은 상대 경로다")
    func bridgeProjectUsesRealPath() throws {
        let root = "/private/tmp/cartograph-project-\(UUID().uuidString)"
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/project", withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: root) }
        try manager.createSymbolicLink(atPath: root + "/alias", withDestinationPath: root + "/project")
        try Self.pluginSource.write(toFile: root + "/project/CameraPlugin.swift", atomically: true, encoding: .utf8)
        let paths = [root + "/project", String(root.dropFirst("/private".count)) + "/project", root + "/alias"]
        for path in paths {
            var configuration = CartographConfiguration.default
            configuration.projectPath = path
            let service = CartographService(configuration: configuration, environment: CartographEnvironment(
                indexProviderOverride: StaticIndexProvider(IndexSnapshot()), usesSyntaxCache: false
            ))
            let json = try service.exportBridgeFacts(generatedAt: fixedDate).output
            let document = try JSONDecoder().decode(BridgeFactsDocument.self, from: Data(json.utf8))
            #expect(document.project == root + "/project")
            #expect(!document.facts.isEmpty)
            #expect(document.facts.allSatisfy { $0.location.path == "CameraPlugin.swift" })
        }
    }

    @Test("사용자 파일 시스템이 realpath를 지원하지 않으면 구현할 메서드를 안내한다")
    func explainsUnsupportedRealPath() {
        let service = CartographService(configuration: .default, environment: CartographEnvironment(
            fileSystem: UnsupportedRealPathFileSystem(), indexProviderOverride: StaticIndexProvider(IndexSnapshot())
        ))
        #expect(throws: CartographError.invalidConfiguration(path: "/p", reason:
            "The provided FileSystem does not support realPath(at:). Implement it before exporting bridge facts."
        )) { try service.exportBridgeFacts() }
    }

    @Test("프로젝트 경로를 해결할 수 없으면 브리지 문서를 내보내지 않는다")
    func refusesUnresolvableProject() {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/tmp/cartograph-missing-\(UUID().uuidString)"
        let service = CartographService(configuration: configuration, environment: CartographEnvironment(
            indexProviderOverride: StaticIndexProvider(IndexSnapshot())
        ))
        #expect(throws: CartographError.self) { try service.exportBridgeFacts() }
    }

    @Test("JSON 은 계약의 머리말을 담고 키가 정렬되어 두 번 인코딩해도 같다")
    func jsonFollowsExchangeFormat() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let first = try service.exportBridgeFacts(generatedAt: fixedDate).output
        let second = try service.exportBridgeFacts(generatedAt: fixedDate).output
        #expect(first == second)
        #expect(first.contains("\"format\" : \"bridge-facts\""))
        #expect(first.contains("\"version\" : 1"))
        #expect(first.contains("\"platform\" : \"swift\""))
        #expect(first.contains("\"generatedAt\" : \"2026-09-04T00:00:00.000Z\""))
        #expect(first.contains("\"dynamic\" : false"))
        #expect(!first.contains("channelPrefix"))

        let decoded = try JSONDecoder().decode(BridgeFactsDocument.self, from: Data(first.utf8))
        #expect(decoded.facts.count == 2)
    }

    @Test("@objc(Name) 클래스와 이벤트 채널은 한계로 센다")
    func countsAssumedModulesAndEventChannels() throws {
        let source = """
            @objc(Coordinator) class Coordinator: NSObject { @objc func start() {} }
            let events = FlutterEventChannel(name: "e", binaryMessenger: m)
            let pigeon = BasicMessageChannel<Any?>(name: "p", binaryMessenger: m)
            """
        let service = makeService(files: ["/p/Sources/A.swift": source], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.map(\.kind) == ["module-export", "method-handle"])
        #expect(document.limitations.contains { $0.hasPrefix("objc-named-classes: 1 module-export and 1 method-handle") })
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-event-channels: 1") })
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-message-channels: 1") })
    }

    @Test("messages 문서는 BasicMessageChannel 핸들러만 v2로 내보내고 기본 v1은 유지한다")
    func exportsBasicMessageDocument() throws {
        let source = """
            let basic = BasicMessageChannel<Any?>(name: "dev.flutter.pigeon.CameraApi.takePhoto", binaryMessenger: m)
            basic.setMessageHandler { _, _ in }
            basic.setMessageHandler(nil)
            FlutterMethodChannel(name: "camera", binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let service = makeService(files: ["/p/A.swift": source], snapshot: IndexSnapshot())
        let messageDocument = try service.bridgeFacts(
            generatedAt: fixedDate, target: .flutter, messages: true
        )
        #expect(messageDocument.version == 2)
        #expect(messageDocument.transport == "basic-message-channel")
        #expect(messageDocument.platform == "swift")
        #expect(messageDocument.facts.map(\.kind) == ["message-handle"])
        #expect(messageDocument.facts.first?.method == nil)
        // 전송별 문서도 자신의 관측 공백을 싣는다 — 없다와 못 봤다를 소비자가 구분한다.
        #expect(messageDocument.limitations.contains { $0.hasPrefix("unscanned-message-channels: 1") })
        let json = try service.exportBridgeFacts(
            generatedAt: fixedDate, target: .flutter, messages: true
        ).output
        #expect(json.contains("\"transport\" : \"basic-message-channel\""))
        #expect(json.contains("\"version\" : 2"))
        #expect(json.contains("\"kind\" : \"message-handle\""))
        #expect(!json.contains("\"method\""))

        let defaultDocument = try service.bridgeFacts(generatedAt: fixedDate, target: .flutter)
        #expect(defaultDocument.version == 1)
        #expect(defaultDocument.transport == nil)
        #expect(defaultDocument.facts.map(\.kind) == ["channel-register"])
        #expect(defaultDocument.limitations.contains { $0.hasPrefix("unscanned-message-channels: 1") })
    }

    @Test("messages 는 두 closure를 구분하고 setup 밖 공유 reference와 dispatch 후보를 보존한다")
    func exportsMessageExecutionDependencies() throws {
        let source = """
            class P {
                static func install() {
                    let one = BasicMessageChannel<Any?>(name: "one", binaryMessenger: m)
                    one.setMessageHandler { _, _ in first() }
                    let two = BasicMessageChannel<Any?>(name: "two", binaryMessenger: m)
                    two.setMessageHandler { _, _ in second() }
                    shared()
                }
            }
            """
        let setup = IndexedSymbol(
            usr: "s:setup", name: "install()", kind: .method, module: "App",
            location: .init(path: "/p/A.swift", line: 2, column: 5)
        )
        let first = IndexedSymbol(
            usr: "s:first", name: "first()", kind: .function, module: "App",
            location: .init(path: "/p/A.swift", line: 3, column: 1)
        )
        let second = IndexedSymbol(
            usr: "s:second", name: "second()", kind: .function, module: "App",
            location: .init(path: "/p/A.swift", line: 5, column: 1)
        )
        let shared = IndexedSymbol(
            usr: "s:shared", name: "shared()", kind: .function, module: "App",
            location: .init(path: "/p/A.swift", line: 6, column: 1)
        )
        let requirement = IndexedSymbol(
            usr: "s:req", name: "first()", kind: .method, module: "App",
            location: .init(path: "/p/A.swift", line: 8, column: 1)
        )
        let implementation = IndexedSymbol(
            usr: "s:impl", name: "first()", kind: .method, module: "App",
            location: .init(path: "/p/A.swift", line: 9, column: 1)
        )
        let references = [
            // 호출 위치는 `in` 뒤의 본문이다 — 시그니처(`{ _, _ in` 앞쪽)는 등록 근거다.
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:req", kind: .call,
                location: .init(path: "/p/A.swift", line: 4, column: 41)),
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:second", kind: .call,
                location: .init(path: "/p/A.swift", line: 6, column: 41)),
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:shared", kind: .call,
                location: .init(path: "/p/A.swift", line: 7, column: 5)),
            IndexedReference(sourceUSR: "s:impl", targetUSR: "s:req", kind: .overrides,
                location: .init(path: "/p/A.swift", line: 9, column: 1)),
        ]
        let snapshot = IndexSnapshot(symbols: [setup, first, second, shared, requirement, implementation], references: references)
        let service = makeService(files: ["/p/A.swift": source], snapshot: snapshot)
        let data = Data(try service.exportBridgeFacts(target: .flutter, messages: true).output.utf8)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let facts = try #require(document["facts"] as? [[String: Any]])
        #expect(facts.count == 2)
        #expect(facts.allSatisfy { $0["symbol"] != nil })
        #expect(facts.allSatisfy { $0["handlerScope"] != nil })
        #expect(facts.allSatisfy { $0["dependencies"] != nil })
        #expect(facts.allSatisfy { $0["method"] == nil })
        let firstFact = try #require(facts.first { $0["channel"] as? String == "one" })
        let firstScope = try #require(firstFact["handlerScope"] as? [String: Any])
        #expect(firstScope["complete"] as? Bool == false)
        let firstDependencies = try #require(firstFact["dependencies"] as? [[String: Any]])
        #expect(firstDependencies.contains { $0["scope"] as? String == "handler" })
        #expect(firstDependencies.contains { $0["scope"] as? String == "registration" })
        let dispatch = firstDependencies.first { dependency in
            guard let symbol = dependency["symbol"] as? [String: Any] else { return false }
            return symbol["usr"] as? String == "s:req"
        }
        let dependencySymbol = try #require(dispatch?["symbol"] as? [String: Any])
        #expect(dependencySymbol["qualifiedName"] as? String == "App.first()")
        let dispatchTargets = try #require(dispatch?["dispatchTargets"] as? [[String: Any]])
        #expect(dispatchTargets.contains { $0["usr"] as? String == "s:impl" })
        #expect(dispatchTargets.first?["qualifiedName"] as? String == "App.first()")
    }

    @Test("requirement부터 두 단계인 override 구현 후보를 모두 보존한다")
    func exportsTransitiveDispatchTargets() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp", line: 4, column: 20),
            end: .init(path: "/tmp", line: 5, column: 5), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/tmp", line: 2, column: 1),
            end: .init(path: "/tmp", line: 8, column: 1)
        )
        let symbols = [
            IndexedSymbol(usr: "s:setup", name: "install()", kind: .function, module: "App",
                location: .init(path: "/tmp", line: 2, column: 1)),
            IndexedSymbol(usr: "s:req", name: "run()", kind: .method, module: "App",
                location: .init(path: "/tmp", line: 10, column: 1)),
            IndexedSymbol(usr: "s:base", name: "run()", kind: .method, module: "App",
                location: .init(path: "/tmp", line: 11, column: 1)),
            IndexedSymbol(usr: "s:sub", name: "run()", kind: .method, module: "App",
                location: .init(path: "/tmp", line: 12, column: 1)),
        ]
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:req", kind: .call,
                location: .init(path: "/tmp", line: 4, column: 30)),
            IndexedReference(sourceUSR: "s:base", targetUSR: "s:req", kind: .overrides,
                location: .init(path: "/tmp", line: 11, column: 1)),
            IndexedReference(sourceUSR: "s:base", targetUSR: "s:req", kind: .overrides,
                location: .init(path: "/tmp", line: 11, column: 1)),
            IndexedReference(sourceUSR: "s:sub", targetUSR: "s:base", kind: .overrides,
                location: .init(path: "/tmp", line: 12, column: 1)),
        ])
        let fact = BridgeFact(
            kind: .messageHandle, target: .flutter, channel: "run", handlerScope: scope,
            location: .init(path: "/tmp", line: 4, column: 1)
        )
        let resolved = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp"]).resolve([
            ScannedBridgeFact(fact: fact, declaration: declaration)
        ]).first
        let targets = resolved?.dependencies?.first?.dispatchTargets.map(\.usr) ?? []
        #expect(targets == ["s:base", "s:sub"])
    }

    @Test("override 순환은 중단하고 참조 대상 방향의 후보만 반환한다")
    func dispatchTargetsRespectDirectionAndCycles() {
        let scope = BridgeFact.HandlerScope(
            start: .init(path: "/tmp", line: 4, column: 20),
            end: .init(path: "/tmp", line: 5, column: 5), complete: false
        )
        let declaration = EnclosingDeclaration(
            name: "install", indexName: "install()", qualifiedName: "P.install", line: 2,
            start: .init(path: "/tmp", line: 2, column: 1), end: .init(path: "/tmp", line: 8, column: 1)
        )
        let symbols = ["setup", "requirement", "base", "sub"].enumerated().map { index, name in
            IndexedSymbol(usr: "s:\(name)", name: index == 0 ? "install()" : "run()", kind: .method, module: "App",
                location: .init(path: "/tmp", line: index + 2, column: 1))
        }
        let refs = [
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:requirement", kind: .call,
                location: .init(path: "/tmp", line: 4, column: 30)),
            IndexedReference(sourceUSR: "s:base", targetUSR: "s:requirement", kind: .overrides),
            IndexedReference(sourceUSR: "s:sub", targetUSR: "s:base", kind: .overrides),
            IndexedReference(sourceUSR: "s:requirement", targetUSR: "s:sub", kind: .overrides),
        ]
        let fact = BridgeFact(kind: .messageHandle, target: .flutter, channel: "run", handlerScope: scope,
            location: .init(path: "/tmp", line: 4, column: 1))
        let resolved = BridgeSymbolResolver(snapshot: IndexSnapshot(symbols: symbols, references: refs), freshPaths: ["/tmp"])
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration)]).first
        #expect(resolved?.dependencies?.first?.dispatchTargets.map(\.usr) == ["s:base", "s:sub"])

        let reverse = BridgeFact(kind: .messageHandle, target: .flutter, channel: "base", handlerScope: scope,
            location: .init(path: "/tmp", line: 4, column: 1))
        let reverseReferences = [
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:base", kind: .call,
                location: .init(path: "/tmp", line: 4, column: 30)),
            refs[2],
        ]
        let reverseResolved = BridgeSymbolResolver(
            snapshot: IndexSnapshot(symbols: symbols, references: reverseReferences), freshPaths: ["/tmp"]
        )
            .resolve([ScannedBridgeFact(fact: reverse, declaration: declaration)]).first
        #expect(reverseResolved?.dependencies?.first?.dispatchTargets.map(\.usr) == ["s:sub"])
    }

    @Test("같은 setup의 MethodChannel closure는 Basic registration dependency로 섞이지 않는다")
    func excludesMethodHandlerClosureFromMessageRegistrationScope() throws {
        let source = """
            class P {
                static func install() {
                    FlutterMethodChannel(name: "method", binaryMessenger: m).setMethodCallHandler { _, _ in runtimeNativeValue() }
                    let basic = BasicMessageChannel<Any?>(name: "basic", binaryMessenger: m)
                    basic.setMessageHandler { _, _ in basicHelper() }
                }
            }
            """
        let setup = IndexedSymbol(usr: "s:setup", name: "install()", kind: .method, module: "App",
            location: .init(path: "/p/A.swift", line: 2, column: 5))
        let runtime = IndexedSymbol(usr: "s:runtime", name: "runtimeNativeValue()", kind: .function, module: "App",
            location: .init(path: "/p/A.swift", line: 8, column: 1))
        let helper = IndexedSymbol(usr: "s:helper", name: "basicHelper()", kind: .function, module: "App",
            location: .init(path: "/p/A.swift", line: 9, column: 1))
        let snapshot = IndexSnapshot(symbols: [setup, runtime, helper], references: [
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:runtime", kind: .call,
                location: .init(path: "/p/A.swift", line: 3, column: 110)),
            IndexedReference(sourceUSR: "s:setup", targetUSR: "s:helper", kind: .call,
                location: .init(path: "/p/A.swift", line: 5, column: 38)),
        ])
        let service = makeService(files: ["/p/A.swift": source], snapshot: snapshot)
        let data = Data(try service.exportBridgeFacts(target: .flutter, messages: true).output.utf8)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let facts = try #require(document["facts"] as? [[String: Any]])
        let basic = try #require(facts.first { $0["channel"] as? String == "basic" })
        let dependencies = try #require(basic["dependencies"] as? [[String: Any]])
        #expect(dependencies.contains { ($0["symbol"] as? [String: Any])?["usr"] as? String == "s:helper" })
        #expect(!dependencies.contains { ($0["symbol"] as? [String: Any])?["usr"] as? String == "s:runtime" })
    }

    @Test("case 본문의 참조는 그 메서드의 핸들러 의존으로만 귀속된다")
    func methodBranchScopesIsolateCaseDependencies() throws {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            class P {
                func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                    switch call.method {
                    case "a":
                        result(helperA())
                    case "b":
                        result(helperB())
                    default: break
                    }
                }
            }
            """
        let scanned = BridgeFactScanner().scan(source: source, path: "/tmp/m.swift")
        let a = try #require(scanned.facts.first { $0.fact.method == "a" }?.fact.handlerScope)
        let b = try #require(scanned.facts.first { $0.fact.method == "b" }?.fact.handlerScope)
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:handle", name: "handle(_:result:)", kind: .method, module: "P",
                location: .init(path: "/tmp/m.swift", line: 3, column: 10)),
            IndexedSymbol(usr: "s:a", name: "helperA()", kind: .function, module: "P",
                location: .init(path: "/tmp/m.swift", line: 20, column: 1)),
            IndexedSymbol(usr: "s:b", name: "helperB()", kind: .function, module: "P",
                location: .init(path: "/tmp/m.swift", line: 21, column: 1)),
            IndexedSymbol(usr: "s:shared", name: "shared()", kind: .function, module: "P",
                location: .init(path: "/tmp/m.swift", line: 22, column: 1)),
        ], references: [
            // 절 본문 안의 호출은 그 메서드의 근거, switch 머리의 호출은 공통 등록 근거다.
            IndexedReference(sourceUSR: "s:handle", targetUSR: "s:a", kind: .call,
                location: .init(path: a.start.path, line: a.start.line + 1, column: 9)),
            IndexedReference(sourceUSR: "s:handle", targetUSR: "s:b", kind: .call,
                location: .init(path: b.start.path, line: b.start.line + 1, column: 9)),
            IndexedReference(sourceUSR: "s:handle", targetUSR: "s:shared", kind: .call,
                location: .init(path: "/tmp/m.swift", line: 4, column: 9)),
        ])
        let resolved = BridgeSymbolResolver(snapshot: snapshot, freshPaths: ["/tmp/m.swift"])
            .resolve(scanned.facts, handlerScopes: scanned.handlerScopes)
        let factA = try #require(resolved.first { $0.method == "a" })
        let factB = try #require(resolved.first { $0.method == "b" })
        #expect(factA.handlerScope?.complete == true)
        #expect(factB.handlerScope?.complete == true)
        #expect(factA.dependencies?.filter { $0.scope == .handler }.map(\.symbol.usr) == ["s:a"])
        #expect(factB.dependencies?.filter { $0.scope == .handler }.map(\.symbol.usr) == ["s:b"])
        #expect(factA.dependencies?.filter { $0.scope == .registration }.map(\.symbol.usr) == ["s:shared"])
        #expect(factB.dependencies?.filter { $0.scope == .registration }.map(\.symbol.usr) == ["s:shared"])
    }

    @Test("--events 문서는 stream-handle 사실만 v2 event-channel로 낸다")
    func eventsDocumentCarriesOnlyStreamHandles() throws {
        let service = makeService(files: ["/p/A.swift": """
            class P {
                static func register(messenger: FlutterBinaryMessenger) {
                    let events = FlutterEventChannel(name: "com.example/charging", binaryMessenger: messenger)
                    events.setStreamHandler(BatteryPlusChargingHandler())
                    let channel = FlutterMethodChannel(name: "com.example/battery", binaryMessenger: messenger)
                    channel.setMethodCallHandler { call, result in
                        switch call.method { case "getBatteryLevel": result(1) default: break }
                    }
                }
            }
            """], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(events: true)
        #expect(document.version == BridgeFactsDocument.messageVersion)
        #expect(document.transport == "event-channel")
        #expect(document.facts.map(\.kind) == ["stream-handle"])
        #expect(document.facts.first?.channel == "com.example/charging")
        #expect(document.facts.first?.method == nil)
    }

    @Test("events 문서도 자신의 관측 공백을 싣는다")
    func eventsDocumentCarriesCoverageCounts() throws {
        let service = makeService(files: [
            "/p/A.swift": "let events = FlutterEventChannel(name: \"e\", binaryMessenger: m)\n",
            "/p/Native.m": "void forward(void) {}\n",
        ], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(generatedAt: fixedDate, events: true)
        #expect(document.transport == "event-channel")
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-event-channels: 1") })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-sources: 1") })
    }

    @Test("messages와 events를 함께 켜면 문서를 만들지 않고 설정 오류로 거절한다")
    func rejectsMessagesAndEventsTogether() throws {
        let service = makeService(files: ["/p/A.swift": "struct A {}"], snapshot: IndexSnapshot())
        #expect(throws: CartographError.self) {
            try service.bridgeFacts(messages: true, events: true)
        }
    }

    @Test("closure 없는 Basic method reference는 명시적인 limitation을 남긴다")
    func reportsUnscopedMessageHandler() {
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "t", project: "/p",
            facts: [BridgeFact(kind: .messageHandle, target: .flutter, channel: "c",
                handlerScope: nil, dependencies: nil,
                location: .init(path: "/p/A.swift", line: 1, column: 1), symbol: .init(qualifiedName: "P.install", usr: "s:p"))],
            version: BridgeFactsDocument.messageVersion, transport: "basic-message-channel"
        )
        #expect(document.limitations.contains { $0.hasPrefix("unscoped-message-handlers: 1") })
    }

    @Test("채널을 모르면 키를 빼지 않고 null 로 적는다")
    func encodesUnknownChannelAsNull() throws {
        let fact = BridgeFact(
            kind: .methodHandle,
            target: .flutter,
            channel: nil,
            method: "ping",
            location: SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        )
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "0"), generatedAt: "t", project: "/p", facts: [fact]
        )
        let json = try CartographService.encodeSortedJSON(document)
        #expect(json.contains("\"channel\" : null"))
        #expect(!json.contains("\"symbol\""))
        #expect(document.limitations.contains { $0.hasPrefix("unattributed-method-handles: 1") })
    }

    @Test("경로 필터 밖의 소스는 훑지 않는다")
    func respectsPathFilter() throws {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.exclude = ["**/Vendor/**"]
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: ["/p/Vendor/Plugin.swift": Self.pluginSource]),
                indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )
        #expect(try service.bridgeFacts(generatedAt: fixedDate).facts.isEmpty)
    }

    @Test("텍스트 형식은 사실마다 한 줄이고 요약으로 끝난다")
    func rendersText() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let text = try service.exportBridgeFacts(generatedAt: fixedDate, asText: true).output
        #expect(text.contains("Sources/CameraPlugin.swift:9:14  method-handle  channel=com.example/camera  method=takePhoto  s:handle"))
        #expect(text.contains("2 bridge fact(s) · target flutter\n"))
    }
}

// realPath의 기본 미지원 구현을 쓰는 기존 임베드 소비자를 재현한다.
private struct UnsupportedRealPathFileSystem: FileSystem {
    private let backing = InMemoryFileSystem(currentDirectoryPath: "/p", files: ["/p/A.swift": "struct A {}"])
    var currentDirectoryPath: String { backing.currentDirectoryPath }
    func fileExists(at path: String) -> Bool { backing.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { backing.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try backing.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try backing.write(data, to: path) }
    func removeItem(at path: String) throws { try backing.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try backing.contentsOfDirectory(at: path) }
}
