import Foundation

/// 한 번의 분석에 사용할 인덱스 전체 스냅샷.
///
/// 인덱스 스토어를 열어 두고 질의하는 대신 한 번에 읽어 값 타입으로 고정한다.
/// 덕분에 이후 모든 분석 단계가 순수 함수가 되고, 테스트에서는
/// 인덱스 스토어 없이 스냅샷을 직접 만들어 넣을 수 있다.
public struct IndexSnapshot: Sendable, Codable, Equatable {
    /// 선언 목록. **순서에 의미가 있다.** `symbolsByUSR()` 이 사전으로 접을 때 같은 USR 이
    /// 겹치면 앞의 것이 이기고, `merging` 은 두 배열을 잇기만 하므로 인덱스에서 온 것이
    /// 구문에서 온 것을 이긴다. 인덱스 스토어를 읽는 경로는 USR 순으로 정렬해 넘긴다.
    public var symbols: [IndexedSymbol]

    /// 참조 목록. **순서는 정해져 있지 않다.** 인덱스 스토어를 읽는 경로는 스토어가 준
    /// 순서를 그대로 넘긴다. 정렬 비용이 명령마다 0.1 초를 넘었고 그 순서를 읽는 소비자가
    /// 없었기 때문이다.
    ///
    /// 순서가 결과에 남아서는 안 된다. 이 배열을 사전으로 접는 코드를 새로 쓴다면
    /// "마지막이 이긴다" 가 곧 "인덱스가 정한다" 가 된다는 뜻이므로, 충돌 시의 승자를
    /// 값으로 정하라(`GraphBuilder.extensionTargets` 가 그 예다). 그래프를 거쳐 가는
    /// 경로는 `CodeGraph.init` 이 간선을 서명으로 접고 다시 정렬해 주므로 안전하다.
    /// 이 계약은 `GraphBuilderTests` 의 "참조를 어떤 순서로 넣어도 그래프가 같다" 가 지킨다.
    ///
    /// 이 배열을 그대로 직렬화하거나 `==` 로 비교하는 임베더는 먼저 정규화해야 한다.
    public var references: [IndexedReference]

    /// 파일을 포함하는 최신 인덱스 유닛 시각. 다른 타깃의 빌드가 낡은 파일을 가리지 않게 한다.
    /// nil 은 공급자가 이 정보를 주지 않았다는 뜻이고, 빈 사전은 조회했지만 유닛이 없었다는 뜻이다.
    public var indexedFileDates: [String: Date]?

    /// 함수 파라미터 선언 목록. 그래프 정점이 아니라 미사용 파라미터 질의 전용 입력이다.
    public var parameters: [IndexedParameter]

    /// 프로퍼티·변수 USR 별 접근 방향 합산. assign-only 질의 전용 입력이다.
    ///
    /// 참조 발생이 하나도 없는 심볼은 키가 없다 — 근거가 없는 것과
    /// "읽힌 적 없다" 는 다르므로 키 부재를 미사용으로 읽으면 안 된다.
    public var propertyAccesses: [String: PropertyAccessFacts]

    /// 파일별 `import` 선언 목록. 구문 분석이 채우는 미사용 import 질의 전용 입력이다.
    ///
    /// 구문 정보를 얻지 못한 파일의 import는 목록에 없다 — 근거가 없는 것과
    /// "쓰인 적 없다" 는 다르므로 목록 부재를 미사용으로 읽으면 안 된다.
    public var imports: [IndexedImport]

    /// 파일별로 참조한 선언의 모듈 귀속 합산. 미사용 import 질의 전용 입력이다.
    ///
    /// 인덱스에 발생이 없는 파일은 키가 없다 — 그 파일의 import는 판정할 수 없다.
    public var fileModuleUsages: [String: FileModuleUsage]

    public init(
        symbols: [IndexedSymbol] = [],
        references: [IndexedReference] = [],
        indexedFileDates: [String: Date]? = nil,
        parameters: [IndexedParameter] = [],
        propertyAccesses: [String: PropertyAccessFacts] = [:],
        imports: [IndexedImport] = [],
        fileModuleUsages: [String: FileModuleUsage] = [:]
    ) {
        self.symbols = symbols
        self.references = references
        self.indexedFileDates = indexedFileDates
        self.parameters = parameters
        self.propertyAccesses = propertyAccesses
        self.imports = imports
        self.fileModuleUsages = fileModuleUsages
    }

    private enum CodingKeys: String, CodingKey {
        case symbols, references, indexedFileDates, parameters, propertyAccesses, imports, fileModuleUsages
    }

    /// 파라미터 목록과 접근 합산·import 근거는 뒤늦게 추가된 필드라, 그것이 없는 예전 스냅샷 문서도 읽는다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbols = try container.decode([IndexedSymbol].self, forKey: .symbols)
        references = try container.decode([IndexedReference].self, forKey: .references)
        indexedFileDates = try container.decodeIfPresent([String: Date].self, forKey: .indexedFileDates)
        parameters = try container.decodeIfPresent([IndexedParameter].self, forKey: .parameters) ?? []
        propertyAccesses = try container.decodeIfPresent(
            [String: PropertyAccessFacts].self, forKey: .propertyAccesses) ?? [:]
        imports = try container.decodeIfPresent([IndexedImport].self, forKey: .imports) ?? []
        fileModuleUsages = try container.decodeIfPresent(
            [String: FileModuleUsage].self, forKey: .fileModuleUsages) ?? [:]
    }

    /// USR 로 심볼을 찾기 위한 사전. 반복 조회가 많아 미리 만들어 쓴다.
    public func symbolsByUSR() -> [String: IndexedSymbol] {
        Dictionary(symbols.map { ($0.usr, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 등장하는 모듈 이름 목록(정렬됨).
    public var moduleNames: [String] {
        Set(symbols.map(\.module)).sorted()
    }

    /// 등장하는 소스 파일 경로 목록(정렬됨).
    public var filePaths: [String] {
        Set(symbols.map(\.location.path)).sorted()
    }

    /// 두 스냅샷을 합친다. 인덱스 스토어와 구문 분석 결과를 합칠 때 쓴다.
    public func merging(_ other: IndexSnapshot) -> IndexSnapshot {
        let dates: [String: Date]? = indexedFileDates == nil && other.indexedFileDates == nil
            ? nil
            : (indexedFileDates ?? [:]).merging(other.indexedFileDates ?? [:], uniquingKeysWith: min)
        return IndexSnapshot(
            symbols: symbols + other.symbols,
            references: references + other.references,
            indexedFileDates: dates,
            parameters: parameters + other.parameters,
            propertyAccesses: propertyAccesses.merging(other.propertyAccesses) {
                var merged = $0
                merged.merge($1)
                return merged
            },
            imports: imports + other.imports,
            fileModuleUsages: fileModuleUsages.merging(other.fileModuleUsages) { base, extra in
                FileModuleUsage(
                    owningModule: base.owningModule ?? extra.owningModule,
                    referencedModules: base.referencedModules.union(extra.referencedModules),
                    hasUnattributedReferences: base.hasUnattributedReferences
                        || extra.hasUnattributedReferences
                )
            }
        )
    }
}
