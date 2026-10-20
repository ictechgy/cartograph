import CartographCore
import SwiftSyntax

/// 함수·접근자 본문의 구간을 모은다.
///
/// 참조가 선언의 인터페이스에 있는지 본문에 있는지는 인덱스에 없다. 접근 수준
/// 판정("대상이 공개여야 하는가")은 이 구분에 달려 있으므로, 소스를 파싱할 때
/// 본문 구간을 한 번 모아 둔다.
///
/// 클라이언트로 전개되는 본문(`@inlinable` 등)은 본문으로 기록하지 않는다.
/// 그 안의 참조는 인터페이스와 같이 공개 노출을 요구할 수 있다.
///
/// 이미 기록한 본문 안의 중첩 블록·접근자는 따로 기록하지 않는다. 소비자
/// (`SourceBodyRangeIndex`)가 겹친 구간을 합치므로 판정은 같고, 남기면 캐시만 커진다.
struct ReferenceBodyScanner {
    init() {}

    func scan(tree: SourceFileSyntax, path: String, converter: SourceLocationConverter) -> [SourceRange] {
        let collector = ReferenceBodyCollector(path: path, converter: converter)
        collector.walk(tree)
        return collector.ranges
    }
}

/// 클라이언트 코드로 전개되어 내부 선언을 참조할 수 없는 속성들.
private let clientEmittedAttributes: Set<String> = [
    "inlinable", "usableFromInline", "_transparent", "_alwaysEmitIntoClient",
]

/// 본문 구간을 실제로 걷는 방문자.
///
/// `ParameterUsageScanner` 처럼 타입 밖에 둔다. 중첩 타입은 타입 레벨 그래프에서
/// 바깥 타입으로 접히므로, 안쪽이 바깥의 정적 API 를 부르면 자기 순환으로 보고된다.
private final class ReferenceBodyCollector: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var ranges: [SourceRange] = []
    /// 마지막으로 기록한 본문의 바이트 구간. 방문은 소스 순서라 중첩 블록은 이 구간 안에서 나온다.
    private var lastRecorded: (start: AbsolutePosition, end: AbsolutePosition)?

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    private func record(_ node: some SyntaxProtocol) {
        let start = node.positionAfterSkippingLeadingTrivia
        let end = node.endPositionBeforeTrailingTrivia
        // 기록한 구간에 포함될 때만 건너뛴다. 빠진 토큰처럼 바깥 구간 밖에 자리 잡은 노드는
        // 예전처럼 따로 판정하므로 기록한 구간의 합집합이 그대로다.
        if let lastRecorded, lastRecorded.start <= start, end <= lastRecorded.end { return }
        guard !Self.isClientEmitted(node) else { return }
        ranges.append(SourceRange(start: location(start), end: location(end)))
        lastRecorded = (start, end)
    }

    private func location(_ position: AbsolutePosition) -> CartographCore.SourceLocation {
        let point = converter.location(for: position)
        return CartographCore.SourceLocation(path: path, line: point.line, column: point.column)
    }

    private static func isClientEmitted(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let syntax = current {
            if let attributed = syntax.asProtocol(WithAttributesSyntax.self),
               attributed.attributes.contains(where: { element in
                   guard case let .attribute(attribute) = element else { return false }
                   return clientEmittedAttributes
                       .contains(attribute.attributeName.trimmedDescription)
               }) {
                return true
            }
            current = syntax.parent
        }
        return false
    }
}
