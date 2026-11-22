import CartographCore

/// Git 이 무시하지만 컴파일러가 색인한 소스가 참조하는 선언을 보존 근거로 옮긴다.
///
/// R.swift·SwiftGen·Sourcery 처럼 생성 파일을 `.gitignore` 에 두는 팀이 흔하다. 소스 발견은 무시 파일을 빼므로,
/// 그 파일만 부르는 앱 코드는 호출자를 잃고 `unreachable` 로 보고됐다. 무시 파일을 분석 범위에 다시 넣으면 그 안의
/// 생성 선언이 미사용·순환·레이어·import 판정에 새로 섞인다. 그래서 범위는 그대로 두고, 그 파일에서 나가는 사용의
/// 대상만 표시한다. 인덱스 레코드는 컴파일된 파일에만 있으므로, 색인되지 않은 무시 사본(`.claude/worktrees/...`)은
/// 아무것도 더하지 않는다.
enum IgnoredSourceReferences {
    /// 사용으로 읽는 관계.
    ///
    /// 익스텐션(`extends`)은 대상을 쓰지 않고 넓히기만 한다 — 생성기가 표시한 모든 타입에 익스텐션을 만들면 아무도
    /// 쓰지 않는 타입까지 살아남는다. 오버라이드는 기반 선언을 부르지 않는다. import 는 모듈을 가리킨다.
    static let usageKinds: Set<EdgeKind> = [.call, .reference, .inheritance, .conformance]

    /// 무시 파일만 읽은 스냅샷에서, 그 파일들 밖의 선언을 가리키는 사용 참조의 대상 USR.
    static func targets(in supplemental: IndexSnapshot) -> Set<String> {
        let declared = Set(supplemental.symbols.filter { !$0.isExternal }.map(\.usr))
        return Set(supplemental.references.compactMap { reference in
            guard usageKinds.contains(reference.kind), declared.contains(reference.sourceUSR),
                  !declared.contains(reference.targetUSR) else { return nil }
            return reference.targetUSR
        })
    }

    /// 무시 경로 중 링크를 풀어도 추적 소스가 아닌 것.
    ///
    /// 무시된 심볼릭 링크가 추적 파일을 가리키면 그 파일은 본 분석이 이미 읽는다. 보조 근거로 다시 세면 죽은 추적
    /// 코드가 부르는 선언까지 "무시 소스가 쓴다" 로 살아남는다. 순서는 입력을 따른다.
    static func untrackedSources(ignored: [String], tracked: [String]) -> [String] {
        let trackedFiles = Set(tracked.map(LocalFileSystem.canonicalPath))
        return ignored.filter { !trackedFiles.contains(LocalFileSystem.canonicalPath($0)) }
    }

    /// 무시 소스를 include/exclude 로 한 번에 나눈다. 범위 밖 목록에서는 링크를 풀면 추적 소스인 경로를 뺀다.
    ///
    /// 범위 밖 파일은 따라가지 않으므로 그 개수와 걸린 패턴이 한계 문장의 근거다. 추적 파일(범위 밖 포함)을 가리키는
    /// 무시 링크는 독립된 무시 소스가 아니라 추적 파일의 다른 이름이라 세지 않는다 — 세면 패턴을 고쳐도 아무것도
    /// 달라지지 않는 파일을 알리게 된다. 링크 판정은 범위 밖 파일이 있을 때만 한다(경로 정규화 비용).
    static func partition(
        ignored: some Collection<String>, tracked: [String], pathFilter: PathFilter
    ) -> (followed: [String], outsideScope: IgnoredSourcesOutsideScope) {
        var followed: [String] = []
        var outside: [String] = []
        for path in ignored.sorted() {
            if pathFilter.allows(path) { followed.append(path) } else { outside.append(path) }
        }
        guard !outside.isEmpty else { return (followed, .none) }
        let paths = untrackedSources(ignored: outside, tracked: tracked)
        let patterns = pathFilter.exclude.filter { pattern in paths.contains { pathFilter.removes([pattern], $0) } }
        let missesInclude = paths.contains { !pathFilter.removes(pathFilter.exclude, $0) }
        return (followed, IgnoredSourcesOutsideScope(
            paths: paths, excludePatterns: patterns.map(\.pattern), missesInclude: missesInclude))
    }

    /// 대상 선언에 `referencedFromIgnoredSource` 표식을 붙인 사본. 대상이 없으면 그대로 돌려준다.
    static func marking(_ snapshot: IndexSnapshot, targets: Set<String>) -> IndexSnapshot {
        guard !targets.isEmpty else { return snapshot }
        var marked = snapshot
        for index in marked.symbols.indices where targets.contains(marked.symbols[index].usr) {
            marked.symbols[index].attributes.insert(.referencedFromIgnoredSource)
        }
        return marked
    }
}

/// include/exclude 가 걸러 참조를 따라가지 않는 Git 무시 소스와, 걸러진 이유.
///
/// 기본 제외 글롭 `**/*.generated.swift`·`**/Generated/**` 가 R.swift·Sourcery·SwiftGen 의 흔한 출력 경로와 겹친다.
/// 이 파일들이 쓰는 선언은 컴파일러가 색인했어도 보존되지 않으므로, 한계가 "보존한다" 고만 말하면 거짓이 된다.
/// 사용자가 `exclude` 를 쓰면 기본값이 대체되므로, 기본 패턴 이름이 아니라 실제로 걸린 패턴을 남긴다.
struct IgnoredSourcesOutsideScope: Sendable, Equatable {
    /// 링크를 풀어도 추적 소스가 아닌 범위 밖 무시 소스(정렬).
    let paths: [String]
    /// 이 파일들 중 하나 이상에 걸린 exclude 패턴(설정 순서, 중복 없음).
    let excludePatterns: [String]
    /// exclude 에는 걸리지 않고 include 에 맞지 않아 빠진 파일이 있는지.
    let missesInclude: Bool

    /// 범위 밖 무시 소스가 없다.
    static let none = IgnoredSourcesOutsideScope(paths: [], excludePatterns: [], missesInclude: false)
}
