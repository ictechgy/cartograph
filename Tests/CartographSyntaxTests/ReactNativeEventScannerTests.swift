import CartographCore
import CartographSyntax
import Testing

@Suite("React Native 이벤트 방출")
struct ReactNativeEventScannerTests {
    @Test("조건부 import·확장·가림으로 제외한 소스 범위를 이유로 남긴다")
    func unsupportedScopesAreReported() {
        for (source, expected) in [
            ("#if canImport(React)\nimport React\n#endif", "conditional-import"),
            ("#if canImport(React)\nimport class React.RCTEventEmitter\n#endif", "conditional-import"),
            ("import React\nclass RCTEventEmitter {}", "shadowed-identifiers"),
            ("import React\nextension Events { func f() { sendEvent(withName: \"x\", body: nil) } }", "extension"),
        ] {
            var reasons: [String] = []
            let facts = ReactNativeEventScanner().scan(source: source, path: "/p/Events.swift") { reasons.append($0) }
            #expect(facts.isEmpty)
            #expect(reasons == [expected])
        }
    }

    @Test("조건부 본문의 활성 구성을 추측하지 않고 바깥 방출과 분리한다")
    func conditionalEmissionsRemainUnresolved() {
        var reasons: [String] = []
        let facts = ReactNativeEventScanner().scan(source: """
            import React
            class Events: RCTEventEmitter {
              func notify() {
                sendEvent(withName: "observed", body: nil)
                #if os(watchOS)
                sendEvent(withName: "conditional", body: nil)
                #endif
              }
            }
            """, path: "/p/Events.swift") { reasons.append($0) }
        #expect(facts.map(\.fact.channel) == ["observed"])
        #expect(reasons == ["conditional-compilation"])
    }

    @Test("직접 RCTEventEmitter의 bare와 self 방출에 원본 선언과 이름을 붙인다")
    func literalEmissions() {
        let facts = ReactNativeEventScanner().scan(source: """
            import React
            class Events: RCTEventEmitter {
                func notify() {
                    sendEvent(withName: "ready", body: nil)
                    self.sendEvent(withName: "done", body: nil)
                    other.sendEvent(withName: "unrelated", body: nil)
                }
            }
            """, path: "/p/Events.swift")
        #expect(facts.map(\.fact.channel) == ["ready", "done"])
        #expect(facts.allSatisfy { $0.fact.kind == .eventEmit && $0.fact.target == .reactNative })
        #expect(facts[0].fact.location.line == 4)
        #expect(facts[0].declaration?.indexName == "notify()")
        #expect(facts[0].declaration?.qualifiedName == "Events.notify")
    }

    @Test("동적 이름은 버리지 않고 Expo·다른 타입·중첩 타입은 코어 전역 emitter로 연결하지 않는다")
    func dynamicAndUnrelated() {
        let facts = ReactNativeEventScanner().scan(source: #"""
            import React
            class Events: RCTEventEmitter {
                func notify(name: String) { sendEvent(withName: "event.\(name)", body: nil) }
                struct Nested { func run() { sendEvent(withName: "wrong", body: nil) } }
            }
            class Expo: Module { func run() { sendEvent("wrong", [:]) } }
            class Local { func run() { sendEvent(withName: "wrong", body: nil) } }
            """#, path: "/p/Events.swift")
        #expect(facts.count == 1)
        #expect(facts[0].fact.isDynamic)
        #expect(facts[0].fact.channel?.contains("name") == true)
    }

    @Test("React import 부재와 로컬 RCTEventEmitter 가림은 브리지 근거가 아니다")
    func rejectsMissingImportAndShadowing() {
        let source = "class Events: RCTEventEmitter { func run() { sendEvent(withName: \"wrong\", body: nil) } }"
        #expect(ReactNativeEventScanner().scan(source: source, path: "/p/E.swift").isEmpty)
        #expect(ReactNativeEventScanner().scan(source: "import React\nclass RCTEventEmitter {}\n" + source,
            path: "/p/E.swift").isEmpty)
        #expect(ReactNativeEventScanner().scan(source: "import React\nlet sendEvent = local\n" + source,
            path: "/p/E.swift").isEmpty)
    }
}
