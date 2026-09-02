/// 파일 경로와 심볼 이름에 쓰는 글롭 패턴.
///
/// 지원 문법
/// - `?` : 구분자(`/`)가 아닌 문자 하나
/// - `*` : 구분자가 아닌 문자 0개 이상
/// - `**`: 경로 세그먼트 0개 이상 (세그먼트 전체를 차지할 때만 유효)
///
/// 정규식으로 변환하지 않고 직접 매칭하는 이유는, 패턴에 들어 있는
/// `.` `+` `(` 같은 문자를 이스케이프하다 생기는 실수를 원천적으로 없애기 위함이다.
public struct GlobPattern: Hashable, Sendable, CustomStringConvertible {
    public let pattern: String
    private let segments: [String]
    /// 구분자가 없는 패턴은 경로의 마지막 요소에만 적용한다(gitignore 와 같은 직관).
    private let matchesLastComponentOnly: Bool

    public init(_ pattern: String) {
        self.pattern = pattern
        self.segments = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        self.matchesLastComponentOnly = !pattern.contains("/")
    }

    public var description: String { pattern }

    /// 주어진 문자열이 패턴과 일치하는지 판단한다.
    public func matches(_ value: String) -> Bool {
        if matchesLastComponentOnly {
            // gitignore 는 슬래시 없는 패턴을 경로의 어느 요소에나 맞춰 보고,
            // 그것이 디렉터리면 그 아래 전부를 함께 잡는다. 마지막 요소만 보면
            // `exclude: ["Pods"]` 가 `Pods/` 아래 파일을 하나도 걸러 내지 못하고,
            // `retained_files: ["Generated"]` 는 아무것도 보존하지 못한다.
            // 뒤쪽은 지켜 달라고 지정한 파일이 미사용으로 보고되는 방향이라 더 비싸다.
            let component = Array(segments[0])
            return value.split(separator: "/").contains { Self.matchSegment(component, Array($0)) }
        }
        let valueSegments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return Self.matchSegments(segments, valueSegments)
    }

    /// 세그먼트 단위 매칭. `**` 는 임의 개수의 세그먼트를 소비한다.
    private static func matchSegments(_ pattern: [String], _ value: [String]) -> Bool {
        guard let head = pattern.first else { return value.isEmpty }
        if head == "**" {
            let rest = Array(pattern.dropFirst())
            if rest.isEmpty { return true }
            for consumed in 0...value.count where matchSegments(rest, Array(value.dropFirst(consumed))) {
                return true
            }
            return false
        }
        guard let valueHead = value.first, matchSegment(Array(head), Array(valueHead)) else { return false }
        return matchSegments(Array(pattern.dropFirst()), Array(value.dropFirst()))
    }

    /// 세그먼트 하나 안에서의 `*` / `?` 매칭.
    ///
    /// `*` 뒤를 백트래킹해야 하므로 재귀로 구현한다. 세그먼트 길이가 짧아
    /// 실무에서 지수적으로 번지지 않는다.
    private static func matchSegment(_ pattern: [Character], _ value: [Character]) -> Bool {
        var patternIndex = 0
        var valueIndex = 0
        var starPatternIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starPatternIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if patternIndex < pattern.count,
                      pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex] {
                patternIndex += 1
                valueIndex += 1
            } else if let starIndex = starPatternIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

extension GlobPattern: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pattern)
    }
}

extension GlobPattern: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension Collection where Element == GlobPattern {
    /// 하나라도 일치하면 참. 빈 목록은 항상 거짓이다.
    public func matchesAny(_ value: String) -> Bool {
        contains { $0.matches(value) }
    }
}
