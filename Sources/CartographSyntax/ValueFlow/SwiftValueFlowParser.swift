import CartographCore
import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Swift 구문을 함수 간 값 흐름 IR로 낮춘다.
///
/// SwiftSyntax는 컴파일러 인덱스의 USR을 알지 못하므로 이 단계에서는 파일 안에서
/// 결정적인 식별자와 정확한 소스 위치만 만든다. 호출 대상과 필드의 실제 결합은
/// `CartographKit`이 인덱스의 발생 위치를 이용해 나중에 보강한다.
public struct SwiftValueFlowParser: Sendable {
    /// 소스 문자열만 읽어 값 흐름 프로그램을 만든다.
    public init() {}

    /// 주어진 소스를 함수·필드·타입과 평평한 명령 목록으로 낮춘다.
    ///
    /// 파일 시스템에 접근하지 않는 API이므로 호출자는 같은 경로에 대한 소스를
    /// 직접 공급해야 한다. `path`는 위치와 source-local ID의 일부로만 사용된다.
    public func scan(source: String, path: String) -> ValueFlowProgram {
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }
            .as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = ValueFlowDeclarationCollector(path: path, converter: converter)
        collector.walk(tree)
        collector.finalize()

        var limitations = collector.limitations
        if tree.hasError {
            limitations.append("source contains parse errors; affected code is conservative")
        }

        let state = ValueFlowLoweringState(
            path: path,
            converter: converter,
            functions: [],
            knownFunctionNames: Set(collector.functions.compactMap { function in
                function.ownerType.map { "\($0)#\(function.name)" }
            }),
            fields: collector.fields.map { $0.field },
            types: collector.types.map { $0.type },
            limitations: limitations
        )

        for info in collector.functions.sorted(by: { $0.location < $1.location }) {
            if let function = ValueFlowFunctionBuilder.lower(state: state, info: info) {
                state.append(function: function)
            }
        }

        if let topLevel = collector.topLevelStatements, !topLevel.isEmpty {
            let info = ValueFlowDeclarationCollector.FunctionInfo.global(
                path: path,
                converter: converter,
                statements: topLevel,
                unavailableReason: tree.hasError ? "top-level contains parse errors" : nil
            )
            if let function = ValueFlowFunctionBuilder.lower(state: state, info: info) {
                state.append(function: function)
            }
        }

        return state.program()
    }
}

// MARK: - 선언 수집

/// 낮추기에 필요한 선언 문맥을 보관한다. 이 타입은 외부 API의 일부가 아니다.
final class ValueFlowDeclarationCollector: SyntaxVisitor {
    struct FunctionInfo {
        enum Body {
            case function(FunctionDeclSyntax)
            case initializer(InitializerDeclSyntax)
            case accessor(AccessorDeclSyntax, fieldName: String)
            case closure(ClosureExprSyntax)
            case global([CodeBlockItemSyntax])
            case initializerExpression(ExprSyntax)
        }

        let id: String
        let name: String
        let indexName: String
        let location: CartographCore.SourceLocation
        let kind: ValueFlowFunction.Kind
        let parameters: [ValueFlowParameter]
        let allowsImplicitReturn: Bool
        let returnType: String?
        let body: Body?
        let ownerType: String?
        let isStatic: Bool
        let isEntryPoint: Bool
        let mayBeCalledExternally: Bool
        let unavailableReason: String?
    }

    struct FieldInfo {
        let field: ValueFlowField
        let binding: PatternBindingSyntax
    }

    struct TypeInfo {
        let type: ValueFlowType
    }

    let path: String
    let converter: SourceLocationConverter
    private(set) var functions: [FunctionInfo] = []
    private(set) var fields: [FieldInfo] = []
    private(set) var types: [TypeInfo] = []
    private(set) var limitations: [String] = []
    private(set) var topLevelStatements: [CodeBlockItemSyntax]?

    private var typeStack: [String] = []
    private var typeIDStack: [String] = []
    private var mainTypeStack: [Bool] = []
    private var objectiveCMemberStack: [Bool] = []
    private var sourceTypeIDs: [String: String] = [:]
    private var inheritedTypesByID: [String: [String]] = [:]
    private var synthesizableValueTypeIDs: Set<String> = []
    private var unknownTypeNames: Set<String> = []
    private var functionDepth = 0
    private var bodyDepth = 0

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.name.text, node: node, reference: true)
    }

    override func visitPost(_ node: ClassDeclSyntax) { leaveType() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.name.text, node: node, reference: false)
    }

    override func visitPost(_ node: StructDeclSyntax) { leaveType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.name.text, node: node, reference: false)
    }

    override func visitPost(_ node: EnumDeclSyntax) { leaveType() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.name.text, node: node, reference: false)
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { leaveType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.name.text, node: node, reference: true)
    }

    override func visitPost(_ node: ActorDeclSyntax) { leaveType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(name: node.extendedType.trimmedDescription, node: node, reference: false, extensionDecl: true)
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { leaveType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let info = functionInfo(node)
        functions.append(info)
        functionDepth += 1
        bodyDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        functionDepth = max(0, functionDepth - 1)
        bodyDepth = max(0, bodyDepth - 1)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let info = initializerInfo(node)
        functions.append(info)
        functionDepth += 1
        bodyDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        functionDepth = max(0, functionDepth - 1)
        bodyDepth = max(0, bodyDepth - 1)
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        bodyDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: AccessorDeclSyntax) {
        bodyDepth = max(0, bodyDepth - 1)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        bodyDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        bodyDepth = max(0, bodyDepth - 1)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard bodyDepth == 0 else { return .visitChildren }
        collectFields(node)
        return .visitChildren
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        limitations.append("conditional compilation is not lowered")
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        limitations.append("macro declaration is not lowered")
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        limitations.append("subscript declaration is not lowered")
        return .skipChildren
    }

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        topLevelStatements = node.statements.filter { item in
            item.item.as(DeclSyntax.self) == nil
        }
        return .visitChildren
    }

    private func enterType(
        name: String,
        node: some SyntaxProtocol,
        reference: Bool,
        extensionDecl: Bool = false
    ) -> SyntaxVisitorContinueKind {
        let cleanName = ValueFlowSyntax.unescaped(name)
        typeStack.append(cleanName)
        let declaresMain = hasMainAttribute(of: node)
        mainTypeStack.append(declaresMain)
        objectiveCMemberStack.append(hasObjectiveCMembersAttribute(of: node))
        let qualified = typeStack.joined(separator: ".")
        let typeID = ValueFlowID.make(path: path, node: node, kind: "type")
        typeIDStack.append(typeID)
        let inherited = inheritedTypeNames(of: node)
        let hasExternalBase = inherited.contains { $0.contains(".") || $0.hasPrefix("NSObject") }
        let isFinal = node.modifierTexts.contains("final")
        let typeLocation = typeLocation(of: node)
        let unavailableReason = ValueFlowSyntax.unknownTypeAttributeReason(of: node)
        if unavailableReason != nil {
            unknownTypeNames.insert(qualified)
        }
        if extensionDecl {
            types.append(TypeInfo(type: ValueFlowType(
                id: typeID,
                name: qualified,
                location: typeLocation,
                isReferenceType: true,
                isFinal: false,
                hasExternalBase: false,
                isExtension: true,
                unavailableReason: unavailableReason
            )))
            inheritedTypesByID[typeID] = inherited
        } else if sourceTypeIDs[qualified] == nil {
            sourceTypeIDs[qualified] = typeID
            let type = ValueFlowType(
                id: typeID,
                name: qualified,
                location: typeLocation,
                isReferenceType: reference,
                isFinal: isFinal,
                hasExternalBase: hasExternalBase,
                unavailableReason: unavailableReason
            )
            types.append(TypeInfo(type: type))
            inheritedTypesByID[typeID] = inherited
            if node.as(StructDeclSyntax.self) != nil {
                synthesizableValueTypeIDs.insert(typeID)
            }
        }
        return .visitChildren
    }

    private func leaveType() {
        if !typeStack.isEmpty { typeStack.removeLast() }
        if !typeIDStack.isEmpty { typeIDStack.removeLast() }
        if !mainTypeStack.isEmpty { mainTypeStack.removeLast() }
        if !objectiveCMemberStack.isEmpty { objectiveCMemberStack.removeLast() }
    }

    private var currentOwnerType: String? { typeIDStack.last }

    /// 소스에 명시된 생성자가 없는 참조형 타입도 기본 생성자 호출을 잃지 않게 한다.
    ///
    /// 본문이 없는 합성 선언은 인덱스 USR을 추정하지 않는다. 필드 초기화 함수는 각
    /// 필드에 별도로 연결되어 있으므로 합성 생성자는 객체 identity만 보존한다.
    func finalize() {
        let localTypeNames = Set(types.map { $0.type.name })
        types = types.map { typeInfo in
            let type = typeInfo.type
            let inherited = inheritedTypesByID[type.id] ?? []
            let external = inherited.contains { inheritedName in
                !localTypeNames.contains(inheritedName)
            }
            return TypeInfo(type: ValueFlowType(
                id: type.id,
                symbolUSR: type.symbolUSR,
                name: type.name,
                location: type.location,
                isReferenceType: type.isReferenceType,
                isFinal: type.isFinal,
                hasExternalBase: external,
                isExtension: type.isExtension,
                unavailableReason: unknownTypeNames.contains(type.name)
                    ? "type has unknown attribute effects"
                    : type.unavailableReason
            ))
        }
        let explicitInitializers = Set(functions.compactMap { function -> String? in
            guard function.kind == .initializer else { return nil }
            return function.ownerType
        })
        for type in types where !type.type.isExtension
            && !explicitInitializers.contains(type.type.id)
            && (type.type.isReferenceType || synthesizableValueTypeIDs.contains(type.type.id))
            && fields.filter({ $0.field.ownerType == type.type.id }).allSatisfy({ field in
                (type.type.isReferenceType || !field.field.isMutable)
                    && (field.field.initializer != nil || field.field.getter != nil || field.field.setter != nil)
            }) {
            let id = "\(path)#synthetic-initializer:\(type.type.id)"
            guard !functions.contains(where: { $0.id == id }) else { continue }
            functions.append(FunctionInfo(
                id: id,
                name: "init",
                indexName: "init()",
                location: type.type.location,
                kind: .initializer,
                parameters: [],
                allowsImplicitReturn: false,
                returnType: nil,
                body: .global([]),
                ownerType: type.type.id,
                isStatic: false,
                isEntryPoint: false,
                mayBeCalledExternally: false,
                unavailableReason: nil
            ))
        }
    }

    private func inheritedTypeNames(of node: some SyntaxProtocol) -> [String] {
        if let declaration = node.as(ClassDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        if let declaration = node.as(StructDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        if let declaration = node.as(EnumDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        if let declaration = node.as(ActorDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        if let declaration = node.as(ProtocolDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        }
        return []
    }

    private func hasMainAttribute(of node: some SyntaxProtocol) -> Bool {
        if let declaration = node.as(ClassDeclSyntax.self) {
            return ValueFlowSyntax.hasAttribute(declaration.attributes, named: "main")
        }
        if let declaration = node.as(StructDeclSyntax.self) {
            return ValueFlowSyntax.hasAttribute(declaration.attributes, named: "main")
        }
        if let declaration = node.as(ActorDeclSyntax.self) {
            return ValueFlowSyntax.hasAttribute(declaration.attributes, named: "main")
        }
        if let declaration = node.as(EnumDeclSyntax.self) {
            return ValueFlowSyntax.hasAttribute(declaration.attributes, named: "main")
        }
        if let declaration = node.as(ProtocolDeclSyntax.self) {
            return ValueFlowSyntax.hasAttribute(declaration.attributes, named: "main")
        }
        return false
    }

    private func hasObjectiveCMembersAttribute(of node: some SyntaxProtocol) -> Bool {
        func contains(_ attributes: AttributeListSyntax) -> Bool {
            ValueFlowSyntax.hasAttribute(attributes, named: "objcMembers")
        }
        if let declaration = node.as(ClassDeclSyntax.self) { return contains(declaration.attributes) }
        if let declaration = node.as(StructDeclSyntax.self) { return contains(declaration.attributes) }
        if let declaration = node.as(ActorDeclSyntax.self) { return contains(declaration.attributes) }
        return false
    }

    private func typeLocation(of node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        if let declaration = node.as(ClassDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.name, converter: converter, path: path)
        }
        if let declaration = node.as(StructDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.name, converter: converter, path: path)
        }
        if let declaration = node.as(EnumDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.name, converter: converter, path: path)
        }
        if let declaration = node.as(ActorDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.name, converter: converter, path: path)
        }
        if let declaration = node.as(ProtocolDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.name, converter: converter, path: path)
        }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return ValueFlowSyntax.location(of: declaration.extendedType, converter: converter, path: path)
        }
        return ValueFlowSyntax.location(of: node, converter: converter, path: path)
    }

    private func collectFields(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                limitations.append("complex variable pattern is not lowered")
                continue
            }
            let name = ValueFlowSyntax.unescaped(pattern.identifier.text)
            let owner = currentOwnerType
            let fieldID = ValueFlowID.make(path: path, node: pattern.identifier, kind: "field")
            let initializerID: String?
            if let initializer = binding.initializer {
                let initFunctionID = ValueFlowID.make(path: path, node: initializer, kind: "field-initializer")
                initializerID = initFunctionID
                functions.append(FunctionInfo(
                    id: initFunctionID,
                    name: "\(name) initializer",
                    indexName: "\(name) initializer",
                    location: ValueFlowSyntax.location(of: initializer.value, converter: converter, path: path),
                    kind: .global,
                    parameters: [],
                    allowsImplicitReturn: true,
                    returnType: binding.typeAnnotation?.type.trimmedDescription,
                    body: .initializerExpression(initializer.value),
                    ownerType: owner,
                    isStatic: node.modifierTexts.contains("static") || node.modifierTexts.contains("class"),
                    isEntryPoint: false,
                    mayBeCalledExternally: false,
                    unavailableReason: initializer.value.hasError
                        ? "field initializer contains parse errors"
                        : nil
                ))
            } else {
                initializerID = nil
            }

            var getterID: String?
            var setterID: String?
            var unknownObservers = false
            if let accessorBlock = binding.accessorBlock {
                switch accessorBlock.accessors {
                case .accessors(let accessors):
                    for accessor in accessors {
                        let specifier = accessor.accessorSpecifier.text
                        if specifier == "get" || specifier == "_read" || specifier == "read" {
                            getterID = addAccessor(
                                accessor,
                                fieldName: name,
                                owner: owner,
                                kind: .getter,
                                returnType: binding.typeAnnotation?.type.trimmedDescription
                            )
                        } else if specifier == "set" || specifier == "_modify" || specifier == "modify" {
                            setterID = addAccessor(
                                accessor,
                                fieldName: name,
                                owner: owner,
                                kind: .setter,
                                returnType: nil
                            )
                        } else {
                            unknownObservers = true
                        }
                    }
                case .getter:
                    getterID = ValueFlowID.make(path: path, node: accessorBlock, kind: "getter")
                    functions.append(FunctionInfo(
                        id: getterID!,
                        name: name,
                        indexName: name,
                        location: ValueFlowSyntax.location(of: accessorBlock.leftBrace, converter: converter, path: path),
                        kind: .getter,
                        parameters: [],
                        allowsImplicitReturn: true,
                        returnType: binding.typeAnnotation?.type.trimmedDescription,
                        body: .global(Array(accessorBlock.accessors.as(CodeBlockItemListSyntax.self) ?? [])),
                        ownerType: owner,
                        isStatic: node.modifierTexts.contains("static") || node.modifierTexts.contains("class"),
                        isEntryPoint: false,
                        mayBeCalledExternally: true,
                        unavailableReason: nil
                    ))
                }
            }
            let hasMacroAttribute = node.attributes.contains { attribute in
                let text = attribute.trimmedDescription
                return text.hasPrefix("@") && !text.hasPrefix("@available") && !text.hasPrefix("@objc")
            }
            let dynamicMember = node.modifierTexts.contains("class") || node.modifierTexts.contains("dynamic")
            if node.modifierTexts.contains("lazy") || hasMacroAttribute || dynamicMember {
                unknownObservers = true
                limitations.append(dynamicMember ? "dynamic property dispatch is unavailable"
                    : (hasMacroAttribute ? "property macro effects are unknown" : "lazy property effects are unknown"))
            }
            if unknownObservers {
                let reason = "property effects are unknown"
                if let initializerID {
                    markFunctionUnavailable(initializerID, reason: reason)
                }
                if let getterID {
                    markFunctionUnavailable(getterID, reason: reason)
                }
                if let setterID {
                    markFunctionUnavailable(setterID, reason: reason)
                }
            }
            let fieldLocation = ValueFlowSyntax.location(of: pattern.identifier, converter: converter, path: path)
            fields.append(FieldInfo(field: ValueFlowField(
                id: fieldID,
                name: name,
                location: fieldLocation,
                declaredType: binding.typeAnnotation?.type.trimmedDescription,
                ownerType: owner,
                isStatic: node.modifierTexts.contains("static") || node.modifierTexts.contains("class"),
                isMutable: node.bindingSpecifier.text == "var",
                initializer: initializerID,
                getter: getterID,
                setter: setterID,
                hasUnknownObservers: unknownObservers
            ), binding: binding))
        }
    }

    private func markFunctionUnavailable(_ id: String, reason: String) {
        functions = functions.map { function in
            guard function.id == id else { return function }
            return function.replacingUnavailableReason(reason)
        }
    }

    private func addAccessor(
        _ accessor: AccessorDeclSyntax,
        fieldName: String,
        owner: String?,
        kind: ValueFlowFunction.Kind,
        returnType: String?
    ) -> String {
        let id = ValueFlowID.make(path: path, node: accessor, kind: kind.rawValue)
        let parameters: [ValueFlowParameter]
        if kind == .setter {
            let name = accessor.parameters?.name.text ?? "newValue"
            parameters = [ValueFlowParameter(name: name, label: "", isInout: false, isFunction: false)]
        } else {
            parameters = []
        }
        functions.append(FunctionInfo(
            id: id,
            name: fieldName,
            indexName: fieldName,
            location: ValueFlowSyntax.location(of: accessor.accessorSpecifier, converter: converter, path: path),
            kind: kind,
            parameters: parameters,
            allowsImplicitReturn: kind == .getter,
            returnType: returnType,
            body: .accessor(accessor, fieldName: fieldName),
            ownerType: owner,
            isStatic: false,
            isEntryPoint: false,
            mayBeCalledExternally: true,
            unavailableReason: accessor.hasError
                ? "accessor contains parse errors"
                : (accessor.body == nil ? "accessor has no body" : nil)
        ))
        return id
    }

    private func functionInfo(_ node: FunctionDeclSyntax) -> FunctionInfo {
        let name = ValueFlowSyntax.unescaped(node.name.text)
        let owner = currentOwnerType
        let params = ValueFlowSyntax.parameters(node.signature.parameterClause.parameters)
        let indexName = ValueFlowSyntax.indexName(name: name, parameters: params)
        return FunctionInfo(
            id: ValueFlowID.make(path: path, node: node.name, kind: "function"),
            name: name,
            indexName: indexName,
            location: ValueFlowSyntax.location(of: node.name, converter: converter, path: path),
            kind: .function,
            parameters: params,
            allowsImplicitReturn: ValueFlowSyntax.allowsImplicitReturn(node),
            returnType: node.signature.returnClause?.type.trimmedDescription,
            body: node.body.map { _ in .function(node) },
            ownerType: owner,
            isStatic: node.modifierTexts.contains("static") || node.modifierTexts.contains("class"),
            isEntryPoint: ValueFlowSyntax.hasAttribute(node.attributes, named: "main")
                || (mainTypeStack.last == true && name == "main"),
            mayBeCalledExternally: ValueFlowSyntax.mayBeCalledExternally(attributes: node.attributes, modifiers: node.modifiers)
                || objectiveCMemberStack.last == true,
            unavailableReason: node.modifierTexts.contains("class") || node.modifierTexts.contains("dynamic")
                ? "dynamic class or runtime dispatch is unavailable"
                : node.hasError
                ? "function contains parse errors"
                : (ValueFlowSyntax.unsupportedParameterReason(node.signature.parameterClause.parameters)
                    ?? (node.body == nil
                        ? "function has no body"
                        : (node.modifierTexts.contains("mutating")
                            ? "mutating value-type method is unavailable"
                            : nil)))
        )
    }

    private func initializerInfo(_ node: InitializerDeclSyntax) -> FunctionInfo {
        let params = ValueFlowSyntax.parameters(node.signature.parameterClause.parameters)
        let owner = currentOwnerType
        return FunctionInfo(
            id: ValueFlowID.make(path: path, node: node.initKeyword, kind: "initializer"),
            name: "init",
            indexName: ValueFlowSyntax.indexName(name: "init", parameters: params),
            location: ValueFlowSyntax.location(of: node.initKeyword, converter: converter, path: path),
            kind: .initializer,
            parameters: params,
            allowsImplicitReturn: false,
            returnType: nil,
            body: node.body.map { _ in .initializer(node) },
            ownerType: owner,
            isStatic: false,
            isEntryPoint: false,
            mayBeCalledExternally: ValueFlowSyntax.mayBeCalledExternally(attributes: node.attributes, modifiers: node.modifiers)
                || objectiveCMemberStack.last == true,
            unavailableReason: node.hasError
                ? "initializer contains parse errors"
                : (ValueFlowSyntax.unsupportedParameterReason(node.signature.parameterClause.parameters)
                    ?? (node.optionalMark != nil
                        ? "failable initializer is unavailable"
                        : (node.modifierTexts.contains("convenience")
                            ? "convenience initializer is unavailable"
                            : (node.body == nil ? "initializer has no body" : nil))))
        )
    }
}

private extension ValueFlowDeclarationCollector.FunctionInfo {
    func replacingUnavailableReason(_ unavailableReason: String?) -> Self {
        Self(
            id: id,
            name: name,
            indexName: indexName,
            location: location,
            kind: kind,
            parameters: parameters,
            allowsImplicitReturn: allowsImplicitReturn,
            returnType: returnType,
            body: body,
            ownerType: ownerType,
            isStatic: isStatic,
            isEntryPoint: isEntryPoint,
            mayBeCalledExternally: mayBeCalledExternally,
            unavailableReason: unavailableReason
        )
    }
}

// MARK: - 공통 구문 도우미

enum ValueFlowID {
    static func make(path: String, node: some SyntaxProtocol, kind: String) -> String {
        "\(path)#\(kind):\(node.position.utf8Offset)"
    }
}

enum ValueFlowSyntax {
    static func unknownTypeAttributeReason(of node: some SyntaxProtocol) -> String? {
        let attributes: AttributeListSyntax?
        if let declaration = node.as(ClassDeclSyntax.self) {
            attributes = declaration.attributes
        } else if let declaration = node.as(StructDeclSyntax.self) {
            attributes = declaration.attributes
        } else if let declaration = node.as(EnumDeclSyntax.self) {
            attributes = declaration.attributes
        } else if let declaration = node.as(ActorDeclSyntax.self) {
            attributes = declaration.attributes
        } else if let declaration = node.as(ProtocolDeclSyntax.self) {
            attributes = declaration.attributes
        } else if let declaration = node.as(ExtensionDeclSyntax.self) {
            attributes = declaration.attributes
        } else {
            attributes = nil
        }
        guard let attributes else { return nil }
        let known = Set([
            "available", "main", "objc", "objcMembers", "preconcurrency", "frozen",
            "usableFromInline", "inlinable", "inline", "nonobjc", "dynamicMemberLookup",
            "preconcurrency", "MainActor", "globalActor", "unchecked", "testable"
        ])
        let hasUnknown = attributes.contains { attribute in
            let text = attribute.trimmedDescription
            guard text.hasPrefix("@") else { return false }
            let name = text.dropFirst().split(separator: "(", maxSplits: 1).first.map(String.init) ?? ""
            return !known.contains(name)
        }
        return hasUnknown ? "type has unknown attribute effects" : nil
    }

    static func allowsImplicitReturn(_ node: FunctionDeclSyntax) -> Bool {
        guard let returnType = node.signature.returnClause?.type.trimmedDescription else { return false }
        return returnType != "Void" && returnType != "()"
    }

    static func unescaped(_ name: String) -> String {
        guard name.hasPrefix("`"), name.hasSuffix("`"), name.count > 1 else { return name }
        return String(name.dropFirst().dropLast())
    }

    static func location(of node: some SyntaxProtocol, converter: SourceLocationConverter, path: String) -> CartographCore.SourceLocation {
        let location = node.startLocation(converter: converter)
        return CartographCore.SourceLocation(path: path, line: location.line, column: location.column)
    }

    static func parameters(_ parameters: FunctionParameterListSyntax) -> [ValueFlowParameter] {
        parameters.map { parameter in
            let first = unescaped(parameter.firstName.text)
            let name = unescaped(parameter.secondName?.text ?? (first == "_" ? "arg\(parameter.position.utf8Offset)" : first))
            let label = first == "_" ? "" : first
            let type = parameter.type.trimmedDescription
            return ValueFlowParameter(
                name: name,
                label: label,
                isInout: type.hasPrefix("inout ") || type == "inout",
                isFunction: type.contains("->"),
                declaredType: type
            )
        }
    }

    static func unsupportedParameterReason(_ parameters: FunctionParameterListSyntax) -> String? {
        if parameters.contains(where: { $0.ellipsis != nil }) {
            return "variadic parameter is unavailable"
        }
        if parameters.contains(where: { parameter in
            parameter.attributes.contains { $0.trimmedDescription.contains("autoclosure") }
                || parameter.type.trimmedDescription.contains("autoclosure")
        }) {
            return "autoclosure parameter is unavailable"
        }
        return nil
    }

    static func closureParameters(_ signature: ClosureSignatureSyntax?) -> [ValueFlowParameter] {
        guard let parameterClause = signature?.parameterClause else { return [] }
        switch parameterClause {
        case .parameterClause(let clause):
            return clause.parameters.enumerated().map { index, parameter in
                let first = ValueFlowSyntax.unescaped(parameter.firstName.text)
                let name = ValueFlowSyntax.unescaped(parameter.secondName?.text ?? (first == "_" ? "arg\(index)" : first))
                return ValueFlowParameter(name: name, label: first == "_" ? "" : first,
                                          isInout: false,
                                          isFunction: parameter.type?.trimmedDescription.contains("->") ?? false,
                                          declaredType: parameter.type?.trimmedDescription)
            }
        case .simpleInput(let parameters):
            return parameters.map { parameter in
                ValueFlowParameter(name: ValueFlowSyntax.unescaped(parameter.name.text), label: "",
                                   isInout: false, isFunction: false, declaredType: nil)
            }
        }
    }

    static func closureReturnType(_ signature: ClosureSignatureSyntax?) -> String? {
        signature?.returnClause?.type.trimmedDescription
    }

    static func indexName(name: String, parameters: [ValueFlowParameter]) -> String {
        guard !parameters.isEmpty else { return "\(name)()" }
        return "\(name)(\(parameters.map { $0.label.isEmpty ? "_" : $0.label }.map { "\($0):" }.joined()))"
    }

    static func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        attributes.contains { attribute in
            let text = attribute.trimmedDescription
            return text == "@\(name)" || text.hasPrefix("@\(name)(") || text.hasPrefix("@\(name) ")
        }
    }

    static func mayBeCalledExternally(attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax) -> Bool {
        let modifiers = Set(modifiers.map { $0.name.text })
        return modifiers.contains("public") || modifiers.contains("open") || modifiers.contains("override")
            || hasAttribute(attributes, named: "objc")
    }
}

private extension SyntaxProtocol {
    var modifierTexts: [String] {
        if let node = self.as(ClassDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(StructDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(EnumDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(ProtocolDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(ActorDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(FunctionDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(InitializerDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        if let node = self.as(VariableDeclSyntax.self) { return node.modifiers.map { $0.name.text } }
        return []
    }
}
