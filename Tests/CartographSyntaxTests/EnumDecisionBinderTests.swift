import CartographCore
@testable import CartographSyntax
import Testing

@Suite("enum 결정의 컴파일러 위치 결합")
struct EnumDecisionBinderTests {
    private let path = "/p/Decisions.swift"
    private let source = """
    enum Status { case a, b }
    func f(_ status: Status) -> Bool {
        switch status {
        case .a: return true
        default: return [Status.a, .b].contains(status)
        }
    }
    """

    @Test("같은 결정의 토큰과 타입만 결합하고 default 위치를 보존한다")
    func exactDecisionBindings() throws {
        let (facts, snapshot) = try fixture()
        let file = try bind(facts, snapshot)
        #expect(file.status == "fresh")
        #expect(file.inventories.first?.complete == true)
        #expect(file.decisions.count == 2)
        #expect(file.decisions.allSatisfy { $0.status == "resolved" && $0.enumUSR == "Status" },
            "\(file.decisions.map(\.limitations))")
        let raw = try #require(facts.enumDecisionFacts?.decisions.first { $0.kind == .switchDefault })
        let bound = try #require(file.decisions.first { $0.kind == .switchDefault })
        #expect(raw.fallbackLocations.allSatisfy { bound.evidenceLocations.contains($0) })
    }

    @Test("잘못된 열이나 추론 참조로는 enum case를 결합하지 않는다")
    func exactCompilerOccurrencesRequired() throws {
        let (facts, snapshot) = try fixture()
        for origin in [ReferenceOrigin.compiler, .inferred, .unknown] {
            var changed = snapshot
            changed.references = snapshot.references.map { reference in
                guard reference.targetUSR.hasPrefix("Status.") else { return reference }
                let location = reference.location.map {
                    CartographCore.SourceLocation(path: $0.path, line: $0.line, column: $0.column + (origin == .compiler ? 1 : 0))
                }
                return .init(sourceUSR: reference.sourceUSR, targetUSR: reference.targetUSR,
                    kind: reference.kind, location: location, origin: origin)
            }
            let result = try bind(facts, changed)
            #expect(result.decisions.allSatisfy { $0.status == "unresolved" })
            #expect(result.decisions.allSatisfy { $0.limitations.contains("unbound-decision-case") })
        }
    }

    @Test("subject 타입이 다르거나 파라미터 근거가 없으면 switch도 미해결이다")
    func subjectTypeMustAgree() throws {
        let (facts, snapshot) = try fixture()
        var missing = snapshot
        missing.parameters = []
        let noParameter = try bind(facts, missing)
        #expect(noParameter.decisions.allSatisfy { $0.status == "unresolved" })
        #expect(noParameter.decisions.first?.limitations.contains("unverified-switch-subject-type") == true)
        var mismatch = snapshot
        mismatch.symbols.append(.init(usr: "Other", name: "Other", kind: .enumType, module: "App",
            location: .init(path: path, line: 20, column: 1)))
        mismatch.references = mismatch.references.map { ref in
            guard ref.targetUSR == "Status" else { return ref }
            return .init(sourceUSR: ref.sourceUSR, targetUSR: "Other", kind: ref.kind, location: ref.location, origin: ref.origin)
        }
        #expect(try bind(facts, mismatch).decisions.allSatisfy {
            $0.status == "unresolved" && $0.enumUSR == nil
        })
    }

    @Test("사용자 contains는 위치와 case 근거를 남기되 지원 후보로 승격하지 않는다")
    func customTargetRemainsUnresolved() throws {
        let (facts, snapshot) = try fixture()
        var custom = snapshot
        custom.references = snapshot.references.map { reference in
            guard reference.kind == .call else { return reference }
            return .init(sourceUSR: reference.sourceUSR, targetUSR: "custom.contains",
                kind: .call, location: reference.location, origin: reference.origin)
        }
        let decision = try #require(bind(facts, custom).decisions.first { $0.kind == .literalMembership })
        #expect(decision.status == "unresolved")
        #expect(decision.enumUSR == "Status")
        #expect(decision.explicitCaseUSRs == ["Status.a", "Status.b"])
        #expect(decision.operationTargetUSRs == ["custom.contains"])
        #expect(decision.limitations.contains("unsupported-or-unresolved-membership-target"))
    }

    @Test("결합 못 한 선언과 낡은 파일은 완전한 빈 수집으로 보이지 않는다")
    func coverageFailuresAreExplicit() throws {
        let (facts, snapshot) = try fixture()
        var missing = snapshot
        missing.symbols.removeAll { $0.usr == "Status" }
        let file = try bind(facts, missing)
        #expect(file.status == "partial")
        #expect(file.limitations.contains("unbound-enum-declaration"))
        let stale = try #require(EnumDecisionBinder.bind(snapshot: snapshot, files: [path: facts],
            freshPaths: [])?.first)
        #expect(stale.status == "unverifiedFreshness")
        #expect(stale.inventories.allSatisfy { !$0.complete })
        #expect(stale.decisions.allSatisfy { $0.status == "unresolved" })
    }

    @Test("결정이 묻지 않는 자리의 심볼·참조·매개변수는 색인하지 않아 무관한 행이 늘어도 색인 크기가 같다")
    func indexesOnlyQueriedLocations() throws {
        // 프로젝트 전체 참조를 위치마다 묶으면 참조 100만 개에서 바인더 하나가 0.5초와 0.4GB 를 더 썼다.
        let (facts, snapshot) = try fixture()
        var plain = 0
        var padded = 0
        let expected = EnumDecisionBinder.bind(snapshot: snapshot, files: [path: facts], freshPaths: [path],
            onIndexedRows: { plain = $0 })
        let result = EnumDecisionBinder.bind(snapshot: noisy(snapshot), files: [path: facts], freshPaths: [path],
            onIndexedRows: { padded = $0 })
        #expect(result == expected)
        #expect(plain > 0)
        #expect(padded == plain)
    }

    @Test("결정과 목록이 하나도 없으면 스냅샷을 색인하지 않는다")
    func skipsIndexWithoutDecisions() throws {
        let (_, snapshot) = try fixture()
        let facts = SwiftSyntaxAnalyzer().analyze(source: "func plain() -> Int { 1 }", path: path)
        var indexed: Int?
        let result = try #require(EnumDecisionBinder.bind(snapshot: noisy(snapshot), files: [path: facts],
            freshPaths: [path], onIndexedRows: { indexed = $0 })?.first)
        #expect(result.inventories.isEmpty && result.decisions.isEmpty)
        #expect(indexed == 0)
    }

    /// 결정과 무관한 다른 파일의 심볼·컴파일러 참조·매개변수를 더한다.
    private func noisy(_ snapshot: IndexSnapshot) -> IndexSnapshot {
        var result = snapshot
        for index in 0..<200 {
            let location = CartographCore.SourceLocation(path: "/p/Other\(index % 7).swift", line: index + 1, column: 3)
            result.symbols.append(IndexedSymbol(usr: "noise\(index)", name: "noise\(index)()", kind: .function,
                module: "App", location: location))
            result.references.append(IndexedReference(sourceUSR: "noise\(index)", targetUSR: "Status",
                kind: .reference, location: location, origin: .compiler))
            result.parameters.append(IndexedParameter(usr: "noise\(index).value", name: "value", module: "App",
                location: location, functionUSR: "noise\(index)"))
        }
        return result
    }

    private func bind(_ facts: SourceFileFacts, _ snapshot: IndexSnapshot) throws -> EnumImpactFileFacts {
        try #require(EnumDecisionBinder.bind(snapshot: snapshot, files: [path: facts], freshPaths: [path])?.first)
    }

    private func fixture() throws -> (SourceFileFacts, IndexSnapshot) {
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        let scan = try #require(facts.enumDecisionFacts)
        let inventory = try #require(scan.inventories.first)
        let parameter = try #require(scan.decisions.first?.subjectParameter)
        let symbols = [
            IndexedSymbol(usr: "Status", name: "Status", kind: .enumType, module: "App",
                location: inventory.nameLocation),
            IndexedSymbol(usr: "f", name: "f(_:)", kind: .function, module: "App",
                location: parameter.functionRange.start),
        ] + inventory.cases.map {
            IndexedSymbol(usr: "Status.\($0.name)", name: $0.name, kind: .enumCase, module: "App",
                location: $0.location, parentUSR: "Status")
        }
        var references: [IndexedReference] = [
            .init(sourceUSR: "f", targetUSR: "Status", kind: .reference, location: parameter.typeNameLocation, origin: .compiler),
        ]
        for decision in scan.decisions {
            references += (decision.explicitCases + decision.guardedCases).map {
                .init(sourceUSR: "f", targetUSR: "Status.\($0.name)", kind: .reference, location: $0.location, origin: .compiler)
            }
            if let operation = decision.operationLocation {
                references.append(.init(sourceUSR: "f", targetUSR: "s:STsSQ7ElementRpzrlE8containsySbABF",
                    kind: .call, location: operation, origin: .compiler))
            }
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: references, parameters: [
            .init(usr: "parameter", name: parameter.parameterName, module: "App",
                location: parameter.parameterNameLocation, functionUSR: "f"),
        ])
        let verified = try bind(facts, snapshot)
        try #require(verified.decisions.count == 2 && verified.decisions.allSatisfy {
            $0.status == "resolved" && $0.enumUSR == "Status"
        }, "\(verified.decisions.map(\.limitations))")
        return (facts, snapshot)
    }
}
