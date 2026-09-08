import CartographCore
import Foundation
import SwiftSyntax

/// 수집된 선언을 함수별 명령과 CFG 블록으로 낮추는 내부 상태.
final class ValueFlowLoweringState {
    let path: String
    let converter: SourceLocationConverter
    var functions: [ValueFlowFunction] = []
    let knownFunctionNames: Set<String>
    var fields: [ValueFlowField]
    var types: [ValueFlowType]
    var limitations: [String]
    private var loweredIDs: Set<String> = []

    init(
        path: String,
        converter: SourceLocationConverter,
        functions: [ValueFlowFunction],
        knownFunctionNames: Set<String>,
        fields: [ValueFlowField],
        types: [ValueFlowType],
        limitations: [String]
    ) {
        self.path = path
        self.converter = converter
        self.functions = functions
        self.knownFunctionNames = knownFunctionNames
        self.fields = fields
        self.types = types
        self.limitations = limitations
    }

    func claimFunctionID(_ id: String) -> Bool {
        loweredIDs.insert(id).inserted
    }

    func append(function: ValueFlowFunction) {
        functions.append(function)
    }

    func program() -> ValueFlowProgram {
        ValueFlowProgram(
            functions: functions.sorted { ($0.location, $0.id) < ($1.location, $1.id) },
            fields: fields.sorted { ($0.location, $0.id) < ($1.location, $1.id) },
            types: types.sorted { ($0.location, $0.id) < ($1.location, $1.id) },
            limitations: Array(Set(limitations)).sorted()
        )
    }
}

extension ValueFlowDeclarationCollector.FunctionInfo {
    static func global(
        path: String,
        converter: SourceLocationConverter,
        statements: [CodeBlockItemSyntax],
        unavailableReason: String? = nil
    ) -> Self {
        let first = statements.first
        let location = first.map { ValueFlowSyntax.location(of: $0, converter: converter, path: path) }
            ?? CartographCore.SourceLocation(path: path, line: 1, column: 1)
        let id = "\(path)#global:\(first?.position.utf8Offset ?? 0)"
        return Self(
            id: id,
            name: "<top-level>",
            indexName: "<top-level>",
            location: location,
            kind: .global,
            parameters: [],
            allowsImplicitReturn: false,
            returnType: nil,
            body: .global(statements),
            ownerType: nil,
            isStatic: true,
            isEntryPoint: true,
            mayBeCalledExternally: true,
            unavailableReason: unavailableReason
        )
    }
}

// MARK: - Function builder

private enum ValueFlowBinding: Equatable {
    case address(Int)
    case value(Int)
}

private struct ValueFlowScope {
    var values: [String: ValueFlowBinding] = [:]
}

private struct StringLiteralContext {
    let expectedType: String?
    let inferred: Bool

    static let direct = StringLiteralContext(expectedType: nil, inferred: false)
    static let inferred = StringLiteralContext(expectedType: nil, inferred: true)

    static func typed(_ type: String?) -> StringLiteralContext {
        StringLiteralContext(expectedType: type, inferred: false)
    }
}

private final class ValueFlowBlockBuilder {
    let id: Int
    var instructions: [ValueFlowInstruction] = []
    var terminator: ValueFlowTerminator = .stop(reason: "open block")

    init(id: Int) { self.id = id }

    var isOpen: Bool {
        if case .stop(let reason) = terminator, reason == "open block" { return true }
        return false
    }

    func value() -> ValueFlowBlock {
        ValueFlowBlock(id: id, instructions: instructions, terminator: terminator)
    }
}

/// 한 함수의 명령 ID·스코프·CFG를 만든다.
final class ValueFlowFunctionBuilder {
    private let state: ValueFlowLoweringState
    private let info: ValueFlowDeclarationCollector.FunctionInfo
    private weak var parent: ValueFlowFunctionBuilder?
    private var blocks: [ValueFlowBlockBuilder] = [ValueFlowBlockBuilder(id: 0)]
    private var currentBlock = 0
    private var nextInstruction = 0
    private var nextBlock = 1
    private var scopes: [ValueFlowScope] = []
    private var explicitCaptures: [(name: String, operand: Int)] = []
    private var captureNames: [String: Int] = [:]
    private var captureBindings: [String: ValueFlowBinding] = [:]
    private var captureParentOperands: [Int: Int] = [:]
    private var shorthandParameters: [String: ValueFlowBinding] = [:]
    private var didCreateReceiver = false
    private var unavailableReason: String?

    init(state: ValueFlowLoweringState, info: ValueFlowDeclarationCollector.FunctionInfo, parent: ValueFlowFunctionBuilder? = nil) {
        self.state = state
        self.info = info
        self.parent = parent
        self.unavailableReason = info.unavailableReason
    }

    static func lower(state: ValueFlowLoweringState,
                      info: ValueFlowDeclarationCollector.FunctionInfo,
                      parent: ValueFlowFunctionBuilder? = nil) -> ValueFlowFunction? {
        guard state.claimFunctionID(info.id) else { return nil }
        return ValueFlowFunctionBuilder(state: state, info: info, parent: parent).lower()
    }

    func lower() -> ValueFlowFunction {
        scopes = [ValueFlowScope()]
        for capture in explicitCaptures {
            let index = captureNames.count
            captureNames[capture.name] = index
            captureParentOperands[index] = capture.operand
            bind(capture.name, .value(emit(.capture(index))))
        }
        createParameters()
        if info.kind != .function && info.kind != .initializer && info.kind != .getter && info.kind != .setter && info.kind != .closure {
            // 전역·필드 초기화 함수에는 암시적 수신자가 없다.
        } else if info.ownerType != nil && !info.isStatic && info.kind != .closure {
            let receiver = emit(.receiver)
            bind("self", .value(receiver))
            didCreateReceiver = true
        }

        if let body = info.body {
            switch body {
            case .function(let node):
                if let codeBlock = node.body {
                    lower(items: codeBlock.statements, implicitReturn: info.allowsImplicitReturn,
                          context: returnContext)
                }
            case .initializer(let node):
                if let codeBlock = node.body { lower(items: codeBlock.statements) }
            case .accessor(let node, _):
                if let codeBlock = node.body {
                    lower(items: codeBlock.statements, implicitReturn: info.allowsImplicitReturn,
                          context: returnContext)
                }
            case .closure(let node):
                if info.parameters.isEmpty { lowerClosureSignature(node.signature) }
                lower(items: node.statements, implicitReturn: true, context: returnContext)
            case .global(let items):
                lower(items: items, implicitReturn: info.allowsImplicitReturn)
            case .initializerExpression(let expression):
                let value = lowerExpression(expression, context: returnContext)
                if currentIsOpen { terminate(.return(value)) }
            }
        } else if unavailableReason == nil {
            unavailableReason = "declaration has no lowerable body"
        }

        if currentIsOpen {
            if info.kind == .global || info.kind == .initializer || info.kind == .getter
                || info.kind == .setter || info.kind == .closure || !info.allowsImplicitReturn {
                terminate(.return(nil))
            } else {
                terminate(.stop(reason: "implicit fallthrough; return value is unavailable"))
            }
        }

        let blocks = self.blocks.map { $0.value() }
        return ValueFlowFunction(
            id: info.id,
            name: info.name,
            indexName: info.indexName,
            location: info.location,
            kind: info.kind,
            parameters: info.parameters,
            blocks: blocks,
            entry: 0,
            ownerType: info.ownerType,
            isStatic: info.isStatic,
            isEntryPoint: info.isEntryPoint,
            mayBeCalledExternally: info.mayBeCalledExternally,
            unavailableReason: unavailableReason,
            returnType: info.returnType
        )
    }

    private var returnContext: StringLiteralContext {
        StringLiteralContext.typed(info.returnType)
    }

    // MARK: 매개변수와 스코프

    private func createParameters() {
        for (index, parameter) in info.parameters.enumerated() {
            let parameterValue = emit(.parameter(index))
            if parameter.isInout {
                bind(parameter.name, .address(parameterValue))
            } else {
                let address = emit(.local(name: parameter.name, initial: parameterValue, mutable: false))
                bind(parameter.name, .address(address))
            }
        }
    }

    private func lowerClosureSignature(_ signature: ClosureSignatureSyntax?) {
        guard let parameterClause = signature?.parameterClause else { return }
        switch parameterClause {
        case .parameterClause(let clause):
            for (index, parameter) in clause.parameters.enumerated() {
                let parameterValue = emit(.parameter(index), syntax: parameter)
                let first = parameter.firstName.text
                let second = parameter.secondName?.text
                let name = ValueFlowSyntax.unescaped(second ?? first)
                let address = emit(.local(name: name, initial: parameterValue, mutable: false), syntax: parameter)
                bind(name, .address(address))
            }
        case .simpleInput(let parameters):
            for (index, parameter) in parameters.enumerated() {
                let parameterValue = emit(.parameter(index), syntax: parameter)
                let name = ValueFlowSyntax.unescaped(parameter.name.text)
                let address = emit(.local(name: name, initial: parameterValue, mutable: false), syntax: parameter)
                bind(name, .address(address))
            }
        }
    }

    private func bind(_ name: String, _ binding: ValueFlowBinding) {
        scopes[scopes.count - 1].values[ValueFlowSyntax.unescaped(name)] = binding
    }

    private func lookup(_ name: String) -> ValueFlowBinding? {
        let clean = ValueFlowSyntax.unescaped(name)
        for scope in scopes.reversed() {
            if let value = scope.values[clean] { return value }
        }
        if let parent, let captured = capture(from: parent, name: clean) {
            return captured
        }
        if info.kind == .closure, let index = shorthandIndex(clean) {
            return ensureShorthandParameter(name: clean, index: index)
        }
        return nil
    }

    private func shorthandIndex(_ name: String) -> Int? {
        guard name.first == "$", name.count > 1 else { return nil }
        return Int(name.dropFirst())
    }

    private func ensureShorthandParameter(name: String, index: Int) -> ValueFlowBinding {
        if let binding = shorthandParameters[name] { return binding }
        let parameter = emit(.parameter(index))
        let address = emit(.local(name: name, initial: parameter, mutable: false))
        let binding = ValueFlowBinding.address(address)
        shorthandParameters[name] = binding
        scopes[0].values[name] = binding
        return binding
    }

    private func capture(from parent: ValueFlowFunctionBuilder, name: String) -> ValueFlowBinding? {
        guard let parentBinding = parent.bindingForChild(name) else { return nil }
        if let binding = captureBindings[name] { return binding }
        let index = captureNames.count
        captureNames[name] = index
        let captureID = emit(.capture(index))
        captureParentOperands[index] = parentBinding.operandID
        let binding = parentBinding.isAddress ? ValueFlowBinding.address(captureID) : .value(captureID)
        captureBindings[name] = binding
        return binding
    }

    private func bindingForChild(_ name: String) -> ValueFlowBinding? {
        let clean = ValueFlowSyntax.unescaped(name)
        for scope in scopes.reversed() {
            if let value = scope.values[clean] { return value }
        }
        if let parent { return capture(from: parent, name: clean) }
        return nil
    }

    private func pushScope() { scopes.append(ValueFlowScope()) }
    private func popScope() { if scopes.count > 1 { scopes.removeLast() } }

    // MARK: 블록

    private var current: ValueFlowBlockBuilder { blocks[currentBlock] }
    private var currentIsOpen: Bool { current.isOpen }

    private func makeBlock() -> Int {
        let id = nextBlock
        nextBlock += 1
        blocks.append(ValueFlowBlockBuilder(id: id))
        return id
    }

    private func switchTo(_ block: Int) { currentBlock = block }

    private func terminate(_ terminator: ValueFlowTerminator) {
        guard currentIsOpen else { return }
        current.terminator = terminator
    }

    private func jumpIfOpen(to block: Int) {
        if currentIsOpen { terminate(.jump(block)) }
    }

    private func emit(_ operation: ValueFlowOperation) -> Int {
        emit(operation, location: info.location)
    }

    private func emit<S: SyntaxProtocol>(_ operation: ValueFlowOperation, syntax: S) -> Int {
        emit(operation, location: ValueFlowSyntax.location(of: syntax, converter: state.converter, path: state.path))
    }

    private func emit(_ operation: ValueFlowOperation, location: CartographCore.SourceLocation) -> Int {
        let id = nextInstruction
        nextInstruction += 1
        current.instructions.append(ValueFlowInstruction(id: id, operation: operation, location: location))
        return id
    }

    // MARK: 문장

    private func lower(
        items: CodeBlockItemListSyntax,
        implicitReturn: Bool = false,
        context: StringLiteralContext = .direct
    ) {
        lower(items: Array(items), implicitReturn: implicitReturn, context: context)
    }

    private func lower(
        items: [CodeBlockItemSyntax],
        implicitReturn: Bool = false,
        context: StringLiteralContext = .direct
    ) {
        if implicitReturn, items.count == 1, let expression = items[0].item.as(ExprSyntax.self),
           expression.as(IfExprSyntax.self) == nil, currentIsOpen {
            let value = lowerExpression(expression, context: context)
            terminate(.return(value))
            return
        }
        for item in items {
            guard currentIsOpen else { break }
            lower(item: item, context: context)
        }
    }

    private func lower(item: CodeBlockItemSyntax, context: StringLiteralContext) {
        if let declaration = item.item.as(VariableDeclSyntax.self) {
            lower(local: declaration)
        } else if let expression = item.item.as(ExprSyntax.self) {
            if let ifExpression = expression.as(IfExprSyntax.self) {
                lowerIfStatement(ifExpression)
            } else {
                _ = lowerExpression(expression, context: context)
            }
        } else if let statement = item.item.as(StmtSyntax.self) {
            lower(statement: statement)
        } else if let declaration = item.item.as(IfConfigDeclSyntax.self) {
            _ = emit(.unknown(reason: "conditional compilation", inputs: [], mayWrite: true), syntax: declaration)
            terminate(.stop(reason: "unsupported control flow"))
        } else if item.item.as(FunctionDeclSyntax.self) != nil || item.item.as(InitializerDeclSyntax.self) != nil {
            // 지역 함수 선언은 실행 시점의 값 효과가 없다. 별도 FunctionInfo로 낮춘다.
        } else if let declaration = item.item.as(DeclSyntax.self) {
            _ = emit(.unknown(reason: "unsupported declaration", inputs: [], mayWrite: true), syntax: declaration)
            terminate(.stop(reason: "unsupported control flow"))
        } else if item.item.hasError {
            _ = emit(.unknown(reason: "syntax error", inputs: [], mayWrite: true), syntax: item)
            terminate(.stop(reason: "syntax error"))
        }
    }

    private func lower(local declaration: VariableDeclSyntax) {
        let mutable = declaration.bindingSpecifier.text == "var"
        for binding in declaration.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                _ = emit(.unknown(reason: "complex local binding", inputs: [], mayWrite: true), syntax: declaration)
                continue
            }
            let declaredType = binding.typeAnnotation?.type.trimmedDescription
            let context = declaredType.map(StringLiteralContext.typed) ?? .inferred
            let initial = binding.initializer.map { lowerExpression($0.value, context: context) }
            let address = emit(.local(name: pattern.identifier.text, initial: initial, mutable: mutable), syntax: pattern.identifier)
            bind(pattern.identifier.text, .address(address))
            if let accessor = binding.accessorBlock {
                _ = emit(.unknown(reason: "local accessor", inputs: [], mayWrite: true), syntax: accessor)
            }
        }
    }

    private func lower(statement: StmtSyntax) {
        if let returnStatement = statement.as(ReturnStmtSyntax.self) {
            let value = returnStatement.expression.map { lowerExpression($0, context: returnContext) }
            terminate(.return(value))
            return
        }
        if let ifExpression = IfExprSyntax(statement) {
            lowerIfStatement(ifExpression)
            return
        }
        if let whileStatement = statement.as(WhileStmtSyntax.self) {
            lower(whileStatement: whileStatement)
            return
        }
        if let doStatement = statement.as(DoStmtSyntax.self) {
            pushScope()
            lower(items: doStatement.body.statements)
            popScope()
            if !doStatement.catchClauses.isEmpty {
                unavailableReason = "catch control flow unavailable"
                if currentIsOpen {
                    _ = emit(.unknown(reason: "catch control flow", inputs: [], mayWrite: true), syntax: doStatement)
                    terminate(.stop(reason: "unsupported control flow"))
                }
            }
            return
        }
        if let guardStatement = statement.as(GuardStmtSyntax.self) {
            let inputs = lower(conditionElements: guardStatement.conditions)
            let unknown = emit(.unknown(reason: "guard condition", inputs: inputs, mayWrite: false), syntax: guardStatement)
            let body = makeBlock()
            let after = makeBlock()
            terminate(.branch(condition: unknown, then: after, otherwise: body))
            switchTo(body)
            pushScope()
            lower(items: guardStatement.body.statements)
            popScope()
            jumpIfOpen(to: after)
            switchTo(after)
            return
        }
        if let expressionStatement = statement.as(ExpressionStmtSyntax.self) {
            _ = lowerExpression(expressionStatement.expression, context: .direct)
            return
        }
        _ = emit(.unknown(reason: "unsupported statement", inputs: [], mayWrite: true), syntax: statement)
        terminate(.stop(reason: "unsupported control flow"))
    }

    private func lowerIfStatement(_ ifExpression: IfExprSyntax) {
        let conditionInputs = lower(conditionElements: ifExpression.conditions)
        let condition = conditionInputs.count == 1
            ? conditionInputs[0]
            : emit(.unknown(reason: "if condition", inputs: conditionInputs, mayWrite: false), syntax: ifExpression)
        let thenBlock = makeBlock()
        let elseBlock = makeBlock()
        let mergeBlock = makeBlock()
        terminate(.branch(condition: condition, then: thenBlock, otherwise: elseBlock))

        switchTo(thenBlock)
        pushScope()
        lower(items: ifExpression.body.statements)
        popScope()
        let thenFallsThrough = currentIsOpen
        jumpIfOpen(to: mergeBlock)

        switchTo(elseBlock)
        pushScope()
        if let elseBody = ifExpression.elseBody {
            switch elseBody {
            case .ifExpr(let nested): lowerIfStatement(nested)
            case .codeBlock(let block): lower(items: block.statements)
            }
        }
        popScope()
        let elseFallsThrough = currentIsOpen
        jumpIfOpen(to: mergeBlock)
        switchTo(mergeBlock)
        if !thenFallsThrough && !elseFallsThrough {
            terminate(.stop(reason: "unreachable merge"))
        }
    }

    private func lowerIfExpression(
        _ ifExpression: IfExprSyntax,
        context: StringLiteralContext
    ) -> Int {
        let conditionInputs = lower(conditionElements: ifExpression.conditions)
        let condition = conditionInputs.count == 1
            ? conditionInputs[0]
            : emit(.unknown(reason: "if expression condition", inputs: conditionInputs, mayWrite: false),
                   syntax: ifExpression)
        let result = emit(.local(name: "<if-expression>", initial: nil, mutable: true), syntax: ifExpression)
        let thenBlock = makeBlock()
        let elseBlock = makeBlock()
        let mergeBlock = makeBlock()
        terminate(.branch(condition: condition, then: thenBlock, otherwise: elseBlock))

        switchTo(thenBlock)
        pushScope()
        let thenValue = lowerExpressionBranch(ifExpression.body.statements, context: context)
        _ = emit(.write(address: result, value: thenValue), syntax: ifExpression.body)
        popScope()
        jumpIfOpen(to: mergeBlock)

        switchTo(elseBlock)
        pushScope()
        let elseValue: Int
        if let elseBody = ifExpression.elseBody {
            switch elseBody {
            case .ifExpr(let nested):
                elseValue = lowerIfExpression(nested, context: context)
            case .codeBlock(let block):
                elseValue = lowerExpressionBranch(block.statements, context: context)
            }
        } else {
            elseValue = emit(.unknown(reason: "if expression missing else", inputs: [], mayWrite: false),
                             syntax: ifExpression)
        }
        _ = emit(.write(address: result, value: elseValue), syntax: ifExpression)
        popScope()
        jumpIfOpen(to: mergeBlock)

        switchTo(mergeBlock)
        return emit(.read(address: result), syntax: ifExpression)
    }

    private func lowerExpressionBranch(
        _ items: CodeBlockItemListSyntax,
        context: StringLiteralContext
    ) -> Int {
        let elements = Array(items)
        if elements.count == 1, let expression = elements[0].item.as(ExprSyntax.self) {
            return lowerExpression(expression, context: context)
        }
        lower(items: elements)
        return emit(.unknown(reason: "if expression branch", inputs: [], mayWrite: true), syntax: items)
    }

    private func lower(whileStatement: WhileStmtSyntax) {
        let conditionBlock = makeBlock()
        let bodyBlock = makeBlock()
        let exitBlock = makeBlock()
        terminate(.jump(conditionBlock))

        switchTo(conditionBlock)
        let inputs = lower(conditionElements: whileStatement.conditions)
        let condition = inputs.count == 1
            ? inputs[0]
            : emit(.unknown(reason: "while condition", inputs: inputs, mayWrite: false), syntax: whileStatement)
        terminate(.branch(condition: condition, then: bodyBlock, otherwise: exitBlock))

        switchTo(bodyBlock)
        pushScope()
        lower(items: whileStatement.body.statements)
        popScope()
        jumpIfOpen(to: conditionBlock)
        switchTo(exitBlock)
    }

    private func lower(conditionElements: ConditionElementListSyntax) -> [Int] {
        var values: [Int] = []
        for element in conditionElements {
            switch element.condition {
            case .expression(let expression): values.append(lowerExpression(expression))
            case .availability: values.append(emit(.unknown(reason: "availability condition", inputs: [], mayWrite: false), syntax: element))
            case .matchingPattern(let matching):
                let input = lowerExpression(matching.initializer.value)
                values.append(emit(.unknown(reason: "pattern condition", inputs: [input], mayWrite: false), syntax: matching))
            case .optionalBinding(let optionalBinding):
                let input = optionalBinding.initializer.map { lowerExpression($0.value) }
                    ?? emit(.unknown(reason: "optional binding source", inputs: [], mayWrite: false), syntax: optionalBinding)
                values.append(emit(.unknown(reason: "optional binding condition", inputs: [input], mayWrite: false), syntax: optionalBinding))
            }
        }
        return values
    }

    // MARK: 표현식

    @discardableResult
    private func lowerExpression(
        _ expression: ExprSyntax,
        context: StringLiteralContext = .direct
    ) -> Int {
        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            let text = literal.literal.text.replacingOccurrences(of: "_", with: "")
            guard let value = Int(text) else {
                return unknown(reason: "integer literal overflow", inputs: [], mayWrite: false, syntax: literal)
            }
            return emit(.literal(.integer(value)), syntax: literal)
        }
        if let literal = expression.as(BooleanLiteralExprSyntax.self) {
            return emit(.literal(.boolean(literal.literal.text == "true")), syntax: literal)
        }
        if let literal = expression.as(SimpleStringLiteralExprSyntax.self) {
            return emit(.stringLiteral(
                literal.segments.description,
                expectedType: context.expectedType,
                inferred: context.inferred
            ), syntax: literal)
        }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            if let value = literal.representedLiteralValue {
                return emit(.stringLiteral(
                    value,
                    expectedType: context.expectedType,
                    inferred: context.inferred
                ), syntax: literal)
            }
            return unknown(reason: "string interpolation", inputs: lowerDirectExpressionChildren(expression), mayWrite: true, syntax: literal)
        }
        if expression.is(NilLiteralExprSyntax.self) {
            return emit(.literal(.null), syntax: expression)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return lower(reference: reference)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return lower(member: member, asAddress: false)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return lower(call: call, isAwait: false)
        }
        if let awaitExpression = expression.as(AwaitExprSyntax.self) {
            if let call = awaitExpression.expression.as(FunctionCallExprSyntax.self) {
                return lower(call: call, isAwait: true)
            }
            let input = lowerExpression(awaitExpression.expression)
            return unknown(reason: "await expression", inputs: [input], mayWrite: false, syntax: awaitExpression)
        }
        if let assignment = expression.as(AssignmentExprSyntax.self) {
            _ = assignment
            return emit(.literal(.unit), syntax: expression)
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            return lower(infix: infix)
        }
        if let ternary = expression.as(TernaryExprSyntax.self) {
            return lower(ternary: ternary, context: context)
        }
        if let ifExpression = expression.as(IfExprSyntax.self) {
            return lowerIfExpression(ifExpression, context: context)
        }
        if let closure = expression.as(ClosureExprSyntax.self) {
            return lower(closure: closure)
        }
        if let inoutExpression = expression.as(InOutExprSyntax.self) {
            return lowerAddress(inoutExpression.expression)
        }
        if let parentheses = expression.as(SequenceExprSyntax.self), parentheses.elements.count == 1,
           let child = parentheses.elements.first {
            return lowerExpression(child, context: context)
        }
        if let tryExpression = expression.as(TryExprSyntax.self) {
            return lowerExpression(tryExpression.expression, context: context)
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            let input = lowerDirectExpressionChildren(optional)
            return unknown(reason: "optional chaining", inputs: input, mayWrite: false, syntax: optional)
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            let inputs = lowerDirectExpressionChildren(switchExpression)
            let value = unknown(reason: "unsupported control flow", inputs: inputs, mayWrite: true, syntax: switchExpression)
            terminate(.stop(reason: "unsupported control flow"))
            return value
        }
        return unknown(
            reason: "unsupported expression",
            inputs: lowerDirectExpressionChildren(expression),
            mayWrite: true,
            syntax: expression
        )
    }

    private func lower(reference: DeclReferenceExprSyntax) -> Int {
        let name = ValueFlowSyntax.unescaped(reference.baseName.text)
        if let binding = lookup(name) {
            switch binding {
            case .address(let address): return emit(.read(address: address), syntax: reference.baseName)
            case .value(let value): return value
            }
        }
        if let member = implicitMember(name: name, syntax: reference.baseName, asAddress: false) {
            return member
        }
        if name == "self" && didCreateReceiver {
            return emit(.unknown(reason: "unbound self", inputs: [], mayWrite: false), syntax: reference)
        }
        return emit(.symbol(ValueFlowSymbolReference(
            location: ValueFlowSyntax.location(of: reference.baseName, converter: state.converter, path: state.path),
            spelling: name
        )), syntax: reference.baseName)
    }

    private func lower(member: MemberAccessExprSyntax, asAddress: Bool) -> Int {
        let base: Int
        if let expression = member.base {
            base = lowerExpression(expression)
        } else {
            base = emit(.symbol(ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: member.declName.baseName, converter: state.converter, path: state.path),
                spelling: "Self"
            )), syntax: member.declName.baseName)
        }
        let operation = emit(.member(
            base: base,
            symbol: ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: member.declName.baseName, converter: state.converter, path: state.path),
                spelling: ValueFlowSyntax.unescaped(member.declName.baseName.text)
            )
        ), syntax: member.declName.baseName)
        if asAddress { return operation }
        return emit(.read(address: operation), syntax: member.declName.baseName)
    }

    private func lowerAddress(_ expression: ExprSyntax) -> Int {
        if let inoutExpression = expression.as(InOutExprSyntax.self) {
            return lowerAddress(inoutExpression.expression)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self), let binding = lookup(reference.baseName.text) {
            switch binding {
            case .address(let address): return address
            case .value(let value): return value
            }
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self),
           let member = implicitMember(name: ValueFlowSyntax.unescaped(reference.baseName.text),
                                       syntax: reference.baseName, asAddress: true) {
            return member
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return lower(member: member, asAddress: true)
        }
        let value = lowerExpression(expression)
        return unknown(reason: "inout address unavailable", inputs: [value], mayWrite: true, syntax: expression)
    }

    private func implicitMember(name: String, syntax: some SyntaxProtocol, asAddress: Bool) -> Int? {
        guard let ownerType = info.ownerType else { return nil }
        let isField = state.fields.contains { $0.ownerType == ownerType && $0.name == name }
        let isFunction = state.knownFunctionNames.contains("\(ownerType)#\(name)")
            || state.functions.contains { $0.ownerType == ownerType && $0.name == name }
        guard isField || isFunction, let receiver = lookup("self") else { return nil }
        let member = emit(.member(
            base: receiver.operandID,
            symbol: ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: syntax, converter: state.converter, path: state.path),
                spelling: name
            )
        ), syntax: syntax)
        if asAddress || isFunction { return member }
        return emit(.read(address: member), syntax: syntax)
    }

    private func lower(call: FunctionCallExprSyntax, isAwait: Bool) -> Int {
        let callee = lowerCallee(call.calledExpression)
        var arguments: [Int] = []
        var labels: [String] = []
        for argument in call.arguments {
            labels.append(argument.label?.text ?? "")
            if argument.expression.as(InOutExprSyntax.self) != nil {
                arguments.append(lowerAddress(argument.expression))
            } else {
                arguments.append(lowerExpression(argument.expression))
            }
        }
        if let trailing = call.trailingClosure {
            arguments.append(lower(closure: trailing))
            labels.append("")
        }
        for trailing in call.additionalTrailingClosures {
            arguments.append(lower(closure: trailing.closure))
            labels.append(trailing.label.text)
        }
        return emit(.call(callee: callee, arguments: arguments, argumentLabels: labels, isAwait: isAwait), syntax: call)
    }

    private func lowerCallee(_ expression: ExprSyntax) -> Int {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = ValueFlowSyntax.unescaped(reference.baseName.text)
            if let binding = lookup(name) {
                switch binding {
                case .address(let address): return emit(.read(address: address), syntax: reference.baseName)
                case .value(let value): return value
                }
            }
            if let member = implicitMember(name: name, syntax: reference.baseName, asAddress: false) {
                return member
            }
            return emit(.symbol(ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: reference.baseName, converter: state.converter, path: state.path),
                spelling: name
            )), syntax: reference.baseName)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let base = member.base.map { lowerExpression($0) } ?? emit(.symbol(ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: member.declName.baseName, converter: state.converter, path: state.path), spelling: "Self"
            )), syntax: member.declName.baseName)
            return emit(.member(
                base: base,
                symbol: ValueFlowSymbolReference(
                    location: ValueFlowSyntax.location(of: member.declName.baseName, converter: state.converter, path: state.path),
                    spelling: ValueFlowSyntax.unescaped(member.declName.baseName.text)
                )
            ), syntax: member.declName.baseName)
        }
        return lowerExpression(expression)
    }

    /// 연산자 오버로드의 inout 가능성을 위해 lvalue는 주소로, 임시 값은 값으로 넘긴다.
    private func lowerOperatorOperand(_ expression: ExprSyntax) -> Int {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.label == nil {
            return lowerOperatorOperand(element.expression)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            if lookup(reference.baseName.text) != nil { return lowerAddress(expression) }
            if let member = implicitMember(name: reference.baseName.text, syntax: reference.baseName, asAddress: true) {
                return member
            }
            return emit(.symbol(ValueFlowSymbolReference(
                location: ValueFlowSyntax.location(of: reference.baseName, converter: state.converter, path: state.path),
                spelling: ValueFlowSyntax.unescaped(reference.baseName.text))), syntax: reference.baseName)
        }
        if expression.is(MemberAccessExprSyntax.self) || expression.is(InOutExprSyntax.self) {
            return lowerAddress(expression)
        }
        return lowerExpression(expression)
    }

    private func lower(infix: InfixOperatorExprSyntax) -> Int {
        let op = infix.operator.trimmedDescription
        if op == "=" {
            let rhs = lowerExpression(infix.rightOperand)
            if infix.leftOperand.as(DiscardAssignmentExprSyntax.self) != nil
                || (infix.leftOperand.as(DeclReferenceExprSyntax.self)?.baseName.text == "_") {
                return emit(.literal(.unit), syntax: infix.operator)
            }
            let address = lowerAddress(infix.leftOperand)
            _ = emit(.write(address: address, value: rhs), syntax: infix.operator)
            return emit(.literal(.unit), syntax: infix.operator)
        }
        let lhs = lowerOperatorOperand(infix.leftOperand)
        let rhs = lowerOperatorOperand(infix.rightOperand)
        return emit(.operatorApplication(op, inputs: [lhs, rhs]), syntax: infix.operator)
    }

    private func lower(
        ternary: TernaryExprSyntax,
        context: StringLiteralContext
    ) -> Int {
        let condition = lowerExpression(ternary.condition)
        let result = emit(.local(name: "<ternary-expression>", initial: nil, mutable: true), syntax: ternary)
        let thenBlock = makeBlock()
        let elseBlock = makeBlock()
        let mergeBlock = makeBlock()
        terminate(.branch(condition: condition, then: thenBlock, otherwise: elseBlock))

        switchTo(thenBlock)
        pushScope()
        let thenValue = lowerExpression(ternary.thenExpression, context: context)
        _ = emit(.write(address: result, value: thenValue), syntax: ternary.thenExpression)
        popScope()
        jumpIfOpen(to: mergeBlock)

        switchTo(elseBlock)
        pushScope()
        let elseValue = lowerExpression(ternary.elseExpression, context: context)
        _ = emit(.write(address: result, value: elseValue), syntax: ternary.elseExpression)
        popScope()
        jumpIfOpen(to: mergeBlock)

        switchTo(mergeBlock)
        return emit(.read(address: result), syntax: ternary)
    }

    private func lower(closure: ClosureExprSyntax) -> Int {
        let id = ValueFlowID.make(path: state.path, node: closure, kind: "closure")
        let nestedInfo = ValueFlowDeclarationCollector.FunctionInfo(
            id: id,
            name: "<closure>",
            indexName: "<closure>",
            location: ValueFlowSyntax.location(of: closure.leftBrace, converter: state.converter, path: state.path),
            kind: .closure,
            parameters: ValueFlowSyntax.closureParameters(closure.signature),
            allowsImplicitReturn: true,
            returnType: ValueFlowSyntax.closureReturnType(closure.signature),
            body: .closure(closure),
            ownerType: info.ownerType,
            isStatic: false,
            isEntryPoint: false,
            mayBeCalledExternally: false,
            unavailableReason: closure.hasError ? "closure contains syntax errors" : nil
        )
        guard state.claimFunctionID(id) else {
            return emit(.unknown(reason: "duplicate closure", inputs: [], mayWrite: false), syntax: closure)
        }
        let nested = ValueFlowFunctionBuilder(state: state, info: nestedInfo, parent: self)
        for capture in closure.signature?.capture?.items ?? [] {
            let name = ValueFlowSyntax.unescaped(capture.name.text)
            let operand = capture.initializer.map { lowerExpression($0.value, context: .inferred) }
                ?? capturedValue(named: name, token: capture.name)
            let copied = emit(.read(address: operand), syntax: capture)
            nested.explicitCaptures.append((name, copied))
            if capture.specifier != nil { nested.unavailableReason = "capture ownership is unavailable" }
        }
        let function = nested.lower()
        state.append(function: function)
        let captures = nested.captureParentOperands.sorted { $0.key < $1.key }.map(\.value)
        return emit(.closure(function: id, captures: captures), syntax: closure)
    }

    /// 캡처 목록은 클로저 생성 시점에 읽고, 본문에서는 외부 지역 주소를 다시 읽지 않는다.
    private func capturedValue(named name: String, token: TokenSyntax) -> Int {
        if let binding = lookup(name) { return binding.operandID }
        if let member = implicitMember(name: name, syntax: token, asAddress: false) { return member }
        return emit(.symbol(ValueFlowSymbolReference(
            location: ValueFlowSyntax.location(of: token, converter: state.converter, path: state.path),
            spelling: name)), syntax: token)
    }

    private func lowerDirectExpressionChildren(_ expression: some SyntaxProtocol) -> [Int] {
        var values: [Int] = []
        for child in expression.children(viewMode: .sourceAccurate) {
            if let childExpression = child.as(ExprSyntax.self) {
                values.append(lowerExpression(childExpression))
            }
        }
        return values
    }

    private func unknown(reason: String, inputs: [Int], mayWrite: Bool, syntax: some SyntaxProtocol) -> Int {
        emit(.unknown(reason: reason, inputs: inputs, mayWrite: mayWrite), syntax: syntax)
    }
}

private extension ValueFlowBinding {
    var operandID: Int {
        switch self {
        case .address(let id), .value(let id): return id
        }
    }

    var isAddress: Bool {
        if case .address = self { return true }
        return false
    }
}
