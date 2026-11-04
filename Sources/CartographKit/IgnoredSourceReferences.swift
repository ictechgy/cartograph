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
