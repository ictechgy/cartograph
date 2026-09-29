import CartographCore

/// 문서 단위로 모은 라우터 표에서 case 별 route-call 을 만든 결과.
public struct RouterRouteCalls: Hashable, Sendable {
    public let calls: [ScannedRouteCall]
    /// 사실로 만들지 못한 라우터(`unmodelledRouters`)와 기술자 타입(`undeclaredWrapperSinks`).
    public let counts: RouteCallScanCounts
}

extension HTTPRouteCallScanner {
    /// 라우터 타입마다 case 하나에 route-call 하나를 만든다.
    ///
    /// 사실의 심볼은 enum case 선언이다(비열거 타입이면 타입 선언). 인덱스는 case 를 쓰는 모든 곳을
    /// 참조로 기록하므로, isthmus trace 가 이 USR 에서 역방향으로 이어 가면 `provider.request(.users)` 처럼
    /// 직접 쓰는 곳과 `fetch(.users)` 처럼 case 를 매개변수로 넘기는 곳의 호출자에 모두 닿는다. 위치는 그
    /// case 의 경로 분기이고, 경로 분기가 없으면 case 선언이다.
    ///
    /// - Parameters:
    ///   - declaredDescriptorOwners: 사용자가 생성자 래퍼로 선언한 타입의 마지막 이름. 저장 프로퍼티로 경로를
    ///     받는 기술자 라우터가 이미 래퍼 호출로 덮였는지 판단한다.
    public static func routerRouteCalls(
        tables: [HTTPTargetMemberTable], recipes: [HTTPRouterRecipe], surface: HTTPDeclarationSurface,
        declaredDescriptorOwners: Set<String> = []
    ) -> RouterRouteCalls {
        let index = RouterTableIndex(tables: tables, recipes: recipes, surface: surface)
        var calls: [ScannedRouteCall] = []
        var counts = RouteCallScanCounts()
        for chain in surface.routerChains {
            guard let kind = surface.routerKind(of: chain) else { continue }
            guard let pathTable = index.table(.path, of: chain) else {
                counts.unmodelledRouters += 1
                continue
            }
            if pathTable.isStoredWithoutValue {
                let name = chain.split(separator: ".").last.map(String.init) ?? chain
                if !declaredDescriptorOwners.contains(name) { counts.undeclaredWrapperSinks += 1 }
                continue
            }
            let recipe = kind == .alamofire ? index.recipe(of: chain) : nil
            if kind == .alamofire, recipe == nil {
                counts.unmodelledRouters += 1
                continue
            }
            let builder = RouterCallBuilder(pathTable: pathTable, methodTable: index.table(.method, of: chain),
                                            baseTable: index.table(.baseURL, of: chain), recipe: recipe)
            calls += RouterCallBuilder.subjects(of: chain, surface: surface).map(builder.call)
        }
        return RouterRouteCalls(calls: calls.sorted { $0.fact < $1.fact }, counts: counts)
    }
}

/// 라우터 타입의 멤버 표와 레시피를 찾는다. 자기 멤버가 먼저이고, 없으면 준수하는 프로토콜의 기본 구현이다.
private struct RouterTableIndex {
    private let tables: [String: [HTTPTargetMemberTable]]
    private let recipes: [String: [HTTPRouterRecipe]]
    private let surface: HTTPDeclarationSurface

    init(tables: [HTTPTargetMemberTable], recipes: [HTTPRouterRecipe], surface: HTTPDeclarationSurface) {
        self.tables = Dictionary(grouping: tables) { $0.owner + "\0" + $0.member.rawValue }
        self.recipes = Dictionary(grouping: recipes, by: \.owner)
        self.surface = surface
    }

    /// 멤버 표. 같은 멤버가 두 번 선언되면(다른 모듈의 동명 타입 등) 어느 것인지 모르므로 nil.
    func table(_ member: HTTPTargetMemberTable.Member, of chain: String) -> HTTPTargetMemberTable? {
        let own = tables[chain + "\0" + member.rawValue] ?? []
        if !own.isEmpty { return own.count == 1 ? own[0] : nil }
        let inherited = providers(of: chain).flatMap { tables[$0 + "\0" + member.rawValue] ?? [] }
        return inherited.count == 1 ? inherited[0] : nil
    }

    func recipe(of chain: String) -> HTTPRouterRecipe? {
        let own = recipes[chain] ?? []
        if !own.isEmpty { return own.count == 1 ? own[0] : nil }
        let inherited = providers(of: chain).flatMap { recipes[$0] ?? [] }
        return inherited.count == 1 ? inherited[0] : nil
    }

    /// 기본 구현을 줄 수 있는 프로토콜 사슬들. 프로젝트 프로토콜과 라이브러리 프로토콜 이름 자신이다.
    private func providers(of chain: String) -> [String] {
        let names = surface.conformedNames(of: chain)
        let projectProtocols = surface.protocolChains.filter { protocolChain in
            protocolChain.split(separator: ".").last.map { names.contains(String($0)) } ?? false
        }
        let library = HTTPRouterKind.allCases.map(\.rawValue).filter(names.contains)
        return projectProtocols.sorted() + library
    }
}

/// 라우터 case(또는 비열거 타입) 하나의 사실을 만든다.
private struct RouterCallBuilder {
    /// 사실의 주체. enum case 거나, 비열거 타입이면 타입 자신이다.
    struct Subject {
        let caseDeclaration: HTTPEnumCaseDeclaration?
        let declaration: EnclosingDeclaration?
    }

    let pathTable: HTTPTargetMemberTable
    let methodTable: HTTPTargetMemberTable?
    let baseTable: HTTPTargetMemberTable?
    let recipe: HTTPRouterRecipe?

    /// 타입의 case 들. case 가 없으면 타입 선언 하나다.
    static func subjects(of chain: String, surface: HTTPDeclarationSurface) -> [Subject] {
        if let cases = surface.enumCases[chain], !cases.isEmpty {
            return cases.map { caseDeclaration in
                Subject(caseDeclaration: caseDeclaration, declaration: EnclosingDeclaration(
                    name: caseDeclaration.name, indexName: caseDeclaration.indexName,
                    qualifiedName: chain + "." + caseDeclaration.name, line: caseDeclaration.start.line,
                    start: caseDeclaration.start, end: caseDeclaration.end
                ))
            }
        }
        let site = surface.typeSites[chain]
        let name = chain.split(separator: ".").last.map(String.init) ?? chain
        return [Subject(caseDeclaration: nil, declaration: EnclosingDeclaration(
            name: name, indexName: name, qualifiedName: chain, line: site?.start.line ?? 0, start: site?.start, end: site?.end
        ))]
    }

    func call(_ subject: Subject) -> ScannedRouteCall {
        let caseName = subject.caseDeclaration?.name
        let pathArm = pathTable.arm(for: caseName)
        let resolution = resolution(pathArm: pathArm, rawValue: subject.caseDeclaration?.rawValue, caseName: caseName)
        let location = pathArm?.location ?? subject.caseDeclaration?.start ?? subject.declaration?.start
            ?? CartographCore.SourceLocation(path: "", line: 1, column: 1)
        let fact = RouteCallFact(
            resolution: resolution, method: method(caseName: caseName),
            dynamicText: resolution.isDynamic ? pathArm?.dynamicText : nil, service: nil,
            isTestSource: pathTable.isTestSource, location: location
        )
        return ScannedRouteCall(fact: fact, declaration: subject.declaration)
    }

    /// 경로 분기와 base 를 라이브러리 규칙으로 조립한다. 경로를 읽지 못했으면 dynamic 이다.
    private func resolution(pathArm: HTTPTargetMemberTable.Arm?, rawValue: String?, caseName: String?) -> HTTPRouteResolution {
        guard case let .path(pieces)? = pathArm?.value else { return .init(template: nil, pathAnchor: .base) }
        let path = pieces.map { piece -> HTTPURLPart in
            switch piece {
            case let .part(part): part
            case .selfRawValue: rawValue.map(HTTPURLPart.literal) ?? .pathValue
            }
        }
        if let recipe { return HTTPTargetRouteRules.router(recipe, path: path) }
        guard case let .url(base)? = baseTable?.arm(for: caseName)?.value else {
            return HTTPTargetRouteRules.moya(base: nil, path: path)
        }
        return HTTPTargetRouteRules.moya(base: base, path: path)
    }

    /// 동사. 레시피가 고정한 값이 있으면 그것, 아니면 `method` 멤버의 case 분기다.
    private func method(caseName: String?) -> String? {
        if case let .fixed(verb)? = recipe?.method { return verb }
        guard case let .verb(verb)? = methodTable?.arm(for: caseName)?.value else { return nil }
        return verb
    }
}
