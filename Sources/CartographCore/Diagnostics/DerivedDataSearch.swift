/// DerivedData 에서 인덱스 스토어를 찾아본 결과.
///
/// 이름이 하나도 맞지 않으면 후보 경로가 한 줄도 생기지 않아, 실패 메시지의
/// "Searched:" 목록에 DerivedData 가 아예 나타나지 않았다. 사용자는 도구가 그곳을
/// 보기라도 했는지 알 수 없었다. 무엇을 어떤 이름으로 훑었는지를 값으로 들고 다닌다.
///
/// 값만 담는다. 디렉터리를 세는 일은 파일 시스템을 아는 `CartographIndexStore` 가 하고
/// 여기서는 그 숫자를 문장으로 바꾸기만 한다. `CartographCore` 는 외부 의존성도 파일
/// 접근도 갖지 않는다는 규칙 때문이다.
public struct DerivedDataSearch: Sendable, Equatable {
    /// 훑어본 DerivedData 루트.
    public let root: String
    /// 그 루트가 실제로 있었는지.
    public let rootExists: Bool
    /// 디렉터리 이름으로 시도한 프로젝트 이름들. 시도한 순서 그대로다.
    public let names: [String]
    /// 이름이 맞은 디렉터리 수.
    public let matchedDirectoryCount: Int
    /// 그중 실제로 인덱스 스토어를 품고 있던 수.
    public let storeDirectoryCount: Int

    public init(
        root: String,
        rootExists: Bool,
        names: [String],
        matchedDirectoryCount: Int,
        storeDirectoryCount: Int
    ) {
        self.root = root
        self.rootExists = rootExists
        self.names = names
        self.matchedDirectoryCount = matchedDirectoryCount
        self.storeDirectoryCount = storeDirectoryCount
    }

    /// 왜 DerivedData 에서 찾지 못했는지와, 다음에 무엇을 할지.
    ///
    /// 네 갈래의 다음 행동이 서로 다르다. 루트가 없는 것, 이름이 안 맞은 것,
    /// 이름은 맞았는데 빌드된 적이 없는 것, 이름도 맞고 스토어도 있는데 이 프로젝트의
    /// 것이라고 확인되지 않은 것.
    public var explanation: String {
        guard rootExists else {
            return "There is no DerivedData directory at \(root)."
        }
        if matchedDirectoryCount == 0 { return unmatchedExplanation }
        if storeDirectoryCount == 0 { return notBuiltExplanation }
        return unownedExplanation
    }

    private var namesList: String {
        names.map { "'\($0)'" }.joined(separator: ", ")
    }

    private var unmatchedExplanation: String {
        """
        Nothing under \(root) is named <name>-<hash> for any of \(namesList). Xcode names that \
        directory after the document it opened, not after the folder that holds it, so a project \
        whose file is not named like its folder needs the file's name. Pass --index-store <path> \
        if the store is somewhere else.
        """
    }

    private var notBuiltExplanation: String {
        """
        \(matchedDirectoryCount) directory(ies) under \(root) matched \(namesList) but hold no index \
        store: this project has not been built there yet, or DerivedData was cleaned. Build once in \
        Xcode; from the command line add COMPILER_INDEX_STORE_ENABLE=YES to xcodebuild.
        """
    }

    private var unownedExplanation: String {
        """
        \(matchedDirectoryCount) directory(ies) under \(root) matched \(namesList) and hold an index \
        store, but their info.plist names a different project, so none was used. Pass \
        --index-store <path> to read one anyway.
        """
    }
}
