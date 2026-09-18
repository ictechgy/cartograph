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
struct ReferenceBodyScanner {
    /// 클라이언트 코드로 전개되어 내부 선언을 참조할 수 없는 속성들.
    static let clientEmittedAttributes: Set<String> = [
        "inlinable", "usableFromInline", "_transparent", "_alwaysEmitIntoClient",
    ]

    init() {}

    func scan(tree: SourceFileSyntax, path: String, converter: SourceLocationConverter) -> [SourceRange] {
        let collector = Collector(path: path, converter: converter)
        collector.walk(tree)
        return collector.ranges
    }

    private final class Collector: SyntaxVisitor {
        private let path: String
        private let converter: SourceLocationConverter
        private(set) var ranges: [SourceRange] = []

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
            guard !Self.isClientEmitted(node) else { return }
            ranges.append(SourceRange(
                start: location(node.positionAfterSkippingLeadingTrivia),
                end: location(node.endPositionBeforeTrailingTrivia)
            ))
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
                       return ReferenceBodyScanner.clientEmittedAttributes
                           .contains(attribute.attributeName.trimmedDescription)
                   }) {
                    return true
                }
                current = syntax.parent
            }
            return false
        }
    }
}
