// 프로토콜 요구사항 호출은 요구사항에서 구현과 기본 구현으로 역방향 디스패치된다.
// existential 과 generic 호출을 실제로 컴파일해, 요구사항 정점을 살리는 방향을 고정한다.
protocol LiveDefaultRequirement {
    func render() -> Int
}

extension LiveDefaultRequirement {
    func render() -> Int { defaultRenderHelper() }
    func defaultRenderHelper() -> Int { 1 }
}

struct LiveDefaultValue: LiveDefaultRequirement {}

func invokeExistential(_ value: any LiveDefaultRequirement) -> Int {
    value.render()
}

func invokeGeneric<T: LiveDefaultRequirement>(_ value: T) -> Int {
    value.render()
}

// 구체 타입의 메서드를 직접 부르는 경우다. 이 호출만으로 프로토콜 요구사항이나
// 선택되지 않은 기본 구현까지 살아나면, 아래 두 선언과 기본 구현의 도우미가 오탐으로
// 보존된다.
protocol ConcreteDispatchRequirement {
    func run() -> Int
}

extension ConcreteDispatchRequirement {
    func run() -> Int { concreteDefaultHelper() }
    func concreteDefaultHelper() -> Int { 2 }
}

struct LiveConcreteWitness: ConcreteDispatchRequirement {
    func run() -> Int { concreteWitnessHelper() }
    func concreteWitnessHelper() -> Int { 3 }
}

// 정적 타입의 기본 메서드와 동적 타입의 오버라이드는 양쪽 방향을 모두 보존해야 한다.
class DispatchBase {
    func execute() -> Int { baseHelper() }
    func baseHelper() -> Int { 4 }
}

class LiveDispatchSubclass: DispatchBase {
    override func execute() -> Int { subclassHelper() }
    func subclassHelper() -> Int { 5 }
}

func invokeClassVirtually() -> Int {
    let value: DispatchBase = LiveDispatchSubclass()
    return value.execute()
}

// 외부 타입의 익스텐션에서 외부 순수 Swift 프로토콜을 만족하는 증인이다. 인덱스에는
// Array와 Identifiable의 정점이 없을 수 있으므로, 소유자를 확인할 수 없는 경우에도
// 프레임워크가 요구하는 프로퍼티를 보존해야 한다.
extension Array: @retroactive Identifiable {
    public var id: Int { unknownExternalWitnessHelper() }
}

func unknownExternalWitnessHelper() -> Int { 6 }

// 자식이 요구사항을 다시 선언해도 부모 익스텐션의 기본 구현을 사용할 수 있다.
// 구체 증인 → 요구사항과 달리 요구사항 → 부모 요구사항은 실제 계약 사용이다.
protocol ParentRefinementRequirement {
    func refinedValue() -> Int
    static func refinedStaticValue() -> Int
}

extension ParentRefinementRequirement {
    func refinedValue() -> Int { inheritedDefaultHelper() }
    static func refinedStaticValue() -> Int { inheritedStaticDefaultHelper() }
}

func inheritedDefaultHelper() -> Int { 7 }
func inheritedStaticDefaultHelper() -> Int { 8 }

protocol ChildRefinementRequirement: ParentRefinementRequirement {
    func refinedValue() -> Int
    static func refinedStaticValue() -> Int
}

struct RefinedDefaultValue: ChildRefinementRequirement {}

func invokeRefinedExistential(_ value: any ChildRefinementRequirement) -> Int {
    value.refinedValue()
}

func invokeRefinedGeneric<T: ChildRefinementRequirement>(_ value: T) -> Int {
    value.refinedValue() + T.refinedStaticValue()
}

/// 실제 인덱스에 프로토콜·클래스 디스패치 모양을 남긴다.
public func exerciseProtocolDispatchShapes() {
    let value = LiveDefaultValue()
    let existential: any LiveDefaultRequirement = value
    _ = invokeExistential(existential)
    _ = invokeGeneric(value)
    _ = LiveConcreteWitness().run()
    _ = invokeClassVirtually()
    _ = invokeRefinedExistential(RefinedDefaultValue())
    _ = invokeRefinedGeneric(RefinedDefaultValue())
}
