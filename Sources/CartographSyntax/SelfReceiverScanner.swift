import CartographCore
import SwiftSyntax

/// Syntax identity is intentionally separate from compiler symbol identity.
public struct SelfReceiverSyntaxCall: Codable, Equatable, Sendable {
    public let location: CartographCore.SourceLocation
    public let callerLocation: CartographCore.SourceLocation
    public let memberName: String?

    public init(location: CartographCore.SourceLocation, callerLocation: CartographCore.SourceLocation,
                memberName: String? = nil) {
        self.location = location
        self.callerLocation = callerLocation
        self.memberName = memberName
    }
}

public struct DispatchReceiverSyntaxFacts: Codable, Equatable, Sendable {
    public let selfCalls: [SelfReceiverSyntaxCall]
    public let finalClassLocations: [CartographCore.SourceLocation]
}

struct SelfReceiverScanner {
    func scan(tree: SourceFileSyntax, path: String,
              converter: SourceLocationConverter) -> DispatchReceiverSyntaxFacts? {
        guard !tree.hasError else { return nil }
        let collector = SelfReceiverCollector(path: path, converter: converter)
        collector.walk(tree)
        return DispatchReceiverSyntaxFacts(selfCalls: collector.calls, finalClassLocations: collector.finalClassLocations)
    }
}

private final class SelfReceiverCollector: SyntaxVisitor {
    private struct Caller {
        let location: CartographCore.SourceLocation
        let body: CodeBlockSyntax
    }
    private let path: String
    private let converter: SourceLocationConverter
    private var callers: [Caller?] = []
    private(set) var calls: [SelfReceiverSyntaxCall] = []
    private(set) var finalClassLocations: [CartographCore.SourceLocation] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.modifiers.contains(where: { $0.name.text == "final" }) {
            finalClassLocations.append(location(node.name.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let member = node.parent?.is(MemberBlockItemSyntax.self) == true
        let instance = !node.modifiers.contains { ["static", "class"].contains($0.name.text) }
        let caller = member && instance && callers.isEmpty
            ? node.body.map { Caller(location: location(node.name.positionAfterSkippingLeadingTrivia), body: $0) } : nil
        callers.append(caller)
        return .visitChildren
    }
    override func visitPost(_: FunctionDeclSyntax) { callers.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let caller = callers.isEmpty && node.parent?.is(MemberBlockItemSyntax.self) == true
            ? node.body.map { Caller(location: location(node.initKeyword.positionAfterSkippingLeadingTrivia), body: $0) } : nil
        callers.append(caller)
        return .visitChildren
    }
    override func visitPost(_: InitializerDeclSyntax) { callers.removeLast() }

    // Captures may rebind self; local functions and accessors require a separate
    // compiler owner proof. This first bounded capability does not infer them.
    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let entry = callers.last, let caller = entry,
              caller.body.positionAfterSkippingLeadingTrivia <= node.positionAfterSkippingLeadingTrivia,
              node.endPositionBeforeTrailingTrivia <= caller.body.endPositionBeforeTrailingTrivia
        else { return .visitChildren }
        let token: TokenSyntax?
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "self" {
            token = member.declName.baseName
        } else if let implicit = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            // The binder also requires the exact compiler target to be an instance
            // method with this spelling; callable values remain conservative.
            token = implicit.baseName
        } else {
            token = nil
        }
        if let token {
            calls.append(SelfReceiverSyntaxCall(location: location(token.positionAfterSkippingLeadingTrivia),
                callerLocation: caller.location, memberName: token.text))
        }
        return .visitChildren
    }

    private func location(_ position: AbsolutePosition) -> CartographCore.SourceLocation {
        let point = converter.location(for: position)
        return CartographCore.SourceLocation(path: path, line: point.line, column: point.column)
    }
}
