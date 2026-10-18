import CartographCore

/// 보존 표식과 구분한 XCTest 신원 근거다. 실행 관측이나 안전한 테스트 생략을 뜻하지 않는다.
/// SDK 정점이 그래프에서 빠져도 원시 상속 관계를 사용하며, 다른 플랫폼의 USR은 추측하지 않는다.
public struct XCTestIdentityFacts: Sendable, Equatable {
    /// 실제 수집한 XCTestCase USR까지 상속 경로가 이어지는 프로젝트 클래스.
    public let classUSRs: Set<String>
    /// 확인한 XCTest 소유자와 컴파일러 테스트 표식을 모두 가진 인자 없는 테스트 메서드.
    public let methodUSRs: Set<String>
    /// 보존 후보지만 위 근거가 부족한 선언. 호출부는 이를 안전한 생략으로 해석하면 안 된다.
    public let uncertainUSRs: Set<String>

    public init(snapshot: IndexSnapshot) {
        let symbols = snapshot.symbolsByUSR()
        var subclasses: [String: Set<String>] = [:]
        for reference in snapshot.references where reference.kind == .inheritance {
            // 옛 문서의 출처 누락은 허용하되 구문·추론으로 만든 관계는 증명으로 올리지 않는다.
            guard [.compiler, .compilerAndSyntax, .unknown].contains(reference.origin),
                  symbols[reference.sourceUSR]?.kind == .classType else { continue }
            subclasses[reference.targetUSR, default: []].insert(reference.sourceUSR)
        }
        // Swift 6.3.3 macOS 컴파일러 픽스처에서 직접 관찰한 SDK 신원이다.
        var pending = ["c:objc(cs)XCTestCase"]
        var seen = Set(pending)
        var classes: Set<String> = []
        var index = 0
        while index < pending.count {
            let current = pending[index]
            index += 1
            for child in subclasses[current] ?? [] where seen.insert(child).inserted {
                pending.append(child)
                if symbols[child]?.isExternal == false { classes.insert(child) }
            }
        }

        var methods: Set<String> = []
        var uncertain: Set<String> = []
        for symbol in symbols.values where !symbol.isExternal {
            let marked = symbol.compilerUnitTest == true || symbol.attributes.contains(.unitTest)
            if symbol.kind == .method, symbol.compilerUnitTest == true,
               let owner = symbol.parentUSR, classes.contains(owner),
               symbol.name.hasPrefix("test"), symbol.name.hasSuffix("()"),
               !symbol.name.dropLast(2).contains("("), !symbol.attributes.contains(.generic) {
                methods.insert(symbol.usr)
            } else if marked && !classes.contains(symbol.usr) {
                uncertain.insert(symbol.usr)
            }
        }
        classUSRs = classes
        methodUSRs = methods
        uncertainUSRs = uncertain
    }
}
