/// 소스 코드 위치.
///
/// 컬럼은 인덱스 스토어가 주는 UTF-8 바이트 오프셋을 그대로 보존한다.
/// Xcode 리포터가 요구하는 형식(`path:line:column:`)과 그대로 맞는다.
public struct SourceLocation: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let path: String
    public let line: Int
    public let column: Int

    public init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = line
        self.column = column
    }

    public var description: String { "\(path):\(line):\(column)" }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.path, lhs.line, lhs.column) < (rhs.path, rhs.line, rhs.column)
    }

    /// 주어진 기준 경로에 대한 상대 경로 위치로 변환한다.
    ///
    /// CI 로그에서 절대 경로는 잡음이므로 리포터가 상대 경로를 선호한다.
    /// 기준 경로 아래가 아니면 원본을 그대로 돌려준다.
    public func relative(to base: String) -> SourceLocation {
        // macOS 에서 인덱스 스토어는 `/private/tmp` 로, 설정은 `/tmp` 로 같은 곳을
        // 가리킨다. 접두사를 그대로 비교하면 한쪽 표기에서만 상대화되어, 필터는
        // 통과한 파일이 리포트에는 절대 경로로 찍힌다.
        for candidate in PathFilter.variants(of: base) {
            let normalized = candidate.hasSuffix("/") ? candidate : candidate + "/"
            guard path.hasPrefix(normalized) else { continue }
            return SourceLocation(path: String(path.dropFirst(normalized.count)), line: line, column: column)
        }
        return self
    }
}
