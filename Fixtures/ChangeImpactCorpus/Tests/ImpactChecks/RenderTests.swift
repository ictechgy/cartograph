import ImpactData
import ImpactFeatures
import Testing

@Test("실제 구현을 프로토콜을 통해 호출한다")
func rendersLiveStore() { #expect(render(LiveStore()) == "live") }

@Test("익스텐션 멤버의 소비자를 확인한다")
func rendersExtension() { #expect(renderExtension() == "extension") }
