/// Core Data 빌드 근거에 포함된 파일 또는 디렉터리 지문.
///
/// 디렉터리 지문은 정렬된 상대 경로와 각 파일의 SHA-256을 다시 해시한 값이다.
/// 경로만 같은 다른 빌드 산출물을 근거로 재사용하지 못하게 한다.
public struct CoreDataBuildArtifact: Codable, Sendable, Equatable {
    /// 단일 파일과 재귀 디렉터리 지문의 계산 방식을 구분한다.
    public enum Kind: String, Codable, Sendable {
        case file, directory
    }

    public let path: String
    public let kind: Kind
    public let sha256: String
    public let byteCount: UInt64
    public let fileCount: Int

    /// 파일 종류와 내용 지문을 함께 보존해 같은 경로의 다른 산출물을 거부한다.
    public init(path: String, kind: Kind, sha256: String, byteCount: UInt64, fileCount: Int) {
        self.path = path
        self.kind = kind
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileCount = fileCount
    }
}

/// 실행 파일이 속한 앱 번들과 `NSPersistentContainer(name:)` 리소스의 결합 근거.
public struct CoreDataBundleBuildEvidence: Codable, Sendable, Equatable {
    public let path: String
    public let identifier: String
    public let resourceRoot: String
    public let persistentContainerName: String
    public let compiledModelRelativePath: String
    public let compiledModel: CoreDataBuildArtifact

    /// container literal과 main bundle의 exact 컴파일 모델 멤버를 묶는다.
    public init(
        path: String,
        identifier: String,
        resourceRoot: String,
        persistentContainerName: String,
        compiledModelRelativePath: String,
        compiledModel: CoreDataBuildArtifact
    ) {
        self.path = path
        self.identifier = identifier
        self.resourceRoot = resourceRoot
        self.persistentContainerName = persistentContainerName
        self.compiledModelRelativePath = compiledModelRelativePath
        self.compiledModel = compiledModel
    }
}

/// 소스 모델의 엔티티와 컴파일된 모델이 실제로 제공한 클래스 이름의 대조 결과.
public struct CoreDataBuildEntityEvidence: Codable, Sendable, Equatable {
    public let name: String
    public let representedClassName: String?
    public let managedObjectClassName: String
    public let codeGenerationType: String?
    public let superentityName: String?

    /// 소스 모델 표현명과 Core Data SDK가 읽은 실제 클래스명을 나란히 보존한다.
    public init(
        name: String,
        representedClassName: String?,
        managedObjectClassName: String,
        codeGenerationType: String? = nil,
        superentityName: String? = nil
    ) {
        self.name = name
        self.representedClassName = representedClassName
        self.managedObjectClassName = managedObjectClassName
        self.codeGenerationType = codeGenerationType
        self.superentityName = superentityName
    }
}

/// 선택된 소스 모델 버전과 컴파일된 현재 버전이 같음을 재검증할 입력.
public struct CoreDataSourceModelBuildEvidence: Codable, Sendable, Equatable {
    public let container: CoreDataBuildArtifact
    public let selectedContents: CoreDataBuildArtifact
    public let selectedVersionName: String?
    public let currentVersionMarker: CoreDataBuildArtifact?
    public let entities: [CoreDataBuildEntityEvidence]

    /// 전체 소스 모델 지문과 선택된 버전의 별도 지문을 함께 보존한다.
    public init(
        container: CoreDataBuildArtifact,
        selectedContents: CoreDataBuildArtifact,
        selectedVersionName: String? = nil,
        currentVersionMarker: CoreDataBuildArtifact? = nil,
        entities: [CoreDataBuildEntityEvidence]
    ) {
        self.container = container
        self.selectedContents = selectedContents
        self.selectedVersionName = selectedVersionName
        self.currentVersionMarker = currentVersionMarker
        self.entities = entities
    }
}

/// 생성 Swift 파일과 컴파일러 선언 신원을 연결하기 위한 빌드 근거.
///
/// 파일명이나 생성 주석은 클래스 신원의 증거가 아니다. 소비자는 `declarationUSRs`가
/// 현재 인덱스에서 이 파일과 모듈에 속하는지 다시 확인해야 한다.
public struct CoreDataDeclaredGeneratedMapping: Codable, Sendable, Equatable {
    public let entityName: String
    public let source: CoreDataBuildArtifact
    public let module: String
    public let declarationUSRs: [String]
    /// 실행 파일의 정의된 심볼 표에서 확인한 Swift metadata와 선택적 Objective-C 신원.
    public let linkedBinarySymbols: [String]

    /// 제시된 파일·모듈·USR를 이후 인덱스 검증에 사용할 값으로 만든다.
    public init(
        entityName: String,
        source: CoreDataBuildArtifact,
        module: String,
        declarationUSRs: [String],
        linkedBinarySymbols: [String]
    ) {
        self.entityName = entityName
        self.source = source
        self.module = module
        self.declarationUSRs = declarationUSRs
        self.linkedBinarySymbols = linkedBinarySymbols
    }
}

/// 자동 생성 Core Data 클래스를 현재 앱 빌드에 귀속시키는 교환 문서.
public struct CoreDataBuildEvidenceDocument: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let executable: CoreDataBuildArtifact
    public let bundle: CoreDataBundleBuildEvidence
    public let model: CoreDataSourceModelBuildEvidence
    /// 생산자가 제시한 매핑이다. 현재 인덱스의 파일·모듈·USR·신선도를
    /// 대조하기 전에는 생성된 선언이라는 판정 근거로 사용할 수 없다.
    public let declaredGeneratedMappings: [CoreDataDeclaredGeneratedMapping]

    /// 빌드 입력 지문과 선언 매핑을 버전이 있는 교환 문서로 만든다.
    public init(
        format: String = "coredata-build-evidence",
        version: Int = 1,
        executable: CoreDataBuildArtifact,
        bundle: CoreDataBundleBuildEvidence,
        model: CoreDataSourceModelBuildEvidence,
        declaredGeneratedMappings: [CoreDataDeclaredGeneratedMapping] = []
    ) {
        self.format = format
        self.version = version
        self.executable = executable
        self.bundle = bundle
        self.model = model
        self.declaredGeneratedMappings = declaredGeneratedMappings
    }
}
