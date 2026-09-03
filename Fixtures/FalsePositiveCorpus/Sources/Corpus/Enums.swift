/// `allCases` 로만 소비되는 케이스. 지우면 동작이 달라진다.
public enum Mode: CaseIterable {
    case fast
    case slow
}

public func enumerateModes() -> Int { Mode.allCases.count }
