@testable import CartographAnalysis
import CartographCore
import Testing

@Suite("런타임 발견 이름 색인")
struct RuntimeDiscoveryIndexTests {
    private static let path = "/p/App.swift"
    private static let storyboard = "/p/Main.storyboard"
    private static let model = "/p/Model.xcdatamodel/contents"

    @Test("이름으로 찾는 경계는 관계없는 선언을 두 배로 늘려도 같은 수의 선언만 살펴보고 같은 답을 낸다")
    func lookupWorkDoesNotGrowWithUnrelatedDeclarations() {
        let small = Self.resolveNamedBoundaries(fillers: 100)
        let large = Self.resolveNamedBoundaries(fillers: 200)
        #expect(small.examined == large.examined)
        #expect(small.findings == large.findings)
        // outlet, customClass, KVC, key path, 클래스 조회, selector 호출, Core Data entity 순서다.
        #expect(small.findings.map(\.status) == Array(repeating: .resolved, count: 7))
        #expect(small.findings.map(\.targets) == [
            ["title"], ["screen"], ["title"], ["title"], ["screen"], ["open"], ["entity"],
        ].map { $0.map { NodeID($0) } })
    }

    @Test("여러 모듈의 동명 클래스와 프로퍼티는 모두 후보로 내고, 한정 이름과 ObjC 별칭은 하나를 고른다")
    func sameNamedDeclarationsKeepDeclarationOrder() {
        // 선언 순서(B 가 먼저)와 식별자 순서(a 가 먼저)를 일부러 다르게 둔다. 답의 후보는 식별자 순이다.
        let ambiguousClass = Self.resolveModules(Self.customClass("Shared", line: 1))
        #expect(ambiguousClass.status == .ambiguous)
        #expect(ambiguousClass.candidates == [NodeID("a-shared"), NodeID("z-shared")])
        let qualified = Self.resolveModules(Self.customClass("A.Shared", line: 2))
        #expect(qualified.targets == [NodeID("a-shared")])
        // 수신자가 모호한 outlet 은 그 이름의 프로퍼티를 모두 후보로 낸다.
        let ambiguousOutlet = Self.resolveModules(.init(
            kind: .interfaceBuilderOutlet, api: "outlet", location: .init(path: Self.storyboard, line: 3, column: 1),
            name: "label", nameOrigin: .resource, receiverTypeName: "Shared", receiverOrigin: .enclosingType,
            receiverTypeLocation: .init(path: Self.storyboard, line: 3, column: 1), targetMemberName: "label",
            resourceObjectID: "three"
        ))
        #expect(ambiguousOutlet.status == .ambiguous)
        #expect(ambiguousOutlet.candidates == [NodeID("a-label"), NodeID("z-label")])
        // ObjC 별칭으로는 찾고, 별칭이 있는 클래스의 Swift 이름만으로는 런타임 이름이 아니다.
        #expect(Self.resolveModules(Self.classLookup("LegacyName")).targets == [NodeID("renamed")])
        #expect(Self.resolveModules(Self.classLookup("A.Renamed")).targets == [NodeID("renamed")])
        #expect(Self.resolveModules(Self.classLookup("Renamed")).status == .unresolved)
    }

    @Test("정확한 선언 참조가 있는 selector 등록은 이름과 ObjC 이름이 달라도 참조한 메서드를 고른다")
    func directReferenceSelectsReferencedMethod() {
        let finding = Self.resolveDirectReference()
        #expect(finding.status == .resolved)
        #expect(finding.targets == [NodeID("plain")])
    }

    /// ObjC 이름 없는 메서드를 `#selector` 처럼 정확히 참조하는 등록 하나를 해석한다.
    private static func resolveDirectReference() -> RuntimeDiscoveryFinding {
        let caller = IndexedSymbol(usr: "caller", name: "use()", kind: .function, module: "App", location: location(1))
        let owner = IndexedSymbol(usr: "screen", name: "Screen", kind: .classType, module: "App",
                                  location: location(10))
        let method = IndexedSymbol(usr: "plain", name: "plain()", kind: .method, module: "App",
                                   location: location(11), parentUSR: "screen")
        let snapshot = IndexSnapshot(symbols: [caller, owner, method], references: [
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)UIControl(im)addTarget:action:forControlEvents:",
                  kind: .call, location: location(2, 5)),
            .init(sourceUSR: "caller", targetUSR: "plain", kind: .reference, location: location(2, 30)),
        ])
        let declarations: [RuntimeDeclaration] = [
            .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                  location: location(10), endLocation: location(12)),
            .init(name: "plain", indexName: "plain()", qualifiedName: "Screen.plain", kind: .method,
                  location: location(11), endLocation: location(11), parentLocation: location(10),
                  isTypeMember: true),
        ]
        let boundary = RuntimeBoundary(
            kind: .selectorRegistration, api: "addTarget", location: location(2), calleeLocation: location(2, 5),
            name: "differentName", nameOrigin: .literal, receiverTypeName: "Screen", receiverOrigin: .explicitTarget,
            referencedTargetLocation: location(2, 30)
        )
        let report = RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: declarations, boundaries: [boundary])], snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh]
        )
        return report.findings[0]
    }

    /// 이름으로 찾는 경계 일곱 가지를 관계없는 클래스 `fillers` 개와 함께 해석하고, 술어를 적용한 선언 수를 센다.
    private static func resolveNamedBoundaries(
        fillers: Int
    ) -> (findings: [RuntimeDiscoveryFinding], examined: Int) {
        var symbols: [IndexedSymbol] = [
            .init(usr: "caller", name: "use()", kind: .function, module: "App", location: location(1)),
            .init(usr: "screen", name: "Screen", kind: .classType, module: "App", location: location(10)),
            .init(usr: "title", name: "titleLabel", kind: .property, module: "App", location: location(11),
                  parentUSR: "screen", attributes: [.objc]),
            .init(usr: "open", name: "open()", kind: .method, module: "App", location: location(12),
                  parentUSR: "screen", attributes: [.objc]),
            .init(usr: "entity", name: "Entity", kind: .classType, module: "App", location: location(20)),
        ]
        var references: [IndexedReference] = [
            .init(sourceUSR: "screen", targetUSR: "c:objc(cs)NSObject", kind: .inheritance),
            .init(sourceUSR: "entity", targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSObject(im)valueForKey:", kind: .call,
                  location: location(2, 5)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSObject(im)valueForKeyPath:", kind: .call,
                  location: location(3, 5)),
            .init(sourceUSR: "caller", targetUSR: "c:@F@NSClassFromString", kind: .call, location: location(4, 5)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSObject(im)performSelector:", kind: .call,
                  location: location(5, 5)),
        ]
        var declarations = screenDeclarations()
        for ordinal in 0..<fillers {
            let filler = filler(ordinal)
            symbols += filler.symbols
            references.append(
                .init(sourceUSR: "filler\(ordinal)", targetUSR: "c:objc(cs)NSObject", kind: .inheritance)
            )
            declarations += filler.declarations
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: references)
        var examined = 0
        let index = RuntimeDiscoveryIndex(
            files: [.init(path: path, declarations: declarations)], snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh],
            onExamine: { examined += $0 }
        )
        let findings = namedBoundaries().map { index.resolve($0) }
        return (findings, examined)
    }

    private static func screenDeclarations() -> [RuntimeDeclaration] {
        [
            .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                  location: location(10), endLocation: location(15), objectiveCName: "Screen", attributes: [.objc],
                  isFinal: true),
            .init(name: "titleLabel", indexName: "titleLabel", qualifiedName: "Screen.titleLabel", kind: .property,
                  location: location(11), endLocation: location(11), parentLocation: location(10),
                  objectiveCName: "titleLabel", attributes: [.objc], isTypeMember: true, isSettable: true),
            .init(name: "open", indexName: "open()", qualifiedName: "Screen.open", kind: .method,
                  location: location(12), endLocation: location(13), parentLocation: location(10),
                  objectiveCName: "open", attributes: [.objc], isTypeMember: true),
            .init(name: "Entity", indexName: "Entity", qualifiedName: "Entity", kind: .classType,
                  location: location(20), endLocation: location(25)),
        ]
    }

    /// 이름이 겹치지 않는 NSObject 하위 클래스 하나와 그 ObjC 프로퍼티·메서드.
    private static func filler(_ ordinal: Int) -> (symbols: [IndexedSymbol], declarations: [RuntimeDeclaration]) {
        let line = 100 + 3 * ordinal
        let usr = "filler\(ordinal)"
        let symbols: [IndexedSymbol] = [
            .init(usr: usr, name: "Filler\(ordinal)", kind: .classType, module: "App", location: location(line)),
            .init(usr: usr + "-fill", name: "fill\(ordinal)", kind: .property, module: "App",
                  location: location(line + 1), parentUSR: usr, attributes: [.objc]),
            .init(usr: usr + "-run", name: "run\(ordinal)()", kind: .method, module: "App",
                  location: location(line + 2), parentUSR: usr, attributes: [.objc]),
        ]
        let owner = "Filler\(ordinal)"
        let declarations: [RuntimeDeclaration] = [
            .init(name: owner, indexName: owner, qualifiedName: owner, kind: .classType, location: location(line),
                  endLocation: location(line + 2), objectiveCName: owner, attributes: [.objc], isFinal: true),
            .init(name: "fill\(ordinal)", indexName: "fill\(ordinal)", qualifiedName: "\(owner).fill\(ordinal)",
                  kind: .property, location: location(line + 1), endLocation: location(line + 1),
                  parentLocation: location(line), objectiveCName: "fill\(ordinal)", attributes: [.objc],
                  isTypeMember: true, isSettable: true),
            .init(name: "run\(ordinal)", indexName: "run\(ordinal)()", qualifiedName: "\(owner).run\(ordinal)",
                  kind: .method, location: location(line + 2), endLocation: location(line + 2),
                  parentLocation: location(line), objectiveCName: "run\(ordinal)", attributes: [.objc],
                  isTypeMember: true),
        ]
        return (symbols, declarations)
    }

    /// outlet, customClass, KVC 읽기, key path 읽기, 클래스 조회, selector 호출, Core Data entity.
    private static func namedBoundaries() -> [RuntimeBoundary] {
        let resource = CartographCore.SourceLocation(path: storyboard, line: 4, column: 1)
        return [
            .init(kind: .interfaceBuilderOutlet, api: "outlet", location: .init(path: storyboard, line: 5, column: 1),
                  name: "titleLabel", nameOrigin: .resource, receiverTypeName: "Screen",
                  receiverOrigin: .enclosingType, receiverTypeLocation: resource, targetMemberName: "titleLabel",
                  resourceObjectID: "screen"),
            .init(kind: .interfaceBuilderClass, api: "customClass", location: resource, name: "Screen",
                  nameOrigin: .resource, receiverTypeName: "Screen", receiverOrigin: .annotation,
                  receiverTypeLocation: resource, resourceObjectID: "screen"),
            .init(kind: .keyValueRead, api: "value", location: location(2), calleeLocation: location(2, 5),
                  name: "titleLabel", nameOrigin: .literal, receiverTypeName: "App.Screen",
                  receiverOrigin: .annotation),
            .init(kind: .keyPathRead, api: "value", location: location(3), calleeLocation: location(3, 5),
                  name: "titleLabel", nameOrigin: .literal, receiverTypeName: "App.Screen", receiverOrigin: .annotation,
                  keyPaths: ["titleLabel"]),
            classLookup("Screen"),
            .init(kind: .selectorInvocation, api: "perform", location: location(5), calleeLocation: location(5, 5),
                  name: "open", nameOrigin: .literal, receiverTypeName: "Screen", receiverOrigin: .construction),
            .init(kind: .coreDataEntityClass, api: "representedClassName",
                  location: .init(path: model, line: 2, column: 1), name: "App.Entity", nameOrigin: .resource,
                  receiverTypeName: "App.Entity", receiverOrigin: .annotation, resourceObjectID: "Entity"),
        ]
    }

    /// 수신 타입 이름만 다른 storyboard customClass 경계. 그 위치에는 컴파일러 참조가 없다.
    private static func customClass(_ receiver: String, line: Int) -> RuntimeBoundary {
        let location = CartographCore.SourceLocation(path: storyboard, line: line, column: 1)
        return .init(kind: .interfaceBuilderClass, api: "customClass", location: location, name: "Shared",
                     nameOrigin: .resource, receiverTypeName: receiver, receiverOrigin: .annotation,
                     receiverTypeLocation: location, resourceObjectID: "object\(line)")
    }

    private static func classLookup(_ name: String) -> RuntimeBoundary {
        .init(kind: .classLookup, api: "NSClassFromString", location: location(4), calleeLocation: location(4, 5),
              name: name, nameOrigin: .literal)
    }

    /// 모듈 B·A 에 같은 이름 `Shared`(프로퍼티 `label` 포함)를, A 에 ObjC 별칭 `LegacyName` 인 `Renamed` 를 둔다.
    private static func resolveModules(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        var symbols: [IndexedSymbol] = [
            .init(usr: "caller", name: "use()", kind: .function, module: "A", location: location(1)),
        ]
        var declarations: [RuntimeDeclaration] = []
        for (prefix, module, line) in [("z", "B", 10), ("a", "A", 20)] {
            symbols += [
                .init(usr: "\(prefix)-shared", name: "Shared", kind: .classType, module: module,
                      location: location(line)),
                .init(usr: "\(prefix)-label", name: "label", kind: .property, module: module,
                      location: location(line + 1), parentUSR: "\(prefix)-shared", attributes: [.objc]),
            ]
            declarations += [
                .init(name: "Shared", indexName: "Shared", qualifiedName: "Shared", kind: .classType,
                      location: location(line), endLocation: location(line + 5)),
                .init(name: "label", indexName: "label", qualifiedName: "Shared.label", kind: .property,
                      location: location(line + 1), endLocation: location(line + 1), parentLocation: location(line),
                      objectiveCName: "label", attributes: [.objc], isTypeMember: true, isSettable: true),
            ]
        }
        symbols.append(.init(usr: "renamed", name: "Renamed", kind: .classType, module: "A", location: location(30)))
        declarations.append(.init(name: "Renamed", indexName: "Renamed", qualifiedName: "Renamed", kind: .classType,
                                  location: location(30), endLocation: location(35), objectiveCName: "LegacyName",
                                  attributes: [.objc]))
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            .init(sourceUSR: "caller", targetUSR: "c:@F@NSClassFromString", kind: .call, location: location(4, 5)),
        ])
        let report = RuntimeDiscoveryResolver().resolve(
            files: [.init(path: path, declarations: declarations, boundaries: [boundary])], snapshot: snapshot,
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot), freshness: [path: .fresh]
        )
        return report.findings[0]
    }

    private static func location(_ line: Int, _ column: Int = 1) -> CartographCore.SourceLocation {
        .init(path: path, line: line, column: column)
    }
}
