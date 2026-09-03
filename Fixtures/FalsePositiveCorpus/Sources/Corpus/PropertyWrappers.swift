import SwiftUI

/// 투영값으로만 읽는 상태.
///
/// 직접 만든 프로퍼티 래퍼로는 재현되지 않는다. 컴파일러가 `$name` 을 별도 심볼로
/// 내보내는 것은 SwiftUI 의 `@State` 같은 경우뿐이라, 그 구조를 확인하려면
/// 진짜 SwiftUI 가 필요하다. 실측 빌드 비용은 7초라 감수할 만하다.
public struct Child: View {
    @Binding var text: String
    public var body: some View { TextField("x", text: $text) }
}

public struct BindingHost: View {
    /// `$` 로만 읽는다. 인덱스에는 `$projectedOnly` 로만 참조가 남는다.
    @State private var projectedOnly: String = ""
    /// 값으로 읽는다.
    @State private var readDirectly: String = ""
    /// 아무도 쓰지 않는다.
    @State private var genuinelyUnusedState: String = ""

    public init() {}

    public var body: some View {
        VStack {
            Child(text: $projectedOnly)
            Text(readDirectly)
        }
    }
}
