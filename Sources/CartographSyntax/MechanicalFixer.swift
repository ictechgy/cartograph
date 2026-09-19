import CartographCore
import SwiftParser
import SwiftSyntax

/// 기계적으로 고칠 수 있는 편집 하나의 요청.
///
/// 위치는 인덱스·구문 사실이 가리키는 자리다. 구문 트리에서 그 자리에 요청이
/// 기대한 선언이 있을 때만 편집을 만든다 — 소스가 바뀌어 자리가 어긋났으면
/// 지우지 않는다.
public enum MechanicalFixRequest: Sendable, Equatable {
    /// `import` 선언을 줄째로 지운다.
    case removeImport(modulePath: [String], scopedKind: String?, at: CartographCore.SourceLocation)
    /// 파라미터의 내부 이름을 없앤다. 인자 레이블은 유지한다.
    case unnameParameter(name: String, at: CartographCore.SourceLocation)

    /// 진단 위치.
    public var location: CartographCore.SourceLocation {
        switch self {
        case let .removeImport(_, _, location), let .unnameParameter(_, location):
            location
        }
    }
}

/// 편집을 만들지 못한 이유.
public enum MechanicalFixSkipReason: String, Sendable, Codable, Equatable {
    /// 요청 위치에 기대한 선언이 없다 — 소스가 바뀌었거나 다른 선언이다.
    case notFound
    /// `import` 줄에 다른 코드나 블록 주석이 함께 있다.
    case lineHasOtherCode
    /// 파라미터가 이미 이름을 갖지 않는다(`_`).
    case alreadyUnnamed
    /// 파일이 지금 파싱 오류를 갖고 있다.
    case sourceHasErrors
    /// 편집을 적용한 결과가 파싱 오류를 낸다.
    case resultHasErrors
    /// 다른 편집과 겹친다.
    case overlapping
    /// 소스를 다시 읽지 못했다.
    case unreadable
}

/// 요청 하나의 처리 결과.
public enum MechanicalFixStatus: Sendable, Equatable {
    /// 바꿔 끼울 텍스트. import 제거는 빈 문자열이다.
    case fixable(replacement: String)
    case skipped(MechanicalFixSkipReason)
}

/// 구문 편집을 메모리에서 적용한 결과.
public struct MechanicalFixApplication: Sendable, Equatable {
    /// 편집된 소스. 적용된 편집이 없으면 원본 그대로다.
    public let source: String
    /// 요청 순서대로의 상태.
    public let statuses: [MechanicalFixStatus]

    /// 적용 가능한 편집이 하나라도 있는지.
    public var changed: Bool {
        statuses.contains { if case .fixable = $0 { true } else { false } }
    }

    init(source: String, statuses: [MechanicalFixStatus]) {
        self.source = source
        self.statuses = statuses
    }
}

/// 안전한 경고 두 종류를 소스 편집으로 바꾼다.
///
/// 텍스트를 통째로 다시 쓰지 않는다. 구문 트리에서 대상 토큰의 UTF-8 범위만
/// 찾아 원문 바이트를 그대로 두고 그 구간만 바꿔 끼운다 — 나머지 코드와 주석,
/// 공백이 바이트까지 보존된다. 편집 결과는 다시 파싱해 오류가 없을 때만
/// 돌려주므로, 호출자는 파싱되지 않는 소스를 쓸 수 없다.
public struct MechanicalFixer: Sendable {
    public init() {}

    public func apply(
        _ requests: [MechanicalFixRequest],
        to source: String,
        path: String
    ) -> MechanicalFixApplication {
        guard !requests.isEmpty else {
            return MechanicalFixApplication(source: source, statuses: [])
        }
        let tree = Parser.parse(source: source)
        guard !tree.hasError else {
            return skipped(requests, reason: .sourceHasErrors, source: source)
        }
        let bytes = Array(source.utf8)
        let index = SyntaxTargetIndex(tree: tree, path: path)

        var planned: [PlannedEdit] = []
        var statuses = Array(repeating: MechanicalFixStatus.skipped(.notFound), count: requests.count)
        for (position, request) in requests.enumerated() {
            switch request {
            case let .removeImport(modulePath, scopedKind, location):
                guard let importNode = index.imports[LocationKey(location)],
                      importNode.path.map(\.name.text) == modulePath,
                      importNode.importKind?.text == scopedKind
                else { continue }
                guard let edit = SyntaxTargetIndex.removalEdit(of: importNode, in: bytes) else {
                    statuses[position] = .skipped(.lineHasOtherCode)
                    continue
                }
                planned.append(PlannedEdit(edit: edit, request: position))
                statuses[position] = .fixable(replacement: edit.replacement)
            case let .unnameParameter(name, location):
                guard let site = index.parameters[LocationKey(location)],
                      DeclarationCollector.unescaped(site.token.text) == name
                else { continue }
                if site.token.text == "_" {
                    statuses[position] = .skipped(.alreadyUnnamed)
                    continue
                }
                planned.append(PlannedEdit(edit: site.edit, request: position))
                statuses[position] = .fixable(replacement: site.edit.replacement)
            }
        }

        // 겹치는 편집은 뒤쪽을 포기한다. 한 자리를 두 요청이 노리는 것은
        // 정상적인 입력이 아니므로 조용히 두 번 지우지 않는다.
        var accepted: [PlannedEdit] = []
        for edit in planned.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = accepted.last, edit.lowerBound < last.upperBound {
                statuses[edit.request] = .skipped(.overlapping)
                continue
            }
            accepted.append(edit)
        }

        var edited = bytes
        for edit in accepted.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            edited.replaceSubrange(edit.lowerBound..<edit.upperBound, with: Array(edit.replacement.utf8))
        }
        let result = String(decoding: edited, as: UTF8.self)
        guard !Parser.parse(source: result).hasError else {
            return skipped(requests, reason: .resultHasErrors, source: source)
        }
        return MechanicalFixApplication(source: result, statuses: statuses)
    }

    private func skipped(
        _ requests: [MechanicalFixRequest],
        reason: MechanicalFixSkipReason,
        source: String
    ) -> MechanicalFixApplication {
        MechanicalFixApplication(
            source: source,
            statuses: Array(repeating: .skipped(reason), count: requests.count)
        )
    }
}

/// 편집 하나: 원문 바이트 범위와 대체 텍스트.
private struct PlannedEdit {
    let lowerBound: Int
    let upperBound: Int
    let replacement: String
    let request: Int

    init(edit: SyntaxEdit, request: Int) {
        lowerBound = edit.lowerBound
        upperBound = edit.upperBound
        replacement = edit.replacement
        self.request = request
    }
}

/// 구문 트리에서 찾은 바이트 범위 편집.
private struct SyntaxEdit {
    let lowerBound: Int
    let upperBound: Int
    let replacement: String

    init(lowerBound: Int, upperBound: Int, replacement: String = "") {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.replacement = replacement
    }
}

/// 요청 위치를 구문 노드로 푸는 색인. 파일마다 한 번만 트리를 걷는다.
private struct SyntaxTargetIndex {
    let imports: [LocationKey: ImportDeclSyntax]
    let parameters: [LocationKey: ParameterSite]

    init(tree: SourceFileSyntax, path: String) {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = TargetCollector(converter: converter)
        collector.walk(tree)
        imports = collector.imports
        parameters = collector.parameters
    }

    /// `import` 선언이 차지하는 줄 전체를 지우는 편집.
    ///
    /// 속성이 앞줄에 있으면 그 줄까지 함께 지운다(선언 시작이 속성 토큰이다).
    /// 줄 끝의 `//` 주석은 선언에 딸린 것으로 보고 함께 지운다. 그 밖에 다른
    /// 코드나 블록 주석이 줄에 있으면(`;` 로 이어 붙인 import 등) 건드리지
    /// 않는다 — 줄 단위 삭제가 다른 문장을 함께 지울 수 있다.
    static func removalEdit(of node: ImportDeclSyntax, in bytes: [UInt8]) -> SyntaxEdit? {
        let declStart = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let declEnd = node.endPositionBeforeTrailingTrivia.utf8Offset
        let lineStart = lineStart(before: declStart, in: bytes)
        let lineEnd = lineEnd(after: declEnd, in: bytes)
        guard bytes[lineStart..<declStart].allSatisfy(isWhitespace),
              isLineCommentOrWhitespace(bytes[declEnd..<lineEnd])
        else { return nil }
        return SyntaxEdit(lowerBound: lineStart, upperBound: lineEnd)
    }

    /// 줄 끝의 `//` 주석은 지워도 안전하다 — 그 줄에 코드가 더 있을 수 없다.
    /// 블록 주석은 다음 줄로 이어질 수 있어 보수적으로 거부한다.
    private static func isLineCommentOrWhitespace(_ slice: ArraySlice<UInt8>) -> Bool {
        var index = slice.startIndex
        while index < slice.endIndex {
            let byte = slice[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            let isLineComment = byte == UInt8(ascii: "/")
                && index + 1 < slice.endIndex && slice[index + 1] == UInt8(ascii: "/")
            return isLineComment
        }
        return true
    }

    static func lineStart(before offset: Int, in bytes: [UInt8]) -> Int {
        var index = offset
        while index > 0, bytes[index - 1] != UInt8(ascii: "\n") { index -= 1 }
        return index
    }

    static func lineEnd(after offset: Int, in bytes: [UInt8]) -> Int {
        var index = offset
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
        return index < bytes.count ? index + 1 : index
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
            || byte == UInt8(ascii: "\n")
    }
}

/// 파라미터 하나의 편집 재료.
private struct ParameterSite {
    let token: TokenSyntax
    /// 둘째 이름이 있으면 그것이 내부 이름이다 — 토큰을 `_` 로 바꾸면 레이블이 남는다.
    let tokenIsSecondName: Bool
    let isOperatorFunction: Bool

    /// 레이블은 유지하고 내부 이름만 없앤다.
    ///
    /// `func f(label x: Int)` 는 내부 이름 토큰만 `_` 로 바꾸면 된다. 레이블이
    /// 따로 없는 `func f(x: Int)` 는 이름을 없애면 호출 레이블까지 사라지므로
    /// `x _:` 로 둘째 이름을 넣는다. 연산자 함수는 레이블이 의미가 없어 그냥
    /// `_` 로 바꾼다.
    var edit: SyntaxEdit {
        let lower = token.positionAfterSkippingLeadingTrivia.utf8Offset
        let upper = token.endPositionBeforeTrailingTrivia.utf8Offset
        if tokenIsSecondName || isOperatorFunction {
            return SyntaxEdit(lowerBound: lower, upperBound: upper, replacement: "_")
        }
        return SyntaxEdit(lowerBound: lower, upperBound: upper, replacement: "\(token.text) _")
    }
}

/// 위치 키. 줄·열은 인덱스가 주는 UTF-8 열과 같은 단위다.
private struct LocationKey: Hashable {
    let line: Int
    let column: Int

    init(_ location: SwiftSyntax.SourceLocation) {
        line = location.line
        column = location.column
    }

    init(_ location: CartographCore.SourceLocation) {
        line = location.line
        column = location.column
    }
}

/// 한 번의 트리 순회로 편집 대상을 모은다.
private final class TargetCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private(set) var imports: [LocationKey: ImportDeclSyntax] = [:]
    private(set) var parameters: [LocationKey: ParameterSite] = [:]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.importKeyword.positionAfterSkippingLeadingTrivia)
        imports[LocationKey(location)] = node
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let token = node.secondName ?? node.firstName
        let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        parameters[LocationKey(location)] = ParameterSite(
            token: token,
            tokenIsSecondName: node.secondName != nil,
            isOperatorFunction: Self.isOperatorParameter(node)
        )
        return .visitChildren
    }

    /// 연산자 함수의 파라미터인지. 연산자는 인자 레이블이 의미가 없다.
    private static func isOperatorParameter(_ parameter: FunctionParameterSyntax) -> Bool {
        var current = parameter.parent
        while let syntax = current {
            if let function = syntax.as(FunctionDeclSyntax.self) {
                switch function.name.tokenKind {
                case .binaryOperator, .prefixOperator, .postfixOperator: return true
                default: return false
                }
            }
            if syntax.is(SubscriptDeclSyntax.self) || syntax.is(InitializerDeclSyntax.self) {
                return false
            }
            current = syntax.parent
        }
        return false
    }
}
