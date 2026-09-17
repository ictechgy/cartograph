import CartographCore

/// 파일의 `import` 중 그 파일의 참조 근거가 증명하지 못하는 것을 찾는다.
///
/// 판정 재료는 두 출처다. 구문 분석이 import 선언(속성·`#if` 여부 포함)을
/// 모으고, 인덱스가 파일이 참조한 선언의 모듈 귀속을 모은다. 그래프 정점을
/// 쓰지 않는 별도 질의다 — 죽은 파일의 import도 import로서는 미사용이다.
///
/// 보고 조건은 전부 보존 방향이다. 어느 모듈 소유인지 알 수 없는 참조
/// (인덱스에 선언이 없는 clang 심볼 등)가 하나라도 있는 파일이나, import 없이
/// 참조된 모듈이 있는 파일(어떤 import가 재수출로 그 모듈을 공급했을 수 있다)
/// 에서는 import를 미사용으로 보고하지 않는다.
public enum UnusedImportAnalyzer {
    /// `import` 없이 참조할 수 있는 모듈들.
    ///
    /// stdlib·`_Concurrency`·`_StringProcessing`은 컴파일러가 항상 묵시 import
    /// 하고, Darwin 플랫폼에서는 `ObjectiveC` 런타임도 묵시 가용하다. 잘못 넣으면
    /// 재수출 통로가 아닌데 "설명됨"으로 처리해 미사용 오탐이 되므로, 확실하지
    /// 않은 모듈(Darwin, Dispatch 등)은 여기 두지 않는다 — 미설명으로 남으면
    /// 억제되므로 그쪽이 안전하다.
    static let implicitlyAvailableModules: Set<String> = [
        "Swift", "_Concurrency", "_StringProcessing", "ObjectiveC",
    ]

    /// 프로젝트 모듈이 `@_exported`·`public import`로 다시 노출하는 모듈의 전이 폐포.
    struct ReexportClosure: Equatable {
        /// 프로젝트 안에서 재수출이 끝까지 따라가 도달한 모듈들.
        var modules: Set<String>
        /// 재수출 사슬이 프로젝트 밖 모듈에 닿았는지. 그 안의 재수출은
        /// 인덱스에 없어 볼 수 없으므로, 닿았다면 어떤 모듈이든 전달할 수 있다.
        var hasExternalEdge: Bool
    }

    /// 미사용으로 증명된 import를 위치 순으로 돌려준다.
    public static func analyze(_ snapshot: IndexSnapshot) -> [IndexedImport] {
        guard !snapshot.imports.isEmpty else { return [] }
        let usages = snapshot.fileModuleUsages
        let projectModules = Set(snapshot.moduleNames)
        let closures = reexportClosures(in: snapshot, projectModules: projectModules)
        let importsByFile = Dictionary(grouping: snapshot.imports, by: { $0.location.path })

        var findings: [IndexedImport] = []
        for (path, fileImports) in importsByFile {
            // 인덱스 발생이 없는 파일(인덱스 못 한 신규 파일 등)은 판정 근거가 없다.
            guard let usage = usages[path] else { continue }
            let importedHeads = Set(fileImports.map(\.module))
            var implicit = implicitlyAvailableModules
            if let own = usage.owningModule { implicit.insert(own) }
            // import 없이 참조된 모듈 — 어떤 import가 재수출로 공급한 것이다.
            let unexplained = usage.referencedModules
                .subtracting(importedHeads)
                .subtracting(implicit)
            for fact in fileImports {
                guard !fact.isConditional, !fact.isReexported, !fact.isIgnored,
                      !fact.module.isEmpty,
                      !usage.referencedModules.contains(fact.module)
                else { continue }
                // 귀속을 못 한 참조가 이 모듈의 선언일 수 있다.
                if usage.hasUnattributedReferences { continue }
                // 미설명 모듈의 공급 통로일 수 있는 import는 지울 수 없다.
                if !unexplained.isEmpty,
                   maySupply(fact.module, anyOf: unexplained,
                             closures: closures, projectModules: projectModules) { continue }
                findings.append(fact)
            }
        }
        return findings.sorted {
            ($0.location.path, $0.location.line, $0.location.column)
                < ($1.location.path, $1.location.line, $1.location.column)
        }
    }

    /// 이 import가 미설명 모듈 중 하나의 재수출 통로일 수 있는지 판정한다.
    ///
    /// 외부 모듈의 내부 재수출은 볼 수 없으므로 항상 가능성이 있다. 프로젝트
    /// 모듈은 구문 사실로 폐포를 계산해 두었으므로, 미설명 모듈이 폐포에
    /// 들어 있지 않고 외부 통로도 없으면 이 import는 무관하다고 증명된다.
    private static func maySupply(
        _ module: String,
        anyOf unexplained: Set<String>,
        closures: [String: ReexportClosure],
        projectModules: Set<String>
    ) -> Bool {
        guard projectModules.contains(module) else { return true }
        guard let closure = closures[module] else { return false }
        return closure.hasExternalEdge || !closure.modules.isDisjoint(with: unexplained)
    }

    /// 모듈별 재수출 전이 폐포를 구한다. `@_exported` 표식이 있는 import만
    /// 사슬에 오른다.
    private static func reexportClosures(
        in snapshot: IndexSnapshot,
        projectModules: Set<String>
    ) -> [String: ReexportClosure] {
        var direct: [String: Set<String>] = [:]
        for fact in snapshot.imports where fact.isReexported {
            guard let owner = snapshot.fileModuleUsages[fact.location.path]?.owningModule,
                  !fact.module.isEmpty else { continue }
            direct[owner, default: []].insert(fact.module)
        }
        // 전이 폐포는 고정점 반복으로 구한다. 재귀 DFS에서 순환을 만나면
        // "조상 경로에서 절단된" 부분 폐포가 그대로 메모되어 도달 가능한
        // 모듈이 빠진다 — 폐포가 작아지면 maySupply 가 거짓을 돌려
        // 재수출 통로인 import를 미사용으로 오보한다.
        var closures: [String: ReexportClosure] = [:]
        for (module, targets) in direct {
            var closure = ReexportClosure(modules: [], hasExternalEdge: false)
            for next in targets {
                if projectModules.contains(next) {
                    closure.modules.insert(next)
                } else {
                    closure.hasExternalEdge = true
                }
            }
            closures[module] = closure
        }
        var changed = true
        while changed {
            changed = false
            for module in direct.keys.sorted() {
                var grown = closures[module]!
                for next in grown.modules {
                    guard let inner = closures[next] else { continue }
                    if !grown.modules.isSuperset(of: inner.modules)
                        || (inner.hasExternalEdge && !grown.hasExternalEdge) {
                        grown.modules.formUnion(inner.modules)
                        grown.hasExternalEdge = grown.hasExternalEdge || inner.hasExternalEdge
                        changed = true
                    }
                }
                closures[module] = grown
            }
        }
        return closures
    }
}
