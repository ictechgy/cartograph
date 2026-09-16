/// 소스 파일 하나가 참조한 선언들의 모듈 귀속 합산.
///
/// "이 파일의 `import M` 이 쓰이는가" 를 판정하는 근거다. 인덱스가 기록한 참조
/// 발생의 USR에서 모듈 이름을 읽어 모은다. 귀속을 결정하지 못한 참조가 하나라도
/// 있으면 `hasUnattributedReferences` 를 세운다 — 그 참조가 바로 보고하려던
/// 모듈의 선언일 수 있으므로, 그런 파일에서는 어떤 import도 미사용으로 보고하지
/// 않는다.
public struct FileModuleUsage: Codable, Sendable, Equatable {
    /// 이 파일을 컴파일한 모듈(타깃) 이름. 인덱스 발생의 `moduleName`.
    /// 자기 모듈의 선언은 import 없이 참조할 수 있으므로 따로 뺀다.
    public var owningModule: String?
    /// 파일이 참조한 선언이 속한 모듈 이름들(자기 모듈·묵시 모듈 포함).
    public var referencedModules: Set<String>
    /// 어느 모듈 소유인지 결정하지 못한 참조가 있는지.
    ///
    /// Objective-C/C++/clang 선언의 USR(`c:`, `e:`)은 모듈 이름을 담지 않고,
    /// 프로젝트 인덱스에 그 선언이 없으면 귀속할 방법이 없다.
    public var hasUnattributedReferences: Bool

    public init(
        owningModule: String? = nil,
        referencedModules: Set<String> = [],
        hasUnattributedReferences: Bool = false
    ) {
        self.owningModule = owningModule
        self.referencedModules = referencedModules
        self.hasUnattributedReferences = hasUnattributedReferences
    }
}
