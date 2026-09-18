// `cartograph:ignore` 의 두 판정을 고정한다. 쓰이는 선언에 붙은 주석은
// 불필요로 보고되어야 하고, 실제로 죽은 선언의 주석은 억제를 계속해야 한다.

// MARK: - 불필요로 보고되어야 하는 것

/// 사용되는 선언에 붙은 무시 주석.
///
/// 주석이 없어도 참조가 살리므로 이 주석은 아무 일도 하지 않는다.
/// 출처: Periphery 3.7 의 superfluous ignore 와 같은 판정.
// cartograph:ignore
struct IgnoredButUsed {
    func ping() {}
}

// MARK: - 억제를 계속해야 하는 것

/// 실제로 죽은 선언에 붙은 무시 주석.
///
/// 이 주석을 떼면 미사용으로 보고되므로 주석이 일을 한다 — 불필요로
/// 보고되면 안 되고 미사용 목록에도 나타나면 안 된다.
// cartograph:ignore
struct IgnoredAndDead {
    func neverCalled() {}
}

/// 무시가 붙은 선언들을 실제로 쓰는 자리.
public func exerciseIgnoreCommentShapes() {
    IgnoredButUsed().ping()
    FileIgnoredButUsed().ping()
}
