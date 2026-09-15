/// 소스에서 증명한 지역 함수를 컴파일러 USR과 구분하는 그래프 식별자 규칙.
public enum SourceLocalSymbol {
    /// 합성 키임을 감추지 않고 질의에 다시 사용할 수 있도록 별도 이름 공간을 쓴다.
    public static func identifier(ownerUSR: String, location: SourceLocation, name: String) -> String {
        "cartograph:local-function:\(ownerUSR):\(location.line):\(location.column):\(name)"
    }

    /// 인덱스가 직접 제공한 선언과 소스 보완 선언을 구분한다.
    public static func contains(_ usr: String) -> Bool {
        usr.hasPrefix("cartograph:local-function:")
    }
}
