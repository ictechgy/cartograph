import Foundation
import ImpactData
import Testing

@Test("문자열로 등록된 Objective-C 런타임 클래스를 실제로 찾는다")
func resolvesRuntimeController() throws {
    let resolved = try #require(resolveRuntimeController())
    #expect(NSStringFromClass(resolved) == "CartographRuntimeController")
}
