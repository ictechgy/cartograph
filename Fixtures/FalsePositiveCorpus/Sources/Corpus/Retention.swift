import SwiftUI

// 보존 규칙을 좁히면서 함께 넣은 케이스들이다. 두 방향을 한 파일에 둔다.
// 살아야 하는 것과 보고되어야 하는 것을 나란히 두어야, 규칙을 다시 넓히거나
// 더 좁힐 때 어느 쪽이 깨지는지 한눈에 보인다.

// MARK: - 보고되어야 하는 것

/// 아무도 그리지 않는 뷰.
///
/// 외부 프로토콜 준수가 타입 자신을 살리던 시절에는 침묵했다. `body` 는 프레임워크가
/// 부르므로 계속 보존되지만, 그것이 타입까지 살리지는 않는다.
/// 출처: HealthMap 의 CourseTag·CourseThumbnail 외 3건.
struct DeadCourseCard: View {
    var body: some View { Text("") }
}

/// 준수를 익스텐션으로 쓴, 아무도 그리지 않는 뷰.
///
/// 같은 코드의 두 표기가 반대 답을 내면 판정이 코드가 아니라 작성 취향의 함수가 된다.
struct DeadSplitCard {
    let title: String
}

extension DeadSplitCard: View {
    var body: some View { Text(title) }
}

/// 아무도 만들지 않는 Equatable 열거형.
///
/// 케이스가 개별로 보고되면 소비자가 그것만 지우고 빈 껍데기를 남긴다. 그 껍데기는
/// 합성 선언 때문에 영원히 보고되지 않는다. 타입 자신이 보고되어야 한다.
/// 출처: HealthMap.HealthMapListSectionState.
enum DeadSectionState: Equatable {
    case notLoaded
    case ready(Int)
}

/// 합성 이니셜라이저만 가진, 아무도 만들지 않는 구조체.
/// 출처: HealthMap.NotificationPreferencesController.
struct DeadPreferencesController {
    let gateway: Int
}

// MARK: - 살아야 하는 것

/// 다른 뷰의 body 안에서만 쓰이는 뷰. 보고되면 안 된다.
struct LiveBadge: View {
    var body: some View { Text("live") }
}

/// 위 뷰를 그리는 화면. 진입점이 만든다.
struct LiveScreen: View {
    var body: some View { LiveBadge() }
}

/// 합성 이니셜라이저로만 만들어지는 구조체. 진입점이 만든다.
struct LiveSettings {
    let value: Int
}

/// 열거형 케이스의 연관 값으로만 쓰이는 타입.
///
/// 인덱서가 이 자리의 참조에 관계를 달지 않아, 간선을 위치로 붙이기 전에는
/// 들어오는 간선이 하나도 없었다.
struct LivePayload {
    let n: Int
}

enum LiveEvent {
    case fired(LivePayload)
}

/// 위의 살아야 하는 형태들을 실제로 만드는 사용자.
///
/// 모듈 안에 둔다. 합성 이니셜라이저는 internal 이라 진입점이 직접 부를 수 없고,
/// 명시적 `public init` 을 붙이면 "합성 이니셜라이저만 있는 구조체" 라는 형태 자체가
/// 사라져 이 케이스가 아무것도 확인하지 못하게 된다.
public func exerciseRetentionShapes() {
    _ = LiveScreen()
    _ = LiveSettings(value: 1)
    _ = LiveEvent.fired(LivePayload(n: 1))
}
