/// 참조 위치를 어느 입력에서 얻었는지 알린다. 실행 관측이나 삭제 가능성을 뜻하지 않는다.
public enum ReferenceOrigin: String, Codable, Sendable {
    case compiler
    case syntax
    case compilerAndSyntax
    case inferred
    case graph
    case unknown
}
