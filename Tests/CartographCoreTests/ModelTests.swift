import CartographCore
import Foundation
import Testing

@Suite("도메인 모델")
struct ModelTests {
    @Test("NodeID 는 문자열로 직렬화된다")
    func nodeIDCodable() throws {
        let id = NodeID("s:3App3FooV")
        let data = try JSONEncoder().encode(["id": id])
        let decoded = try JSONDecoder().decode([String: NodeID].self, from: data)
        #expect(decoded["id"] == id)
        #expect(id.description == "s:3App3FooV")
    }

    @Test("GraphLevel 은 거친 순서대로 정렬된다")
    func graphLevelOrdering() {
        #expect(GraphLevel.module < .file)
        #expect(GraphLevel.file < .type)
        #expect(GraphLevel.type < .symbol)
        #expect(GraphLevel.allCases.count == 4)
    }

    @Test("SymbolKind 는 타입/추상/멤버를 구분한다")
    func symbolKindClassification() {
        #expect(SymbolKind.classType.isTypeDeclaration)
        #expect(SymbolKind.protocolType.isTypeDeclaration)
        #expect(!SymbolKind.method.isTypeDeclaration)
        #expect(SymbolKind.protocolType.isAbstract)
        #expect(SymbolKind.associatedType.isAbstract)
        #expect(!SymbolKind.structType.isAbstract)
        #expect(SymbolKind.property.isMember)
        #expect(!SymbolKind.function.isMember)
    }

    @Test("Accessibility 는 노출이 넓을수록 작다")
    func accessibilityOrdering() {
        #expect(Accessibility.openLevel < .publicLevel)
        #expect(Accessibility.publicLevel < .internalLevel)
        #expect(Accessibility.internalLevel < .privateLevel)
        #expect(Accessibility.openLevel.isExposedOutsideModule)
        #expect(Accessibility.publicLevel.isExposedOutsideModule)
        #expect(!Accessibility.packageLevel.isExposedOutsideModule)
    }

    @Test("Accessibility 는 제어자 문자열에서 만들어진다")
    func accessibilityFromModifier() {
        #expect(Accessibility(modifierName: "fileprivate") == .fileprivateLevel)
        #expect(Accessibility(modifierName: "package") == .packageLevel)
        #expect(Accessibility(modifierName: "nonsense") == nil)
    }

    @Test("SourceLocation 은 상대 경로로 바꿀 수 있다")
    func sourceLocationRelative() {
        let location = SourceLocation(path: "/project/Sources/A.swift", line: 12, column: 3)
        #expect(location.relative(to: "/project").path == "Sources/A.swift")
        #expect(location.relative(to: "/project/").path == "Sources/A.swift")
        #expect(location.relative(to: "/other").path == "/project/Sources/A.swift")
        #expect(location.description == "/project/Sources/A.swift:12:3")
    }

    @Test("EdgeKind 는 사용 의미와 순환 참여 여부를 구분한다")
    func edgeKindSemantics() {
        #expect(EdgeKind.call.impliesUsage)
        #expect(!EdgeKind.member.impliesUsage)
        #expect(EdgeKind.inheritance.participatesInCycles)
        #expect(!EdgeKind.member.participatesInCycles)
        #expect(!EdgeKind.retention.participatesInCycles)
    }

    @Test("GraphNode 는 모듈 접두사를 붙인 이름을 만든다")
    func qualifiedName() {
        let node = GraphNode(id: "u", name: "Foo", kind: .structType, module: "App")
        #expect(node.qualifiedName == "App.Foo")
        let moduleNode = GraphNode(id: "App", name: "App", kind: .module, module: "App")
        #expect(moduleNode.qualifiedName == "App")
    }

    @Test("GraphNode 의 속성은 정렬되어 직렬화된다")
    func graphNodeAttributesAreSorted() throws {
        let node = GraphNode(
            id: "u",
            name: "Foo",
            kind: .classType,
            attributes: [.objc, .entryPoint, .implicit]
        )
        let data = try JSONEncoder().encode(node)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(GraphNode.self, from: data)
        #expect(decoded == node)
        // entryPoint < implicit < objc (rawValue 사전순)
        #expect(json.contains("\"entryPoint\",\"implicit\",\"objc\""))
    }
}

@Suite("심볼 이름 정규화")
struct SymbolNameTests {
    @Test("인자 목록을 뗀 이름을 제공한다")
    func baseNameStripsArgumentList() {
        // 인덱스는 함수 이름을 main(), describe(_:) 처럼 인자 라벨까지 붙여 준다.
        // 이름으로 규칙을 거는 쪽에서는 그 꼬리가 늘 걸림돌이 된다.
        #expect(GraphNode(id: "a", name: "main()", kind: .method).baseName == "main")
        #expect(GraphNode(id: "a", name: "describe(_:)", kind: .method).baseName == "describe")
        #expect(GraphNode(id: "a", name: "buildBlock(_:)", kind: .method).baseName == "buildBlock")
        #expect(GraphNode(id: "a", name: "wrappedValue", kind: .property).baseName == "wrappedValue")
    }
}
