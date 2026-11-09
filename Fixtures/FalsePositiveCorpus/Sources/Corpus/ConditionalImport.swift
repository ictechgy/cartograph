import Combine

// 무조건 import 한 모듈을 다른 플랫폼의 `#if` 분기에서만 쓴다. macOS 인덱스에는 사용 흔적이 없어 unused-import 로
// 보이지만, `fix --apply` 가 지우면 iOS 빌드가 깨진다. 이 파일에는 일부러 다른 선언을 두지 않는다 — 미사용 목록과
// fix 계획이 바뀌지 않아야, 판정을 되돌렸을 때 fix 계획에 이 import 가 나타나는 것으로 회귀가 드러난다.
#if os(iOS)
func corpusIOSOnlyTicker() -> AnyPublisher<Int, Never> {
    Just(1).eraseToAnyPublisher()
}
#endif
