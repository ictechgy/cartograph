import Foundation

/// include/exclude 글롭으로 경로를 걸러 내는 필터.
///
/// 규칙은 단순하다.
/// 1. include 가 비어 있지 않으면, 하나라도 일치해야 통과한다.
/// 2. exclude 에 하나라도 일치하면 무조건 탈락한다(exclude 우선).
/// 3. 대조하는 경로 형태가 방향마다 다르다. include 는 절대 경로와 상대 경로를
///    모두 보고, exclude 는 프로젝트 안의 경로면 상대 경로만 본다. 두 방향의
///    실패 비용이 다르기 때문이다 — include 를 좁히면 아무것도 안 골라 "정점 0개"가
///    되고, exclude 를 넓히면 조상 디렉터리 이름 하나로 프로젝트 전체가 사라진다.
///    절대 경로로 쓴 exclude 패턴은 의도가 분명하므로 절대 경로에 그대로 적용한다.
///
/// 인덱스가 주는 경로는 절대 경로지만 사용자는 `Sources/**` 처럼 프로젝트
/// 기준으로 쓴다. 두 형태를 모두 후보로 보지 않으면 설정이 조용히 아무것도
/// 매칭하지 않고, 결과는 "정점 0개"가 되어 원인을 찾기 어렵다.
public struct PathFilter: Sendable, Equatable {
    public let include: [GlobPattern]
    public let exclude: [GlobPattern]
    /// 상대 경로를 만들 기준 디렉터리.
    public let basePath: String?
    /// 상대 경로를 만들 때 시도할 기준 디렉터리 형태들.
    ///
    /// macOS 에서 `/tmp`·`/var`·`/etc` 는 `/private` 아래로의 심볼릭 링크다.
    /// Foundation 은 `/private/tmp` 를 `/tmp` 로 되돌리는 쪽을 정규형으로 보지만,
    /// 인덱스 스토어에는 컴파일러가 본 그대로 `/private/tmp/...` 가 기록된다.
    /// 기준 경로가 `/tmp/proj` 면 접두사가 맞지 않아 `include` 가 아무것도 고르지
    /// 않고 "정점 0개"가 된다. 이 타입의 주석이 막겠다고 한 바로 그 실패다.
    ///
    /// 경로마다 파일 시스템에 물어보면 심볼 수만큼 시스템 호출이 생기므로,
    /// 기준 경로만 한 번 여러 형태로 펼쳐 두고 그것들로 대조한다.
    private let basePathVariants: [String]

    public init(include: [GlobPattern] = [], exclude: [GlobPattern] = [], basePath: String? = nil) {
        self.include = include
        self.exclude = exclude
        self.basePath = basePath
        self.basePathVariants = basePath.map(Self.variants(of:)) ?? []
    }

    /// 기준 경로가 가질 수 있는 표기들. 순서는 고정한다.
    static func variants(of basePath: String) -> [String] {
        let expanded = URL(fileURLWithPath: (basePath as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
        var result = [basePath, expanded, URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path]

        // `/private` 접두사 유무만 다른 짝을 함께 본다.
        let privatePrefix = "/private"
        for path in result {
            if path.hasPrefix(privatePrefix + "/") {
                result.append(String(path.dropFirst(privatePrefix.count)))
            } else if path.hasPrefix("/") {
                result.append(privatePrefix + path)
            }
        }

        var seen: Set<String> = []
        return result.filter { seen.insert($0).inserted }
    }

    /// 어떤 경로도 거르지 않는 필터.
    public static let passthrough = PathFilter()

    public func allows(_ path: String) -> Bool {
        if excludes(path) { return false }
        if include.isEmpty { return true }
        return matchCandidates(for: path).contains { include.matchesAny($0) }
    }

    /// 제외 판정. 프로젝트 안의 경로는 프로젝트 기준 상대 경로로만 본다.
    ///
    /// 절대 경로까지 후보로 두면 프로젝트 루트의 *조상* 디렉터리 이름이 패턴에 걸린다.
    /// 기본 제외 목록에는 `**/DerivedData/**` 처럼 흔한 이름이 있어, 프로젝트가
    /// `~/DerivedData/App` 아래 있기만 하면 모든 파일이 제외되고 결과는 "정점 0개"가
    /// 된다. 그 상태에서 `--strict` 는 아무것도 분석하지 않은 채 통과한다.
    /// 같은 일이 사용자가 쓴 글롭에도 일어난다 — `exclude: ["**/Normal/**"]` 은
    /// 조상 디렉터리 이름이 `Normal` 이기만 해도 프로젝트 전체를 삼킨다.
    ///
    /// include 는 바꾸지 않는다. 포함 후보를 좁히는 것은 설정이 조용히 아무것도
    /// 고르지 않는 방향이고, 이 타입이 막겠다고 존재하는 실패가 바로 그것이다.
    private func excludes(_ path: String) -> Bool {
        // 절대 경로로 쓴 패턴은 의도가 분명하므로 절대 경로에 그대로 적용한다.
        if exclude.contains(where: { $0.isAbsolute && $0.matches(path) }) { return true }
        return relativeCandidates(for: path).contains { exclude.matchesAny($0) }
    }

    /// 기준 디렉터리에 대한 상대 경로들. 기준이 없거나 기준 밖의 경로면 절대 경로 하나뿐이다.
    ///
    /// 기준 밖의 경로에까지 상대 후보가 없다고 제외를 포기하면, 프로젝트 밖에
    /// 체크아웃된 의존성(`~/Library/.../SourcePackages/checkouts/**`)을 걸러 내지
    /// 못한다. 그쪽은 절대 경로로 판단하는 것이 맞다.
    func relativeCandidates(for path: String) -> [String] {
        var result: [String] = []
        for base in basePathVariants {
            let candidates = Self.matchCandidates(for: path, relativeTo: base)
            guard candidates.count > 1, !result.contains(candidates[1]) else { continue }
            result.append(candidates[1])
        }
        return result.isEmpty ? [path] : result
    }

    /// 절대 경로와, 기준 디렉터리에 대한 상대 경로들.
    func matchCandidates(for path: String) -> [String] {
        var result = [path]
        for base in basePathVariants {
            for candidate in Self.matchCandidates(for: path, relativeTo: base)
            where !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    /// 경로 글롭을 적용할 때 시도해야 할 형태들.
    ///
    /// 경로 글롭을 쓰는 곳이 여러 군데라 규칙을 한 곳에 둔다.
    /// 한쪽만 상대 경로를 지원하면 같은 패턴이 설정 위치에 따라 다르게 동작한다.
    public static func matchCandidates(for path: String, relativeTo base: String?) -> [String] {
        guard let base else { return [path] }
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(normalizedBase) else { return [path] }
        return [path, String(path.dropFirst(normalizedBase.count))]
    }
}
