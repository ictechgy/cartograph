/// 재현 가능한 난수 생성기.
///
/// 무작위 입력으로 알고리즘을 검증할 때, 실패한 케이스를 다시 만들 수 없으면
/// 그 테스트는 디버깅에 쓸모가 없다. 시드를 고정해 항상 같은 순서를 만든다.
/// splitmix64 를 쓴다. 짧고, 낮은 비트까지 고르게 섞인다.
public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
