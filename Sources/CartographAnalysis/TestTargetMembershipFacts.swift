import CartographCore

/// 기록된 생성 시점의 선언 소스 소속이다. 현재 패키지 전체나 실행 가능한 테스트의 증명이 아니다.
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
        struct Owner: Hashable {
            let root: String
            let module: String
            let target: String
        }
        var ownersByUSR: [String: Set<Owner>] = [:]
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
            ownersByUSR[symbol.usr, default: []].insert(
                Owner(root: owner.packageRoot, module: owner.module, target: owner.name)
            )
            if owner.isTest { test.insert(symbol.usr) } else { ordinary.insert(symbol.usr) }
        }
        unknown.formUnion(ownersByUSR.filter { $0.value.count > 1 }.map(\.key))
        unknown.formUnion(test.intersection(ordinary))
        testUSRs = test.subtracting(unknown)
        ordinaryUSRs = ordinary.subtracting(unknown)
        unknownUSRs = all.subtracting(testUSRs).subtracting(ordinaryUSRs)
    }
}
