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
    /// 매칭용 세그먼트. 판정마다 문자 배열로 바꾸지 않도록 만들 때 한 번만 바꿔 둔다.
    ///
    /// 원문에서 유도한 값이라 같음·해시·직렬화에는 쓰지 않는다(`pattern` 만 쓴다).
    private let segments: [[Character]]
    /// 구분자가 없는 패턴인지. 이름과 달리 마지막 요소만 보지 않는다 — 경로의 각 요소(디렉터리와 파일
    /// 이름)에 대 본다(gitignore 와 같은 직관, `matches(components:)`). 절대 경로를 넘기면 프로젝트 루트
    /// 위의 디렉터리도 그 요소에 든다.
    private let matchesLastComponentOnly: Bool
    /// 사용자가 절대 경로로 쓴 패턴인지.
    ///
    /// 제외 판정은 프로젝트 기준 상대 경로로만 하는 것이 기본이다(`PathFilter`).
    /// 절대 경로를 의도적으로 적은 패턴만 절대 경로에 그대로 적용해, 그 의도를 살린다.
    public let isAbsolute: Bool

    /// 세그먼트 전체를 차지하는 `**`.
    private static let globstar: [Character] = ["*", "*"]

    public init(_ pattern: String) {
        self.pattern = pattern
        let raw = pattern.split(separator: "/", omittingEmptySubsequences: false)
        // 연속된 `**` 는 하나와 같다. 그대로 두면 `**` 마다 분기가 곱해져
        // 별 2개당 약 30배로 번진다(깊이 25 경로에 8개면 17초 실측). 원문은
        // 그대로 두고 매칭용 세그먼트만 접는다.
        var collapsed: [[Character]] = []
        collapsed.reserveCapacity(raw.count)
        for segment in raw where segment != "**" || collapsed.last != Self.globstar {
            collapsed.append(Array(segment))
        }
        self.segments = collapsed
        self.matchesLastComponentOnly = !pattern.contains("/")
        self.isAbsolute = pattern.hasPrefix("/")
    }

    public var description: String { pattern }

    public static func == (lhs: GlobPattern, rhs: GlobPattern) -> Bool {
        lhs.pattern == rhs.pattern
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pattern)
    }

    /// 주어진 문자열이 패턴과 일치하는지 판단한다.
    public func matches(_ value: String) -> Bool {
        matches(components: Self.components(of: value))
    }

    /// 판정할 값을 구분자로 나눈 세그먼트. 빈 요소는 구분자가 겹치거나 앞뒤에 붙은 자리다.
    ///
    /// 같은 경로를 여러 패턴에 대 보는 쪽(`PathFilter`)이 한 번만 나눠 모든 패턴에 넘긴다.
    static func components(of value: String) -> [[Character]] {
        value.split(separator: "/", omittingEmptySubsequences: false).map(Array.init)
    }

    /// 미리 나눈 값(`components(of:)`)과 대 본다.
    func matches(components: [[Character]]) -> Bool {
        if matchesLastComponentOnly {
            // gitignore 는 슬래시 없는 패턴을 경로의 어느 요소에나 맞춰 보고,
            // 그것이 디렉터리면 그 아래 전부를 함께 잡는다. 마지막 요소만 보면
            // `exclude: ["Pods"]` 가 `Pods/` 아래 파일을 하나도 걸러 내지 못하고,
            // `retained_files: ["Generated"]` 는 아무것도 보존하지 못한다.
            // 뒤쪽은 지켜 달라고 지정한 파일이 미사용으로 보고되는 방향이라 더 비싸다.
            // 빈 요소는 경로 요소가 아니라 구분자 자리이므로 대 보지 않는다.
            let component = segments[0]
            return components.contains { !$0.isEmpty && Self.matchSegment(component, $0) }
        }
        return Self.matchSegments(segments, components)
    }

    /// 같은 패턴·경로 위치를 한 번만 계산한다.
    ///
    /// 연속 `**` 를 접어도 `**/a/**/a/.../missing` 은 실패할 때 조합 수만큼
    /// 되돌아간다. 두 행만 유지하는 동적 계획법으로 세그먼트 수 P·V 에 대해
    /// 상태 수를 O(PV), 추가 메모리를 O(V) 로 제한하고 재귀와 배열 조각 복사를 없앤다.
    private static func matchSegments(_ pattern: [[Character]], _ components: [[Character]]) -> Bool {
        var previous = [Bool](repeating: false, count: components.count + 1)
        previous[0] = true
        for segment in pattern {
            var current = [Bool](repeating: false, count: previous.count)
            if segment == globstar {
                current[0] = previous[0]
                for index in components.indices {
                    current[index + 1] = previous[index + 1] || current[index]
                }
            } else {
                for index in components.indices where previous[index] {
                    current[index + 1] = matchSegment(segment, components[index])
                }
            }
            if !current.contains(true) { return false }
            previous = current
        }
        return previous[components.count]
    }

    /// 세그먼트 하나 안에서의 `*` / `?` 매칭.
    ///
    /// 마지막 `*` 의 위치만 기억해 반복한다. 재귀나 배열 복사 없이 되돌아간다.
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
