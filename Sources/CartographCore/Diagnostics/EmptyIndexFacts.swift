/// 인덱스가 이 프로젝트의 선언을 하나도 모를 때, 원인을 좁히는 데 쓰는 사실들.
///
/// 값만 담는다. 파일을 세는 일은 파일 시스템을 아는 위층(`CartographKit`)이 하고
/// 여기서는 그 숫자를 문장으로 바꾸기만 한다. `CartographCore` 는 외부 의존성도
/// 파일 접근도 갖지 않는다는 규칙 때문이다.
///
/// 원인이 셋으로 갈리고 다음 행동이 각각 다르다. 소스를 못 찾은 것, 경로 필터가
/// 다 걸러 낸 것, 스토어가 남의 것이거나 아직 비어 있는 것. 숫자 세 개의 조합이
/// 곧 판정이므로 셋을 함께 싣는다.
public struct EmptyIndexFacts: Sendable, Equatable {
    /// 인덱스 스토어를 어떻게 골랐는지.
    ///
    /// 자동 탐색이 남의 스토어를 집는 경우가 가장 흔한 원인이라, 무엇을 읽었는지
    /// 만큼이나 왜 그것을 읽었는지가 사용자에게 필요하다.
    public enum StoreOrigin: String, Sendable, Equatable {
        /// `--index-store` 로 직접 지정했다.
        case explicit
        /// 프로젝트 안의 흔한 위치에서 찾았다.
        case autoDetected
        /// DerivedData 아래에서 찾았다.
        case derivedData
        /// 임베더가 공급자를 직접 주입했다.
        case injected
    }

    /// 사용자가 지정한 프로젝트 루트.
    public let projectPath: String
    /// 심볼릭 링크를 푼 프로젝트 루트. 표기가 같으면 nil.
    public let resolvedProjectPath: String?
    /// 실제로 읽은 인덱스 스토어 경로.
    public let storePath: String
    public let storeOrigin: StoreOrigin
    /// 인덱스를 읽는 데 쓴 libIndexStore 경로.
    public let libraryPath: String
    /// 프로젝트 아래에서 찾은 Swift 파일 수. 경로 필터를 걸지 않은 값이다.
    public let sourceFileCount: Int
    /// 그중 include/exclude 를 통과한 수.
    public let filteredSourceFileCount: Int
    /// 프로젝트 아래의 Objective-C 소스 수.
    ///
    /// Swift 가 하나도 없을 때 경로가 틀린 것인지, 이 도구가 못 읽는 언어로 쓰인
    /// 프로젝트인지를 가른다. 후자에게 "경로를 고치라" 고 하면 없는 오류를 찾게 만든다.
    public let objectiveCSourceCount: Int
    /// 스토어가 담고 있는 유닛 수. 셀 수 없으면 nil.
    public let unitCount: Int?

    public init(
        projectPath: String,
        resolvedProjectPath: String? = nil,
        storePath: String,
        storeOrigin: StoreOrigin,
        libraryPath: String,
        sourceFileCount: Int,
        filteredSourceFileCount: Int,
        objectiveCSourceCount: Int = 0,
        unitCount: Int? = nil
    ) {
        self.projectPath = projectPath
        self.resolvedProjectPath = resolvedProjectPath
        self.storePath = storePath
        self.storeOrigin = storeOrigin
        self.libraryPath = libraryPath
        self.sourceFileCount = sourceFileCount
        self.filteredSourceFileCount = filteredSourceFileCount
        self.objectiveCSourceCount = objectiveCSourceCount
        self.unitCount = unitCount
    }

    /// 무엇을 보고 그렇게 판단했는지를 적은 사실 블록.
    public var summary: String {
        [
            "  project:       \(projectPath)\(resolvedSuffix)",
            "  index store:   \(storePath) (\(originDescription))",
            "  libIndexStore: \(libraryPath)",
            "  Swift files:   \(sourceFileCount) under the project, "
                + "\(filteredSourceFileCount) of them in scope after include/exclude",
            "  index units:   \(unitCount.map(String.init) ?? "unknown")",
        ].joined(separator: "\n") + objectiveCLine
    }

    /// 원인별 다음 행동. 숫자 세 개가 원인을 가른다.
    ///
    /// 유닛 수를 모르면 둘 중 어느 쪽이라고도 말하지 않는다. "유닛이 있다"고 단정한
    /// 문장 뒤에 "index units: unknown" 이 붙으면 그 답 전체를 믿을 수 없게 된다.
    public var remedy: String {
        if sourceFileCount == 0 {
            return objectiveCSourceCount > 0
                ? objectiveCOnlyRemedy
                : Self.noSourcesRemedy
        }
        if filteredSourceFileCount == 0 { return Self.filteredOutRemedy }
        switch unitCount {
        case 0: return Self.nothingCompiledRemedy
        case nil: return Self.unknownStoreRemedy
        default: return Self.foreignStoreRemedy
        }
    }

    /// 탈출구를 안내해도 되는 상황인지.
    ///
    /// 원인이 이미 특정된 경우에는 안내하지 않는다. 오류의 마지막 줄은 가장 눈에 띄고,
    /// 에이전트는 그것을 해결책으로 읽는다. 경로가 틀렸거나 필터가 다 걸러 낸 것을
    /// 아는 상태에서 "이 플래그로 넘기라" 고 하면 원인 조사 대신 은폐를 권하는 셈이다.
    public var suggestsEscapeHatch: Bool {
        sourceFileCount > 0 && filteredSourceFileCount > 0
    }

    /// Objective-C 만 있는 프로젝트. Flutter·React Native 의 `ios/` 가 흔히 이 모양이다.
    private var objectiveCOnlyRemedy: String {
        """
        This project has \(objectiveCSourceCount) Objective-C source file(s) and no Swift file that \
        this tool can read, so the path is probably right and there is simply nothing here to \
        analyse. Point --project at the Swift sources if they live elsewhere.
        """
    }

    /// Objective-C 소스가 있을 때만 한 줄 더 적는다. 0 은 알릴 것이 없다.
    private var objectiveCLine: String {
        guard objectiveCSourceCount > 0 else { return "" }
        return "\n  ObjC files:    \(objectiveCSourceCount) under the project, not analysed"
    }

    /// 링크를 지정했을 때만 실제 경로를 덧붙인다. 같은 경로를 두 번 보여 주지 않는다.
    private var resolvedSuffix: String {
        guard let resolvedProjectPath, resolvedProjectPath != projectPath else { return "" }
        return "  (resolves to \(resolvedProjectPath))"
    }

    private var originDescription: String {
        switch storeOrigin {
        case .explicit: return "given by --index-store"
        case .autoDetected: return "auto-detected"
        case .derivedData: return "found under DerivedData"
        case .injected: return "injected by the embedder"
        }
    }

    private static let noSourcesRemedy = """
        No Swift file was found under the project root. Point --project at the directory that \
        contains the sources.
        """

    private static let filteredOutRemedy = """
        Every Swift file was removed by the path filter, so the include and exclude patterns are \
        the thing to look at first. Run again with --exclude to replace the defaults, or set \
        `include` and `exclude` in .cartograph.yml.
        """

    private static let nothingCompiledRemedy = """
        The store holds no units: nothing has been compiled into it yet. Build first, then run again:
          swift build
          xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
        """

    private static let unknownStoreRemedy = """
        The store's unit directory could not be read, so this is either a store nothing has been \
        compiled into yet or one written for a different checkout, scheme or target. Build first, \
        or pass --index-store <path> to name the right store:
          swift build
          xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
        """

    private static let foreignStoreRemedy = """
        The store holds units, but none of them covers a file in this project — it was written for \
        a different checkout, scheme or target. Pass --index-store <path> to name the right store.
        Note: the index format is only backward compatible, so a store written by a toolchain newer \
        than the libIndexStore above can read as empty.
        """
}
