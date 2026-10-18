import CartographCore

/// 선언된 소스 타깃 소속이다. 프레임워크 신원이나 실행 가능한 테스트 판정과 구분한다.
public struct TestTargetMembershipFacts: Sendable, Equatable {
    public let testUSRs: Set<String>
    public let ordinaryUSRs: Set<String>
    public let unknownUSRs: Set<String>

    /// 검증된 입력을 받은 호출자만 targets를 넘긴다. 근거가 없으면 모든 프로젝트 선언이 미확인이다.
    public init(snapshot: IndexSnapshot, targets: [SwiftPMDeclaredTarget]?) {
        let symbols = snapshot.symbols.filter { !$0.isExternal }
        let all = Set(symbols.map(\.usr))
        guard let targets else {
            testUSRs = []
            ordinaryUSRs = []
            unknownUSRs = all
            return
        }
        let byModule = Dictionary(grouping: targets, by: \.module)
        let byName = Dictionary(grouping: targets, by: \.name)
        let byPath = Dictionary(grouping: targets.flatMap { target in
            target.sourcePaths.map { ($0, target) }
        }, by: { $0.0 })
        let roots = Set(targets.map(\.packageRoot))
        let conflictingRoots = Set(roots.filter { root in
            roots.contains { $0 != root && (root.hasPrefix($0 + "/") || $0.hasPrefix(root + "/")) }
        })
        var test: Set<String> = []
        var ordinary: Set<String> = []
        var unknown: Set<String> = []
        for symbol in symbols {
            let candidates = byModule[symbol.module] ?? []
            guard candidates.count == 1, let owner = candidates.first,
                  byName[owner.name]?.count == 1,
                  owner.sourcePaths.contains(symbol.location.path),
                  symbol.location.path.hasPrefix(owner.packageRoot + "/"),
                  byPath[symbol.location.path]?.count == 1,
                  !conflictingRoots.contains(owner.packageRoot)
            else {
                unknown.insert(symbol.usr)
                continue
            }
            if owner.isTest { test.insert(symbol.usr) } else { ordinary.insert(symbol.usr) }
        }
        unknown.formUnion(test.intersection(ordinary))
        testUSRs = test.subtracting(unknown)
        ordinaryUSRs = ordinary.subtracting(unknown)
        unknownUSRs = all.subtracting(testUSRs).subtracting(ordinaryUSRs)
    }
}
