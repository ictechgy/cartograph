import CartographCore
import Foundation
import SwiftParser
import SwiftSyntax

/// 코어 RN의 직접 RCTEventEmitter 하위 타입에서만 전역 이벤트 방출을 관찰한다.
public struct ReactNativeEventScanner: Sendable {
    public init() {}

    /// 인덱스 신원을 합성하지 않고 방출을 담은 Swift 선언을 함께 돌려준다.
    public func scan(
        source: String, path: String, onUnsupported: (String) -> Void = { _ in }
    ) -> [ScannedBridgeFact] {
        let tree = Parser.parse(source: source)
        let tokens = Array(tree.tokens(viewMode: .sourceAccurate))
        let importsReact = tree.statements.contains { statement in
            guard let item = statement.item.as(ImportDeclSyntax.self) else { return false }
            return item.path.first.map { ["React", "React_RCTEventEmitter"].contains($0.name.text) } ?? false
        }
        guard importsReact else {
            let imports = ReactEventImportVisitor(viewMode: .sourceAccurate)
            imports.walk(tree)
            if imports.hasReactImport { onUnsupported("conditional-import") }
            return []
        }
        if tokens.indices.dropLast().contains(where: {
            ["class", "typealias"].contains(tokens[$0].text) && tokens[$0 + 1].text == "RCTEventEmitter"
        }) { onUnsupported("shadowed-identifiers"); return [] }
        if tokens.indices.dropLast().contains(where: {
            ["func", "let", "var"].contains(tokens[$0].text) && tokens[$0 + 1].text == "sendEvent" ||
                tokens[$0].text == "sendEvent" && tokens[$0 + 1].text == ":"
        }) { onUnsupported("shadowed-identifiers"); return [] }
        let visitor = ReactNativeEventVisitor(path: path, tree: tree)
        visitor.walk(tree)
        for _ in 0..<visitor.unsupportedExtensions { onUnsupported("extension") }
        for _ in 0..<visitor.unsupportedConditionals { onUnsupported("conditional-compilation") }
        return visitor.facts
    }
}

private final class ReactEventImportVisitor: SyntaxVisitor {
    var hasReactImport = false
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.path.first.map({ ["React", "React_RCTEventEmitter"].contains($0.name.text) }) == true {
            hasReactImport = true
        }
        return .skipChildren
    }
}

private final class ReactNativeEventVisitor: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    var types: [(name: String, emitter: Bool)] = []
    var declarations: [EnclosingDeclaration] = []
    var facts: [ScannedBridgeFact] = []
    var unsupportedExtensions = 0
    var unsupportedConditionals = 0

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let emitter = node.inheritanceClause?.inheritedTypes.contains {
            ["RCTEventEmitter", "React.RCTEventEmitter"].contains($0.type.trimmedDescription)
        } ?? false
        types.append((node.name.text, emitter))
        return .visitChildren
    }
    override func visitPost(_: ClassDeclSyntax) { types.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        types.append((node.name.text, false)); return .visitChildren
    }
    override func visitPost(_: StructDeclSyntax) { types.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        types.append((node.name.text, false)); return .visitChildren
    }
    override func visitPost(_: EnumDeclSyntax) { types.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        types.append((node.name.text, false)); return .visitChildren
    }
    override func visitPost(_: ActorDeclSyntax) { types.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.tokens(viewMode: .sourceAccurate).contains(where: { $0.text == "sendEvent" }) {
            unsupportedExtensions += 1
        }
        return .skipChildren
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.tokens(viewMode: .sourceAccurate).contains(where: { $0.text == "sendEvent" }) {
            unsupportedConditionals += 1
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let point = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        declarations.append(EnclosingDeclaration(name: node.name.text,
            indexName: RuntimeSyntaxNames.indexName(node.name.text, parameters: node.signature.parameterClause.parameters),
            qualifiedName: (types.map(\.name) + [node.name.text]).joined(separator: "."), line: point.line))
        return .visitChildren
    }
    override func visitPost(_: FunctionDeclSyntax) { declarations.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard types.last?.emitter == true else { return .visitChildren }
        let called: String?
        if let name = node.calledExpression.as(DeclReferenceExprSyntax.self) { called = name.baseName.text }
        else if let member = node.calledExpression.as(MemberAccessExprSyntax.self), member.base?.trimmedDescription == "self" {
            called = member.declName.baseName.text
        } else { called = nil }
        guard called == "sendEvent", let argument = node.arguments.first,
              argument.label?.text == "withName" else { return .visitChildren }
        let value = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        let literal = value.flatMap { !$0.isEmpty && PrintableText.printable($0) == $0 ? $0 : nil }
        let expression = PrintableText.printable(argument.expression.trimmedDescription)
        let point = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        facts.append(ScannedBridgeFact(fact: BridgeFact(kind: .eventEmit, target: .reactNative,
            channel: literal ?? (expression.isEmpty ? "<dynamic>" : expression), isDynamic: literal == nil,
            location: .init(path: path, line: point.line, column: point.column)), declaration: declarations.last))
        return .visitChildren
    }
}
