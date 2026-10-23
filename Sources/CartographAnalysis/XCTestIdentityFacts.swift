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

        let extensionOwners = Self.compilerExtensionOwners(snapshot: snapshot, symbols: symbols, classes: classes)
        var methods: Set<String> = []
        var uncertain: Set<String> = []
        for symbol in symbols.values where !symbol.isExternal {
            let marked = symbol.compilerUnitTest == true || symbol.attributes.contains(.unitTest)
            if symbol.kind == .method, symbol.compilerUnitTest == true,
               let parent = symbol.parentUSR,
               classes.contains(extensionOwners[parent] ?? parent),
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

    /// 확장의 표시 이름이나 구문 관계를 소유자 증명으로 쓰지 않는다. 충돌한 대상은 임의 선택하지 않는다.
    private static func compilerExtensionOwners(
        snapshot: IndexSnapshot, symbols: [String: IndexedSymbol], classes: Set<String>
    ) -> [String: String] {
        var targets: [String: Set<String>] = [:]
        var compilerSources: Set<String> = []
        for reference in snapshot.references where reference.kind == .extends {
            guard let source = symbols[reference.sourceUSR], !source.isExternal,
                  source.kind == .extensionDeclaration else { continue }
            targets[reference.sourceUSR, default: []].insert(reference.targetUSR)
            if [.compiler, .compilerAndSyntax].contains(reference.origin) {
                compilerSources.insert(reference.sourceUSR)
            }
        }
        var owners: [String: String] = [:]
        for (source, candidates) in targets where compilerSources.contains(source) && candidates.count == 1 {
            guard let target = candidates.first, classes.contains(target) else { continue }
            owners[source] = target
        }
        return owners
    }
}
