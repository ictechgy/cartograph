import SwiftSyntax

/// 런타임 스캐너들이 공유하는 Swift 이름과 selector 구문 해석이다.
enum RuntimeSyntaxNames {
    struct NameAPI {
        let api: String
        let token: TokenSyntax
    }

    struct SelectorTarget {
        let selector: String
        let member: String
        let token: TokenSyntax
        let receiverType: String?
        let receiverToken: TokenSyntax?
    }

    static func calleeToken(_ expression: ExprSyntax) -> TokenSyntax? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName }
        if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) {
            return calleeToken(specialized.expression)
        }
        return nil
    }

    static func calleeName(_ call: FunctionCallExprSyntax) -> String? {
        calleeToken(call.calledExpression).map { SyntaxIdentifiers.unescaped($0.text) }
    }

    static func dottedName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return SyntaxIdentifiers.unescaped(reference.baseName.text)
        }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
              let prefix = dottedName(base)
        else { return nil }
        return prefix + "." + SyntaxIdentifiers.unescaped(member.declName.baseName.text)
    }

    static func nameAPI(_ expression: ExprSyntax) -> NameAPI? {
        guard let fullName = dottedName(expression), let token = calleeToken(expression) else { return nil }
        let baseName: String
        if fullName.hasSuffix(".init") {
            baseName = String(fullName.dropLast(".init".count))
        } else {
            baseName = fullName
        }
        let api: String
        if baseName == "Selector" || baseName.hasSuffix(".Selector") { api = "Selector" }
        else if baseName == "NSSelectorFromString" || baseName.hasSuffix(".NSSelectorFromString") {
            api = "NSSelectorFromString"
        } else if baseName == "Notification.Name" || baseName.hasSuffix(".Notification.Name") {
            api = "Notification.Name"
        } else if baseName == "Name" || baseName.hasSuffix(".Name") { api = "Name" }
        else { return nil }
        return NameAPI(api: api, token: token)
    }

    static func selectorTarget(_ expression: ExprSyntax) -> SelectorTarget? {
        let expression = unparenthesized(expression)
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
            let colons = member.declName.argumentNames?.arguments.count ?? 0
            let receiver = member.base.flatMap(dottedName)
            return SelectorTarget(
                selector: name + String(repeating: ":", count: colons), member: name,
                token: member.declName.baseName, receiverType: receiver,
                receiverToken: member.base.flatMap(calleeToken)
            )
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
            let colons = reference.argumentNames?.arguments.count ?? 0
            return SelectorTarget(
                selector: name + String(repeating: ":", count: colons), member: name,
                token: reference.baseName, receiverType: nil, receiverToken: nil
            )
        }
        return nil
    }

    static func unparenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        guard let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let element = tuple.elements.first, element.label == nil
        else { return expression }
        return unparenthesized(element.expression)
    }

    static func isNil(_ expression: ExprSyntax) -> Bool {
        var value = unparenthesized(expression)
        while let cast = value.as(AsExprSyntax.self) { value = unparenthesized(cast.expression) }
        return value.is(NilLiteralExprSyntax.self)
    }

    static func indexName(_ base: String, parameters: FunctionParameterListSyntax) -> String {
        SyntaxIdentifiers.unescaped(base) + "("
            + parameters.map { SyntaxIdentifiers.unescaped($0.firstName.text) + ":" }.joined() + ")"
    }
}
