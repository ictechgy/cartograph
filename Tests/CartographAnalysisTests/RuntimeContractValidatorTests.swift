import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("런타임 계약 검증")
struct RuntimeContractValidatorTests {
    private func graph(_ build: (inout SnapshotBuilder) -> Void) -> CodeGraph {
        var builder = SnapshotBuilder()
        build(&builder)
        return GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())
    }

    @Test("모든 시나리오가 올바르게 관측되면 실행된 계약으로 표시한다")
    func allScenariosObserved() {
        let graph = graph { builder in
            builder.symbol("Router.open", name: "open", kind: .function, module: "App")
            builder.symbol("Settings.open", name: "open", kind: .function, module: "App")
        }
        let contract = RuntimeContract(
            id: "settings.route", source: "Router.open", target: "Settings.open",
            mechanism: .callback, requiredScenarios: ["happy", "fallback"], expectedValue: "ok"
        )
        let observations = [
            RuntimeObservation(contract: "settings.route", scenario: "fallback", outcome: .observed, value: "ok"),
            RuntimeObservation(contract: "settings.route", scenario: "happy", outcome: .observed, value: "ok"),
        ]

        let result = RuntimeContractValidator().validate(
            contracts: [contract], observations: observations, in: graph
        ).results[0]
        #expect(result.status == .observed)
        #expect(result.observedScenarios == ["fallback", "happy"])
        #expect(result.missingScenarios.isEmpty)
        #expect(result.failedScenarios.isEmpty)
        #expect(result.source?.id == NodeID("Router.open"))
        #expect(result.target?.id == NodeID("Settings.open"))
    }

    @Test("실패 관측과 잘못된 값은 성공 관측보다 우선한다")
    func failureDominatesSuccessAndValueMismatch() {
        let graph = graph { builder in
            builder.symbol("Target", kind: .function)
        }
        let contract = RuntimeContract(
            id: "target", target: "Target", mechanism: .registration,
            requiredScenarios: ["failed", "wrong", "missing", "duplicate"], expectedValue: "yes"
        )
        let observations = [
            RuntimeObservation(contract: "target", scenario: "failed", outcome: .observed, value: "yes"),
            RuntimeObservation(contract: "target", scenario: "failed", outcome: .failed),
            RuntimeObservation(contract: "target", scenario: "wrong", outcome: .observed, value: "no"),
            RuntimeObservation(contract: "target", scenario: "duplicate", outcome: .observed, value: "yes"),
            RuntimeObservation(contract: "target", scenario: "duplicate", outcome: .failed),
        ]

        let result = RuntimeContractValidator().validate(
            contracts: [contract], observations: observations, in: graph
        ).results[0]
        #expect(result.status == .failed)
        #expect(result.observedScenarios.isEmpty)
        #expect(result.missingScenarios == ["missing"])
        #expect(result.failedScenarios == ["duplicate", "failed", "wrong"])
    }

    @Test("관측 문서가 없으면 선언 상태이고 빈 문서는 미관측 상태다")
    func distinguishesDeclaredFromUnobserved() {
        let graph = graph { $0.symbol("Target", kind: .function) }
        let contract = RuntimeContract(
            id: "target", target: "Target", mechanism: .other, requiredScenarios: ["launch"]
        )
        let validator = RuntimeContractValidator()
        let declared = validator.validate(contracts: [contract], observations: nil, in: graph).results[0]
        let unobserved = validator.validate(contracts: [contract], observations: [], in: graph).results[0]
        #expect(declared.status == .declared)
        #expect(unobserved.status == .unobserved)
        #expect(unobserved.missingScenarios == ["launch"])
    }

    @Test("계획 지문이 오래되면 관측 근거를 적용하지 않는다")
    func staleObservationsAreNotApplied() {
        let graph = graph {
            $0.symbol("Type", kind: .classType)
            $0.symbol("Target", kind: .method, parent: "Type", attributes: [.objc])
        }
        let contract = RuntimeContract(
            id: "target", target: "Target", mechanism: .selector, requiredScenarios: ["launch"]
        )
        let observation = RuntimeObservation(contract: "target", scenario: "launch", outcome: .observed)
        let result = RuntimeContractValidator().validate(
            contracts: [contract], observations: [observation], observationsMatchPlan: false, in: graph
        ).results[0]
        #expect(result.status == .staleObservations)
        #expect(result.observedScenarios.isEmpty)
        #expect(result.failedScenarios.isEmpty)
        #expect(result.missingScenarios == ["launch"])
    }

    @Test("모호한 소스와 타깃은 임의로 고르지 않는다")
    func ambiguousBindingsRemainAmbiguous() {
        let graph = graph { builder in
            builder.symbol("a:Source", name: "Source", module: "A")
            builder.symbol("b:Source", name: "Source", module: "B")
            builder.symbol("a:Target", name: "Target", module: "A")
            builder.symbol("b:Target", name: "Target", module: "B")
        }
        let contracts = [
            RuntimeContract(
                id: "source", source: "Source", target: "a:Target",
                mechanism: .other, requiredScenarios: ["x"]
            ),
            RuntimeContract(
                id: "target", source: "a:Source", target: "Target",
                mechanism: .other, requiredScenarios: ["x"]
            ),
        ]
        let results = RuntimeContractValidator().validate(contracts: contracts, in: graph).results
        #expect(results[0].status == .ambiguousSource)
        #expect(results[0].sourceCandidates.count == 2)
        #expect(results[1].status == .ambiguousTarget)
        #expect(results[1].targetCandidates.count == 2)
    }

    @Test("삭제되거나 아직 인덱싱되지 않은 선언은 결손으로 구분한다")
    func missingBindingsAreExplicit() {
        let graph = graph { $0.symbol("Source", kind: .function) }
        let contracts = [
            RuntimeContract(
                id: "source", source: "GoneSource", target: "Source",
                mechanism: .other, requiredScenarios: ["x"]
            ),
            RuntimeContract(
                id: "target", source: "Source", target: "GoneTarget",
                mechanism: .other, requiredScenarios: ["x"]
            ),
        ]
        let results = RuntimeContractValidator().validate(contracts: contracts, in: graph).results
        #expect(results[0].status == .missingSource)
        #expect(results[1].status == .missingTarget)
    }

    @Test("알 수 없는 계약 ID를 정렬해 별도로 보고한다")
    func unknownObservationIDsAreReported() {
        let graph = graph { $0.symbol("Target", kind: .function) }
        let contract = RuntimeContract(id: "known", target: "Target", mechanism: .bridge, requiredScenarios: ["x"])
        let observations = [
            RuntimeObservation(contract: "zeta", scenario: "x", outcome: .observed),
            RuntimeObservation(contract: "alpha", scenario: "x", outcome: .failed),
        ]
        let report = RuntimeContractValidator().validate(contracts: [contract], observations: observations, in: graph)
        #expect(report.unexpectedContracts == ["alpha", "zeta"])
        #expect(report.results[0].status == .unobserved)
        #expect(report.results[0].missingScenarios == ["x"])
    }

    @Test("freshness가 없으면 타깃 관측을 미검증으로 남긴다")
    func unknownFreshnessRemainsUnverified() {
        let graph = graph { $0.symbol("Target", kind: .function) }
        let contract = RuntimeContract(
            id: "target", target: "Target", mechanism: .other, requiredScenarios: ["launch"]
        )
        let observation = RuntimeObservation(contract: "target", scenario: "launch", outcome: .observed)
        let result = RuntimeContractValidator().validate(
            contracts: [contract],
            observations: [observation],
            freshness: [:],
            in: graph
        ).results[0]

        #expect(result.status == .unverifiedTarget)
        #expect(result.targetFreshness == .unknownIndexDate)
        #expect(result.observedScenarios.isEmpty)
    }

    @Test("selector와 classLookup는 그래프가 보장할 수 없는 대상을 invalidMechanism으로 남긴다")
    func rejectsImpossibleMechanisms() {
        let graph = graph {
            $0.symbol("Type", kind: .structType)
            $0.symbol("Plain", name: "plain()", kind: .method, parent: "Type")
            $0.symbol("Value", kind: .structType)
        }
        let contracts = [
            RuntimeContract(
                id: "selector", target: "Plain", mechanism: .selector, requiredScenarios: ["launch"]
            ),
            RuntimeContract(
                id: "class", target: "Value", mechanism: .classLookup, requiredScenarios: ["launch"]
            ),
        ]

        let results = RuntimeContractValidator().validate(contracts: contracts, in: graph).results

        #expect(results.allSatisfy { $0.status == .invalidMechanism })
    }

    @Test("selector는 ObjCMembers나 ObjC 노출을 요구하고 Swift dynamic만으로 허용하지 않는다")
    func acceptsEligibleSelectorTargets() {
        let graph = graph {
            $0.symbol("ObjCType", kind: .classType, attributes: [.objcMembers])
            $0.symbol("ObjCMethod", name: "open()", kind: .method, parent: "ObjCType")
            $0.symbol("DynamicType", kind: .classType)
            $0.symbol("DynamicMethod", name: "open()", kind: .method, parent: "DynamicType",
                      attributes: [.dynamicDispatch])
        }
        let contracts = [
            RuntimeContract(id: "objc", target: "ObjCMethod", mechanism: .selector, requiredScenarios: ["launch"]),
            RuntimeContract(
                id: "dynamic", target: "DynamicMethod",
                mechanism: .selector, requiredScenarios: ["launch"]
            ),
        ]

        let results = RuntimeContractValidator().validate(contracts: contracts, in: graph).results

        #expect(results.first { $0.contractID == "objc" }?.status == .declared)
        #expect(results.first { $0.contractID == "dynamic" }?.status == .invalidMechanism)
    }

    @Test("중복 계약과 빈 시나리오도 순수 검증기를 중단시키지 않는다")
    func invalidContractsBecomeResults() {
        let graph = graph { $0.symbol("Target", kind: .function) }
        let contracts = [
            RuntimeContract(id: "duplicate", target: "Target", mechanism: .other, requiredScenarios: ["x"]),
            RuntimeContract(id: "duplicate", target: "Target", mechanism: .other, requiredScenarios: ["x"]),
            RuntimeContract(id: "empty", target: "Target", mechanism: .other, requiredScenarios: []),
        ]
        let results = RuntimeContractValidator().validate(contracts: contracts, in: graph).results
        #expect(results.allSatisfy { $0.status == .invalidContract })
    }

    @Test("중첩 타입 멤버 이름으로 함수 간 타깃을 해석한다")
    func resolvesCrossFunctionMemberTarget() {
        let graph = graph { builder in
            builder.symbol("Router", kind: .structType)
            builder.symbol("Router.open", name: "open()", kind: .function, parent: "Router")
        }
        let contract = RuntimeContract(
            id: "route", source: "Router.open", target: "Router.open", mechanism: .callback,
            requiredScenarios: ["open"]
        )
        let result = RuntimeContractValidator().validate(contracts: [contract], in: graph).results[0]
        #expect(result.status == .declared)
        #expect(result.source?.id == NodeID("Router.open"))
        #expect(result.target?.id == NodeID("Router.open"))
    }
}
