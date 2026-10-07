import CartographCore
import SwiftSyntax

/// enum case 선언 하나. 라우터 case 마다 route-call 을 내고, 그 case 를 사실의 심볼로 쓴다.
///
/// 라우터의 경로는 호출 지점이 아니라 case 별 분기에 있다. 사실을 case 에 귀속시키면 isthmus trace 의
/// 역방향 순회가 인덱스의 case 참조(`provider.request(.users)`, `fetch(.users)`)를 따라 그 엔드포인트를
/// 쓰는 모든 코드에 닿는다. 호출 지점마다 사실을 내면 `target` 을 매개변수로 흘리는 중간 함수 뒤의
/// 호출자는 귀속할 수 없다.
public struct HTTPEnumCaseDeclaration: Hashable, Sendable {
    public let name: String
    /// 인덱스가 붙이는 이름. 연관값이 있으면 레이블까지 붙는다(`user(id:)`, `item(_:)`).
    public let indexName: String
    /// 문자열 원시값. 명시한 리터럴이거나, 원시 타입이 `String` 인 enum 의 암시적 값(case 이름)이다.
    public let rawValue: String?
    /// `#if` 안에서만 선언된 case인지. 활성 조건을 모르는 문서 스캔에서는 값을 확정할 수 없다.
    public let isConditional: Bool
    public let start: CartographCore.SourceLocation
    public let end: CartographCore.SourceLocation

    public init(name: String, indexName: String, rawValue: String?, start: CartographCore.SourceLocation,
                end: CartographCore.SourceLocation, isConditional: Bool = false) {
        self.name = name
        self.indexName = indexName
        self.rawValue = rawValue
        self.isConditional = isConditional
        self.start = start
        self.end = end
    }
}

/// 타입의 주 선언(익스텐션이 아닌 것)의 위치. 비열거 라우터 타입의 심볼이다.
public struct HTTPTypeDeclarationSite: Hashable, Sendable {
    public let name: String
    public let start: CartographCore.SourceLocation
    public let end: CartographCore.SourceLocation

    public init(name: String, start: CartographCore.SourceLocation, end: CartographCore.SourceLocation) {
        self.name = name
        self.start = start
        self.end = end
    }
}

/// 다른 파일의 정적 문자열 멤버를 안전하게 다시 찾기 위한 닫힌 식.
///
/// 호출부에서 실행하거나 이름을 추측하지 않고, 리터럴·멤버 참조·원시값·문자열 연결만 허용한다.
indirect enum HTTPStaticStringExpression: Hashable, Sendable {
    case literal(String)
    case reference(type: [String], member: String)
    case rawValue(type: [String], caseName: String)
    case concatenation([Self])
    case unknown
}

/// 타입 안의 정적 문자열 선언 하나.
struct HTTPStaticStringMember: Hashable, Sendable {
    let owner: String
    let name: String
    let expression: HTTPStaticStringExpression
    let isSafe: Bool
    let location: CartographCore.SourceLocation
    let isConditional: Bool
}

/// 문서 전체에서 보이는 typealias 선언 하나.
struct HTTPTypeAliasDeclaration: Hashable, Sendable {
    let name: String
    let target: [String]
    let location: CartographCore.SourceLocation
    let isConditional: Bool
}

/// 프로토콜이 요구하는 연관 타입 이름 하나.
struct HTTPAssociatedTypeDeclaration: Hashable, Sendable {
    let name: String
    let isConditional: Bool
}

/// 이 도구가 읽는 라우터 프로토콜.
public enum HTTPRouterKind: String, Hashable, Sendable, CaseIterable {
    /// Moya `TargetType`: `baseURL`·`path`·`method` 멤버.
    case moya = "TargetType"
    /// Alamofire `URLRequestConvertible`: `asURLRequest()` 가 요청을 만든다.
    case alamofire = "URLRequestConvertible"
}

extension HTTPDeclarationSurface {
    /// 라우터 타입 문맥에서 보이는 프로토콜 연관 타입 이름을 모은다.
    func associatedTypeNames(in chain: String) -> Set<String> {
        var visited = Set<String>()
        var pending = [chain]
        var names = Set<String>()
        while let owner = pending.popLast() {
            guard visited.insert(owner).inserted else { continue }
            for declaration in associatedTypes[owner] ?? [] { names.insert(declaration.name) }
            for inherited in inheritedNames[owner] ?? [] {
                for protocolChain in protocolChains
                where protocolChain == inherited || protocolChain.split(separator: ".").last.map(String.init) == inherited {
                    pending.append(protocolChain)
                }
            }
        }
        return names
    }

    /// 타입 사슬이 준수하는 이름의 닫힘. 프로젝트 프로토콜의 상속을 따라간다.
    ///
    /// 상속 절은 이름만 적으므로(`BaseTarget`, `Moya.TargetType`) 마지막 구성 요소로 비교하고, 그 이름의
    /// 프로젝트 프로토콜이 다시 상속하는 이름을 더한다. `protocol BaseTarget: TargetType` 을 거친 준수가
    /// 흔한 모양이다.
    func conformedNames(of chain: String) -> Set<String> {
        var seen: Set<String> = []
        var queue = Array(inheritedNames[chain] ?? [])
        while let name = queue.popLast() {
            guard seen.insert(name).inserted else { continue }
            for protocolChain in protocolChains where protocolChain.split(separator: ".").last.map(String.init) == name {
                queue.append(contentsOf: inheritedNames[protocolChain] ?? [])
            }
        }
        return seen
    }

    /// 프로젝트가 같은 이름의 타입을 선언했는지. 그렇다면 라이브러리 프로토콜이라고 증명할 수 없다.
    func declaresTypeNamed(_ name: String) -> Bool {
        typeLastNames.contains(name)
    }

    /// 사슬이 라이브러리 라우터 프로토콜을 준수하는 구체 타입이면 그 종류. 프로토콜 자신은 아니다.
    public func routerKind(of chain: String) -> HTTPRouterKind? {
        guard !protocolChains.contains(chain) else { return nil }
        let names = conformedNames(of: chain)
        return HTTPRouterKind.allCases.first { names.contains($0.rawValue) && !declaresTypeNamed($0.rawValue) }
    }

    /// 사슬의 멤버를 라우터 표로 읽어야 하는지. 구체 라우터, 라우터 프로토콜을 상속한 프로젝트
    /// 프로토콜(기본 구현을 담는 익스텐션), 라이브러리 프로토콜 자신의 익스텐션이다.
    func ownsRouterMembers(_ chain: String) -> Bool {
        if HTTPRouterKind.allCases.contains(where: { $0.rawValue == chain && !declaresTypeNamed($0.rawValue) }) { return true }
        let names = conformedNames(of: chain)
        return HTTPRouterKind.allCases.contains { names.contains($0.rawValue) && !declaresTypeNamed($0.rawValue) }
    }

    /// 구체 라우터 타입 사슬들. 결정적 순서다.
    public var routerChains: [String] {
        typeChains.filter { routerKind(of: $0) != nil }.sorted()
    }

    /// `A.B.rawValue` 의 원시값. 원시 타입이 `String` 인 enum 의 case 일 때만.
    func rawValue(ofCase name: String, inTypeNamed type: [String]) -> String? {
        var resolver = staticStringResolver()
        return resolver.rawValue(ofCase: name, inTypeNamed: type, depth: 0)
    }

    /// 다른 파일의 Type.member 로 읽을 수 있는 정적 문자열 값.
    func staticStringValue(ofMember member: String, inTypeNamed type: [String]) -> String? {
        let resolver = staticStringResolver()
        return resolver.staticStringValue(ofMember: member, inTypeNamed: type)
    }

    /// 닫힌 평가에서 거부한 정적 멤버를 이전 파일 단위 바인딩이 다시 상수로 만들지 않게 한다.
    /// 지원 식 밖의 String 보간만 이전 조각 확장에 맡겨 증명된 접두사를 보존한다.
    func allowsLegacyStaticExpansion(ofMember member: String, inTypeNamed type: [String]) -> Bool {
        let owners = typeChains.filter { suffixMatches($0, type) }
        guard owners.count == 1, let owner = owners.first,
              typeConditionality[owner]?.contains(true) != true else { return false }
        guard let declarations = staticStringMembers[owner + "\u{0}" + member] else { return true }
        guard declarations.count == 1, let declaration = declarations.first,
              declaration.isSafe, !declaration.isConditional else { return false }
        return declaration.expression == .unknown
            || usesOnlyFileConstantReferences(declaration.expression, owner: owner)
    }

    /// 기존 파일 수준 상수는 바인딩 수집기가 읽는다. 타입 멤버 사슬의 실패에는 이 우회를 허용하지 않는다.
    private func usesOnlyFileConstantReferences(
        _ expression: HTTPStaticStringExpression, owner: String, depth: Int = 0
    ) -> Bool {
        guard depth < 64 else { return false }
        switch expression {
        case .literal: return true
        case let .reference(type, member):
            return type.isEmpty && staticStringMembers[owner + "\u{0}" + member] == nil
        case let .concatenation(parts):
            return parts.allSatisfy { usesOnlyFileConstantReferences($0, owner: owner, depth: depth + 1) }
        case .rawValue, .unknown: return false
        }
    }

    /// 다른 파일의 정적 멤버와 typealias를 문서 표면에 더한다.
    mutating func addStaticStringMember(_ member: HTTPStaticStringMember) {
        staticStringMembers[member.owner + "\u{0}" + member.name, default: []].append(member)
    }

    mutating func addTypeAlias(_ owner: [String], name: String, target: [String],
                               location: CartographCore.SourceLocation, isConditional: Bool = false) {
        let chain = (owner + [name]).joined(separator: ".")
        typeAliases[chain, default: []].append(.init(
            name: chain, target: target, location: location, isConditional: isConditional
        ))
    }

    private func suffixMatches(_ chain: String, _ type: [String]) -> Bool {
        routeTypeSuffixMatches(chain, type)
    }

    /// 평가기에 필요한 값만 넘겨 표면 타입으로의 역방향 의존을 만들지 않는다.
    private func staticStringResolver() -> StaticStringResolver {
        StaticStringResolver(enumCases: enumCases, staticStringMembers: staticStringMembers,
            typeAliases: typeAliases, typeChains: typeChains, typeConditionality: typeConditionality)
    }

    /// 정적 라우트 문자열을 한 문맥 안에서만 제한적으로 평가한다.
    private struct StaticStringResolver {
        private enum Outcome: Equatable {
            case value(String)
            case unknown
        }

        private struct MemberKey: Hashable {
            let owner: String
            let member: String
        }

        private struct TypeKey: Hashable {
            let components: [String]
        }

        let enumCases: [String: [HTTPEnumCaseDeclaration]]
        let staticStringMembers: [String: [HTTPStaticStringMember]]
        let typeAliases: [String: [HTTPTypeAliasDeclaration]]
        let typeChains: Set<String>
        let typeConditionality: [String: [Bool]]
        private var memberMemo: [MemberKey: Outcome] = [:]
        private var typeMemo: [TypeKey: Outcome] = [:]

        init(enumCases: [String: [HTTPEnumCaseDeclaration]], staticStringMembers: [String: [HTTPStaticStringMember]],
             typeAliases: [String: [HTTPTypeAliasDeclaration]], typeChains: Set<String>,
             typeConditionality: [String: [Bool]]) {
            self.enumCases = enumCases
            self.staticStringMembers = staticStringMembers
            self.typeAliases = typeAliases
            self.typeChains = typeChains
            self.typeConditionality = typeConditionality
        }

        func staticStringValue(ofMember member: String, inTypeNamed type: [String]) -> String? {
            var resolver = self
            guard case let .value(value) = resolver.evaluateMember(
                ownerType: type, member: member, depth: 0, visitingMembers: [], visitingTypes: []
            ) else { return nil }
            return value
        }

        mutating func rawValue(ofCase name: String, inTypeNamed type: [String], depth: Int) -> String? {
            guard depth < 64,
                  case let .value(owner) = resolveType(type, depth: depth, visiting: []),
                  let declarations = enumCases[owner]?.filter({ $0.name == name }),
                  declarations.count == 1, let declaration = declarations.first,
                  !declaration.isConditional,
                  let value = declaration.rawValue,
                  value.utf16.count <= HTTPRouteTemplate.maxLength else { return nil }
            return value
        }

        private mutating func evaluateMember(
            ownerType: [String], member: String, depth: Int, visitingMembers: Set<MemberKey>,
            visitingTypes: Set<TypeKey>
        ) -> Outcome {
            guard depth < 64, case let .value(owner) = resolveType(ownerType, depth: depth, visiting: visitingTypes) else {
                return .unknown
            }
            let key = MemberKey(owner: owner, member: member)
            guard !visitingMembers.contains(key) else { return .unknown }
            if let cached = memberMemo[key] { return cached }
            guard let declarations = staticStringMembers[owner + "\u{0}" + member],
                  declarations.count == 1, let declaration = declarations.first,
                  declaration.isSafe, !declaration.isConditional else {
                memberMemo[key] = .unknown
                return .unknown
            }
            let outcome = evaluate(
                declaration.expression, owner: owner, depth: depth + 1,
                visitingMembers: visitingMembers.union([key]), visitingTypes: visitingTypes
            )
            memberMemo[key] = outcome
            return outcome
        }

        private mutating func evaluate(
            _ expression: HTTPStaticStringExpression, owner: String, depth: Int,
            visitingMembers: Set<MemberKey>, visitingTypes: Set<TypeKey>
        ) -> Outcome {
            guard depth < 64 else { return .unknown }
            switch expression {
            case let .literal(value):
                return value.utf16.count <= HTTPRouteTemplate.maxLength ? .value(value) : .unknown
            case let .reference(type, member):
                return evaluateMember(
                    ownerType: type.isEmpty ? owner.split(separator: ".").map(String.init) : type,
                    member: member, depth: depth + 1, visitingMembers: visitingMembers,
                    visitingTypes: visitingTypes
                )
            case let .rawValue(type, caseName):
                guard let value = rawValue(ofCase: caseName, inTypeNamed: type, depth: depth + 1) else {
                    return .unknown
                }
                return .value(value)
            case let .concatenation(parts):
                var result = ""
                for part in parts {
                    guard case let .value(value) = evaluate(
                        part, owner: owner, depth: depth + 1,
                        visitingMembers: visitingMembers, visitingTypes: visitingTypes
                    ), result.utf16.count + value.utf16.count <= HTTPRouteTemplate.maxLength else {
                        return .unknown
                    }
                    result += value
                }
                return .value(result)
            case .unknown:
                return .unknown
            }
        }

        private mutating func resolveType(
            _ type: [String], depth: Int, visiting: Set<TypeKey>
        ) -> Outcome {
            guard depth < 64, !type.isEmpty else { return .unknown }
            let key = TypeKey(components: type)
            if let cached = typeMemo[key] { return cached }
            guard !visiting.contains(key) else { return .unknown }
            let direct = typeChains.filter { routeTypeSuffixMatches($0, type) }.sorted()
            let aliases = typeAliases.keys.filter { routeTypeSuffixMatches($0, type) }.sorted()
            let unconditionalDirect = direct.filter {
                guard let states = typeConditionality[$0] else { return false }
                return states.count == 1 && states[0] == false
            }
            guard direct.isEmpty || aliases.isEmpty else {
                typeMemo[key] = .unknown
                return .unknown
            }
            if direct.count == 1, unconditionalDirect.count == 1 {
                let result: Outcome = .value(direct[0])
                typeMemo[key] = result
                return result
            }
            guard direct.isEmpty, aliases.count == 1, let alias = aliases.first,
                  let declarations = typeAliases[alias], declarations.count == 1,
                  declarations[0].isConditional == false else {
                typeMemo[key] = .unknown
                return .unknown
            }
            let result = resolveType(
                declarations[0].target, depth: depth + 1, visiting: visiting.union([key])
            )
            typeMemo[key] = result
            return result
        }
    }
}

/// 같은 접미 타입 표기를 표면과 평가기가 동일하게 대조한다.
private func routeTypeSuffixMatches(_ chain: String, _ type: [String]) -> Bool {
    let components = chain.split(separator: ".").map(String.init)
    return components.count >= type.count && Array(components.suffix(type.count)) == type
}

/// 라우터에 필요한 선언 표면(상속 절, 프로토콜, enum case, 주 선언 위치)을 모은다.
///
/// `HTTPSurfaceCollector` 가 타입 문맥을 쌓으며 부른다. 상태가 표면 하나라 따로 두면 두 방문자가
/// 같은 트리를 두 번 걸어야 한다.
struct HTTPRouterSurfaceRecorder {
    let converter: SourceLocationConverter?
    let path: String

    /// 타입 선언 하나의 상속 절과 주 선언 위치를 기록한다.
    func recordType(_ node: some DeclSyntaxProtocol, chain: [String], inheritance: InheritanceClauseSyntax?,
                    isProtocol: Bool, isExtension: Bool, into surface: inout HTTPDeclarationSurface) {
        let key = chain.joined(separator: ".")
        let names = inheritance?.inheritedTypes.compactMap { $0.type.trimmedDescription.split(separator: ".").last.map(String.init) } ?? []
        surface.addInheritance(key, names: names, isProtocol: isProtocol)
        guard !isExtension, let converter, let name = chain.last else { return }
        surface.addTypeSite(key, HTTPTypeDeclarationSite(name: name, start: location(node.positionAfterSkippingLeadingTrivia, converter),
                                                         end: location(node.endPositionBeforeTrailingTrivia, converter)))
    }

    /// enum case 선언들을 기록한다. 원시 타입이 `String` 이면 암시적 원시값은 case 이름이다.
    func recordCases(_ node: EnumCaseDeclSyntax, chain: [String], isStringBacked: Bool,
                     isConditional: Bool = false, into surface: inout HTTPDeclarationSurface) {
        guard let converter else { return }
        for element in node.elements {
            let name = SyntaxIdentifiers.unescaped(element.name.text)
            let explicit = element.rawValue?.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue
            let raw = isStringBacked ? (explicit ?? name) : nil
            surface.addCase(chain.joined(separator: "."), HTTPEnumCaseDeclaration(
                name: name, indexName: Self.indexName(name, element.parameterClause),
                rawValue: raw, start: location(element.name.positionAfterSkippingLeadingTrivia, converter),
                end: location(element.endPositionBeforeTrailingTrivia, converter), isConditional: isConditional
            ))
        }
    }

    /// 정적 문자열 멤버의 초기식을 실행 없이 닫힌 값 표현으로 바꾼다.
    static func stringExpression(_ expression: ExprSyntax) -> HTTPStaticStringExpression {
        let value = HTTPSyntax.unwrapped(expression)
        if let literal = value.as(StringLiteralExprSyntax.self),
           let represented = literal.representedLiteralValue {
            return .literal(represented)
        }
        if let infix = value.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
            return .concatenation([stringExpression(infix.leftOperand), stringExpression(infix.rightOperand)])
        }
        if let member = value.as(MemberAccessExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
            if name == "rawValue", let caseAccess = member.base?.as(MemberAccessExprSyntax.self),
               let type = caseAccess.base.flatMap(HTTPSyntax.dottedName) {
                return .rawValue(
                    type: type.map(SyntaxIdentifiers.unescaped),
                    caseName: SyntaxIdentifiers.unescaped(caseAccess.declName.baseName.text)
                )
            }
            if let base = member.base, let type = HTTPSyntax.dottedName(base) {
                return .reference(
                    type: type.map(SyntaxIdentifiers.unescaped),
                    member: name
                )
            }
            if member.base == nil {
                return .reference(type: [], member: name)
            }
        }
        if let reference = value.as(DeclReferenceExprSyntax.self) {
            return .reference(type: [], member: SyntaxIdentifiers.unescaped(reference.baseName.text))
        }
        return .unknown
    }

    /// 타입 별칭의 단순한 점 표기만 보존한다. 제네릭·합성 타입은 값 해석에 쓰지 않는다.
    static func typeComponents(_ type: TypeSyntax) -> [String]? {
        let parts = type.trimmedDescription.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0.first?.isLetter == true || $0.first == "_" }) else { return nil }
        return parts.map(SyntaxIdentifiers.unescaped)
    }

    /// 인덱스의 enum case 이름. 연관값이 있으면 외부 레이블(없으면 `_`)을 붙인다.
    static func indexName(_ name: String, _ clause: EnumCaseParameterClauseSyntax?) -> String {
        guard let clause else { return name }
        let labels = clause.parameters.map { parameter -> String in
            guard let label = parameter.firstName, label.text != "_" else { return "_:" }
            return SyntaxIdentifiers.unescaped(label.text) + ":"
        }
        return name + "(" + labels.joined() + ")"
    }

    /// 상속 절의 첫 타입이 `String` 인지. 원시값 enum 은 원시 타입을 맨 앞에 쓴다.
    static func isStringBacked(_ inheritance: InheritanceClauseSyntax?) -> Bool {
        guard let first = inheritance?.inheritedTypes.first?.type.trimmedDescription else { return false }
        return first == "String" || first == "Swift.String"
    }

    private func location(_ position: AbsolutePosition, _ converter: SourceLocationConverter) -> CartographCore.SourceLocation {
        let resolved = converter.location(for: position)
        return CartographCore.SourceLocation(path: path, line: resolved.line, column: resolved.column)
    }
}
