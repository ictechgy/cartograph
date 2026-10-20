import Foundation

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
    ///
    /// 기준 경로의 표기들을 펼치는 일(URL 정규화·심볼릭 링크 해석)은 파일
    /// 시스템을 물어보는 연산이다. 리포트는 진단 수천 건마다 상대화를 부르므로,
    /// 부르는 쪽이 표기들을 한 번만 계산해 넘기는 `relative(toBaseVariants:)`
    /// 쪽이 바른 자리다.
    public func relative(to base: String) -> SourceLocation {
        relative(toBaseVariants: PathFilter.variants(of: base))
    }

    /// 미리 펼쳐 둔 기준 경로 표기들로 상대 경로 위치로 변환한다.
    public func relative(toBaseVariants baseVariants: [String]) -> SourceLocation {
        // macOS 에서 인덱스 스토어는 `/private/tmp` 로, 설정은 `/tmp` 로 같은 곳을
        // 가리킨다. 접두사를 그대로 비교하면 한쪽 표기에서만 상대화되어, 필터는
        // 통과한 파일이 리포트에는 절대 경로로 찍힌다.
        for candidate in baseVariants {
            let normalized = candidate.hasSuffix("/") ? candidate : candidate + "/"
            guard path.hasPrefix(normalized) else { continue }
            return SourceLocation(path: String(path.dropFirst(normalized.count)), line: line, column: column)
        }
        return self
    }
}

extension SourceLocation {
    private enum CodingKeys: String, CodingKey {
        case path, line, column
    }

    /// 합성 Codable 과 같은 형식을 읽는다.
    ///
    /// 경로 생략 문맥(`SourceLocationPathElision`)이 있는 디코더에서만 빠진 경로를 문맥의
    /// 경로로 채운다. 문맥이 없으면 예전처럼 경로가 없는 위치를 거부한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let elided = SourceLocationPathElision.elidedPath(in: decoder.userInfo), !container.contains(.path) {
            path = elided
        } else {
            path = try container.decode(String.self, forKey: .path)
        }
        line = try container.decode(Int.self, forKey: .line)
        column = try container.decode(Int.self, forKey: .column)
    }

    /// 합성 Codable 과 같은 키를 같은 순서로 쓴다.
    ///
    /// 경로 생략 문맥이 있고 그 경로와 표기까지 같을 때만 경로를 뺀다. 그래서 문맥이 없는
    /// 리포트·스냅샷·교환 문서의 바이트는 예전과 같다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if path != SourceLocationPathElision.elidedPath(in: encoder.userInfo) {
            try container.encode(path, forKey: .path)
        }
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
    }
}

/// 바깥 문서가 이미 정한 파일 경로를 안쪽 위치마다 다시 쓰지 않게 하는 직렬화 문맥.
///
/// 구문 캐시는 파일 하나의 사실에 위치를 수백 개 담는데, 그 경로가 모두 항목 키와 같은
/// 절대 경로였다(이 저장소 실측에서 캐시 JSON 의 62%). 같은 타입을 리포트·스냅샷·교환
/// 문서도 쓰므로 공개 Codable 형식은 그대로 두고, 이 문맥을 `userInfo` 에 둔 인코더·
/// 디코더에서만 경로를 생략하고 되살린다. 표기가 다른 경로(`/tmp` 와 `/private/tmp`)는
/// 다른 경로로 보고 그대로 쓴다.
///
/// 항목마다 생략할 경로가 달라서, 바깥 문서가 항목을 부호화하는 동안 경로를 바꿔 끼우는
/// 참조형 상자다. 오늘의 호출은 한 스레드의 인코드·디코드 한 번이지만 `Sendable` 경계를
/// 넘는 타입이므로 상태는 락 아래에 둔다.
package final class SourceLocationPathElision: @unchecked Sendable {
    /// 인코더·디코더 `userInfo` 에서 이 문맥을 찾는 키.
    package static let userInfoKey = CodingUserInfoKey(rawValue: "cartograph.sourceLocationPathElision")!

    private let lock = NSLock()
    private var path: String?

    package init() {}

    /// `path` 를 생략할 경로로 두고 `body` 를 실행한 뒤 이전 경로로 되돌린다.
    ///
    /// `userInfo` 에 문맥이 없으면 경로를 생략하지 않고 `body` 만 실행한다.
    package static func eliding<Result>(
        _ path: String, in userInfo: [CodingUserInfoKey: Any], _ body: () throws -> Result
    ) rethrows -> Result {
        guard let context = context(in: userInfo) else { return try body() }
        let previous = context.exchange(path)
        defer { _ = context.exchange(previous) }
        return try body()
    }

    /// 지금 생략하는 경로. 문맥이 없거나 바깥 항목 밖이면 nil 이다.
    static func elidedPath(in userInfo: [CodingUserInfoKey: Any]) -> String? {
        context(in: userInfo)?.currentPath
    }

    private var currentPath: String? { lock.withLock { path } }

    private static func context(in userInfo: [CodingUserInfoKey: Any]) -> SourceLocationPathElision? {
        // 리포트처럼 문맥 없는 인코더가 위치 수천 개를 쓸 때 키 해시를 매번 계산하지 않는다.
        userInfo.isEmpty ? nil : userInfo[userInfoKey] as? SourceLocationPathElision
    }

    private func exchange(_ newPath: String?) -> String? {
        lock.withLock {
            let previous = path
            path = newPath
            return previous
        }
    }
}
