// C-P1-3: 사용자가 보고한 중첩 State 형태를 회사 소스 없이 일반화했다.
final class NeverMadeStore {
    struct State: Equatable { let value: Int }
}

final class NeverMadePlain {
    struct State { let value: Int }
}

final class NeverMadeHashable {
    struct State: Hashable { let value: Int }
}

final class NeverMadeExtension {
    struct State { let value: Int }
}
extension NeverMadeExtension.State: Equatable {}

struct LiveState: Equatable { let value: Int }
struct LiveHashable: Hashable { let value: Int }
struct LiveExtension { let value: Int }
extension LiveExtension: Equatable {}

final class ReferencedContainer {
    struct State: Equatable { let value: Int }
}

func exerciseOwnerConditionedRetention() {
    precondition(LiveState(value: 1) == LiveState(value: 1))
    precondition(Set([LiveHashable(value: 1)]).contains(LiveHashable(value: 1)))
    precondition(LiveExtension(value: 1) == LiveExtension(value: 1))
    precondition(ReferencedContainer.State(value: 1) == ReferencedContainer.State(value: 1))
}
