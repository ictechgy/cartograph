// 무시된 생성 파일이 쓰는 선언과 아무도 쓰지 않는 대조군을 한 타입에 나란히 둔다.
struct Helper {
    // 컴파일된 무시 파일(GeneratedAccessors.swift)만 부른다. 보고되면 안 된다.
    static func usedByGenerated() {}

    // 아무도 부르지 않는다. 보고되어야 한다.
    static func neverCalled() {}

    // 색인되지 않은 무시 사본(.claude/worktrees)만 부른다. 레코드가 없으므로 보고되어야 한다.
    static func usedOnlyByUncompiledCopy() {}

    // 기본 제외 글롭(**/*.generated.swift)에 걸린 무시 파일만 부른다. 제외한 파일의 간선은 버려지므로
    // 보고된다. 이 경계가 바뀌면 기대 파일과 README 를 함께 고친다.
    static func usedOnlyByExcludedGenerated() {}
}

// 무시 파일의 익스텐션만 넓힌다. 익스텐션은 대상을 쓰지 않으므로 보고되어야 한다.
struct ExtendedOnly {}

// 무시 파일의 타입이 준수한다. 지우면 생성 코드가 컴파일되지 않으므로 보고되면 안 된다.
protocol AdoptedByGenerated {}

// 무시 파일과 서로 참조한다. 실제 코드에는 타입 순환이 있지만 무시 파일은 그래프에 들어오지 않으므로
// 순환으로 보고되면 안 된다. 생성 코드가 Screen 을 이름으로 쓰므로 타입은 남고, 아무도 읽지 않는 title 은 보고된다.
struct Screen {
    // 생성 코드가 읽는다. 보고되면 안 된다.
    static let fallbackTitle = "Untitled"

    var title: String { GeneratedAccessors.screenTitle }
}
