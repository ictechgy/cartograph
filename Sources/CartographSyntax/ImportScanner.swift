import CartographCore
import SwiftSyntax

/// 이미 파싱한 트리에서 `import` 선언을 모은다.
///
/// 미사용 import 판정의 구문 쪽 재료다. 인덱스도 `import M` 을 모듈 심볼
/// 참조(`c:@M@M`)로 기록하지만 속성·접근 수준·`#if` 여부는 알 수 없어,
/// 보고 대상 선별은 구문에서만 가능하다.
struct ImportScanner {
    init() {}

    /// 소스 트리에서 import 선언 사실을 만든다.
    func scan(tree: SourceFileSyntax, path: String, converter: SourceLocationConverter) -> [IndexedImport] {
        let collector = Collector(path: path, converter: converter)
        collector.walk(tree)
        return collector.imports
    }
}

private final class Collector: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var imports: [IndexedImport] = []
    /// `#if` 절의 중첩 깊이 — 안쪽 import는 현재 플랫폼 빌드에 없을 수 있다.
    private var conditionalDepth = 0

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        conditionalDepth += 1
        return .visitChildren
    }
    override func visitPost(_: IfConfigDeclSyntax) { conditionalDepth -= 1 }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let position = converter.location(for: node.importKeyword.positionAfterSkippingLeadingTrivia)
        let comments = SyntaxComments.lines(in: node.leadingTrivia)
            + SyntaxComments.lines(in: node.trailingTrivia)
        let commands = comments.compactMap { CommentCommand.parse(comment: $0) }
        imports.append(
            IndexedImport(
                modulePath: node.path.map { $0.name.text },
                scopedKind: node.importKind?.text,
                isConditional: conditionalDepth > 0,
                isReexported: isReexported(node),
                isIgnored: !commands.isEmpty,
                // 파일 맨 앞의 `ignore:all` 은 첫 import 의 trivia 에 걸려
                // 파일 지시로 무시된다. 자기 `ignore` 주석이 같이 있으면
                // 파일 주석을 떼어도 무시가 남으므로 출처를 따로 남긴다.
                isIgnoredOnlyByFileComment: commands.contains(.ignoreAll)
                    && !commands.contains(.ignore),
                location: CartographCore.SourceLocation(
                    path: path, line: position.line, column: position.column)
            )
        )
        return .visitChildren
    }

    /// 클라이언트에 심볼을 다시 노출하는 import인지 판정한다.
    ///
    /// `@_exported` 는 물론 Swift 6의 `public`/`package`/`open import` 도
    /// 사용처 모듈의 공개 인터페이스 일부다 — 지우면 import 하는 쪽의
    /// 클라이언트가 깨질 수 있으므로 미사용 후보에서 제외한다.
    private func isReexported(_ node: ImportDeclSyntax) -> Bool {
        let attributes = node.attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported"
        }
        let access = node.modifiers.contains { ["public", "package", "open"].contains($0.name.text) }
        return attributes || access
    }
}
