import CartographCore
import Foundation
import Testing

@Suite("설정 모델")
struct ConfigurationTests {
    @Test("기본 설정은 빌드 산출물을 제외한다")
    func defaultExcludes() {
        let filter = CartographConfiguration.default.pathFilter
        #expect(!filter.allows("/p/.build/checkouts/Yams/Node.swift"))
        #expect(!filter.allows("/p/Pods/Alamofire/Session.swift"))
        #expect(!filter.allows("/p/Sources/App/API.generated.swift"))
        #expect(filter.allows("/p/Sources/App/Main.swift"))
    }

    @Test("정의되지 않은 레이어를 참조하면 검증에 실패한다")
    func validateRejectsUnknownLayer() {
        var configuration = CartographConfiguration.default
        configuration.layers = [LayerDefinition(name: "Presentation", patterns: ["Features/**"])]
        configuration.rules = [LayerRule(from: "Presentation", deny: ["Data"])]
        #expect(throws: CartographError.self) { try configuration.validate() }
    }

    @Test("정의된 레이어만 참조하면 검증을 통과한다")
    func validateAcceptsKnownLayers() throws {
        var configuration = CartographConfiguration.default
        configuration.layers = [
            LayerDefinition(name: "Presentation", patterns: ["Features/**"]),
            LayerDefinition(name: "Data", patterns: ["Data/**"]),
        ]
        configuration.rules = [LayerRule(from: "Presentation", deny: ["Data"])]
        try configuration.validate()
        #expect(configuration.layer(named: "Data")?.patterns.count == 1)
        #expect(configuration.layer(named: "없음") == nil)
    }

    @Test("JSON 왕복 후에도 설정이 보존된다")
    func codableRoundTrip() throws {
        var configuration = CartographConfiguration.default
        configuration.level = .type
        configuration.edgeKinds = [.call, .conformance]
        configuration.retention.retainPublic = true
        configuration.thresholds = Thresholds(maxCycles: 0, maxInstability: 0.8)
        configuration.layers = [LayerDefinition(name: "Domain", patterns: ["Domain/**"])]
        configuration.rules = [LayerRule(from: "Domain", allow: [])]

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(CartographConfiguration.self, from: data)
        #expect(decoded == configuration)
    }

    @Test("대조 대상을 적지 않은 레이어는 예전과 같은 바이트로 직렬화되고, 적은 레이어는 왕복한다")
    func layerMatchTargetsEncodeOnlyWhenSet() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(LayerDefinition(name: "Domain", patterns: ["Domain/**"]))
        #expect(String(decoding: plain, as: UTF8.self) == #"{"match":["Domain\/**"],"name":"Domain"}"#)

        let narrowed = LayerDefinition(name: "Net", patterns: ["*Network*"], matchTargets: [.path])
        let data = try encoder.encode(narrowed)
        #expect(String(decoding: data, as: UTF8.self) == #"{"match":["*Network*"],"match_on":["path"],"name":"Net"}"#)
        #expect(try JSONDecoder().decode(LayerDefinition.self, from: data) == narrowed)
        #expect(try JSONDecoder().decode(LayerDefinition.self, from: plain).matchTargets == nil)
    }

    @Test("코드로 만든 설정도 대조 대상이 빈 레이어는 검증에서 거부한다")
    func validateRejectsEmptyLayerMatchTargets() {
        // 설정 파일은 디코딩이 막지만, 임베더가 코드로 만든 레이어는 디코더를 거치지 않는다.
        var configuration = CartographConfiguration.default
        configuration.layers = [LayerDefinition(name: "Network", patterns: ["*Network*"], matchTargets: [])]
        #expect {
            try configuration.validate()
        } throws: { error in
            let message = (error as? CartographError)?.errorDescription ?? ""
            return message.contains("layer 'Network'") && message.contains("match_on must list at least one")
        }
        configuration.layers = [LayerDefinition(name: "Network", patterns: ["*Network*"], matchTargets: [.path])]
        #expect(throws: Never.self) { try configuration.validate() }
    }

    @Test("레이어 규칙은 금지 목록을 먼저 본다")
    func denyListTakesPrecedence() {
        let rule = LayerRule(from: "Presentation", allow: ["Domain", "Data"], deny: ["Data"])
        #expect(rule.isViolated(from: "Presentation", to: "Data"))
        #expect(!rule.isViolated(from: "Presentation", to: "Domain"))
    }

    @Test("허용 목록만 있으면 화이트리스트로 동작한다")
    func allowListActsAsWhitelist() {
        let rule = LayerRule(from: "Domain", allow: [])
        #expect(rule.isViolated(from: "Domain", to: "Data"))
        #expect(!rule.isViolated(from: "Data", to: "Domain"))
        #expect(!rule.isViolated(from: "Domain", to: "Domain"))
    }

    @Test("규칙 이름이 없으면 내용으로 만들어 준다")
    func displayNameIsDerived() {
        #expect(LayerRule(from: "A", deny: ["B"]).displayName == "A must not depend on B")
        #expect(LayerRule(from: "A", allow: []).displayName == "A may only depend on nothing")
        #expect(LayerRule(from: "A", allow: ["B"]).displayName == "A may only depend on B")
        #expect(LayerRule(name: "직접 지정", from: "A").displayName == "직접 지정")
        #expect(LayerRule(from: "A").displayName == "A dependency rule")
    }

    @Test("레이어는 여러 후보 문자열 중 하나만 맞으면 된다")
    func layerMatchesAnyCandidate() {
        let layer = LayerDefinition(name: "Presentation", patterns: ["*ViewController", "Features/**"])
        #expect(layer.matches(candidates: ["HomeViewController", "App"]))
        #expect(layer.matches(candidates: ["Whatever", "Features/Home/Home.swift"]))
        #expect(!layer.matches(candidates: ["Domain", "Domain/User.swift"]))
    }
}

@Suite("오류 메시지")
struct CartographErrorTests {
    @Test("인덱스 스토어 부재 오류는 해결 방법을 안내한다")
    func indexStoreNotFoundExplainsRemedy() throws {
        let error = CartographError.indexStoreNotFound(searchedPaths: ["/a", "/b"])
        let description = try #require(error.errorDescription)
        #expect(description.contains("/a"))
        #expect(description.contains("index-store-path"))
        #expect(description.contains("COMPILER_INDEX_STORE_ENABLE"))
    }

    @Test("모든 오류 케이스가 설명을 가진다")
    func allCasesHaveDescriptions() {
        let errors: [CartographError] = [
            .indexStoreNotFound(searchedPaths: []),
            .indexStoreUnreadable(path: "/a", underlying: "boom"),
            .indexStoreLibraryNotFound(searchedPaths: ["/x"]),
            .invalidConfiguration(path: "/c.yml", reason: "bad"),
            .invalidBaseline(path: "/b.json", reason: "bad"),
            .unknownLayer(name: "X", definedLayers: []),
            .thresholdExceeded(rule: "cycles", message: "3 > 0"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
