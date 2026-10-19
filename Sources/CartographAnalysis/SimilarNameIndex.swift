import CartographCore
import Foundation

/// notFound 추천 한 번이 한 일. 테스트가 추천 비용을 시간이 아니라 작업량으로 센다.
struct SimilarNameWork: Equatable {
    /// 이 호출이 추천 색인을 만들며 정규화(길이 세기·소문자화)한 이름 키 수. 색인이 이미 있으면 0이다.
    var normalizedKeys = 0
    /// 길이 창 안에서 살펴본 키 수.
    var examinedKeys = 0
    /// 편집 거리를 실제로 계산한 키 수.
    var measuredKeys = 0
}

/// 추천 비교에 쓸 이름 키를 한 번만 정규화해 원래 키의 글자(grapheme) 수별로 담는다.
///
/// 예전에는 notFound 질의마다 이름 키 전체를 돌며 글자 수를 세고, 소문자 문자열과 스칼라 배열 두 개와
/// DP 행 두 개를 새로 만들었다. 질의 1000건짜리 배치면 같은 준비를 1000번 했다. 여기서는 그 값을 한 번
/// 만들어 두고, 질의는 길이 차가 한도 안인 칸만 본다. 걸러 내는 데 쓰는 값(스칼라 수, 글자 종류 비트)은
/// 따로 붙여 두어 걸러지는 키는 이름을 읽지 않는다.
struct SimilarNameIndex {
    /// 매우 긴 USR 은 정확 조회로만 찾는다. 추천용 편집 거리로 이차 비용을 만들지 않는다.
    static let longestSubject = 256
    /// 한도는 질의 길이의 3분의 1이라, 이보다 긴 키는 어떤 질의의 길이 창에도 들지 않는다.
    static let longestComparableKey = longestSubject + longestSubject / 3

    /// 글자 수가 같은 키들. 세 배열의 같은 자리가 같은 키다.
    struct Bucket {
        /// 소문자 키의 스칼라 수.
        var scalarCounts: [Int] = []
        /// 소문자 키의 글자 종류 비트.
        var masks: [UInt64] = []
        var entries: [Entry] = []
    }

    /// 키 하나. 원래 키는 (거리, 이름) 순위와 거리 계산에 쓴다.
    struct Entry {
        let name: String
        /// 아스키가 아닌 키의 소문자 형태. 아스키 키는 비교할 때 글자마다 소문자로 접어 따로 두지 않는다.
        let lowered: String?
        /// 키의 대표 정점. 한 키에 정점이 여럿이면 첫 정점이다.
        let node: NodeID

        /// 바늘과 이 키의 거리. 한도를 넘으면 nil.
        func distance(using measure: inout BoundedEditDistance, scalarCount: Int, limit: Int) -> Int? {
            if let lowered {
                return measure.distance(
                    to: lowered.unicodeScalars.lazy.map(\.value), scalarCount: scalarCount, limit: limit
                )
            }
            return measure.distance(
                to: name.utf8.lazy.map(SimilarNameProfile.foldedASCII), scalarCount: scalarCount, limit: limit
            )
        }
    }

    private let buckets: [Bucket]
    /// 만들며 정규화한 키 수.
    let normalizedKeys: Int

    /// 이름 항목을 주어진 순서대로 담는다. 순위는 순서와 무관하므로 사전을 그대로 넘겨도 된다.
    ///
    /// 키의 첫 정점이 대표다. 질의 색인의 이름 사전은 그래프 정점으로만 만들므로 키마다 큰 정점 사전을
    /// 다시 찾아 확인하지 않는다.
    init<Names: Sequence>(names: Names) where Names.Element == (key: String, value: [NodeID]) {
        var buckets = [Bucket](repeating: Bucket(), count: Self.longestComparableKey + 1)
        var normalized = 0
        for (name, ids) in names {
            guard let node = ids.first else { continue }
            normalized += 1
            let key = SimilarNameKey(name)
            guard key.length <= Self.longestComparableKey else { continue }
            buckets[key.length].scalarCounts.append(key.profile.scalarCount)
            buckets[key.length].masks.append(key.profile.mask)
            buckets[key.length].entries.append(Entry(name: name, lowered: key.lowered, node: node))
        }
        self.buckets = buckets
        normalizedKeys = normalized
    }

    /// 원래 키의 글자 수가 `lengths` 안인 칸들.
    func buckets(lengths: ClosedRange<Int>) -> ArraySlice<Bucket> {
        let lower = max(0, lengths.lowerBound)
        let upper = min(Self.longestComparableKey, lengths.upperBound)
        return lower <= upper ? buckets[lower...upper] : []
    }

    /// 처음 추천할 때 한 번만 색인을 만든다. 값으로 복사된 질의 색인들이 같은 상자를 나눠 쓴다.
    ///
    /// 이름 조회만 하는 경로(found 질의, `--explain`, impact 의 심볼 선택)는 추천을 묻지 않으므로
    /// 그 비용을 치르지 않는다.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var index: SimilarNameIndex?

        func index(work: inout SimilarNameWork, make: () -> SimilarNameIndex) -> SimilarNameIndex {
            lock.lock()
            defer { lock.unlock() }
            if let index { return index }
            let made = make()
            work.normalizedKeys = made.normalizedKeys
            index = made
            return made
        }
    }
}

/// 질의 한 번의 준비물. 바늘의 소문자 스칼라와 거리 한도를 한 번만 만든다.
struct SimilarNameQuery {
    /// 소문자로 바꾼 질의의 글자 수. 거리 한도는 이 길이에 비례한다.
    let length: Int
    /// 추천으로 받아들이는 편집 거리의 최댓값.
    let threshold: Int
    /// 소문자 질의의 유니코드 스칼라 값.
    private let scalars: [UInt32]
    private let profile: SimilarNameProfile

    /// 빈 이름과 너무 긴 이름에는 추천을 계산하지 않는다.
    init?(_ subject: String) {
        guard !subject.isEmpty else { return nil }
        let needle = subject.lowercased()
        length = needle.count
        guard length <= SimilarNameIndex.longestSubject else { return nil }
        // 고정 한도는 긴 한정 이름을 하나도 못 잡는다 — 조각 하나만 달라도 수십 자가 떨어져 있다.
        threshold = max(2, length / 3)
        scalars = needle.unicodeScalars.map(\.value)
        profile = SimilarNameProfile(scalars)
    }

    /// 질의와 글자 수 차이가 한도 안인 키 길이. 차이가 한도를 넘는 키는 거리도 한도를 넘는다.
    var lengths: ClosedRange<Int> { max(0, length - threshold)...(length + threshold) }

    /// 거리 한도 안의 키가 가리키는 대표 정점을 (거리, 이름) 순으로 고른다.
    ///
    /// 한 정점에 여러 별칭이 맞으면 그중 가장 앞선 점수를 쓴다. 그래서 칸과 키의 방문 순서와 무관하게
    /// 같은 추천이 나온다.
    func candidates<Buckets: Sequence>(
        in buckets: Buckets, limit: Int, graph: CodeGraph, work: inout SimilarNameWork
    ) -> [GraphNode] where Buckets.Element == SimilarNameIndex.Bucket {
        var best: [NodeID: (distance: Int, name: String)] = [:]
        var measure = BoundedEditDistance(needle: scalars)
        for bucket in buckets {
            work.examinedKeys += bucket.entries.count
            for position in bucket.entries.indices where admits(bucket, at: position) {
                work.measuredKeys += 1
                let entry = bucket.entries[position]
                guard let distance = entry.distance(
                    using: &measure, scalarCount: bucket.scalarCounts[position], limit: threshold
                ) else { continue }
                if let kept = best[entry.node], (kept.distance, kept.name) <= (distance, entry.name) { continue }
                best[entry.node] = (distance, entry.name)
            }
        }
        return best.sorted { ($0.value.distance, $0.value.name) < ($1.value.distance, $1.value.name) }
            .prefix(limit)
            .compactMap { graph.node($0.key) }
    }

    /// 거리를 계산하지 않고도 한도를 넘는다고 확정되는 키를 거른다.
    ///
    /// 스칼라 수의 차이와, 한쪽에만 있는 글자 종류의 수는 둘 다 편집 거리의 하한이다 — 짝이 없는 글자는
    /// 편집 한 번이 많아야 하나씩만 없앤다.
    private func admits(_ bucket: SimilarNameIndex.Bucket, at position: Int) -> Bool {
        guard abs(bucket.scalarCounts[position] - scalars.count) <= threshold else { return false }
        return profile.distanceLowerBound(to: bucket.masks[position]) <= threshold
    }
}

/// 이름 키 하나를 비교용으로 정규화한 값. 아스키 키는 UTF-8 을 한 번 훑어 소문자 문자열 없이 만든다.
struct SimilarNameKey {
    /// 원래 키의 글자(grapheme) 수.
    let length: Int
    let profile: SimilarNameProfile
    /// 아스키가 아닌 키의 소문자 형태.
    let lowered: String?

    init(_ name: String) {
        if let ascii = SimilarNameProfile.ascii(name.utf8) {
            // 아스키에서 글자 경계가 바이트 경계와 다른 것은 CR LF 하나뿐이다.
            length = ascii.containsCarriageReturn ? name.count : name.utf8.count
            profile = ascii.profile
            lowered = nil
        } else {
            let lowered = name.lowercased()
            length = name.count
            profile = SimilarNameProfile(lowered.unicodeScalars.lazy.map(\.value))
            self.lowered = lowered
        }
    }
}

/// 소문자 키의 스칼라 수와 글자 종류 비트.
struct SimilarNameProfile {
    let scalarCount: Int
    let mask: UInt64

    init<Scalars: Sequence>(_ scalars: Scalars) where Scalars.Element == UInt32 {
        var count = 0
        var mask: UInt64 = 0
        for value in scalars {
            count += 1
            mask |= Self.bit(for: value)
        }
        scalarCount = count
        self.mask = mask
    }

    /// 아스키 키의 프로필과 CR 포함 여부. 바이트를 소문자로 접으며 센다. 아스키가 아니면 nil.
    static func ascii(_ bytes: String.UTF8View) -> (profile: SimilarNameProfile, containsCarriageReturn: Bool)? {
        var mask: UInt64 = 0
        var containsCarriageReturn = false
        for byte in bytes {
            guard byte < 0x80 else { return nil }
            containsCarriageReturn = containsCarriageReturn || byte == 0x0D
            mask |= bit(for: foldedASCII(byte))
        }
        return (SimilarNameProfile(scalarCount: bytes.count, mask: mask), containsCarriageReturn)
    }

    /// 아스키 대문자를 소문자로 접는다. 아스키 문자열에서는 `lowercased()` 와 같은 결과다.
    static func foldedASCII(_ byte: UInt8) -> UInt32 {
        UInt32((0x41...0x5A).contains(byte) ? byte | 0x20 : byte)
    }

    private init(scalarCount: Int, mask: UInt64) {
        self.scalarCount = scalarCount
        self.mask = mask
    }

    /// 두 키 가운데 한쪽에만 있는 글자 종류 수의 큰 쪽. 편집 거리는 이보다 작을 수 없다.
    func distanceLowerBound(to other: UInt64) -> Int {
        max((mask & ~other).nonzeroBitCount, (other & ~mask).nonzeroBitCount)
    }

    /// 영문 소문자와 숫자는 칸을 따로 주고 나머지는 남은 칸에 접는다. 접혀 겹치면 하한이 약해질 뿐 틀리지 않는다.
    private static func bit(for value: UInt32) -> UInt64 {
        switch value {
        case 0x61...0x7A: 1 << UInt64(value - 0x61)
        case 0x30...0x39: 1 << UInt64(26 + value - 0x30)
        default: 1 << UInt64(36 + value % 28)
        }
    }
}

/// 바늘 하나를 여러 키와 비교하는 Levenshtein 거리(유니코드 스칼라 단위). 한도 이하인지만 필요하다.
///
/// 바늘이 64스칼라 이하면 비트 병렬 비교(Myers 1999, Hyyrö 2003 의 전역 거리 변형)로 키 글자 하나를 상수
/// 시간에 처리한다. 더 긴 바늘은 대각선 띠(|i − j| ≤ 한도) 안의 칸만 계산한다. 두 방식 모두 한도 이하인
/// 거리는 전체 DP 와 같은 값을 내고, 한도를 넘는다고 확정되면 그 자리에서 멈춘다.
struct BoundedEditDistance {
    private let needle: [UInt32]
    private let pattern: PatternMasks?
    private var previous: [Int] = []
    private var current: [Int] = []
    private var key: [UInt32] = []

    /// `allowsBitParallel` 은 테스트가 짧은 바늘로도 띠 DP 경로를 확인하도록 둔다.
    init(needle: [UInt32], allowsBitParallel: Bool = true) {
        self.needle = needle
        pattern = allowsBitParallel && (1...64).contains(needle.count) ? PatternMasks(needle) : nil
    }

    /// 한도 이하면 거리를, 넘으면 nil 을 돌려준다. `scalarCount` 는 `other` 의 스칼라 수다.
    mutating func distance<Scalars: Sequence>(
        to other: Scalars, scalarCount: Int, limit: Int
    ) -> Int? where Scalars.Element == UInt32 {
        guard abs(needle.count - scalarCount) <= limit else { return nil }
        if let pattern { return pattern.distance(to: other, scalarCount: scalarCount, limit: limit) }
        key.removeAll(keepingCapacity: true)
        key.append(contentsOf: other)
        return Self.bandedDistance(needle, key, limit: limit, previous: &previous, current: &current)
    }

    private static func bandedDistance(
        _ lhs: [UInt32], _ rhs: [UInt32], limit: Int, previous: inout [Int], current: inout [Int]
    ) -> Int? {
        guard !lhs.isEmpty, !rhs.isEmpty else { return max(lhs.count, rhs.count) }
        if previous.count <= rhs.count {
            previous = [Int](repeating: 0, count: rhs.count + 1)
            current = previous
        }
        return lhs.withUnsafeBufferPointer { lhs in
            rhs.withUnsafeBufferPointer { rhs in
                previous.withUnsafeMutableBufferPointer { above in
                    current.withUnsafeMutableBufferPointer { below in
                        band(lhs, rhs, limit: limit, above: above, below: below)
                    }
                }
            }
        }
    }

    /// 행마다 띠 안 칸만 채운다. 한도를 넘는 값은 `limit + 1` 로 눌러 두고, 다음 행이 읽는 띠 바깥 칸에도
    /// 그 값을 써 둔다. 행 최솟값은 아래로 갈수록 줄지 않으므로 한도를 넘는 행에서 멈춘다.
    private static func band(
        _ lhs: UnsafeBufferPointer<UInt32>, _ rhs: UnsafeBufferPointer<UInt32>, limit: Int,
        above: UnsafeMutableBufferPointer<Int>, below: UnsafeMutableBufferPointer<Int>
    ) -> Int? {
        let cap = limit + 1
        var above = above
        var below = below
        for column in 0...min(rhs.count, cap) { above[column] = min(column, cap) }
        for row in 1...lhs.count {
            let low = max(1, row - limit)
            let high = min(rhs.count, row + limit)
            below[low - 1] = low == 1 ? min(row, cap) : cap
            var minimum = below[low - 1]
            let character = lhs[row - 1]
            for column in low...high {
                let substitution = above[column - 1] + (character == rhs[column - 1] ? 0 : 1)
                let value = min(substitution, above[column] + 1, below[column - 1] + 1, cap)
                below[column] = value
                minimum = min(minimum, value)
            }
            if high < rhs.count { below[high + 1] = cap }
            guard minimum <= limit else { return nil }
            swap(&above, &below)
        }
        return above[rhs.count] <= limit ? above[rhs.count] : nil
    }
}

/// 바늘의 스칼라마다 그 스칼라가 놓인 자리의 비트. 비트 병렬 비교의 표다.
struct PatternMasks {
    private let length: Int
    private var ascii = [UInt64](repeating: 0, count: 128)
    private var others: [UInt32: UInt64] = [:]

    /// 바늘은 1~64 스칼라여야 한다. 자리 하나가 비트 하나다.
    init(_ needle: [UInt32]) {
        length = needle.count
        for (offset, value) in needle.enumerated() {
            let bit: UInt64 = 1 << UInt64(offset)
            if value < 128 { ascii[Int(value)] |= bit } else { others[value, default: 0] |= bit }
        }
    }

    /// 키 글자마다 맨 아래 행의 값(바늘 전체와 키 앞부분의 거리)을 행 사이 차이 비트로 갱신한다.
    ///
    /// 남은 키 글자 하나마다 거리는 많아야 1씩 줄므로, 지금 거리에서 남은 글자 수를 빼도 한도를 넘으면
    /// 멈춘다. 64비트 위로 넘친 자리올림과 바늘 길이 위의 비트는 아래 비트에 영향을 주지 않는다.
    func distance<Scalars: Sequence>(
        to key: Scalars, scalarCount: Int, limit: Int
    ) -> Int? where Scalars.Element == UInt32 {
        var verticalIncrease = UInt64.max
        var verticalDecrease: UInt64 = 0
        var distance = length
        var remaining = scalarCount
        let last: UInt64 = 1 << UInt64(length - 1)
        for value in key {
            let match = mask(for: value)
            let diagonal = (((match & verticalIncrease) &+ verticalIncrease) ^ verticalIncrease) | match
                | verticalDecrease
            let increase = verticalDecrease | ~(diagonal | verticalIncrease)
            let decrease = diagonal & verticalIncrease
            if increase & last != 0 { distance += 1 }
            if decrease & last != 0 { distance -= 1 }
            let shiftedIncrease = (increase << 1) | 1
            verticalIncrease = (decrease << 1) | ~(diagonal | shiftedIncrease)
            verticalDecrease = shiftedIncrease & diagonal
            remaining -= 1
            if distance - remaining > limit { return nil }
        }
        return distance <= limit ? distance : nil
    }

    private func mask(for value: UInt32) -> UInt64 {
        value < 128 ? ascii[Int(value)] : others[value] ?? 0
    }
}
