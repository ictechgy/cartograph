import CartographCore
import SwiftSyntax

/// URL 식을 펼친 조각 하나와, 값이면 그 원문 식. 매개변수 통과 판정에 식이 필요하다.
struct HTTPScannedPart {
    let part: HTTPURLPart
    let expression: ExprSyntax?
    /// 소스에 없는데 결합 규칙이 끼워 넣은 조각(`appendingPathComponent` 의 `/`)인지.
    var isSynthetic = false

    static func literal(_ text: String) -> HTTPScannedPart { .init(part: .literal(text), expression: nil) }
    static func value(_ expression: ExprSyntax) -> HTTPScannedPart { .init(part: .value, expression: expression) }
    static func pathValue(_ expression: ExprSyntax?) -> HTTPScannedPart { .init(part: .pathValue, expression: expression) }
    static let queryTail = HTTPScannedPart(part: .queryTail, expression: nil)
    static let joiningSlash = HTTPScannedPart(part: .literal("/"), expression: nil, isSynthetic: true)

    /// 경로를 읽었다고 할 근거가 되는 소스 리터럴인지. 결합 규칙이 끼워 넣은 `/` 는 근거가 아니다.
    var isMeaningfulLiteral: Bool {
        guard case .literal = part else { return false }
        return !isSynthetic
    }
}

/// 호출 대상의 모양. `f(`, `a.b.f(`, `.f(` 를 가른다.
private enum HTTPCallee {
    case plain(String)
    case member(base: ExprSyntax, name: String)
    case implicit(String)

    init?(_ expression: ExprSyntax) {
        var value = expression
        if let specialized = value.as(GenericSpecializationExprSyntax.self) { value = specialized.expression }
        if let reference = value.as(DeclReferenceExprSyntax.self) {
            self = .plain(SyntaxIdentifiers.unescaped(reference.baseName.text))
        } else if let member = value.as(MemberAccessExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
            self = member.base.map { .member(base: $0, name: name) } ?? .implicit(name)
        } else {
            return nil
        }
    }

    var name: String {
        switch self {
        case let .plain(name), let .member(_, name), let .implicit(name): name
        }
    }
}

/// 래퍼 선언과 호출의 대조 결과.
private enum HTTPWrapperMatch {
    case match
    /// 구성된 경로 매개변수가 기본값이라 호출에서 생략됐다. 명시 경로 래퍼보다 뒤에서 고른다.
    case defaultPath
    /// 이름·레이블은 맞지만 수신자 타입을 증명하지 못했다. 사실로 내지 않고 센다.
    case unproven
    case none
}

/// 경로가 함수 매개변수를 그대로 흘려보내는지. 선언된 생성자 래퍼 타입의 매개변수면 이미 덮인 경로다.
enum HTTPPassThrough {
    case none
    case covered
    case undeclared
}

/// route-call 을 실제로 뽑아내는 방문자.
final class HTTPRouteCallCollector: SyntaxVisitor {
    var calls: [ScannedRouteCall] = []
    var counts = RouteCallScanCounts()
    private(set) var callsByWrapper: [Int: Int] = [:]
    /// 라우터 타입 멤버(`path`·`method`·`baseURL`)의 분기 표. 문서 단위로 합쳐 case 별 사실이 된다.
    var routerTables: [HTTPTargetMemberTable] = []
    /// Alamofire 라우터 `asURLRequest()` 에서 읽은 요청 조립 방식.
    var routerRecipes: [HTTPRouterRecipe] = []

    private let wrappers: [HTTPWrapperDeclaration]
    let surface: HTTPDeclarationSurface
    let converter: SourceLocationConverter
    let bindings: BindingCollector
    let locals: HTTPLocalCollector
    let path: String
    let isTestSource: Bool
    /// 선언된 생성자 래퍼의 타입 이름. 이 타입의 매개변수에서 온 경로는 래퍼 호출이 이미 사실로 냈다.
    let constructorOwners: Set<String>

    /// 감싸는 선언의 스택. 사실을 어느 USR 에 귀속시킬지 정한다.
    private var declarations: [EnclosingDeclaration] = []
    /// 감싸는 타입 이름의 스택. `symbol.qualifiedName` 과 소유 타입 대조에 쓴다.
    private var typeNames: [String] = []

    init(
        wrappers: [HTTPWrapperDeclaration], converter: SourceLocationConverter, bindings: BindingCollector,
        locals: HTTPLocalCollector, surface: HTTPDeclarationSurface, path: String, isTestSource: Bool
    ) {
        self.wrappers = wrappers
        self.surface = surface
        self.converter = converter
        self.bindings = bindings
        self.locals = locals
        self.path = path
        self.isTestSource = isTestSource
        constructorOwners = Set(wrappers.filter { $0.kind == .constructor }.compactMap(\.ownerComponents.last))
        super.init(viewMode: .sourceAccurate)
    }

    /// 지금 타입 문맥의 구성 요소. 익스텐션 이름 `A.B` 는 두 요소로 펼친다.
    var chain: [String] { typeNames.flatMap { $0.split(separator: ".").map(String.init) } }

    // MARK: 선언 문맥

    private func pushType(_ name: String, node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        let unescaped = SyntaxIdentifiers.unescaped(name)
        pushDeclaration(name: unescaped, indexName: unescaped, node: node)
        typeNames.append(unescaped)
        return .visitChildren
    }

    private func popType() {
        typeNames.removeLast()
        declarations.removeLast()
    }

    private func pushDeclaration(name: String, indexName: String, node: some SyntaxProtocol) {
        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        declarations.append(EnclosingDeclaration(
            name: name, indexName: indexName, qualifiedName: (typeNames + [name]).joined(separator: "."),
            line: start.line,
            start: CartographCore.SourceLocation(path: path, line: start.line, column: start.column),
            end: CartographCore.SourceLocation(path: path, line: end.line, column: end.column)
        ))
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text, node: node) }
    override func visitPost(_: ClassDeclSyntax) { popType() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text, node: node) }
    override func visitPost(_: StructDeclSyntax) { popType() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text, node: node) }
    override func visitPost(_: EnumDeclSyntax) { popType() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text, node: node) }
    override func visitPost(_: ActorDeclSyntax) { popType() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription, node: node)
    }
    override func visitPost(_: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let base = SyntaxIdentifiers.unescaped(node.name.text)
        recordRouterRequestBuilder(node, name: base)
        recordURLRewritingAdapter(node, name: base)
        pushDeclaration(name: base, indexName: RuntimeSyntaxNames.indexName(base, parameters: node.signature.parameterClause.parameters), node: node)
        return .visitChildren
    }
    override func visitPost(_: FunctionDeclSyntax) { declarations.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushDeclaration(name: "init", indexName: RuntimeSyntaxNames.indexName("init", parameters: node.signature.parameterClause.parameters), node: node)
        return .visitChildren
    }
    override func visitPost(_: InitializerDeclSyntax) { declarations.removeLast() }

    /// 계산 프로퍼티나 `lazy var` 초기식 안의 호출은 그 프로퍼티에 귀속시킨다. 지역 변수는 정점이 없다.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let name = Self.memberVariableName(node) else { return .visitChildren }
        recordRouterMember(node, name: name)
        pushDeclaration(name: name, indexName: name, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) {
        if Self.memberVariableName(node) != nil { declarations.removeLast() }
    }

    private static func memberVariableName(_ node: VariableDeclSyntax) -> String? {
        guard let name = node.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              !DeclarationCollector.isInsideBody(node) else { return nil }
        return SyntaxIdentifiers.unescaped(name)
    }

    // MARK: 호출

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        recordImport(node)
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let (index, declaration) = matchWrapper(node) {
            emitWrapperCall(node, index: index, declaration: declaration)
        } else if HTTPSyntax.isFoundationInitializer(node, type: "URLRequest"),
                  let url = node.arguments.first(where: { $0.label?.text == "url" }), !Self.isPageLoad(node) {
            // Alamofire 의 `URLRequest(url:method:headers:)` 는 `URLConvertible`(문자열 포함)을 받는다.
            let acceptsString = node.arguments.contains { $0.label?.text == "method" }
            emitDirectRequest(node, urlExpression: url.expression, method: requestMethod(of: node), countsOpaque: true,
                              acceptsString: acceptsString)
        } else if let url = sessionURLArgument(of: node) {
            emitDirectRequest(node, urlExpression: url, method: "GET", countsOpaque: false)
        } else if let request = alamofireRequest(node) {
            emitAlamofireRequest(node, request)
        }
        countURLRewritingEndpoint(node)
        return .visitChildren
    }

    // MARK: 선언된 래퍼

    /// 호출이 어느 래퍼 선언과 맞는지. 이름·레이블만 맞고 수신자를 증명하지 못한 호출은 센다.
    private func matchWrapper(_ node: FunctionCallExprSyntax) -> (Int, HTTPWrapperDeclaration)? {
        guard !wrappers.isEmpty, let callee = HTTPCallee(node.calledExpression) else { return nil }
        var isUnproven = false
        var defaultPathMatch: (Int, HTTPWrapperDeclaration)?
        for (index, declaration) in wrappers.enumerated() {
            let match = declaration.kind == .constructor
                ? constructorMatch(declaration, callee: callee, node: node)
                : functionMatch(declaration, callee: callee, node: node)
            switch match {
            case .match: return (index, declaration)
            case .defaultPath:
                if defaultPathMatch == nil { defaultPathMatch = (index, declaration) }
            case .unproven: isUnproven = true
            case .none: continue
            }
        }
        if let defaultPathMatch { return defaultPathMatch }
        if isUnproven { counts.unprovenReceiverCalls += 1 }
        return nil
    }

    /// `Owner(`·`Owner.init(`·`Module.Owner(` 과, 소유 타입 안의 `Self(`·`self.init(`·`.init(`.
    ///
    /// 암시적 `.init(` 은 문맥 타입이 무엇인지 구문만으로는 모른다. 소유 타입 안에서 경로 레이블을
    /// 단 호출일 때만 받는다 — `.init(name:value:)` 같은 다른 타입의 생성을 래퍼로 읽지 않기 위해서다.
    private func constructorMatch(_ declaration: HTTPWrapperDeclaration, callee: HTTPCallee, node: FunctionCallExprSyntax) -> HTTPWrapperMatch {
        guard declaration.name == "init" else { return .none }
        let isOwner: Bool
        switch callee {
        case let .plain(name):
            isOwner = name == "Self" ? declaration.ownerMatches(chain) : declaration.ownerMatches([name])
        case let .member(base, name):
            if Self.isSelfReference(base) {
                isOwner = name == "init" && declaration.ownerMatches(chain)
            } else if let dotted = HTTPSyntax.dottedName(base) {
                isOwner = declaration.ownerMatches(name == "init" ? dotted : dotted + [name])
            } else {
                isOwner = false
            }
        case let .implicit(name):
            let label = declaration.pathArg.label
            isOwner = name == "init" && declaration.ownerMatches(chain)
                && label != nil && node.arguments.contains {
                    $0.label.map { SyntaxIdentifiers.unescaped($0.text) } == label
                }
        }
        guard isOwner else { return .none }
        let labels = node.arguments.map { $0.label.map { SyntaxIdentifiers.unescaped($0.text) } }
        if HTTPWrapperBinding.argumentIndex(for: declaration.pathArg, labels: labels) != nil {
            return labelsCompatible(node, declaration) ? .match : .none
        }
        return surface.acceptsOmittedPath(of: declaration, labels: labels) ? .defaultPath : .none
    }

    /// `name(` 은 소유 타입 안(또는 모듈 함수), `self.name(`·`Owner.name(` 은 증명된 소유자,
    /// 그 밖의 수신자는 타입 표기나 생성자 바인딩으로 타입을 증명했을 때만 맞는다.
    private func functionMatch(_ declaration: HTTPWrapperDeclaration, callee: HTTPCallee, node: FunctionCallExprSyntax) -> HTTPWrapperMatch {
        guard callee.name == declaration.name, labelsCompatible(node, declaration) else { return .none }
        let isModuleFunction = surface.chains(matching: declaration).isEmpty
        switch callee {
        case .plain:
            if isModuleFunction { return declaresMethod(named: declaration.name) ? .none : .match }
            return declaration.ownerMatches(chain) ? .match : .none
        case let .member(base, _):
            if Self.isSelfReference(base) { return declaration.ownerMatches(chain) ? .match : .none }
            if let dotted = HTTPSyntax.dottedName(base), dotted.first?.first?.isUppercase == true {
                return declaration.ownerMatches(dotted) ? .match : .none
            }
            if receiverType(of: base).map({ declaration.ownerMatches([$0]) }) == true { return .match }
            return isLikelyWrapperCall(node, declaration) ? .unproven : .none
        case .implicit:
            return .none
        }
    }

    /// 수신자를 증명하지 못한 호출을 세어도 되는지. 시그니처를 알면 레이블 일치가, 모르면 경로
    /// 레이블이 근거다. 근거 없이 세면 `subject.send(value)` 같은 동명 호출이 경보를 만든다.
    private func isLikelyWrapperCall(_ node: FunctionCallExprSyntax, _ declaration: HTTPWrapperDeclaration) -> Bool {
        if !surface.signatures(of: declaration).isEmpty { return true }
        guard let label = declaration.pathArg.label else { return false }
        return node.arguments.contains { $0.label?.text == label }
    }

    /// 지금 타입이 같은 이름의 메서드를 선언했는지. 그렇다면 한정 없는 호출은 모듈 함수가 아니다.
    private func declaresMethod(named name: String) -> Bool {
        !chain.isEmpty && surface.functions[chain.joined(separator: ".") + "\0" + name] != nil
    }

    /// 호출의 인자 레이블이 선언된 시그니처 중 하나와 순서대로 맞는지. 기본값 있는 인자는 건너뛸 수 있다.
    private func labelsCompatible(_ node: FunctionCallExprSyntax, _ declaration: HTTPWrapperDeclaration) -> Bool {
        let signatures = surface.signatures(of: declaration)
        guard !signatures.isEmpty else { return true }
        let labels = node.arguments.map { $0.label.map { SyntaxIdentifiers.unescaped($0.text) } }
        return signatures.contains { signature in
            var position = 0
            for label in labels {
                while position < signature.count, signature[position] != label { position += 1 }
                guard position < signature.count else { return false }
                position += 1
            }
            return true
        }
    }

    /// 수신자 식의 타입 이름. 파일 안에서 한 가지로만 표기됐거나 생성자로 묶였을 때만 안다.
    func receiverType(of base: ExprSyntax) -> String? {
        let name: String
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            name = SyntaxIdentifiers.unescaped(reference.baseName.text)
        } else if let member = base.as(MemberAccessExprSyntax.self), let owner = member.base, Self.isSelfReference(owner) {
            name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
        } else {
            return nil
        }
        if let types = locals.annotatedTypes[name], types.count == 1 { return types.first }
        let context = HTTPSyntax.context(of: base)
        if let instance = bindings.instanceTypeName(named: name, in: context) {
            return instance.split(separator: ".").last.map(String.init)
        }
        // 프로퍼티가 다른 파일(주 선언)에 표기되고 호출은 익스텐션에 있는 흔한 모양.
        return surface.memberType(named: name, in: context.enclosingTypes)
    }

    private static func isSelfReference(_ expression: ExprSyntax) -> Bool {
        let text = expression.as(DeclReferenceExprSyntax.self)?.baseName.text
        return text == "self" || text == "Self"
    }

    /// 선언된 래퍼 호출 하나를 사실로 낸다.
    private func emitWrapperCall(_ node: FunctionCallExprSyntax, index: Int, declaration: HTTPWrapperDeclaration) {
        // 래퍼 자신의 본문(편의 이니셜라이저의 위임 등)은 호출 지점이 아니다.
        guard !isInsideDeclaredWrapper(node) else { return }
        let context = HTTPSyntax.context(of: node)
        let arguments = node.arguments.map { (label: $0.label.map { SyntaxIdentifiers.unescaped($0.text) }, expression: $0.expression) }
        let method = HTTPWrapperBinding.method(for: declaration, arguments: arguments.map {
            HTTPWrapperCallArgument(label: $0.label, value: argumentValue($0.expression, context: context))
        })
        guard let pathIndex = HTTPWrapperBinding.argumentIndex(for: declaration.pathArg, labels: arguments.map(\.label)) else {
            if !declaration.pathSuffix.isEmpty { counts.wrapperSuffixUnresolved += 1 }
            emit(.init(template: nil, pathAnchor: declaration.pathAnchor), method: method, source: nil,
                 service: declaration.service, node: node)
            callsByWrapper[index, default: 0] += 1
            return
        }
        let pathExpression = arguments[pathIndex].expression
        let hasTrailingClosures = node.trailingClosure != nil || !node.additionalTrailingClosures.isEmpty
        let parts = implicitEnumPathParts(
            pathExpression, declaration: declaration, labels: arguments.map(\.label),
            hasTrailingClosures: hasTrailingClosures, context: context
        )
            ?? parts(of: pathExpression, context: context)
        guard recordPassThrough(parts, node: node) == .none else { return }
        let baseResolution = HTTPRouteURLResolver.resolve(
            parts.map(\.part), join: .wrapper(declaration.pathAnchor)
        )
            ?? .init(template: nil, pathAnchor: declaration.pathAnchor)
        let suffix = wrapperSuffixExpansion(declaration, arguments: arguments, context: context)
        let resolution = HTTPWrapperSuffixComposer.append(suffix, to: baseResolution)
        if suffix == .dynamic
            || (!declaration.pathSuffix.isEmpty && resolution.isDynamic) {
            counts.wrapperSuffixUnresolved += 1
        }
        emit(resolution, method: method, source: pathExpression, service: declaration.service, node: node)
        callsByWrapper[index, default: 0] += 1
    }

    private func implicitEnumPathParts(
        _ expression: ExprSyntax, declaration: HTTPWrapperDeclaration, labels: [String?],
        hasTrailingClosures: Bool, context: BindingCollector.Context
    ) -> [HTTPScannedPart]? {
        let value = BindingCollector.unparenthesized(expression)
        guard let member = value.as(MemberAccessExprSyntax.self), member.base == nil else { return nil }
        guard !hasTrailingClosures else { return [.value(value)] }
        guard let type = surface.pathTypes(of: declaration, labels: labels).first else { return [.value(value)] }
        guard let raw = surface.rawValue(ofCase: SyntaxIdentifiers.unescaped(member.declName.baseName.text), inTypeNamed: type),
              !isLexicalTypeShadow(named: type.first ?? "", expression: value, context: context) else { return [.value(value)] }
        return [.literal(raw)]
    }

    private func wrapperSuffixExpansion(
        _ declaration: HTTPWrapperDeclaration,
        arguments: [(label: String?, expression: ExprSyntax)],
        context: BindingCollector.Context
    ) -> HTTPWrapperSuffixComposer.Expansion {
        var segments: [HTTPWrapperSuffixComposer.Segment] = []
        for suffix in declaration.pathSuffix {
            switch suffix {
            case let .literal(text):
                segments.append(.literal(text))
            case let .argument(binding, shape):
                guard let index = HTTPWrapperBinding.argumentIndex(
                    for: binding, labels: arguments.map(\.label)
                ) else { return .dynamic }
                let expression = arguments[index].expression
                switch shape {
                case .scalar:
                    guard let segment = wrapperSuffixScalar(
                        expression, context: context, remaining: HTTPWrapperSuffixComposer.maximumExpandedSegments
                    ) else { return .dynamic }
                    segments.append(segment)
                case .array:
                    guard let expanded = wrapperSuffixArray(
                        expression, context: context, remaining: HTTPWrapperSuffixComposer.maximumExpandedSegments
                    ) else { return .dynamic }
                    segments.append(contentsOf: expanded)
                }
            }
            if segments.count > HTTPWrapperSuffixComposer.maximumExpandedSegments {
                return .dynamic
            }
        }
        return .segments(segments)
    }

    /// scalar 선언은 값의 실행 시 문자열을 몰라도 segment 하나라는 모델 주장을 보존한다.
    private func wrapperSuffixScalar(
        _ expression: ExprSyntax,
        context: BindingCollector.Context,
        remaining: Int
    ) -> HTTPWrapperSuffixComposer.Segment? {
        guard remaining > 0 else { return nil }
        let value = wrapperSuffixValue(expression)
        guard !isNonScalarSuffixValue(value) else { return nil }
        let resolved = bindings.resolveString(value, in: context)
        if !resolved.isDynamic { return .literal(resolved.text) }
        if let bound = bindings.constantExpression(for: value, in: context) {
            return wrapperSuffixScalar(
                bound.expression, context: bound.context, remaining: remaining - 1
            )
        }
        return .value
    }

    /// array 선언은 길이를 증명한 배열 리터럴만 펼친다. 빈 배열은 segment를 추가하지 않는다.
    private func wrapperSuffixArray(
        _ expression: ExprSyntax,
        context: BindingCollector.Context,
        remaining: Int
    ) -> [HTTPWrapperSuffixComposer.Segment]? {
        guard remaining > 0 else { return nil }
        let value = wrapperSuffixValue(expression)
        if let array = value.as(ArrayExprSyntax.self) {
            guard array.elements.count <= HTTPWrapperSuffixComposer.maximumExpandedSegments else { return nil }
            var result: [HTTPWrapperSuffixComposer.Segment] = []
            for element in array.elements {
                guard let segment = wrapperSuffixScalar(
                    element.expression, context: context, remaining: remaining - 1
                ) else { return nil }
                result.append(segment)
            }
            return result
        }
        guard let bound = bindings.constantExpression(for: value, in: context) else { return nil }
        return wrapperSuffixArray(
            bound.expression, context: bound.context, remaining: remaining - 1
        )
    }

    private func wrapperSuffixValue(_ expression: ExprSyntax) -> ExprSyntax {
        var value = HTTPSyntax.unwrapped(expression)
        while let cast = value.as(AsExprSyntax.self) {
            value = HTTPSyntax.unwrapped(cast.expression)
        }
        return value
    }

    private func isNonScalarSuffixValue(_ expression: ExprSyntax) -> Bool {
        expression.is(NilLiteralExprSyntax.self)
            || expression.is(ArrayExprSyntax.self)
            || expression.is(DictionaryExprSyntax.self)
            || expression.is(TupleExprSyntax.self)
            || expression.is(ClosureExprSyntax.self)
    }

    /// 인자 값의 모양. 동사 판정에 필요한 만큼만 가른다.
    private func argumentValue(_ expression: ExprSyntax, context: BindingCollector.Context) -> HTTPWrapperCallArgument.Value {
        let value = BindingCollector.unparenthesized(expression)
        if let member = value.as(MemberAccessExprSyntax.self) {
            // `.get` 과 `HTTPMethod.get` 은 case 다. `self.method` 같은 값 접근은 case 가 아니다.
            let base = member.base.flatMap(HTTPSyntax.dottedName)
            if member.base == nil || base?.first?.first?.isUppercase == true {
                return .enumCase(SyntaxIdentifiers.unescaped(member.declName.baseName.text))
            }
        }
        let resolved = bindings.resolveString(value, in: context)
        return resolved.isDynamic ? .opaque : .literal(resolved.text)
    }

    /// 호출이 선언된 래퍼 자신의 본문 안에 있는지.
    func isInsideDeclaredWrapper(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let syntax = current, HTTPSyntax.typeName(of: syntax) == nil {
            if let function = syntax.as(FunctionDeclSyntax.self) {
                let name = SyntaxIdentifiers.unescaped(function.name.text)
                if wrappers.contains(where: { $0.kind == .function && $0.name == name && ownsFunction($0) }) { return true }
            } else if syntax.is(InitializerDeclSyntax.self),
                      wrappers.contains(where: { $0.kind == .constructor && $0.ownerMatches(chain) }) {
                return true
            }
            current = syntax.parent
        }
        return false
    }

    /// 지금 타입 문맥이 함수 래퍼의 소유자인지. 모듈 함수 선언이면 최상위만 소유자다.
    private func ownsFunction(_ declaration: HTTPWrapperDeclaration) -> Bool {
        surface.chains(matching: declaration).isEmpty ? chain.isEmpty : declaration.ownerMatches(chain)
    }

    // MARK: 직접 요청

    /// `URLRequest(url:)` 또는 URL 을 받는 세션 호출 하나를 사실로 낸다.
    ///
    /// 선언된 함수 래퍼 본문 안의 싱크는 래퍼 구현이라 건너뛴다. URL 을 읽지 못하면 매개변수를
    /// 흘려보내는지 보고, 아니면 읽지 못한 싱크로 센다(세션 호출은 인자가 URL 인지조차 모르므로 세지 않는다).
    func emitDirectRequest(
        _ node: FunctionCallExprSyntax, urlExpression: ExprSyntax, method: String?, countsOpaque: Bool, acceptsString: Bool = false
    ) {
        guard !isInsideDeclaredWrapper(node), !isInsideRouterRequestBuilder(node) else { return }
        let context = HTTPSyntax.context(of: node)
        let read = urlParts(urlExpression, context: context, depth: 0)
            ?? (acceptsString ? stringURLParts(urlExpression, context: context).map { ($0, HTTPPathJoin.absoluteURL) } : nil)
        guard let url = read else {
            if countsOpaque { recordOpaque(urlExpression, node: node) }
            return
        }
        emitReadURL(node, url: url, method: method, source: urlExpression)
    }

    /// 펼친 요청 URL 하나를 사실로 낸다. 매개변수 통과면 세고, 리터럴이 하나도 없으면 읽지 못한 싱크다.
    func emitReadURL(_ node: FunctionCallExprSyntax, url: (parts: [HTTPScannedPart], join: HTTPPathJoin), method: String?, source: ExprSyntax) {
        guard recordPassThrough(url.parts, node: node) == .none else { return }
        guard url.parts.contains(where: \.isMeaningfulLiteral),
              let resolution = HTTPRouteURLResolver.resolve(url.parts.map(\.part), join: url.join) else {
            counts.unreadableSinks += 1
            return
        }
        emit(resolution, method: method, source: source, service: nil, node: node)
    }

    /// `webView.load(URLRequest(url:))` 처럼 요청을 곧바로 `load` 에 넘기는 모양인지.
    ///
    /// 웹 뷰의 페이지 탐색은 API 경로 호출이 아니다. 사실로 내면 서버 선언이 없는 거짓 호출이 되고,
    /// 읽지 못한 싱크로 세면 모든 미호출 진단이 근거 없이 `-unverified` 로 내려간다.
    private static func isPageLoad(_ node: FunctionCallExprSyntax) -> Bool {
        guard let argument = node.parent?.as(LabeledExprSyntax.self),
              let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "load"
    }

    /// `session.data(from:)`·`dataTask(with:)` 처럼 URL 로 GET 하는 호출의 URL 인자. URL 식일 때만.
    private func sessionURLArgument(of node: FunctionCallExprSyntax) -> ExprSyntax? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self), member.base != nil,
              let argument = node.arguments.first else { return nil }
        let label = argument.label?.text
        let name = member.declName.baseName.text
        // `dataTaskPublisher(for:)` 는 URL·URLRequest 겹지정이다. 인자가 URL 식일 때만 아래에서 받는다.
        let isGet = (["data", "download", "bytes"].contains(name) && label == "from")
            || (["dataTask", "downloadTask"].contains(name) && label == "with")
            || (name == "dataTaskPublisher" && label == "for")
        guard isGet, urlParts(argument.expression, context: HTTPSyntax.context(of: node), depth: 0) != nil else { return nil }
        return argument.expression
    }

    /// URL 식을 조각과 결합 방식으로 펼친다. 읽을 수 없는 식이면 nil.
    func urlParts(_ expression: ExprSyntax, context: BindingCollector.Context, depth: Int) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        guard depth < 16 else { return nil }
        let value = HTTPSyntax.unwrapped(expression)
        if let call = value.as(FunctionCallExprSyntax.self) {
            if HTTPSyntax.isFoundationInitializer(call, type: "URL"),
               let string = call.arguments.first, string.label?.text == "string" {
                let path = parts(of: string.expression, context: context)
                guard let relative = call.arguments.dropFirst().first, relative.label?.text == "relativeTo" else {
                    return (path, .absoluteURL)
                }
                return relativeURLParts(path, base: relative.expression, context: context, depth: depth)
            }
            if let converted = convertedURLParts(call, context: context, depth: depth) { return converted }
            guard let appended = HTTPSyntax.appendedComponent(of: call) else { return nil }
            return appendedURLParts(call, appended: appended, context: context, depth: depth)
        }
        if let components = componentsURLParts(value, context: context, depth: depth) { return components }
        if let reference = value.as(DeclReferenceExprSyntax.self),
           let bound = locals.urlExpression(named: SyntaxIdentifiers.unescaped(reference.baseName.text), scopes: context.scopes) {
            return urlParts(bound, context: HTTPSyntax.context(of: bound), depth: depth + 1)
        }
        return memberURLParts(value, context: context, depth: depth)
    }

    /// 요청의 동사. `URLRequest` 기본값은 GET 이지만, 바깥으로 나가 다른 곳에서 바뀔 수 있으면 모른다.
    ///
    /// 지역 이름에 묶였으면 같은 본문의 `name.httpMethod = …` 대입을 모두 본다. 한 가지 계약 동사면
    /// 그 동사, 대입이 없고 이름이 반환·inout 으로 나가지 않으면 GET 이다. 동사를 틀리게 내면
    /// 거짓 `route-method-mismatch` 가 되므로 확신이 없으면 `methodDynamic` 쪽을 고른다.
    private func requestMethod(of node: FunctionCallExprSyntax) -> String? {
        let context = HTTPSyntax.context(of: node)
        // Alamofire `URLRequest(url:method:headers:)` 는 생성 때 동사를 정한다. 없으면 URLRequest 기본값 GET.
        let initial = node.arguments.first { $0.label?.text == "method" }
            .map { libraryVerb($0.expression, context: context) } ?? "GET"
        guard let binding = node.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            return Self.isReturned(node) ? nil : initial
        }
        guard let body = Self.enclosingBody(of: node) else { return nil }
        let assignments = HTTPMethodAssignmentCollector(name: SyntaxIdentifiers.unescaped(name)) { [self] in isAlamofireSession($0) }
        assignments.walk(body)
        guard !assignments.escapes else { return nil }
        let verbs = assignments.values.map { assignment -> String? in
            assignment.isLibraryMethod ? libraryVerb(assignment.value, context: context)
                : stringVerb(assignment.value, context: context)
        }
        guard let first = verbs.first else { return initial }
        return verbs.allSatisfy { $0 == first } ? first : nil
    }

    /// `httpMethod` 에 대입한 문자열 식의 동사. `HTTPMethod.post.rawValue` 처럼 라이브러리 멤버의 원시값도 읽는다.
    func stringVerb(_ expression: ExprSyntax, context: BindingCollector.Context) -> String? {
        let value = HTTPSyntax.unwrapped(expression)
        if let member = value.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "rawValue",
           let base = member.base, let verb = libraryVerbMember(base) {
            return verb
        }
        let resolved = bindings.resolveString(value, in: context)
        return resolved.isDynamic ? nil : HTTPLibraryMethod.verb(forRawValue: resolved.text)
    }

    /// 반환되는 식인지. 반환된 요청은 호출자가 동사를 바꿀 수 있다.
    private static func isReturned(_ node: some SyntaxProtocol) -> Bool {
        if node.parent?.is(ReturnStmtSyntax.self) == true { return true }
        // 본문이 식 하나뿐인 함수·클로저·계산 프로퍼티의 암시적 반환.
        guard let item = node.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return false }
        return list.count == 1 && !(list.parent?.is(SourceFileSyntax.self) ?? false)
    }

    /// 노드를 감싸는 함수·이니셜라이저·접근자·클로저의 본문.
    private static func enclosingBody(of node: some SyntaxProtocol) -> Syntax? {
        var current = node.parent
        while let syntax = current {
            if let function = syntax.as(FunctionDeclSyntax.self) { return function.body.map(Syntax.init) }
            if let initializer = syntax.as(InitializerDeclSyntax.self) { return initializer.body.map(Syntax.init) }
            if syntax.is(ClosureExprSyntax.self) || syntax.is(AccessorDeclSyntax.self) || syntax.is(AccessorBlockSyntax.self) {
                return syntax
            }
            if HTTPSyntax.typeName(of: syntax) != nil { return nil }
            current = syntax.parent
        }
        return nil
    }

    // MARK: 경로 조각

    /// 식을 조각으로 펼친다. 같은 파일 상수·값 흐름 상수는 리터럴로, 증명된 query 꼬리는 따로 둔다.
    func parts(of expression: ExprSyntax, context: BindingCollector.Context, depth: Int = 0) -> [HTTPScannedPart] {
        let value = BindingCollector.unparenthesized(expression)
        guard depth < 32 else { return [.value(value)] }
        if let literal = value.as(StringLiteralExprSyntax.self) {
            return literal.segments.flatMap { segmentParts($0, literal: literal, context: context, depth: depth) }
        }
        if let infix = value.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
            return parts(of: infix.leftOperand, context: context, depth: depth + 1)
                + parts(of: infix.rightOperand, context: context, depth: depth + 1)
        }
        return expanded(value, context: context, depth: depth)
    }

    private func segmentParts(
        _ segment: StringLiteralSegmentListSyntax.Element, literal: StringLiteralExprSyntax,
        context: BindingCollector.Context, depth: Int
    ) -> [HTTPScannedPart] {
        switch segment {
        case let .stringSegment(text):
            let single = StringLiteralExprSyntax(
                openingPounds: literal.openingPounds, openingQuote: literal.openingQuote,
                segments: [.stringSegment(text)], closingQuote: literal.closingQuote, closingPounds: literal.closingPounds
            )
            // 구문 트리는 보간 앞뒤에 빈 문자열 조각을 둔다. 빈 리터럴은 경계 판정을 흐리므로 뺀다.
            guard let decoded = single.representedLiteralValue else { return [.value(ExprSyntax(literal))] }
            return decoded.isEmpty ? [] : [.literal(decoded)]
        case let .expressionSegment(interpolation):
            guard interpolation.expressions.count == 1, let only = interpolation.expressions.first, only.label == nil else {
                return [.value(ExprSyntax(literal))]
            }
            return expanded(only.expression, context: context, depth: depth + 1)
        }
    }

    /// 이름 하나를 풀어 본다. 값 흐름 상수 → query 꼬리 → 같은 파일 상수 → 모름 순이다.
    private func expanded(_ expression: ExprSyntax, context: BindingCollector.Context, depth: Int) -> [HTTPScannedPart] {
        let value = BindingCollector.unparenthesized(expression)
        if let text = bindings.resolvedValue(of: value) { return [.literal(text)] }
        // 지역 타입 이름은 기존 상수 바인딩의 전역 멤버 치환도 막아야 한다.
        if let root = HTTPSyntax.dottedName(value)?.first,
           isLexicalTypeShadow(named: root, expression: value, context: context) { return [.value(value)] }
        if let raw = enumRawValue(value, context: context) { return [.literal(raw)] }
        if let member = value.as(MemberAccessExprSyntax.self),
           let base = member.base.flatMap(HTTPSyntax.dottedName),
           staticLookupIsUnbound(base, expression: value, context: context),
           let resolved = surface.staticStringValue(
               ofMember: SyntaxIdentifiers.unescaped(member.declName.baseName.text), inTypeNamed: base
           ) {
            return [.literal(resolved)]
        }
        if isQueryTailLocal(value, context: context) { return [.queryTail] }
        if let member = value.as(MemberAccessExprSyntax.self),
           let type = member.base.flatMap(HTTPSyntax.dottedName), let root = type.first,
           !["self", "Self"].contains(root), !bindings.hasBinding(named: root, in: context),
           !surface.allowsLegacyStaticExpansion(
               ofMember: SyntaxIdentifiers.unescaped(member.declName.baseName.text), inTypeNamed: type
           ) { return [.value(value)] }
        if let bound = bindings.constantExpression(for: value, in: context) {
            return parts(of: bound.expression, context: bound.context, depth: depth + 1)
        }
        return [.value(value)]
    }

    /// `Path.users.rawValue` 의 문자열 원시값. 프로젝트 어느 파일의 enum 이든 표면에서 찾는다.
    private func enumRawValue(_ expression: ExprSyntax, context: BindingCollector.Context) -> String? {
        guard let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "rawValue",
              let caseAccess = member.base?.as(MemberAccessExprSyntax.self), let typeExpression = caseAccess.base,
              let type = HTTPSyntax.dottedName(typeExpression),
              staticLookupIsUnbound(type, expression: expression, context: context) else { return nil }
        return surface.rawValue(ofCase: SyntaxIdentifiers.unescaped(caseAccess.declName.baseName.text), inTypeNamed: type)
    }

    /// 타입처럼 보이는 정적 라우트 이름이 현재 문맥의 값으로 가려졌으면 프로젝트 표면을 조회하지 않는다.
    private func staticLookupIsUnbound(
        _ type: [String], expression: ExprSyntax, context: BindingCollector.Context
    ) -> Bool {
        guard let root = type.first, !["self", "Self"].contains(root) else { return true }
        guard !bindings.hasBinding(named: root, in: context) else { return false }
        return !isLexicalTypeShadow(named: root, expression: expression, context: context)
    }

    /// 값 바인딩과 별개로 현재 문맥의 타입 이름이 전역 타입을 가리는지 확인한다.
    private func isLexicalTypeShadow(
        named name: String, expression: ExprSyntax, context: BindingCollector.Context
    ) -> Bool {
        if context.enclosingTypes.contains(where: { surface.associatedTypeNames(in: $0).contains(name) }) {
            return true
        }
        var current = expression.parent
        while let syntax = current {
            if let function = syntax.as(FunctionDeclSyntax.self),
               function.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let initializer = syntax.as(InitializerDeclSyntax.self),
               initializer.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let declaration = syntax.as(SubscriptDeclSyntax.self),
               declaration.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let declaration = syntax.as(ClassDeclSyntax.self),
               declaration.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let declaration = syntax.as(StructDeclSyntax.self),
               declaration.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let declaration = syntax.as(EnumDeclSyntax.self),
               declaration.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let declaration = syntax.as(ActorDeclSyntax.self),
               declaration.genericParameterClause?.parameters.contains(where: { $0.name.text == name }) == true {
                return true
            }
            if let list = syntax.as(CodeBlockItemListSyntax.self), list.parent?.is(SourceFileSyntax.self) != true,
               containsLocalTypeShadow(list, named: name) {
                return true
            }
            current = syntax.parent
        }
        return false
    }

    /// 조건부 선언도 같은 지역 스코프를 가릴 수 있다. 함수·중첩 타입의 내부로는 들어가지 않는다.
    private func containsLocalTypeShadow(
        _ list: CodeBlockItemListSyntax, named name: String, depth: Int = 0
    ) -> Bool {
        guard depth < 64 else { return true }
        for item in list {
            let declaration = item.item
            if declaration.as(TypeAliasDeclSyntax.self)?.name.text == name
                || declaration.as(ClassDeclSyntax.self)?.name.text == name
                || declaration.as(StructDeclSyntax.self)?.name.text == name
                || declaration.as(EnumDeclSyntax.self)?.name.text == name
                || declaration.as(ActorDeclSyntax.self)?.name.text == name { return true }
            if let conditional = declaration.as(IfConfigDeclSyntax.self) {
                for clause in conditional.clauses {
                    if let items = clause.elements?.as(CodeBlockItemListSyntax.self),
                       containsLocalTypeShadow(items, named: name, depth: depth + 1) { return true }
                }
            }
        }
        return false
    }

    /// `compose.suffix`: 같은 함수의 불변 지역 변수이고, 초기식의 비어 있지 않은 값이 모두 `?` 로
    /// 시작하며 나머지 가지는 빈 문자열인지.
    private func isQueryTailLocal(_ expression: ExprSyntax, context: BindingCollector.Context) -> Bool {
        guard expression.is(DeclReferenceExprSyntax.self),
              let bound = bindings.constantExpression(for: expression, in: context),
              let scope = bound.context.scopes.last, context.scopes.contains(scope) else { return false }
        return queryTailShape(bound.expression, context: bound.context, depth: 0) != nil
    }

    /// 초기식의 모양. `.query` 는 `?` 로 시작하는 값, `.empty` 는 빈 문자열이다. 증명하지 못하면 nil.
    private func queryTailShape(_ expression: ExprSyntax, context: BindingCollector.Context, depth: Int) -> QueryTailShape? {
        guard depth < 16 else { return nil }
        let value = BindingCollector.unparenthesized(expression)
        if let literal = value.as(StringLiteralExprSyntax.self) { return Self.literalShape(literal) }
        if let ternary = value.as(TernaryExprSyntax.self) {
            guard let then = queryTailShape(ternary.thenExpression, context: context, depth: depth + 1),
                  let other = queryTailShape(ternary.elseExpression, context: context, depth: depth + 1) else { return nil }
            return then == .query || other == .query ? .query : .empty
        }
        if let infix = value.as(InfixOperatorExprSyntax.self), let operation = infix.operator.as(BinaryOperatorExprSyntax.self) {
            let left = queryTailShape(infix.leftOperand, context: context, depth: depth + 1)
            switch operation.operator.text {
            case "+": return left == .empty ? queryTailShape(infix.rightOperand, context: context, depth: depth + 1) : left
            case "??":
                guard let right = queryTailShape(infix.rightOperand, context: context, depth: depth + 1),
                      let optional = left ?? mappedShape(infix.leftOperand, depth: depth) else { return nil }
                return optional == .query || right == .query ? .query : .empty
            default: return nil
            }
        }
        guard let bound = bindings.constantExpression(for: value, in: context) else { return nil }
        return queryTailShape(bound.expression, context: bound.context, depth: depth + 1)
    }

    /// `x.map { "?" + $0 }` 처럼 옵셔널을 query 문자열로 바꾸는 식의 모양.
    private func mappedShape(_ expression: ExprSyntax, depth: Int) -> QueryTailShape? {
        guard let call = HTTPSyntax.unwrapped(expression).as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              ["map", "flatMap"].contains(member.declName.baseName.text),
              let closure = call.trailingClosure, closure.statements.count == 1,
              let body = closure.statements.first?.item.as(ExprSyntax.self) else { return nil }
        return queryTailShape(body, context: HTTPSyntax.context(of: body), depth: depth + 1)
    }

    private static func literalShape(_ literal: StringLiteralExprSyntax) -> QueryTailShape? {
        guard let first = literal.segments.first else { return .empty }
        guard case let .stringSegment(text) = first else { return nil }
        if text.content.text.hasPrefix("?") { return .query }
        return literal.representedLiteralValue == "" ? .empty : nil
    }

    // MARK: 매개변수 통과

    /// 경로가 감싸는 함수의 매개변수 그 자체인지 보고, 통과면 센다.
    ///
    /// 매개변수 뒤에 경로 리터럴이 붙으면(`"\(base)/items"`) 그 매개변수는 base 식이고 경로는
    /// 읽힌다. 뒤가 없거나 query·fragment 뿐일 때만 경로 전체가 매개변수에서 온다.
    func recordPassThrough(_ parts: [HTTPScannedPart], node: FunctionCallExprSyntax) -> HTTPPassThrough {
        guard let first = parts.first, first.part.isValue, let expression = first.expression else { return .none }
        let nextLiteral = parts.dropFirst().lazy.compactMap { part -> String? in
            if case let .literal(text) = part.part { return text }
            return nil
        }.first
        if let nextLiteral, !nextLiteral.hasPrefix("?"), !nextLiteral.hasPrefix("#") { return .none }
        let outcome = passThrough(expression, node: node)
        if outcome == .undeclared { counts.undeclaredWrapperSinks += 1 }
        return outcome
    }

    /// 읽지 못한 URL 식. 매개변수 통과가 아니면 읽지 못한 싱크로 센다.
    ///
    /// 선언된 생성자 래퍼 타입을 매개변수로 받는 함수(엔드포인트 기술자로 요청을 만드는 실행기)의
    /// 싱크는 세지 않는다. 그 요청의 경로는 기술자를 만든 호출 지점이 이미 사실로 냈다.
    func recordOpaque(_ expression: ExprSyntax, node: FunctionCallExprSyntax) {
        switch passThrough(expression, node: node) {
        case .none where takesDeclaredDescriptor(node): break
        case .none: counts.unreadableSinks += 1
        case .undeclared: counts.undeclaredWrapperSinks += 1
        case .covered: break
        }
    }

    private func takesDeclaredDescriptor(_ node: FunctionCallExprSyntax) -> Bool {
        HTTPSyntax.enclosingParameters(of: node).values.contains { type in
            type.flatMap(HTTPSyntax.typeBaseName).map(constructorOwners.contains) == true
        }
    }

    private func passThrough(_ expression: ExprSyntax, node: FunctionCallExprSyntax) -> HTTPPassThrough {
        guard let root = HTTPSyntax.rootIdentifier(expression),
              let type = HTTPSyntax.enclosingParameters(of: node)[root] else { return .none }
        let base = type.flatMap(HTTPSyntax.typeBaseName)
        return base.map(constructorOwners.contains) == true ? .covered : .undeclared
    }

    // MARK: 내보내기

    func emit(_ resolution: HTTPRouteResolution, method: String?, source: ExprSyntax?, service: String?, node: FunctionCallExprSyntax) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let fact = RouteCallFact(
            resolution: resolution, method: method,
            dynamicText: resolution.isDynamic ? source.flatMap(HTTPSyntax.sanitizedText) : nil,
            service: service, isTestSource: isTestSource,
            location: CartographCore.SourceLocation(path: path, line: start.line, column: start.column)
        )
        calls.append(ScannedRouteCall(fact: fact, declaration: declarations.last))
    }
}

/// query 꼬리 초기식의 모양.
private enum QueryTailShape {
    case query
    case empty
}

/// 한 본문 안의 `name.httpMethod = …` 대입과, 요청 값이 다른 곳으로 나가는지를 모은다.
///
/// `URLRequest` 는 값 타입이라 다른 이름에 복사하거나(`var copy = request`) 함수에 넘기면 그쪽에서 동사가
/// 바뀐 사본이 전송될 수 있다. 이름이 멤버 접근(`request.x`)의 수신자나 알려진 세션 전송 호출의 인자가
/// 아닌 자리에 나오면 나간 것으로 보고 동사를 확정하지 않는다. 틀린 동사는 거짓 method 불일치 error 다.
final class HTTPMethodAssignmentCollector: SyntaxVisitor {
    /// 요청을 받아 그대로 전송하는 URLSession 호출. 이름과 첫 인자 레이블.
    private static let sendingCalls: Set<String> = [
        "data\0for", "upload\0for", "download\0for", "bytes\0for", "dataTaskPublisher\0for",
        "dataTask\0with", "uploadTask\0with", "downloadTask\0with",
    ]

    /// 동사 대입 하나. `method` 는 Alamofire 의 `URLRequest.method`(`HTTPMethod`) 대입이다.
    struct Assignment {
        let value: ExprSyntax
        let isLibraryMethod: Bool
    }

    private let name: String
    /// 수신자가 Alamofire `Session` 인지. `session.request(request)` 도 요청을 그대로 전송한다.
    private let isAlamofireSession: (ExprSyntax) -> Bool
    private(set) var values: [Assignment] = []
    private(set) var escapes = false

    init(name: String, isAlamofireSession: @escaping (ExprSyntax) -> Bool = { _ in false }) {
        self.name = name
        self.isAlamofireSession = isAlamofireSession
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.is(AssignmentExprSyntax.self),
              let member = node.leftOperand.as(MemberAccessExprSyntax.self),
              ["httpMethod", "method"].contains(member.declName.baseName.text),
              member.base.map(isName) == true
        else { return .visitChildren }
        values.append(Assignment(value: node.rightOperand, isLibraryMethod: member.declName.baseName.text == "method"))
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard isName(ExprSyntax(node)), !isMemberReceiver(node), !isSentDirectly(node), !isOverwrittenOrDiscarded(node)
        else { return .visitChildren }
        escapes = true
        return .visitChildren
    }

    /// `name.x` 의 수신자인지. 속성 읽기·쓰기는 같은 값을 다룬다.
    private func isMemberReceiver(_ node: DeclReferenceExprSyntax) -> Bool {
        node.parent?.as(MemberAccessExprSyntax.self)?.base?.id == ExprSyntax(node).id
    }

    /// `name = …` 로 값을 덮어쓰거나 `_ = name` 으로 버리는 자리인지. 둘 다 요청 값을 내보내지 않는다.
    private func isOverwrittenOrDiscarded(_ node: DeclReferenceExprSyntax) -> Bool {
        guard let assignment = node.parent?.as(InfixOperatorExprSyntax.self),
              assignment.operator.is(AssignmentExprSyntax.self) else { return false }
        if assignment.leftOperand.id == ExprSyntax(node).id { return true }
        return assignment.leftOperand.is(DiscardAssignmentExprSyntax.self)
    }

    /// `session.data(for: name)` 처럼 전송 호출의 첫 인자로 바로 넘어가는지.
    private func isSentDirectly(_ node: DeclReferenceExprSyntax) -> Bool {
        guard let argument = node.parent?.as(LabeledExprSyntax.self),
              let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
              call.arguments.first?.id == argument.id,
              let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        let key = member.declName.baseName.text + "\0" + (argument.label?.text ?? "")
        if Self.sendingCalls.contains(key) { return true }
        // Alamofire 5.12.2 의 `request(_:)`·`download(_:)`·`streamRequest(_:)` 는 `URLRequestConvertible` 을 받아
        // `asURLRequest()`(URLRequest 는 자기 자신)로 그대로 보낸다.
        return ["request\0", "download\0", "streamRequest\0"].contains(key) && member.base.map(isAlamofireSession) == true
    }

    private func isName(_ expression: ExprSyntax) -> Bool {
        expression.as(DeclReferenceExprSyntax.self).map { SyntaxIdentifiers.unescaped($0.baseName.text) } == name
    }
}
