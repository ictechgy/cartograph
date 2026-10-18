/// 빌드 생산자가 실제 describe 실행과 인덱스 관찰을 묶어 남긴 주장이다.
/// 서명이나 실행 가능한 테스트 제품의 증명은 아니다.
public struct SwiftPMTargetEvidenceDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let packageRoot: String
    public let descriptionPath: String
    public let toolchain: String
    public let configuration: String
    public let describeArguments: [String]
    public let buildArguments: [String]
    public let before: Inputs
    public let after: Inputs
    public let snapshotBefore: String
    public let snapshotAfter: String

    public struct Inputs: Sendable, Equatable, Codable {
        public let descriptionSHA256: String
        /// 경로는 packageRoot 기준 상대 경로다. nil 값은 해당 선택 파일의 부재다.
        public let files: [String: String?]

        public init(descriptionSHA256: String, files: [String: String?]) {
            self.descriptionSHA256 = descriptionSHA256
            self.files = files
        }
    }

    public init(
        packageRoot: String, descriptionPath: String, toolchain: String, configuration: String,
        describeArguments: [String], buildArguments: [String], before: Inputs, after: Inputs,
        snapshotBefore: String, snapshotAfter: String
    ) {
        format = "swiftpm-target-evidence"
        version = 1
        self.packageRoot = packageRoot
        self.descriptionPath = descriptionPath
        self.toolchain = toolchain
        self.configuration = configuration
        self.describeArguments = describeArguments
        self.buildArguments = buildArguments
        self.before = before
        self.after = after
        self.snapshotBefore = snapshotBefore
        self.snapshotAfter = snapshotAfter
    }
}

/// describe가 선언한 소스 소속. module은 표시 이름 대신 c99name이다.
public struct SwiftPMDeclaredTarget: Sendable, Equatable {
    public let packageRoot: String
    public let name: String
    public let module: String
    public let isTest: Bool
    public let sourcePaths: Set<String>

    public init(packageRoot: String, name: String, module: String, isTest: Bool, sourcePaths: Set<String>) {
        self.packageRoot = packageRoot
        self.name = name
        self.module = module
        self.isTest = isTest
        self.sourcePaths = sourcePaths
    }
}
