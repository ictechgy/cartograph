import CartographCore

/// 같은 파일의 참조들이 본문 구간 전체를 매번 다시 훑지 않게 하는 조회 문맥이다.
struct SourceBodyRangeIndex {
    private struct Point: Comparable {
        let line: Int
        let column: Int

        init(_ location: SourceLocation) {
            line = location.line
            column = location.column
        }

        static func < (lhs: Point, rhs: Point) -> Bool {
            (lhs.line, lhs.column) < (rhs.line, rhs.column)
        }
    }

    private struct Interval {
        let start: Point
        var end: Point
    }

    private let rangesByPath: [String: [Interval]]

    init(_ ranges: [SourceRange]) {
        var grouped: [String: [Interval]] = [:]
        for range in ranges {
            let start = Point(range.start)
            let end = Point(range.end)
            // 원래 contains도 역전 구간에는 일치하지 않는다. end.path는 기존과 같이 비교하지 않는다.
            guard start <= end else { continue }
            grouped[range.start.path, default: []].append(Interval(start: start, end: end))
        }
        rangesByPath = grouped.mapValues(Self.merged)
    }

    func contains(_ location: SourceLocation) -> Bool {
        guard let ranges = rangesByPath[location.path] else { return false }
        let point = Point(location)
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].start <= point { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        return point <= ranges[low - 1].end
    }

    private static func merged(_ ranges: [Interval]) -> [Interval] {
        var result: [Interval] = []
        result.reserveCapacity(ranges.count)
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, range.start <= previous.end {
                result[result.count - 1].end = max(previous.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
