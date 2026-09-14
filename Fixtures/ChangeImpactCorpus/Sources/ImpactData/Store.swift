/// 구현체 참조 없이 요구사항을 호출하는 실제 컴파일러 관계를 검증한다.
public protocol Store {
    func read() -> String
}
