import CartographCore
import SwiftSyntax

/// Alamofire `Session` 요청 호출 하나의 모양.
struct HTTPAlamofireRequest {
    /// `request`·`streamRequest`·`download`·`upload`.
    let name: String
    /// URL 인자(`URLConvertible` 이거나 `URLRequestConvertible`).
    let url: ExprSyntax
    /// `method:` 인자. 없으면 메서드의 기본 동사다.
    let method: ExprSyntax?
    /// `upload(_:with:)` 처럼 `URLRequestConvertible` 만 받는 겹지정인지.
    let isRequestOnly: Bool
}

/// Foundation·Alamofire 의 URL 조립과 요청 호출을 읽는다.
///
/// 규칙(인코딩·결합·기본 동사)은 `CartographCore` 의 `HTTPFoundationPath`·`HTTPLibraryMethod`·
/// `HTTPTargetRouteRules` 에 있고, 여기서는 식을 조각으로 펼치기만 한다.
extension HTTPRouteCallCollector {
    // MARK: - Foundation URL 조립

    /// `base.appendingPathComponent(x)`·`appending(path:)`·`appending(component:)` 를 펼친다.
    ///
    /// Foundation 은 조각을 디코드된 텍스트로 받아 인코딩한다(`?` → `%3F`). 조각 전체가 값 하나이면
    /// `appending(component:)` 는 `/` 까지 인코딩하므로 세그먼트 하나(`{}`)지만, `appendingPathComponent`·
    /// `appending(path:)` 의 값은 `/` 를 담을 수 있다. 이름이 경로(`path`)를 말하는 값이나 `appending(path:)` 의
    /// 값은 경로 전체로 보고 dynamic 으로 둔다 — 틀린 `{}` 는 조인을 오염시키고 dynamic 은 공백으로 세어진다.
    func appendedURLParts(
        _ call: FunctionCallExprSyntax, appended: (base: ExprSyntax, component: ExprSyntax),
        context: BindingCollector.Context, depth: Int
    ) -> (parts: [HTTPScannedPart], join: HTTPPathJoin) {
        let label = call.arguments.first?.label?.text
        let keepsSlash = label != "component"
        let raw = parts(of: appended.component, context: context)
        let component = encodedComponent(raw, keepsSlash: keepsSlash, isPathArgument: label == "path", source: appended.component)
        guard let base = urlParts(appended.base, context: context, depth: depth + 1) else {
            // base 를 모르면 빈 base 뒤에 붙인 경로를 base 앵커로 읽는다. 조각 앞의 값은 base 식이 아니다.
            return (Self.slashJoined([], component, trimsComponentSlash: keepsSlash), .wrapper(.base))
        }
        return (Self.slashJoined(base.parts, component, trimsComponentSlash: keepsSlash), base.join)
    }

    /// 조각의 리터럴을 Foundation 방식으로 인코딩한다. 값 하나뿐인 경로 인자는 경로 전체 값이다.
    private func encodedComponent(_ raw: [HTTPScannedPart], keepsSlash: Bool, isPathArgument: Bool, source: ExprSyntax) -> [HTTPScannedPart] {
        if keepsSlash, raw.count == 1, raw[0].part == .value, isPathArgument || Self.namesPath(source) {
            return [.pathValue(raw[0].expression)]
        }
        return raw.map { part in
            guard case let .literal(text) = part.part else { return part }
            return .literal(HTTPFoundationPath.encodeDecoded(text, keepsSlash: keepsSlash))
        }
    }

    /// 식의 마지막 이름이 경로를 말하는지(`path`, `endpoint.path`, `requestPath`).
    private static func namesPath(_ expression: ExprSyntax) -> Bool {
        let value = HTTPSyntax.unwrapped(expression)
        let name: String? = if let reference = value.as(DeclReferenceExprSyntax.self) { reference.baseName.text }
            else if let member = value.as(MemberAccessExprSyntax.self) { member.declName.baseName.text } else { nil }
        return name?.lowercased().hasSuffix("path") == true
    }

    /// `appendingPathComponent` 결합(`HTTPTargetRouteRules.slashJoined` 와 같은 규칙). 원문 식을 보존한다.
    static func slashJoined(_ base: [HTTPScannedPart], _ component: [HTTPScannedPart], trimsComponentSlash: Bool) -> [HTTPScannedPart] {
        var head = base
        if case let .literal(text)? = head.last?.part {
            head[head.count - 1] = .literal(HTTPFoundationPath.joinTrimmingOneSlash(base: text, component: "").base)
        }
        var tail = component
        if trimsComponentSlash, case let .literal(text)? = tail.first?.part {
            tail[0] = .literal(HTTPFoundationPath.joinTrimmingOneSlash(base: "", component: text).component)
        }
        return head + [.joiningSlash] + tail
    }

    /// `URL(string: path, relativeTo: base)`. base 가 리터럴 전체 URL 이면 RFC 3986 병합으로 root 를 확정하고,
    /// 모르면 상대 해석 규칙(`/x` root, `x` base)을 쓴다.
    func relativeURLParts(
        _ path: [HTTPScannedPart], base: ExprSyntax, context: BindingCollector.Context, depth: Int
    ) -> (parts: [HTTPScannedPart], join: HTTPPathJoin) {
        guard let base = urlParts(base, context: context, depth: depth + 1),
              case let .literal(head)? = path.first?.part,
              let prefix = HTTPTargetRouteRules.rfc3986Prefix(base: HTTPTargetURL(parts: base.parts.map(\.part), join: base.join), path: head)
        else { return (path, .rfc3986) }
        return ([.literal(prefix)] + path, .absoluteURL)
    }

    /// `x.asURL()`(Alamofire `URLConvertible`)을 펼친다. 문자열이면 `URL(string:)`, URL 이면 그대로다.
    func convertedURLParts(_ call: FunctionCallExprSyntax, context: BindingCollector.Context, depth: Int) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "asURL",
              call.arguments.isEmpty, let base = member.base else { return nil }
        if let url = urlParts(base, context: context, depth: depth + 1) { return url }
        return stringURLParts(base, context: context).map { ($0, .absoluteURL) }
    }

    /// 타입 멤버 상수(`Self.baseURL`, `API.baseURL`, `baseURL`)로 묶인 URL 식을 펼친다.
    func memberURLParts(_ value: ExprSyntax, context: BindingCollector.Context, depth: Int) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        if let bound = bindings.constantExpression(for: value, in: context) {
            return urlParts(bound.expression, context: bound.context, depth: depth + 1)
        }
        guard let bound = locals.memberURLExpression(value, enclosingTypes: context.enclosingTypes) else { return nil }
        return urlParts(bound, context: HTTPSyntax.context(of: bound), depth: depth + 1)
    }

    /// 문자열임을 증명한 식(리터럴·보간·문자열 `+`·문자열 상수)이면 그 조각. `URLConvertible` 문자열 인자다.
    func stringURLParts(_ expression: ExprSyntax, context: BindingCollector.Context) -> [HTTPScannedPart]? {
        isStringExpression(expression, context: context, depth: 0) ? parts(of: expression, context: context) : nil
    }

    private func isStringExpression(_ expression: ExprSyntax, context: BindingCollector.Context, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        let value = HTTPSyntax.unwrapped(expression)
        if value.is(StringLiteralExprSyntax.self) || bindings.resolvedValue(of: value) != nil { return true }
        if let infix = value.as(InfixOperatorExprSyntax.self), infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
            return isStringExpression(infix.leftOperand, context: context, depth: depth + 1)
                || isStringExpression(infix.rightOperand, context: context, depth: depth + 1)
        }
        guard let bound = bindings.constantExpression(for: value, in: context) else { return false }
        return isStringExpression(bound.expression, context: bound.context, depth: depth + 1)
    }

    // MARK: - URLComponents

    /// `components.url` · `URLComponents(string:)!.url` 을 펼친다.
    ///
    /// 같은 코드 블록에서 선언 뒤 사용 앞에 있는 최상위 문장의 `scheme`·`host`·`port`·`path`·
    /// `percentEncodedPath` 대입만 차례로 적용한다. 조건문 안의 대입이나 `&components` 로 넘기는 곳이
    /// 있으면 사용 시점의 값을 증명할 수 없어 읽지 않는다. `path` 는 Foundation 이 인코딩한다(`?` → `%3F`,
    /// `%` → `%25`)는 것을 실측했고, `percentEncodedPath` 는 그대로 쓴다.
    func componentsURLParts(_ value: ExprSyntax, context: BindingCollector.Context, depth: Int) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        guard let member = value.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "url",
              let base = member.base else { return nil }
        return componentsParts(base, use: value, context: context, depth: depth)
    }

    /// `URLComponents` 값 식 자체(Alamofire 는 `URLComponents` 를 `URLConvertible` 로 받는다)를 펼친다.
    func componentsParts(_ base: ExprSyntax, use: ExprSyntax, context: BindingCollector.Context, depth: Int) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        let receiver = HTTPSyntax.unwrapped(base)
        if let call = receiver.as(FunctionCallExprSyntax.self), HTTPSyntax.isFoundationInitializer(call, type: "URLComponents") {
            return initialComponents(call, context: context, depth: depth).flatMap { finish($0) }
        }
        guard let reference = receiver.as(DeclReferenceExprSyntax.self),
              let declaration = locals.componentsBinding(named: SyntaxIdentifiers.unescaped(reference.baseName.text), scopes: context.scopes),
              let call = HTTPSyntax.unwrapped(declaration.value).as(FunctionCallExprSyntax.self),
              var state = initialComponents(call, context: HTTPSyntax.context(of: call), depth: depth) else { return nil }
        let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
        guard let mutations = HTTPComponentsMutations.collect(name: name, declaration: declaration.node, use: use) else { return nil }
        for mutation in mutations {
            apply(mutation, to: &state, context: HTTPSyntax.context(of: mutation.value))
        }
        return finish(state)
    }

    /// 초기식의 상태. 문자열·URL 로 만든 값은 host 가 리터럴일 때만 origin 과 경로로 나눈다.
    private func initialComponents(_ call: FunctionCallExprSyntax, context: BindingCollector.Context, depth: Int) -> HTTPComponentsState? {
        guard let first = call.arguments.first else { return HTTPComponentsState() }
        let whole: [HTTPScannedPart]
        switch first.label?.text {
        case "string": whole = parts(of: first.expression, context: context)
        case "url": guard let url = urlParts(first.expression, context: context, depth: depth + 1), url.join == .absoluteURL else { return nil }
            whole = url.parts
        default: return nil
        }
        return HTTPComponentsState(splitting: whole)
    }

    private func apply(_ mutation: HTTPComponentsMutation, to state: inout HTTPComponentsState, context: BindingCollector.Context) {
        let value = parts(of: mutation.value, context: context)
        switch mutation.property {
        // scheme 은 경로를 바꾸지 않는다. 값을 모르면 자리만 채워 host·경로를 그대로 읽는다.
        case "scheme": state.scheme = Self.literalText(value) ?? "https"
        case "host", "percentEncodedHost": state.host = value
        case "port": state.port = mutation.value.as(IntegerLiteralExprSyntax.self)?.literal.text ?? (mutation.value.is(NilLiteralExprSyntax.self) ? "" : nil)
        case "path": state.setPath(encodedPath(value), appending: mutation.appends)
        default: state.setPath(value, appending: mutation.appends)
        }
    }

    /// `URLComponents.path` 에 넣은 디코드된 텍스트의 리터럴을 인코딩한다.
    private func encodedPath(_ value: [HTTPScannedPart]) -> [HTTPScannedPart] {
        value.map { part in
            guard case let .literal(text) = part.part else { return part }
            return .literal(HTTPFoundationPath.encodeDecoded(text, keepsSlash: true))
        }
    }

    private static func literalText(_ parts: [HTTPScannedPart]) -> String? {
        guard parts.count == 1, case let .literal(text) = parts[0].part else { return nil }
        return text
    }

    /// 상태를 전체 URL 조각으로 만든다. host 가 있는데 경로가 `/` 로 시작하지 않으면 `url` 이 nil 이다.
    private func finish(_ state: HTTPComponentsState) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        guard let origin = state.origin else { return nil }
        if case let .literal(text)? = state.path.first?.part, !text.isEmpty, !text.hasPrefix("/") { return nil }
        return (origin + state.path, .absoluteURL)
    }

    // MARK: - 동사

    /// Alamofire `HTTPMethod`·Moya `Method` 식의 계약 동사. `.post`, `HTTPMethod.post`, `HTTPMethod(rawValue: "POST")`.
    func libraryVerb(_ expression: ExprSyntax, context: BindingCollector.Context) -> String? {
        let value = HTTPSyntax.unwrapped(expression)
        if let verb = libraryVerbMember(value) { return verb }
        guard let call = value.as(FunctionCallExprSyntax.self), let argument = call.arguments.first,
              argument.label?.text == "rawValue" else { return nil }
        let callee = HTTPSyntax.dottedName(call.calledExpression) ?? []
        let isMethodType = callee.last == "init" || ["HTTPMethod", "Method"].contains(callee.last ?? "")
        return isMethodType ? stringVerb(argument.expression, context: context) : nil
    }

    /// `.post`·`HTTPMethod.post`·`Moya.Method.post` 의 동사. 소문자 멤버 이름만 라이브러리 동사다.
    func libraryVerbMember(_ expression: ExprSyntax) -> String? {
        guard let member = HTTPSyntax.unwrapped(expression).as(MemberAccessExprSyntax.self) else { return nil }
        if let base = member.base {
            guard let dotted = HTTPSyntax.dottedName(base), ["HTTPMethod", "Method"].contains(dotted.last ?? "") else { return nil }
        }
        return HTTPLibraryMethod.verb(forMemberName: SyntaxIdentifiers.unescaped(member.declName.baseName.text))
    }

    // MARK: - Alamofire 요청

    /// `AF.request(…)`·`session.upload(…, to:)` 처럼 수신자가 Alamofire `Session` 임을 증명한 요청 호출.
    ///
    /// 수신자는 `AF`, `Session.default`, 또는 타입 표기·생성자로 `Session` 임을 증명한 이름이다. 프로젝트가
    /// `Session` 이라는 타입을 따로 선언했으면 `Session` 표기는 증거가 아니다.
    func alamofireRequest(_ node: FunctionCallExprSyntax) -> HTTPAlamofireRequest? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else { return nil }
        let name = member.declName.baseName.text
        guard HTTPLibraryMethod.alamofireDefaultVerb(forRequestMethod: name) != nil, isAlamofireSession(base) else { return nil }
        let method = node.arguments.first { $0.label?.text == "method" }?.expression
        if name == "upload" {
            if let target = node.arguments.first(where: { $0.label?.text == "to" }) {
                return HTTPAlamofireRequest(name: name, url: target.expression, method: method, isRequestOnly: false)
            }
            guard let request = node.arguments.first(where: { $0.label?.text == "with" }) else { return nil }
            return HTTPAlamofireRequest(name: name, url: request.expression, method: nil, isRequestOnly: true)
        }
        guard let first = node.arguments.first, first.label == nil else { return nil }
        return HTTPAlamofireRequest(name: name, url: first.expression, method: method, isRequestOnly: false)
    }

    func isAlamofireSession(_ base: ExprSyntax) -> Bool {
        let dotted = HTTPSyntax.dottedName(base)
        if dotted == ["AF"] || dotted == ["Alamofire", "AF"] { return true }
        guard !surface.declaresTypeNamed("Session") else { return false }
        if dotted == ["Session", "default"] || dotted == ["Alamofire", "Session", "default"] { return true }
        return receiverType(of: base) == "Session"
    }

    /// Alamofire 요청 하나를 사실로 낸다.
    ///
    /// `method:` 가 있는 겹지정은 `URLConvertible` 만 받는다. 없으면 인자가 라우터·`URLRequest` 일 수 있다 —
    /// 라우터는 case 선언에서, `URLRequest(url:)` 는 생성 지점에서 이미 사실이 되므로 여기서 내지 않는다.
    /// 문자열·URL·`URLComponents` 임을 증명한 인자만 이 호출의 사실이다.
    func emitAlamofireRequest(_ node: FunctionCallExprSyntax, _ request: HTTPAlamofireRequest) {
        guard !request.isRequestOnly, !isInsideDeclaredWrapper(node) else { return }
        let context = HTTPSyntax.context(of: node)
        let verb = request.method.map { libraryVerb($0, context: context) }
            ?? HTTPLibraryMethod.alamofireDefaultVerb(forRequestMethod: request.name)
        if let url = urlConvertibleParts(request.url, context: context) {
            emitReadURL(node, url: url, method: verb, source: request.url)
        } else if request.method != nil || takesURLConvertibleParameter(request.url, node: node) {
            recordOpaque(request.url, node: node)
        }
    }

    /// `URLConvertible` 인자(URL 식·`URLComponents`·문자열)를 펼친다.
    private func urlConvertibleParts(_ expression: ExprSyntax, context: BindingCollector.Context) -> (parts: [HTTPScannedPart], join: HTTPPathJoin)? {
        if let url = urlParts(expression, context: context, depth: 0) { return url }
        if let components = componentsParts(expression, use: expression, context: context, depth: 0) { return components }
        return stringURLParts(expression, context: context).map { ($0, .absoluteURL) }
    }

    /// 인자가 `String`·`URL`·`URLConvertible`·`URLComponents` 로 표기된 매개변수에서 오는지.
    private func takesURLConvertibleParameter(_ expression: ExprSyntax, node: FunctionCallExprSyntax) -> Bool {
        guard let root = HTTPSyntax.rootIdentifier(expression), let type = HTTPSyntax.enclosingParameters(of: node)[root],
              let name = type.flatMap(HTTPSyntax.typeBaseName) else { return false }
        return ["String", "URL", "URLConvertible", "URLComponents"].contains(name)
    }

    // MARK: - URL 재작성

    /// Moya `Endpoint(url:sampleResponseClosure:…)` 를 기본 매핑(`URL(target:)`)이 아닌 URL 로 만드는지 센다.
    ///
    /// 사용자 정의 `endpointClosure` 는 case 가 선언한 경로와 다른 URL 로 요청을 보낼 수 있다. 헤더만 더하는
    /// 흔한 모양(`URL(target: target).absoluteString`)은 URL 을 바꾸지 않으므로 세지 않는다.
    func countURLRewritingEndpoint(_ node: FunctionCallExprSyntax) {
        let callee = HTTPSyntax.dottedName(node.calledExpression)
        guard callee == ["Endpoint"] || callee == ["Moya", "Endpoint"], !surface.declaresTypeNamed("Endpoint") else { return }
        let labels = Set(node.arguments.compactMap { $0.label?.text })
        guard labels.contains("url"), labels.contains("sampleResponseClosure"),
              let url = node.arguments.first(where: { $0.label?.text == "url" })?.expression,
              !url.trimmedDescription.contains("URL(target:") else { return }
        counts.urlRewriters += 1
    }

    /// Alamofire `RequestAdapter.adapt(_:for:completion:)` 가 요청의 `url` 을 바꾸는지 센다.
    ///
    /// 감싸는 타입이 `RequestAdapter`·`RequestInterceptor` 를 준수할 때만 어댑터다. 같은 이름의 무관한 함수를
    /// 세면 모든 미호출 진단이 근거 없이 `-unverified` 로 내려간다.
    func recordURLRewritingAdapter(_ node: FunctionDeclSyntax, name: String) {
        let conformances = chain.isEmpty ? [] : surface.conformedNames(of: chain.joined(separator: "."))
        guard name == "adapt", conformances.contains("RequestAdapter") || conformances.contains("RequestInterceptor"),
              let first = node.signature.parameterClause.parameters.first,
              HTTPSyntax.typeBaseName(first.type) == "URLRequest", let body = node.body else { return }
        let finder = HTTPURLAssignmentFinder()
        finder.walk(body)
        if finder.found { counts.urlRewriters += 1 }
    }

    // MARK: - 모델링하지 않는 클라이언트

    /// 이 도구가 요청을 읽지 않는 HTTP 클라이언트 모듈. 그 모듈을 쓰는 파일의 호출은 사실이 없다.
    static let unmodelledClientModules: Set<String> = ["APIKit", "Get", "Siesta", "RxAlamofire", "Apollo", "AFNetworking"]
    /// OpenAPI 생성 클라이언트 런타임. 생성 코드의 요청은 스펙에서 오며 이 도구는 읽지 않는다.
    static let generatedClientModules: Set<String> = ["OpenAPIRuntime", "OpenAPIURLSession", "OpenAPIAsyncHTTPClient"]

    /// import 한 모듈이 모델링하지 않는 클라이언트면 센다.
    func recordImport(_ node: ImportDeclSyntax) {
        guard let module = node.path.first?.name.text else { return }
        if Self.unmodelledClientModules.contains(module) { counts.unmodelledClientImports[module, default: 0] += 1 }
        if Self.generatedClientModules.contains(module) { counts.generatedClientImports += 1 }
    }
}

/// `URLComponents` 를 조립하는 동안의 상태.
struct HTTPComponentsState {
    var scheme: String?
    var host: [HTTPScannedPart]?
    /// `""` 는 기본 포트(nil 대입), nil 은 알 수 없는 포트 식이다.
    var port: String? = ""
    var path: [HTTPScannedPart] = []
    /// 초기식이 준 origin(`scheme://host[:port]`). 개별 대입이 있으면 그것으로 바꾼다.
    private var initialOrigin: [HTTPScannedPart]?

    init() {}

    /// 전체 URL 조각을 origin 과 경로로 나눈다. host 가 리터럴이 아니면 origin 은 값 하나다.
    init(splitting whole: [HTTPScannedPart]) {
        let merged = HTTPRouteURLResolver.mergedLiterals(whole.map(\.part))
        guard case let .literal(head)? = merged.first, let schemeEnd = HTTPRouteTemplate.schemeLength(head) else {
            initialOrigin = [HTTPScannedPart(part: .value, expression: nil)]
            path = []
            return
        }
        let rest = head.dropFirst(schemeEnd)
        let cut = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        initialOrigin = [.literal(String(head[..<cut]))]
        let tail = rest[cut...]
        // query·fragment 는 경로가 아니다. 뒤따르는 `path +=` 가 query 뒤에 붙지 않게 경로에서 뗀다.
        if let query = tail.firstIndex(where: { "?#".contains($0) }) {
            path = query == tail.startIndex ? [] : [.literal(String(tail[..<query]))]
            return
        }
        path = (tail.isEmpty ? [] : [HTTPScannedPart.literal(String(tail))]) + Self.remainder(whole, afterMerging: head)
    }

    /// 병합한 첫 리터럴 뒤의 원래 조각들(보간 값의 원문 식을 보존한다).
    private static func remainder(_ whole: [HTTPScannedPart], afterMerging head: String) -> [HTTPScannedPart] {
        var consumed = ""
        var index = 0
        while index < whole.count, case let .literal(text) = whole[index].part, consumed.count < head.count {
            consumed += text
            index += 1
        }
        return Array(whole.dropFirst(index))
    }

    mutating func setPath(_ value: [HTTPScannedPart], appending: Bool) {
        path = appending ? path + value : value
    }

    /// 조립된 origin. scheme 이나 host 가 없으면 nil 이다 — `//host/x` 나 `/x` 는 요청 URL 이 아니다.
    var origin: [HTTPScannedPart]? {
        if scheme == nil, host == nil { return initialOrigin }
        guard let host, let scheme else { return nil }
        let prefix = HTTPScannedPart.literal(scheme + "://")
        let portPart: [HTTPScannedPart] = switch port {
        case ""?: []
        case let digits?: [.literal(":" + digits)]
        case nil: [.literal(":"), HTTPScannedPart(part: .value, expression: nil)]
        }
        return [prefix] + host + portPart
    }
}

/// `URLComponents` 변수에 대한 경로·host 대입 하나. `appends` 는 `+=`·`append(_:)` 다.
struct HTTPComponentsMutation {
    let property: String
    let value: ExprSyntax
    let appends: Bool
}

/// `URLComponents` 변수에 대한 경로·host 대입을 모은다.
enum HTTPComponentsMutations {
    /// 사용 시점 값을 바꾸는 속성.
    static let properties: Set<String> = ["scheme", "host", "percentEncodedHost", "port", "path", "percentEncodedPath"]

    /// 선언 뒤 사용 앞의 같은 블록 최상위 대입들. 증명할 수 없는 변경이 있으면 nil.
    static func collect(name: String, declaration: some SyntaxProtocol, use: some SyntaxProtocol) -> [HTTPComponentsMutation]? {
        guard let item = enclosingItem(of: declaration), let list = item.parent?.as(CodeBlockItemListSyntax.self),
              let body = list.parent else { return nil }
        let finder = HTTPComponentsUseFinder(name: name, properties: properties)
        finder.walk(body)
        var mutations: [HTTPComponentsMutation] = []
        let end = item.endPositionBeforeTrailingTrivia
        let usePosition = use.positionAfterSkippingLeadingTrivia
        for found in finder.uses where found.position >= end && found.position < usePosition {
            if found.isInOut || found.isUnprovableWrite { return nil }
            guard let mutation = found.mutation else { continue }
            // 같은 블록의 최상위 문장이 아니면(조건문·클로저 안) 사용 시점의 값을 증명할 수 없다.
            guard found.statementList == list.id else { return nil }
            mutations.append(mutation)
        }
        return mutations
    }

    private static func enclosingItem(of node: some SyntaxProtocol) -> CodeBlockItemSyntax? {
        var current = Syntax(node).parent
        while let syntax = current {
            if let item = syntax.as(CodeBlockItemSyntax.self) { return item }
            current = syntax.parent
        }
        return nil
    }
}

/// 본문에서 `URLComponents` 변수 하나가 쓰인 곳을 찾는다.
final class HTTPComponentsUseFinder: SyntaxVisitor {
    /// 쓰인 곳 하나.
    struct Use {
        let position: AbsolutePosition
        /// `&name` 으로 넘겨 어디서든 바뀔 수 있는지.
        let isInOut: Bool
        /// 값 전체를 바꾸거나(`name = …`, `name.string = …`) 읽지 않는 속성을 대입해 경로를 증명할 수 없는지.
        var isUnprovableWrite = false
        /// 경로·host 를 바꾸는 대입이면 그 내용.
        let mutation: HTTPComponentsMutation?
        /// 대입 문장이 속한 코드 블록 목록. 최상위 문장이 아니면 nil.
        let statementList: SyntaxIdentifier?
    }

    private let name: String
    private let properties: Set<String>
    private(set) var uses: [Use] = []
    /// 대입해도 경로·host 가 바뀌지 않는 속성. 그 밖의 속성 대입(`string` 등)은 URL 전체를 바꿀 수 있다.
    private static let pathNeutral: Set<String> = [
        "queryItems", "percentEncodedQueryItems", "query", "percentEncodedQuery", "fragment", "percentEncodedFragment",
        "user", "password", "percentEncodedUser", "percentEncodedPassword",
    ]

    init(name: String, properties: Set<String>) {
        self.name = name
        self.properties = properties
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard SyntaxIdentifiers.unescaped(node.baseName.text) == name else { return .visitChildren }
        let isInOut = node.parent?.is(InOutExprSyntax.self) == true
        let receiver = Self.receiver(of: node)
        let (mutation, statement) = mutation(at: receiver)
        var use = Use(position: node.positionAfterSkippingLeadingTrivia, isInOut: isInOut, mutation: mutation, statementList: statement)
        use.isUnprovableWrite = mutation == nil && isUnprovableWrite(receiver)
        uses.append(use)
        return .visitChildren
    }

    /// `name?`·`name!` 처럼 이름을 감싼 옵셔널 접근까지 올라간 수신자 식.
    private static func receiver(of node: DeclReferenceExprSyntax) -> ExprSyntax {
        var current = ExprSyntax(node)
        while let parent = current.parent,
              parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
            current = ExprSyntax(parent)!
        }
        return current
    }

    /// 값 전체 대입(`name = …`)이나 경로를 모르는 속성 대입(`name.string = …`)인지.
    private func isUnprovableWrite(_ receiver: ExprSyntax) -> Bool {
        if Self.isAssignmentTarget(receiver) { return true }
        guard let member = receiver.parent?.as(MemberAccessExprSyntax.self), member.base?.id == receiver.id,
              Self.isAssignmentTarget(ExprSyntax(member)) else { return false }
        return !Self.pathNeutral.contains(member.declName.baseName.text)
    }

    private static func isAssignmentTarget(_ expression: ExprSyntax) -> Bool {
        guard let infix = expression.parent?.as(InfixOperatorExprSyntax.self), infix.leftOperand.id == expression.id else { return false }
        if infix.operator.is(AssignmentExprSyntax.self) { return true }
        // 복합 대입(`+=`)만 쓰기다. 비교 연산자(`==`·`<=`)도 `=` 로 끝난다.
        guard let text = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        return text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
    }

    /// `name.path = x`, `name.path += x`, `name.path.append(x)` 를 읽는다(`name?.path` 도 같다).
    private func mutation(at receiver: ExprSyntax) -> (HTTPComponentsMutation?, SyntaxIdentifier?) {
        guard let member = receiver.parent?.as(MemberAccessExprSyntax.self), member.base?.id == receiver.id else { return (nil, nil) }
        let property = member.declName.baseName.text
        guard properties.contains(property) else { return (nil, nil) }
        if let infix = member.parent?.as(InfixOperatorExprSyntax.self), infix.leftOperand.id == ExprSyntax(member).id {
            let appends = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+="
            guard infix.operator.is(AssignmentExprSyntax.self) || appends else { return (nil, nil) }
            return (.init(property: property, value: infix.rightOperand, appends: appends), Self.statementList(of: infix))
        }
        if let append = member.parent?.as(MemberAccessExprSyntax.self), append.declName.baseName.text == "append",
           let call = append.parent?.as(FunctionCallExprSyntax.self), let argument = call.arguments.first, call.arguments.count == 1 {
            return (.init(property: property, value: argument.expression, appends: true), Self.statementList(of: call))
        }
        return (nil, nil)
    }

    /// 식이 곧 문장이면 그 문장이 속한 목록.
    private static func statementList(of expression: some SyntaxProtocol) -> SyntaxIdentifier? {
        guard let item = expression.parent?.as(CodeBlockItemSyntax.self) else { return nil }
        return item.parent?.as(CodeBlockItemListSyntax.self)?.id
    }
}

/// 본문에 `x.url = …` 대입이 있는지 찾는다. 요청 어댑터가 URL 을 바꾸는 증거다.
final class HTTPURLAssignmentFinder: SyntaxVisitor {
    private(set) var found = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.is(AssignmentExprSyntax.self),
           node.leftOperand.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "url" {
            found = true
        }
        return .visitChildren
    }
}
