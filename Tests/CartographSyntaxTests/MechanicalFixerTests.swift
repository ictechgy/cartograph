import CartographCore
@testable import CartographSyntax
import Testing

@Suite("기계적 소스 편집")
struct MechanicalFixerTests {
    private func fix(
        _ requests: [MechanicalFixRequest],
        in source: String,
        path: String = "/p/A.swift"
    ) -> MechanicalFixApplication {
        MechanicalFixer().apply(requests, to: source, path: path)
    }

    private func location(_ line: Int, _ column: Int, path: String = "/p/A.swift") -> CartographCore.SourceLocation {
        SourceLocation(path: path, line: line, column: column)
    }

    private func importRemoval(
        _ module: [String], scoped: String? = nil, line: Int, column: Int = 1
    ) -> MechanicalFixRequest {
        .removeImport(modulePath: module, scopedKind: scoped, at: location(line, column))
    }

    // MARK: - import 제거

    @Test("쓰지 않는 import 줄을 지우고 나머지를 그대로 둔다")
    func removesUnusedImportLine() {
        let source = """
            import Foundation
            import Combine

            struct S {}
            """
        let result = fix([importRemoval(["Combine"], line: 2)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "")])
        #expect(result.source == """
            import Foundation

            struct S {}
            """)
    }

    @Test("좁힌 import도 통째로 지운다")
    func removesScopedImport() {
        let source = "import struct Foundation.Bundle\n"
        let result = fix(
            [importRemoval(["Foundation", "Bundle"], scoped: "struct", line: 1)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "")])
        #expect(result.source.isEmpty)
    }

    @Test("속성이 앞줄에 있어도 그 줄까지 지운다")
    func removesAttributeLine() {
        let source = """
            @_exported
            import Foundation
            struct S {}
            """
        // 위치는 import 키워드다 — 속성 줄이 아니라 그 아랫줄이다.
        let result = fix([importRemoval(["Foundation"], line: 2)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "")])
        #expect(result.source == "struct S {}")
    }

    @Test("줄 끝 주석은 import에 딸린 것으로 보고 함께 지운다")
    func removesTrailingLineComment() {
        let source = """
            import Foundation // needed
            import Combine
            """
        let result = fix([importRemoval(["Foundation"], line: 1)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "")])
        #expect(result.source == "import Combine")
    }

    @Test("CRLF 파일도 줄 경계를 지킨다")
    func removesImportWithCarriageReturn() {
        let source = "import Foundation\r\nlet x = 1\r\n"
        let result = fix([importRemoval(["Foundation"], line: 1)], in: source)
        #expect(result.source == "let x = 1\r\n")
    }

    @Test("같은 줄에 다른 코드가 있으면 건드리지 않는다")
    func keepsImportSharingItsLine() {
        let source = "import Foundation; let x = 1\n"
        let result = fix([importRemoval(["Foundation"], line: 1)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.skipped(.lineHasOtherCode)])
        #expect(result.source == source)
    }

    @Test("위치의 선언이 요청과 다르면 지우지 않는다")
    func refusesMismatchedImport() {
        let source = "import Foundation\n"
        let result = fix([importRemoval(["SwiftUI"], line: 1)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.skipped(.notFound)])
        #expect(result.source == source)
    }

    @Test("파싱 오류가 있는 파일은 통째로 건너뛴다")
    func skipsSourceWithErrors() {
        let source = "func f( {\n"
        let result = fix([importRemoval(["Foundation"], line: 1)], in: source)
        #expect(result.statuses == [MechanicalFixStatus.skipped(.sourceHasErrors)])
        #expect(result.source == source)
    }

    // MARK: - 파라미터 이름 제거

    @Test("레이블이 곧 이름인 파라미터는 레이블을 남기고 내부 이름만 없앤다")
    func preservesLabelWhenItIsTheName() {
        let source = """
            func fetch(retry: Int) -> Int {
                return 1
            }
            """
        let result = fix([.unnameParameter(name: "retry", at: location(1, 12))], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "retry _")])
        #expect(result.source == """
            func fetch(retry _: Int) -> Int {
                return 1
            }
            """)
    }

    @Test("둘째 이름이 있으면 그 토큰만 _ 로 바꾼다")
    func replacesSecondName() {
        let source = """
            func fetch(label retry: Int) -> Int {
                return 1
            }
            """
        let result = fix([.unnameParameter(name: "retry", at: location(1, 18))], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "_")])
        #expect(result.source == """
            func fetch(label _: Int) -> Int {
                return 1
            }
            """)
    }

    @Test("이미 레이블이 없는 파라미터는 둘째 이름을 _ 로 둔다")
    func unnamsUnlabeledParameter() {
        let source = """
            func fetch(_ retry: Int) -> Int {
                return 1
            }
            """
        let result = fix([.unnameParameter(name: "retry", at: location(1, 14))], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "_")])
        #expect(result.source == """
            func fetch(_ _: Int) -> Int {
                return 1
            }
            """)
    }

    @Test("연산자 함수의 파라미터는 이름만 _ 로 바꾼다")
    func unnamesOperatorParameter() {
        let source = """
            struct S {
                static func +(lhs: S, rhs: S) -> S { rhs }
            }
            """
        let result = fix([.unnameParameter(name: "lhs", at: location(2, 19))], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "_")])
        #expect(result.source == """
            struct S {
                static func +(_: S, rhs: S) -> S { rhs }
            }
            """)
    }

    @Test("서브스크립트 파라미터도 레이블을 남긴다")
    func unnamsSubscriptParameter() {
        let source = """
            struct S {
                subscript(index: Int) -> Int {
                    return 1
                }
            }
            """
        let result = fix([.unnameParameter(name: "index", at: location(2, 15))], in: source)
        #expect(result.statuses == [MechanicalFixStatus.fixable(replacement: "index _")])
        #expect(result.source == """
            struct S {
                subscript(index _: Int) -> Int {
                    return 1
                }
            }
            """)
    }

    @Test("여러 편집을 한 번에 적용해도 위치가 어긋나지 않는다")
    func appliesMultipleEditsTogether() {
        let source = """
            import Combine
            func fetch(retry: Int) -> Int {
                return 1
            }
            """
        let result = fix(
            [importRemoval(["Combine"], line: 1), .unnameParameter(name: "retry", at: location(2, 12))],
            in: source
        )
        #expect(result.statuses == [
            MechanicalFixStatus.fixable(replacement: ""),
            .fixable(replacement: "retry _"),
        ])
        #expect(result.source == """
            func fetch(retry _: Int) -> Int {
                return 1
            }
            """)
    }

    @Test("이미 고친 소스에 같은 요청을 다시 걸면 아무것도 하지 않는다")
    func secondPassIsNotFound() {
        let edited = """
            func fetch(retry _: Int) -> Int {
                return 1
            }
            """
        let result = fix([.unnameParameter(name: "retry", at: location(1, 12))], in: edited)
        #expect(result.statuses == [MechanicalFixStatus.skipped(.notFound)])
        #expect(result.source == edited)
    }

    @Test("편집 밖의 주석과 공백은 바이트까지 보존된다")
    func preservesSurroundingTrivia() {
        let source = """
            // 위쪽 주석
            import Combine
            
            /// 문서 주석
            func fetch(retry: Int) -> Int {  // 꼬리 주석
                return 1
            }
            """
        let result = fix(
            [importRemoval(["Combine"], line: 2), .unnameParameter(name: "retry", at: location(5, 12))],
            in: source
        )
        #expect(result.source == """
            // 위쪽 주석

            /// 문서 주석
            func fetch(retry _: Int) -> Int {  // 꼬리 주석
                return 1
            }
            """)
    }
}
