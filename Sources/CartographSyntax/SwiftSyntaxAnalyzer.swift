import CartographCore
import Foundation
import SwiftParser
import SwiftSyntax

/// Swift 소스를 구문 분석해 선언의 접근 수준과 속성을 읽어낸다.
///
/// 인덱스 스토어만으로는 `public` 여부도, `@objc` 여부도 알 수 없다.
/// Periphery 가 인덱스와 SwiftSyntax 를 함께 쓴 것과 같은 이유다.
/// 이 타입은 파일 내용만 입력으로 받으므로 문자열 리터럴로 완전히 테스트된다.
public struct SwiftSyntaxAnalyzer: Sendable {
    /// XCTestCase 외에 테스트 기반 클래스로 볼 이름들.
    ///
    /// 팀마다 `BaseTestCase` 같은 공통 상위 클래스를 두고, 그것이 다른 모듈에 있어
    /// 상속 관계를 인덱스에서 따라갈 수 없는 경우가 흔하다.
    private let externalTestCaseClasses: Set<String>

    public init(externalTestCaseClasses: [String] = []) {
        self.externalTestCaseClasses = Set(externalTestCaseClasses)
    }

    public func analyze(source: String, path: String) -> SourceFileFacts {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = DeclarationCollector(
            converter: converter,
            testCaseBaseClasses: externalTestCaseClasses.union(["XCTestCase"])
        )
        collector.walk(tree)
        return SourceFileFacts(
            path: path,
            declarations: collector.declarations,
            ignoresEntireFile: Self.fileIsIgnored(tree)
        )
    }

    /// 파일 첫머리 주석에 `cartograph:ignore:all` 이 있는지 확인한다.
    private static func fileIsIgnored(_ tree: SourceFileSyntax) -> Bool {
        commentLines(in: tree.leadingTrivia).contains { CommentCommand.parse(comment: $0) == .ignoreAll }
    }

    /// 트리비아에서 주석 텍스트만 뽑아 낸다.
    static func commentLines(in trivia: Trivia) -> [String] {
        trivia.compactMap { piece in
            switch piece {
            case let .lineComment(text), let .blockComment(text),
                 let .docLineComment(text), let .docBlockComment(text):
                text
            default:
                nil
            }
        }
    }
}

/// 선언을 훑으면서 접근 수준과 속성을 모은다.
///
/// 접근 수준과 `@objcMembers` 는 바깥 선언에서 안쪽으로 흘러내리므로
/// 문맥 스택으로 관리한다.
final class DeclarationCollector: SyntaxVisitor {
    /// 바깥 선언에서 상속되는 문맥.
    private struct Context {
        /// 명시적 제어자가 없을 때 적용할 접근 수준.
        var accessibility: Accessibility
        /// `@objcMembers` 타입 내부인지 여부.
        var inheritsObjectiveCExposure: Bool
        /// `cartograph:ignore` 가 걸린 선언 내부인지 여부.
        var isIgnored: Bool
        /// XCTest 메서드가 있을 수 있는 본문 안인지 여부.
        ///
        /// 클래스와 익스텐션이 해당한다. 익스텐션은 확장 대상이 클래스인지
        /// 구문만으로는 알 수 없으니 포함한다. 테스트를 미사용으로 보고하는 쪽이
        /// 제품 코드를 남겨 두는 쪽보다 훨씬 비싸다.
        var allowsTestMethods: Bool
    }

    private(set) var declarations: [DeclarationFacts] = []
    private var contexts: [Context] = [
        Context(
            accessibility: .internalLevel,
            inheritsObjectiveCExposure: false,
            isIgnored: false,
            allowsTestMethods: false
        )
    ]
    private let converter: SourceLocationConverter
    private let testCaseBaseClasses: Set<String>

    init(converter: SourceLocationConverter, testCaseBaseClasses: Set<String>) {
        self.converter = converter
        self.testCaseBaseClasses = testCaseBaseClasses
        super.init(viewMode: .sourceAccurate)
    }

    private var context: Context { contexts[contexts.count - 1] }

    // MARK: - 타입 선언

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        if node.genericParameterClause != nil { attributes.insert(.generic) }
        if isTestCase(node.inheritanceClause) { attributes.insert(.unitTest) }
        return push(
            name: node.name.text,
            node: node,
            attributes: attributes,
            modifiers: node.modifiers,
            allowsTestMethods: true
        )
    }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        if node.genericParameterClause != nil { attributes.insert(.generic) }
        return push(name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers)
    }
    override func visitPost(_ node: StructDeclSyntax) { pop() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: true))
        return push(name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers)
    }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { pop() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        return push(name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers)
    }
    override func visitPost(_ node: ActorDeclSyntax) { pop() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        return push(
            name: node.extendedType.trimmedDescription,
            node: node,
            attributes: attributes,
            modifiers: node.modifiers,
            allowsTestMethods: true
        )
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    // MARK: - 멤버 선언

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        if node.genericParameterClause != nil { attributes.insert(.generic) }
        if context.allowsTestMethods, Self.isXCTestMethod(node, modifiers: node.modifiers) {
            attributes.insert(.unitTest)
        }
        return push(name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers)
    }
    override func visitPost(_ node: FunctionDeclSyntax) { pop() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: "init", node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
    }
    override func visitPost(_ node: InitializerDeclSyntax) { pop() }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        // 연산자는 인덱스에 심볼로 남지만 구문 쪽에 대응이 없어, public 연산자가
        // internal 로 분석되어 미사용으로 보고됐다. 문맥은 쌓지 않는다.
        // 연산자 선언에는 접근 제어자가 붙지 않으므로 빈 목록을 넘긴다.
        record(name: node.name.text, node: node, attributes: [], modifiers: DeclModifierListSyntax([]))
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        push(name: "deinit", node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) { pop() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        if node.parameterClause.parameters.first?.firstName.text == "dynamicMember" {
            attributes.insert(.dynamicMemberLookup)
        }
        return push(name: "subscript", node: node, attributes: attributes, modifiers: node.modifiers)
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { pop() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = commonAttributes(node)
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            record(name: pattern.identifier.text, node: node, attributes: attributes, modifiers: node.modifiers)
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = commonAttributes(node)
        for element in node.elements {
            record(name: element.name.text, node: node, attributes: attributes, modifiers: node.modifiers)
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers)
        return .visitChildren
    }

    // MARK: - 공통 처리

    /// 선언을 기록하고 문맥을 쌓는다.
    private func push(
        name: String,
        node: some SyntaxProtocol,
        attributes: Set<SymbolAttribute>,
        modifiers: DeclModifierListSyntax,
        allowsTestMethods: Bool = false
    ) -> SyntaxVisitorContinueKind {
        let resolved = record(name: name, node: node, attributes: attributes, modifiers: modifiers)
        contexts.append(
            Context(
                accessibility: resolved.accessibility,
                inheritsObjectiveCExposure: context.inheritsObjectiveCExposure
                    || resolved.attributes.contains(.objcMembers),
                isIgnored: resolved.attributes.contains(.ignoreComment),
                allowsTestMethods: allowsTestMethods
            )
        )
        return .visitChildren
    }

    private func pop() {
        if contexts.count > 1 { contexts.removeLast() }
    }

    /// 백틱으로 감싼 식별자에서 백틱을 뗀다.
    static func unescaped(_ name: String) -> String {
        guard name.hasPrefix("`"), name.hasSuffix("`"), name.count > 1 else { return name }
        return String(name.dropFirst().dropLast())
    }

    /// 함수 본문이나 접근자, 클로저 안의 지역 선언인지 확인한다.
    ///
    /// 지역 선언은 인덱스가 `.local` 로 걸러 내 정점이 되지 않는다. 그런데도 구문
    /// 정보로 남겨 두면, 이름이 같은 멤버를 찾을 때 줄 번호가 더 가깝다는 이유로
    /// 지역 변수의 정보가 멤버에 붙을 수 있다. public 프로퍼티가 internal 이 되거나,
    /// 지역 변수에 단 무시 주석이 멤버와 그 하위 전체를 덮는다.
    static func isInsideBody(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let syntax = current {
            // 계산 프로퍼티의 암시적 게터는 CodeBlock 이 아니라 AccessorBlock 아래에 있다.
            if syntax.is(CodeBlockSyntax.self)
                || syntax.is(AccessorBlockSyntax.self)
                || syntax.is(AccessorDeclSyntax.self)
                || syntax.is(ClosureExprSyntax.self) {
                return true
            }
            current = syntax.parent
        }
        return false
    }

    @discardableResult
    private func record(
        name: String,
        node: some SyntaxProtocol,
        attributes: Set<SymbolAttribute>,
        modifiers: DeclModifierListSyntax
    ) -> DeclarationFacts {
        var resolved = attributes
        if context.inheritsObjectiveCExposure { resolved.insert(.objcAccessible) }
        if context.isIgnored { resolved.insert(.ignoreComment) }
        if modifiers.contains(where: { $0.name.text == "override" }) { resolved.insert(.overrideDeclaration) }
        if modifiers.contains(where: { $0.name.text == "dynamic" }) { resolved.insert(.dynamicDispatch) }

        let facts = DeclarationFacts(
            // SwiftSyntax 는 `` `default` `` 의 백틱까지 이름에 담지만 인덱스는 담지 않는다.
            name: Self.unescaped(name),
            line: node.startLocation(converter: converter).line,
            accessibility: accessibility(from: modifiers),
            attributes: resolved
        )
        // 지역 선언은 정점이 되지 않으므로 기록하지 않는다. 남겨 두면 이름이 같은
        // 멤버를 찾을 때 이쪽이 더 가깝다는 이유로 선택될 수 있다.
        if !Self.isInsideBody(node) { declarations.append(facts) }
        return facts
    }

    /// 명시적 제어자가 없으면 바깥 문맥의 접근 수준을 물려받는다.
    private func accessibility(from modifiers: DeclModifierListSyntax) -> Accessibility {
        for modifier in modifiers {
            if let level = Accessibility(modifierName: modifier.name.text) { return level }
        }
        // 바깥이 public 이라고 해서 안쪽이 자동으로 public 이 되지는 않지만,
        // private/fileprivate 로 감싸면 안쪽은 그보다 넓어질 수 없다.
        return context.accessibility > .internalLevel ? context.accessibility : .internalLevel
    }

    /// 속성 목록과 주석에서 공통 표식을 읽는다.
    ///
    /// 주석은 선언 위와 줄 끝 양쪽을 본다. 줄 끝 주석은 SwiftSyntax 에서 그 선언의
    /// 후행 트리비아에 들어가므로 앞 트리비아만 읽으면 조용히 무시된다.
    /// 사용자는 무시했다고 믿는데 그대로 미사용으로 보고되는 상황이 된다.
    private func commonAttributes(_ node: some WithAttributesSyntax & SyntaxProtocol) -> Set<SymbolAttribute> {
        var result = Self.attributes(from: node.attributes)
        let comments = SwiftSyntaxAnalyzer.commentLines(in: node.leadingTrivia)
            + SwiftSyntaxAnalyzer.commentLines(in: node.trailingTrivia)
        if comments.contains(where: { CommentCommand.parse(comment: $0) != nil }) {
            result.insert(.ignoreComment)
        }
        return result
    }

    /// XCTest 가 실제로 실행하는 메서드인지 판단한다.
    ///
    /// 이름만 보면 `struct Pipeline { func testData() -> Data }` 같은 제품 코드가
    /// 테스트로 잡혀 영원히 보존된다. XCTest 는 인스턴스 메서드 중 인자가 없고
    /// 값을 돌려주지 않는 `test` 접두사 메서드만 실행한다.
    static func isXCTestMethod(_ node: FunctionDeclSyntax, modifiers: DeclModifierListSyntax) -> Bool {
        guard node.name.text.hasPrefix("test"),
              node.signature.parameterClause.parameters.isEmpty,
              node.genericParameterClause == nil,
              !modifiers.contains(where: { ["static", "class"].contains($0.name.text) })
        else { return false }
        guard let returnClause = node.signature.returnClause else { return true }
        return ["Void", "()"].contains(returnClause.type.trimmedDescription)
    }

    /// 선언 속성(`@objc`, `@main` 등)을 표식으로 옮긴다.
    static func attributes(from list: AttributeListSyntax) -> Set<SymbolAttribute> {
        var result: Set<SymbolAttribute> = []
        for element in list {
            guard case let .attribute(attribute) = element else { continue }
            switch attribute.attributeName.trimmedDescription {
            case "objc": result.insert(.objc)
            case "objcMembers": result.insert(.objcMembers)
            case "IBOutlet": result.insert(.interfaceBuilderOutlet)
            case "IBAction": result.insert(.interfaceBuilderAction)
            case "IBInspectable": result.insert(.interfaceBuilderInspectable)
            case "IBSegueAction": result.insert(.interfaceBuilderSegueAction)
            case "main", "UIApplicationMain", "NSApplicationMain": result.insert(.entryPoint)
            case "propertyWrapper": result.insert(.propertyWrapper)
            case "resultBuilder": result.insert(.resultBuilder)
            case "dynamicMemberLookup": result.insert(.dynamicMemberLookup)
            case "_dynamicReplacement": result.insert(.dynamicReplacement)
            case "Test": result.insert(.testFunction)
            case "Suite": result.insert(.testSuite)
            // 저장소를 런타임이 관리하므로 컴파일된 코드에 참조가 남지 않는다.
            case "NSManaged", "Observable", "Model", "ObservationTracked",
                 // SwiftUI 가 델리게이트를 대신 만들어 들고 있다. 코드 어디에서도
                 // 이 프로퍼티를 읽지 않지만 지우면 앱이 델리게이트를 잃는다.
                 "NSApplicationDelegateAdaptor", "UIApplicationDelegateAdaptor",
                 "WKApplicationDelegateAdaptor", "WKExtensionDelegateAdaptor":
                result.insert(.runtimeManaged)
            default: break
            }
        }
        return result
    }

    /// 상속/준수 절에서 읽어 내는 표식.
    static func inheritanceAttributes(
        _ clause: InheritanceClauseSyntax?,
        isEnum: Bool
    ) -> Set<SymbolAttribute> {
        guard let clause else { return [] }
        let inherited = clause.inheritedTypes.map { $0.type.trimmedDescription }
        var result: Set<SymbolAttribute> = []

        if inherited.contains(where: codableProtocols.contains) { result.insert(.codable) }
        if inherited.contains("CodingKey") { result.insert(.codingKey) }
        // 케이스를 소스에서 한 번도 이름으로 부르지 않고 `allCases` 로만 쓰는 것은 흔하다.
        // 합성된 `allCases` 의 몸통은 소스 범위가 없어 인덱스에 참조를 남기지 않는다.
        if inherited.contains("CaseIterable") { result.insert(.caseIterable) }
        if inherited.contains("PreviewProvider") { result.insert(.preview) }
        if isEnum, inherited.contains(where: { rawValueTypes.contains($0) || $0 == "RawRepresentable" }) {
            result.insert(.rawRepresentable)
        }
        return result
    }

    /// 테스트 기반 클래스를 상속하는지 확인한다.
    private func isTestCase(_ clause: InheritanceClauseSyntax?) -> Bool {
        clause?.inheritedTypes.contains { testCaseBaseClasses.contains($0.type.trimmedDescription) } ?? false
    }

    static let codableProtocols: Set<String> = ["Codable", "Encodable", "Decodable"]
    /// 열거형 원시값으로 흔히 쓰이는 타입들.
    static let rawValueTypes: Set<String> = [
        "String", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Character",
    ]
}
