import CartographCore
import SwiftParser
import SwiftSyntax

/// Swift 소스를 구문 분석해 선언의 접근 수준과 속성을 읽어낸다.
///
/// 인덱스 스토어만으로는 `public` 여부도, `@objc` 여부도 알 수 없다.
/// Periphery 가 인덱스와 SwiftSyntax 를 함께 쓴 것과 같은 이유다.
/// 이 타입은 파일 내용만 입력으로 받으므로 문자열 리터럴로 완전히 테스트된다.
public struct SwiftSyntaxAnalyzer: Sendable {
    /// 분석 결과가 달라지는 변경을 했다면 이 값을 올린다.
    ///
    /// 캐시는 파일 내용이 같으면 예전 결과를 그대로 쓴다. 분석기를 고쳐 놓고 이
    /// 값을 올리지 않으면, 소스를 건드리지 않은 파일에서는 수정이 영영 적용되지
    /// 않는다. 이 도구가 고쳐 온 오탐들이 정확히 그렇게 무력화될 수 있었다.
    ///
    /// 상수를 분석기 옆에 두는 이유는, 분석기를 고치는 사람이 같은 파일에서 이
    /// 줄을 보게 하기 위해서다. 캐시 쪽에 두면 잊기 쉽다.
    ///
    /// 툴체인(SwiftSyntax) 교체는 이 값으로 잡히지 않는다. 그때는 캐시 디렉터리를
    /// 지우면 된다. 릴리스 간 이동은 도구 버전이 함께 키에 들어가 자동으로 갈린다.
    public static let analysisRevision = 20

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
            ignoresEntireFile: Self.fileIsIgnored(tree),
            runtimeFacts: RuntimeFactScanner().scan(tree: tree, path: path),
            localFunctionScopes: LocalFunctionScanner().scan(tree: tree, path: path),
            parameterUsages: ParameterUsageScanner().scan(tree: tree, path: path, converter: converter),
            imports: ImportScanner().scan(tree: tree, path: path, converter: converter)
        )
    }

    /// 파일 첫머리 주석에 `cartograph:ignore:all` 이 있는지 확인한다.
    private static func fileIsIgnored(_ tree: SourceFileSyntax) -> Bool {
        SyntaxComments.lines(in: tree.leadingTrivia).contains { CommentCommand.parse(comment: $0) == .ignoreAll }
    }

    /// 트리비아에서 주석 텍스트만 뽑아 낸다.
}

/// 선언을 훑으면서 접근 수준과 속성을 모은다.
///
/// 접근 수준과 `@objcMembers` 는 바깥 선언에서 안쪽으로 흘러내리므로
/// 문맥 스택으로 관리한다.
final class DeclarationCollector: SyntaxVisitor {
    /// 바깥 선언에서 상속되는 문맥.
    private struct Context {
        /// 현재 선언을 감싸는 선언의 유효 접근 수준. 최상위에는 없다.
        var enclosingAccessibility: Accessibility?
        /// 현재 선언의 멤버에 접근 제어자가 없을 때 적용할 수준.
        var defaultMemberAccessibility: Accessibility
        /// enum case에 접근 제어자가 없을 때 적용할 수준.
        var enumCaseAccessibility: Accessibility?
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
        /// 이 선언이나 조상에 해석하지 못한 속성이 있는지 여부.
        var hasUnresolvedAttributes: Bool
    }

    private(set) var declarations: [DeclarationFacts] = []
    private var contexts: [Context] = [
        Context(
            enclosingAccessibility: nil,
            defaultMemberAccessibility: .internalLevel,
            enumCaseAccessibility: nil,
            inheritsObjectiveCExposure: false,
            isIgnored: false,
            allowsTestMethods: false,
            hasUnresolvedAttributes: false
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
    override func visitPost(_: ClassDeclSyntax) { pop() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        if node.genericParameterClause != nil { attributes.insert(.generic) }
        return push(
            name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers
        )
    }
    override func visitPost(_: StructDeclSyntax) { pop() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: true))
        return push(
            name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers
        )
    }
    override func visitPost(_: EnumDeclSyntax) { pop() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(
            name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
    }
    override func visitPost(_: ProtocolDeclSyntax) { pop() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        attributes.formUnion(Self.inheritanceAttributes(node.inheritanceClause, isEnum: false))
        return push(
            name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers
        )
    }
    override func visitPost(_: ActorDeclSyntax) { pop() }

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
    override func visitPost(_: ExtensionDeclSyntax) { pop() }

    // MARK: - 멤버 선언

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        if node.genericParameterClause != nil { attributes.insert(.generic) }
        if context.allowsTestMethods, Self.isXCTestMethod(node, modifiers: node.modifiers) {
            attributes.insert(.unitTest)
        }
        return push(
            name: node.name.text, node: node, attributes: attributes, modifiers: node.modifiers
        )
    }
    override func visitPost(_: FunctionDeclSyntax) { pop() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        push(
            name: "init", node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
    }
    override func visitPost(_: InitializerDeclSyntax) { pop() }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        // 연산자는 인덱스에 심볼로 남지만 구문 쪽에 대응이 없어, public 연산자가
        // internal 로 분석되어 미사용으로 보고됐다. 문맥은 쌓지 않는다.
        // 연산자 선언에는 접근 제어자가 붙지 않으므로 빈 목록을 넘긴다.
        record(name: node.name.text, node: node, attributes: [], modifiers: DeclModifierListSyntax([]))
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        push(
            name: "deinit", node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
    }
    override func visitPost(_: DeinitializerDeclSyntax) { pop() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        var attributes = commonAttributes(node)
        if node.parameterClause.parameters.first?.firstName.text == "dynamicMember" {
            attributes.insert(.dynamicMemberLookup)
        }
        return push(
            name: "subscript", node: node, attributes: attributes, modifiers: node.modifiers
        )
    }
    override func visitPost(_: SubscriptDeclSyntax) { pop() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = commonAttributes(node)
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            record(name: pattern.identifier.text, node: node, attributes: attributes,
                modifiers: node.modifiers, nameToken: pattern.identifier)
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = commonAttributes(node)
        for element in node.elements {
            record(name: element.name.text, node: node, attributes: attributes,
                modifiers: node.modifiers, nameToken: element.name)
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        record(
            name: node.name.text, node: node, attributes: commonAttributes(node), modifiers: node.modifiers
        )
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
        let resolved = record(
            name: name,
            node: node,
            attributes: attributes,
            modifiers: modifiers
        )
        contexts.append(
            Context(
                // 익스텐션의 접근 수준은 기본값이지 상한이 아니다. private extension
                // 안에서도 명시적 public 멤버를 선언할 수 있으므로 타입 상한과 분리한다.
                enclosingAccessibility: node.is(ExtensionDeclSyntax.self)
                    ? context.enclosingAccessibility : resolved.accessibility,
                defaultMemberAccessibility: defaultMemberAccessibility(
                    for: node, resolvedAccessibility: resolved.accessibility, modifiers: modifiers
                ),
                enumCaseAccessibility: node.is(EnumDeclSyntax.self) ? resolved.accessibility : nil,
                inheritsObjectiveCExposure: context.inheritsObjectiveCExposure
                    || resolved.attributes.contains(.objcMembers),
                isIgnored: resolved.attributes.contains(.ignoreComment),
                allowsTestMethods: allowsTestMethods,
                hasUnresolvedAttributes: resolved.hasUnresolvedAttributes ?? true
            )
        )
        return .visitChildren
    }

    private func pop() {
        if contexts.count > 1 { contexts.removeLast() }
    }

    /// 백틱으로 감싼 식별자에서 백틱을 뗀다.
    static func unescaped(_ name: String) -> String {
        SyntaxIdentifiers.unescaped(name)
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
        modifiers: DeclModifierListSyntax,
        nameToken: TokenSyntax? = nil
    ) -> DeclarationFacts {
        var resolved = attributes
        if context.inheritsObjectiveCExposure { resolved.insert(.objcAccessible) }
        if context.isIgnored { resolved.insert(.ignoreComment) }
        if modifiers.contains(where: { $0.name.text == "override" }) { resolved.insert(.overrideDeclaration) }
        if modifiers.contains(where: { $0.name.text == "dynamic" }) { resolved.insert(.dynamicDispatch) }

        let hasUnresolvedAttributes = node.asProtocol(WithAttributesSyntax.self)
            .map { Self.hasUnresolvedAttributes(in: $0.attributes) } ?? false
        let facts = DeclarationFacts(
            // SwiftSyntax 는 `` `default` `` 의 백틱까지 이름에 담지만 인덱스는 담지 않는다.
            name: Self.unescaped(name),
            line: node.startLocation(converter: converter).line,
            accessibility: accessibility(from: modifiers, node: node),
            attributes: resolved,
            nameLocation: identifierLocation(in: node, explicitToken: nameToken),
            hasUnresolvedAttributes: context.hasUnresolvedAttributes || hasUnresolvedAttributes
        )
        // 지역 선언은 정점이 되지 않으므로 기록하지 않는다. 남겨 두면 이름이 같은
        // 멤버를 찾을 때 이쪽이 더 가깝다는 이유로 선택될 수 있다.
        if !Self.isInsideBody(node) { declarations.append(facts) }
        return facts
    }

    /// 속성·접근 제어자 대신 컴파일러가 가리키는 식별자 토큰의 물리적 위치를 쓴다.
    private func identifierLocation(
        in node: some SyntaxProtocol, explicitToken: TokenSyntax?
    ) -> CartographCore.SourceLocation? {
        guard !node.hasError else { return nil }
        let token = explicitToken
            ?? node.asProtocol(NamedDeclSyntax.self)?.name
            ?? node.as(InitializerDeclSyntax.self)?.initKeyword
            ?? node.as(DeinitializerDeclSyntax.self)?.deinitKeyword
            ?? node.as(SubscriptDeclSyntax.self)?.subscriptKeyword
        guard let token, token.presence == .present else { return nil }
        let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return CartographCore.SourceLocation(path: location.file, line: location.line, column: location.column)
    }

    /// 명시적 제어자가 없으면 바깥 문맥의 접근 수준을 물려받는다.
    private func accessibility(from modifiers: DeclModifierListSyntax, node: some SyntaxProtocol) -> Accessibility {
        guard let explicit = explicitAccessibility(from: modifiers) else {
            if node.is(EnumCaseDeclSyntax.self), let enumAccess = context.enumCaseAccessibility {
                return enumAccess
            }
            return context.defaultMemberAccessibility
        }
        guard let enclosing = context.enclosingAccessibility, enclosing > .internalLevel else {
            return explicit
        }
        // private/fileprivate 안쪽 선언은 바깥 선언보다 넓게 노출될 수 없다.
        // internal/package 바깥의 명시적 public은 구문에 적힌 사실을 보존한다.
        // `Accessibility` 의 순서에서 더 큰 값이 더 좁은 접근 수준이므로 max가
        // private/fileprivate clamp를 표현한다.
        return Swift.max(explicit, enclosing)
    }

    /// 접근 제어자 목록에서 명시된 첫 접근 수준을 읽는다.
    private func explicitAccessibility(from modifiers: DeclModifierListSyntax) -> Accessibility? {
        modifiers.compactMap { Accessibility(modifierName: $0.name.text) }.first
    }

    /// 선언 종류에 따른 멤버의 기본 접근 수준을 계산한다.
    ///
    /// 프로토콜 요구사항과 명시적 접근 수준의 익스텐션만 기본 접근을 바깥으로
    /// 물려받는다. public nominal 타입은 멤버가 internal이고, 무표시 익스텐션도
    /// internal이므로 public 타입의 접근을 잘못 확장하지 않는다.
    private func defaultMemberAccessibility(
        for node: some SyntaxProtocol,
        resolvedAccessibility: Accessibility,
        modifiers: DeclModifierListSyntax
    ) -> Accessibility {
        if node.is(ProtocolDeclSyntax.self) { return resolvedAccessibility }
        if node.is(ExtensionDeclSyntax.self), explicitAccessibility(from: modifiers) != nil {
            return resolvedAccessibility
        }
        let nominal = node.is(ClassDeclSyntax.self)
            || node.is(StructDeclSyntax.self)
            || node.is(EnumDeclSyntax.self)
            || node.is(ActorDeclSyntax.self)
        if nominal { return Swift.max(.internalLevel, resolvedAccessibility) }
        return .internalLevel
    }

    /// 속성 목록과 주석에서 공통 표식을 읽는다.
    ///
    /// 주석은 선언 위와 줄 끝 양쪽을 본다. 줄 끝 주석은 SwiftSyntax 에서 그 선언의
    /// 후행 트리비아에 들어가므로 앞 트리비아만 읽으면 조용히 무시된다.
    /// 사용자는 무시했다고 믿는데 그대로 미사용으로 보고되는 상황이 된다.
    private func commonAttributes(_ node: some WithAttributesSyntax & SyntaxProtocol) -> Set<SymbolAttribute> {
        var result = Self.attributes(from: node.attributes)
        let comments = SyntaxComments.lines(in: node.leadingTrivia)
            + SyntaxComments.lines(in: node.trailingTrivia)
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

    /// 동적 디스패치에 영향을 줄 수 있는 미해결 속성이 있는지 확인한다.
    ///
    /// 알 수 없는 속성은 값 표식으로 옮기지 못해도 컴파일러가 멤버나 저장소를
    /// 합성했을 수 있다. 동적 디스패치 정규화가 그런 선언의 인덱스 근거를
    /// 지우지 않도록, 좁은 컴파일러 예약 목록 밖의 속성은 모두 미해결로 남긴다.
    static func hasUnresolvedAttributes(in list: AttributeListSyntax) -> Bool {
        list.contains { element in
            switch element {
            case let .attribute(attribute):
                let name = attribute.attributeName.trimmedDescription
                return name.isEmpty
                    || name.contains(".")
                    || !compilerKnownAttributes.contains(name)
            case .ifConfigDecl:
                return true
            @unknown default:
                return true
            }
        }
    }

    /// 합성 효과 또는 별도 보존 표식을 알고 있는 컴파일러 예약 속성.
    ///
    /// 이 목록은 일부러 좁다. `MainActor`, `Observable`, `Test`처럼 이름만으로
    /// 컴파일러 내장 속성임을 확인할 수 없는 이름은 사용자 정의일 수 있으므로
    /// 목록에 넣지 않고 미해결로 취급한다.
    private static let compilerKnownAttributes: Set<String> = [
        "available", "discardableResult", "inlinable", "inline", "usableFromInline",
        "_transparent", "_alwaysEmitIntoClient", "_disfavoredOverload", "_spi",
        "objc", "objcMembers", "_dynamicReplacement",
        "main", "UIApplicationMain", "NSApplicationMain",
        "IBOutlet", "IBAction", "IBInspectable", "IBSegueAction", "dynamicMemberLookup",
    ]

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
