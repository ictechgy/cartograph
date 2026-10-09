import CartographCore
@testable import CartographSyntax
import Testing

@Suite("본문 구간 조회 색인")
struct SourceBodyRangeIndexTests {
    private func point(_ line: Int, _ column: Int, path: String = "/p/A.swift") -> CartographCore.SourceLocation {
        CartographCore.SourceLocation(path: path, line: line, column: column)
    }

    @Test("겹친 구간과 경계·틈·다른 경로는 원래 contains 합집합과 같다")
    func matchesInclusiveUnion() {
        let ranges = [
            SourceRange(start: point(2, 4), end: point(5, 8)),
            SourceRange(start: point(3, 1), end: point(3, 9)),
            SourceRange(start: point(5, 8), end: point(6, 2)),
            SourceRange(start: point(8, 4), end: point(8, 4)),
            SourceRange(start: point(9, 8), end: point(9, 2)),
            SourceRange(start: point(2, 1, path: "/p/B.swift"), end: point(4, 1, path: "/p/B.swift")),
            SourceRange(start: point(11, 2), end: point(12, 5, path: "/other/End.swift")),
        ]
        let index = SourceBodyRangeIndex(Array(ranges.reversed()))
        for path in ["/p/A.swift", "/p/B.swift", "/other/End.swift", "/missing.swift"] {
            for line in 0...13 {
                for column in 0...12 {
                    let location = point(line, column, path: path)
                    #expect(index.contains(location) == ranges.contains { $0.contains(location) })
                }
            }
        }
        #expect(index.contains(point(2, 4)))
        #expect(index.contains(point(6, 2)))
        #expect(!index.contains(point(6, 3)))
        #expect(!index.contains(point(8, 3)))
        #expect(index.contains(point(8, 4)))
    }

    @Test("빈 구간 집합과 떨어진 많은 구간도 선형 oracle과 같은 결과다")
    func matchesSparseRanges() {
        #expect(!SourceBodyRangeIndex([]).contains(point(1, 1)))
        let ranges = (0..<1000).map { number in
            SourceRange(start: point(number * 3 + 1, 5), end: point(number * 3 + 2, 7))
        }
        let index = SourceBodyRangeIndex(ranges)
        for line in stride(from: 0, through: 3002, by: 7) {
            for column in [4, 5, 7, 8] {
                let location = point(line, column)
                #expect(index.contains(location) == ranges.contains { $0.contains(location) })
            }
        }
    }
}
