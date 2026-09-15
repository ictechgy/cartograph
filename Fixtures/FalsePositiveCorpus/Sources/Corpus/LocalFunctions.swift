/// Kingfisher의 handler → failCurrentSource → 속성 참조처럼 인덱스가 지역 소유자를 생략하는 형태.
public func exerciseLocalFunctions() {
    @Sendable func corpusLocalConsumer() {
        corpusLocalTarget()
        _ = CorpusLocalConstructed()
    }
    func corpusLocalHandler() { corpusLocalConsumer() }
    let work = { corpusLocalHandler() }
    work()
}

private func corpusLocalTarget() {}

private struct CorpusLocalConstructed {
    init() {}
}

/// 구분 못한 함수의 이름·위치·진입 사슬 부재를 notFound 응답에서도 확인한다.
public func exerciseLocalDiagnostics() {
    func corpusUnenteredLocal() {}
}
