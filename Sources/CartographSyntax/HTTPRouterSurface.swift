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
    public let start: CartographCore.SourceLocation
    public let end: CartographCore.SourceLocation

    public init(name: String, indexName: String, rawValue: String?, start: CartographCore.SourceLocation, end: CartographCore.SourceLocation) {
        self.name = name
        self.indexName = indexName
        self.rawValue = rawValue
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

/// 이 도구가 읽는 라우터 프로토콜.
public enum HTTPRouterKind: String, Hashable, Sendable, CaseIterable {
    /// Moya `TargetType`: `baseURL`·`path`·`method` 멤버.
    case moya = "TargetType"
    /// Alamofire `URLRequestConvertible`: `asURLRequest()` 가 요청을 만든다.
    case alamofire = "URLRequestConvertible"
}

extension HTTPDeclarationSurface {
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
        let owners = enumCases.keys.filter { chain in
            let components = chain.split(separator: ".").map(String.init)
            return components.count >= type.count && Array(components.suffix(type.count)) == type
        }
        guard owners.count == 1, let cases = enumCases[owners[0]] else { return nil }
        return cases.first { $0.name == name }?.rawValue
    }
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
    func recordCases(_ node: EnumCaseDeclSyntax, chain: [String], isStringBacked: Bool, into surface: inout HTTPDeclarationSurface) {
        guard let converter else { return }
        for element in node.elements {
            let name = SyntaxIdentifiers.unescaped(element.name.text)
            let explicit = element.rawValue?.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue
            let raw = isStringBacked ? (explicit ?? name) : nil
            surface.addCase(chain.joined(separator: "."), HTTPEnumCaseDeclaration(
                name: name, indexName: Self.indexName(name, element.parameterClause),
                rawValue: raw, start: location(element.name.positionAfterSkippingLeadingTrivia, converter),
                end: location(element.endPositionBeforeTrailingTrivia, converter)
            ))
        }
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
