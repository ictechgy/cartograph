import CartographCore
import SwiftSyntax

/// 이미 파싱한 트리에서 본문 있는 함수의 파라미터 사용 근거를 모은다.
///
/// 인덱스 스토어는 지역 심볼의 참조 발생을 기록하지 않아, 파라미터가 본문에서
/// 읽혔는지는 구문으로만 판별할 수 있다. 스코프를 스택으로 관리해 중첩
/// 함수·클로저가 바깥 파라미터를 캡처한 경우와 이름을 가린 경우를 구분한다.
struct ParameterUsageScanner {
    init() {}

    /// 소스 트리에서 파라미터 사용 사실을 만든다.
    func scan(tree: SourceFileSyntax, path: String, converter: SourceLocationConverter) -> [ParameterUsageFacts] {
        let collector = Collector(path: path, converter: converter)
        collector.walk(tree)
        return collector.usages()
    }
}

private final class Collector: SyntaxVisitor {
    /// 이 스코프에 묶인 이름 전체와 그중 보고 대상이 되는 파라미터의 색인.
    ///
    /// 클로저 캡처처럼 파라미터는 아니지만 같은 이름으로 바깥 바인딩을 가리는
    /// 이름도 `bindings` 에 넣는다. 안쪽 바인딩을 먼저 봐야 바깥 파라미터가
    /// 가려졌을 때 "쓰였다"고 잘못 표시하지 않는다.
    private struct Scope {
        var bindings: Set<String>
        var parameterIndexes: [String: Int]
    }

    private let path: String
    private let converter: SourceLocationConverter
    private var scopes: [Scope] = []
    /// 스코프를 쌓은 노드. 방문이 끝날 때 마지막이 자기 자신일 때만 내린다.
    private var scopeOwners: [SyntaxIdentifier] = []
    private var parameters: [(name: String, location: CartographCore.SourceLocation)] = []
    private var usedIndexes: Set<Int> = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    func usages() -> [ParameterUsageFacts] {
        parameters.enumerated().map { index, parameter in
            ParameterUsageFacts(name: parameter.name, location: parameter.location,
                isUsedInBody: usedIndexes.contains(index))
        }
    }

    // MARK: - 스코프를 여는 선언

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.body != nil else { return .visitChildren }
        push(node, parameters: node.signature.parameterClause.parameters)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { pop(node) }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.body != nil else { return .visitChildren }
        push(node, parameters: node.signature.parameterClause.parameters)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { pop(node) }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.accessorBlock != nil else { return .visitChildren }
        push(node, parameters: node.parameterClause.parameters)
        return .visitChildren
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { pop(node) }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // 캡처 항목은 스코프를 쌓기 전에 바깥 스코프의 이름으로 처리한다.
        // `[x]` 는 바깥 x 를 읽는 참조이고, `[x = 식]` 의 식도 바깥 스코프에서
        // 평가된다. 스코프를 먼저 쌓으면 그 참조가 방금 생긴 캡처 바인딩에 빨려
        // 실제로 쓰인 바깥 파라미터가 미사용으로 보고된다.
        var bindings: Set<String> = []
        if let captures = node.signature?.capture?.items {
            for capture in captures {
                bindings.insert(DeclarationCollector.unescaped(capture.name.text))
                if let initializer = capture.initializer {
                    ReferenceMarker(mark: markReference).walk(initializer.value)
                } else {
                    markUsed(capture.name.text)
                }
            }
        }
        var parameterIndexes: [String: Int] = [:]
        switch node.signature?.parameterClause {
        case let .parameterClause(clause):
            for parameter in clause.parameters {
                recordParameter(name: (parameter.secondName ?? parameter.firstName).text,
                    token: parameter.secondName ?? parameter.firstName,
                    bindings: &bindings, parameterIndexes: &parameterIndexes)
            }
        case let .simpleInput(clause):
            for parameter in clause {
                recordParameter(name: parameter.name.text, token: parameter.name,
                    bindings: &bindings, parameterIndexes: &parameterIndexes)
            }
        case nil:
            break
        }
        scopes.append(Scope(bindings: bindings, parameterIndexes: parameterIndexes))
        scopeOwners.append(Syntax(node).id)
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { pop(node) }

    /// 캡처 항목은 `visit(ClosureExprSyntax)` 에서 이미 바깥 스코프로 처리했다.
    /// 자식으로 다시 내려가면 초기화 식이 잘못된 스코프에서 평가된다.
    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: - 참조

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        markReference(node)
        return .visitChildren
    }

    /// `foo.x` 의 `x` 는 멤버 이름이지 파라미터가 아니다. 멤버 접근의
    /// declName 자리까지 세면 같은 이름의 멤버가 있는 파라미터가 영원히
    /// "사용됨"이 된다.
    private func markReference(_ node: DeclReferenceExprSyntax) {
        if node.parent?.as(MemberAccessExprSyntax.self)?.declName.id != node.id {
            markUsed(node.baseName.text)
        }
    }

    // MARK: - 내부

    private func push(_ node: some SyntaxProtocol, parameters: FunctionParameterListSyntax) {
        var bindings: Set<String> = []
        var parameterIndexes: [String: Int] = [:]
        for parameter in parameters {
            recordParameter(name: (parameter.secondName ?? parameter.firstName).text,
                token: parameter.secondName ?? parameter.firstName,
                bindings: &bindings, parameterIndexes: &parameterIndexes)
        }
        scopes.append(Scope(bindings: bindings, parameterIndexes: parameterIndexes))
        scopeOwners.append(Syntax(node).id)
    }

    /// 이름 없는 파라미터(`func f(_ : Int)`)는 본문에서 가리킬 수 없어 기록하지 않는다.
    private func recordParameter(
        name: String, token: TokenSyntax,
        bindings: inout Set<String>, parameterIndexes: inout [String: Int]
    ) {
        let name = DeclarationCollector.unescaped(name)
        guard name != "_" else { return }
        let point = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        parameterIndexes[name] = parameters.count
        parameters.append((name, CartographCore.SourceLocation(path: path, line: point.line, column: point.column)))
        bindings.insert(name)
    }

    private func pop(_ node: some SyntaxProtocol) {
        if scopeOwners.last == Syntax(node).id {
            scopeOwners.removeLast()
            scopes.removeLast()
        }
    }

    /// 가장 안쪽에서 이 이름을 묶은 스코프 하나만 표시한다.
    ///
    /// `func f(x:) { { (x:) in x }() }` 에서 클로저 본문의 `x` 는 클로저의
    /// 파라미터를 가리킨다. 안쪽부터 찾아 첫 바인딩에서 멈춰야 바깥 파라미터가
    /// 섀도된 참조로 "사용됨"이 되지 않는다.
    private func markUsed(_ rawName: String) {
        let name = DeclarationCollector.unescaped(rawName)
        for index in scopes.indices.reversed() where scopes[index].bindings.contains(name) {
            if let parameter = scopes[index].parameterIndexes[name] {
                usedIndexes.insert(parameter)
            }
            break
        }
    }
}

/// 클로저 캡처 초기화 식처럼, 스코프를 쌓기 전에 바깥 스코프의 참조를 표시하기
/// 위한 일회성 방문자.
///
/// `Collector` 를 참조하지 않고 표시 동작만 주입받는다 — 콜렉터가 캡처를 만나
/// 이 타입을 만들고 이 타입이 콜렉터로 돌아가면 타입 수준 순환이 된다.
private final class ReferenceMarker: SyntaxVisitor {
    private let mark: (DeclReferenceExprSyntax) -> Void

    init(mark: @escaping (DeclReferenceExprSyntax) -> Void) {
        self.mark = mark
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        mark(node)
        return .visitChildren
    }
}
