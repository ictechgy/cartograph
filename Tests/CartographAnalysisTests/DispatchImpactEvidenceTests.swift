import CartographAnalysis
import CartographCore
import Foundation
import Testing

@Suite("수신자 증거를 사용한 제한된 영향 후보")
struct DispatchImpactEvidenceTests {
    let path = "/p/Receiver.swift"

    @Test("동일 self 경로의 final 형제만 제외하고 다형·별칭·다른 객체는 남긴다")
    func refinesFinalSelfOnly() {
        let snapshot = fixture()
        let legacy = run(snapshot, refined: false)
        let refined = run(snapshot)
        #expect(Set(legacy.affected.map(\.node)).contains("s:SiblingCaller"))
        #expect(!Set(refined.affected.map(\.node)).contains("s:SiblingCaller"))
        #expect(Set(refined.affected.map(\.node)).isSuperset(of: [
            "s:ChangedCaller", "s:PolyCaller", "s:NonfinalCaller", "s:AliasCaller", "s:OtherCaller"
        ]))
        #expect(refined.receiverPrecision?.mode == "bounded-final-self")
        #expect(refined.receiverPrecision?.excludedTransitions == 1)
    }

    @Test("같은 선언에 unknown 또는 서로 다른 final 상태가 합류하면 전체 기존 결과를 복구한다")
    func preservesConvergingStates() {
        let cases: [Set<NodeID>] = [["s:Changed.send", "s:Base.shared"], ["s:Changed.send", "s:Sibling.send"]]
        for seeds in cases {
            for reverse in [false, true] {
                var snapshot = fixture()
                if reverse { snapshot.symbols.reverse(); snapshot.references.reverse() }
                let legacy = run(snapshot, seeds: seeds, refined: false)
                let actual = run(snapshot, seeds: seeds)
                #expect(actual.affected == legacy.affected)
                #expect(actual.truncatedByDepth == legacy.truncatedByDepth)
                #expect(actual.receiverPrecision?.mode == "conservative-fallback")
                #expect(actual.receiverPrecision?.reason == "receiver-state-convergence")
                #expect(actual.receiverPrecision?.excludedTransitions == 0)
            }
        }
    }

    @Test("나중에 발견한 unknown 경로를 node 방문 집합 때문에 버리지 않는다")
    func unknownAfterConstrainedVisit() {
        var snapshot = fixture()
        snapshot.references.append(ref("s:Base.shared", "s:Base.other", .call, line: 40))
        for reverse in [false, true] {
            if reverse { snapshot.references.reverse() }
            #expect(run(snapshot).affected == run(snapshot, refined: false).affected)
            #expect(run(snapshot).receiverPrecision?.reason == "receiver-state-convergence")
        }
    }

    @Test("누락·혼합 호출·오래된 소스와 런타임 근거는 정밀도로 숨기지 않는다")
    func unknownEvidenceRemains() {
        var mixed = fixture()
        mixed.references.append(ref("s:SiblingCaller", "s:Base.shared", .call, line: 99))
        #expect(Set(run(mixed).affected.map(\.node)).contains("s:SiblingCaller"))
        #expect(run(fixture(), fresh: []).affected == run(fixture(), refined: false).affected)
        let runtime = [ImpactDependency(source: "s:SiblingCaller", target: "s:Base.shared", contract: "callback")]
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: fixture())
        let report = ImpactAnalyzer().analyze(changing: ["s:Changed.send"], in: graph,
            additionalDependencies: runtime, receiverEvidence: evidence(fixture()))
        #expect(Set(report.affected.map(\.node)).contains("s:SiblingCaller"))
    }

    @Test("예산 초과는 전체 보수적 탐색으로 폴백하고 깊이 제한을 보존한다")
    func budgets() {
        let snapshot = fixture()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ImpactAnalyzer().analyze(changing: ["s:Changed.send"], in: graph,
            receiverEvidence: evidence(snapshot), receiverStateBudget: 1)
        #expect(report.affected == run(snapshot, refined: false).affected)
        #expect(report.receiverPrecision?.reason == "receiver-state-budget")
        let shallow = ImpactAnalyzer().analyze(changing: ["s:Changed.send"], in: graph, maxDepth: 1,
            receiverEvidence: evidence(snapshot))
        #expect(shallow.truncatedByDepth)
        #expect(shallow.affected.allSatisfy { $0.depth == 1 })
    }

    @Test("공유 계약의 반복 투영도 작업 예산에 포함하며 순서와 무관하게 전체 결과를 복구한다")
    func sharedContractTransitionBudget() {
        var snapshot = fixture()
        snapshot.references = []
        snapshot.symbols = snapshot.symbols.filter { ["s:Base", "s:Base.send"].contains($0.usr) }
        var seeds: Set<NodeID> = []
        var owners: [String] = []
        for index in 0..<9 {
            let owner = "s:Final\(index)"
            let method = owner + ".send"
            let caller = "s:Unknown\(index)"
            seeds.insert(NodeID(method))
            owners.append(owner)
            snapshot.symbols += [
                .init(usr: owner, name: "Final\(index)", kind: .classType, module: "Fixture",
                    location: .init(path: path, line: 1, column: 1)),
                .init(usr: method, name: "send()", kind: .method, module: "Fixture",
                    location: .init(path: path, line: 1, column: 1), parentUSR: owner),
                .init(usr: caller, name: "unknown\(index)", kind: .function, module: "Fixture",
                    location: .init(path: path, line: 1, column: 1)),
            ]
            snapshot.references += [ref(method, "s:Base.send", .overrides),
                ref(caller, "s:Base.send", .call, receiver: "s:Base")]
        }
        for freshOwners in [owners, Array(owners.prefix(1))] {
            snapshot.dispatchReceiverFiles = [.init(path: path, finalClassUSRs: freshOwners, selfCalls: [])]
            for reverse in [false, true] {
                if reverse { snapshot.symbols.reverse(); snapshot.references.reverse() }
                let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
                let legacy = ImpactAnalyzer().analyze(changing: seeds, in: graph)
                let actual = ImpactAnalyzer().analyze(changing: seeds, in: graph,
                    receiverEvidence: evidence(snapshot), receiverStateBudget: 18)
                #expect(actual.affected == legacy.affected)
                #expect(actual.receiverPrecision?.reason == "receiver-transition-budget")
                #expect(actual.receiverPrecision?.excludedTransitions == 0)
                #expect(actual.receiverPrecision?.visitedStates == 18)
                #expect(actual.receiverPrecision?.examinedTransitions == 72)
                #expect(actual.receiverPrecision?.transitionBudget == 72)
                let initialOverflow = ImpactAnalyzer().analyze(changing: seeds, in: graph,
                    receiverEvidence: evidence(snapshot), receiverStateBudget: 8)
                #expect(initialOverflow.affected == legacy.affected)
                #expect(initialOverflow.receiverPrecision?.reason == "receiver-state-budget")
                #expect(initialOverflow.receiverPrecision?.examinedTransitions == 0)
            }
        }
    }

    @Test("일반 호출자가 없는 override fanout도 후보 생성 전에 작업 예산에 포함한다")
    func filteredOverrideWorkBudget() {
        var snapshot = fixture()
        snapshot.references = []
        snapshot.symbols = snapshot.symbols.filter { ["s:Base", "s:Base.send"].contains($0.usr) }
        var seeds: Set<NodeID> = []
        var owners: [String] = []
        for index in 0..<100 {
            let owner = "s:Final\(index)"
            let method = owner + ".send"
            seeds.insert(NodeID(method))
            owners.append(owner)
            snapshot.symbols += [
                .init(usr: owner, name: "Final\(index)", kind: .classType, module: "Fixture",
                    location: .init(path: path, line: 1, column: 1)),
                .init(usr: method, name: "send()", kind: .method, module: "Fixture",
                    location: .init(path: path, line: 1, column: 1), parentUSR: owner),
            ]
            snapshot.references.append(ref(method, "s:Base.send", .overrides))
        }
        snapshot.dispatchReceiverFiles = [.init(path: path, finalClassUSRs: owners, selfCalls: [])]
        for reverse in [false, true] {
            if reverse { snapshot.symbols.reverse(); snapshot.references.reverse() }
            let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
            let legacy = ImpactAnalyzer().analyze(changing: seeds, in: graph)
            let actual = ImpactAnalyzer().analyze(changing: seeds, in: graph,
                receiverEvidence: evidence(snapshot), receiverStateBudget: 100)
            #expect(actual.affected == legacy.affected)
            #expect(actual.affected.isEmpty)
            #expect(actual.receiverPrecision?.reason == "receiver-work-budget")
            #expect(actual.receiverPrecision?.examinedTransitions == 0)
            #expect(actual.receiverPrecision?.examinedWork == 3_200)
            #expect(actual.receiverPrecision?.workBudget == 3_200)
        }
    }

    @Test("계약의 extension 소유자 조회도 예산에 넣고 진짜 protocol caller를 보존한다")
    func extensionOwnershipWorkBudget() {
        var nodes = [
            GraphNode(id: "P", name: "P", kind: .protocolType),
            GraphNode(id: "Q", name: "Q", kind: .protocolType),
            GraphNode(id: "Extension", name: "Extension", kind: .extensionDeclaration),
            GraphNode(id: "contract", name: "send()", kind: .method),
            GraphNode(id: "changed", name: "send()", kind: .method),
        ]
        var edges = [
            GraphEdge(source: "Extension", target: "contract", kind: .member),
            GraphEdge(source: "Extension", target: "P", kind: .extends),
            GraphEdge(source: "changed", target: "contract", kind: .overrides),
            GraphEdge(source: "P", target: "contract", kind: .call),
            GraphEdge(source: "Q", target: "contract", kind: .call),
        ]
        for index in 0..<600 {
            let id = NodeID("unrelated\(index)")
            nodes.append(GraphNode(id: id, name: id.rawValue, kind: .method))
            edges.append(GraphEdge(source: "Extension", target: id, kind: .call))
        }
        for reverse in [false, true] {
            if reverse { nodes.reverse(); edges.reverse() }
            let graph = CodeGraph(level: .symbol, nodes: nodes, edges: edges)
            let legacy = ImpactAnalyzer().analyze(changing: ["changed"], in: graph)
            let actual = ImpactAnalyzer().analyze(changing: ["changed"], in: graph,
                receiverEvidence: evidence(IndexSnapshot(symbols: [], references: [])), receiverStateBudget: 4)
            #expect(legacy.affected.map(\.node) == [NodeID("Q")])
            #expect(actual.affected == legacy.affected)
            #expect(actual.receiverPrecision?.reason == "receiver-work-budget")
            #expect(actual.receiverPrecision?.examinedWork == 128)
            #expect(actual.receiverPrecision?.examinedTransitions == 0)
        }
    }

    @Test("저장된 이전 snapshot은 현재 self 증명을 빌리지 않는다")
    func historicalCaptureDropsSourceProof() throws {
        let current = fixture()
        let encoded = try JSONEncoder().encode(current)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("dispatchReceiverFiles"))
        let historical = try JSONDecoder().decode(IndexSnapshot.self, from: encoded)
        #expect(historical.dispatchReceiverFiles == nil)
        #expect(historical.references.contains { $0.receiverTypeUSR == "s:Sibling" })
        #expect(run(historical).affected == run(historical, refined: false).affected)
        #expect(run(current).affected.count < run(historical).affected.count)
    }

    @Test("receiver witness output preserves omitted locations and totals")
    func outputLimits() throws {
        var snapshot = fixture()
        for line in 30...32 {
            snapshot.references.append(ref("s:SiblingCaller", "s:Base.shared", .call, line: line, receiver: "s:Sibling"))
        }
        let precision = try #require(run(snapshot).receiverPrecision)
        let limited = precision.limited(to: 1)
        #expect(limited.excludedTransitions == 1)
        #expect(limited.exclusions?.first?.locations.count == 1)
        #expect(limited.exclusions?.first?.locationsOmitted == 3)
        #expect(limited.truncated)
        #expect(precision.limited(to: 0).exclusionsOmitted == 1)
    }

    private func run(_ snapshot: IndexSnapshot, seeds: Set<NodeID> = ["s:Changed.send"],
                     refined: Bool = true, fresh: Set<String>? = nil) -> ImpactReport {
        ImpactAnalyzer().analyze(changing: seeds,
            in: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            receiverEvidence: refined ? evidence(snapshot, fresh: fresh) : nil)
    }

    private func evidence(_ snapshot: IndexSnapshot, fresh: Set<String>? = nil) -> DispatchImpactEvidence {
        DispatchImpactEvidence(snapshot: snapshot, verifiedSourcePaths: fresh ?? [path])
    }

    private func ref(_ source: String, _ target: String, _ kind: EdgeKind,
                     line: Int = 1, receiver: String? = nil) -> IndexedReference {
        IndexedReference(sourceUSR: source, targetUSR: target, kind: kind,
            location: .init(path: path, line: line, column: 1), origin: .compiler, receiverTypeUSR: receiver)
    }

    private func fixture() -> IndexSnapshot {
        let names = ["Base", "Changed", "Sibling", "Nonfinal", "Changed.send", "Sibling.send", "Base.send",
            "Base.shared", "Base.alias", "Base.other", "ChangedCaller", "SiblingCaller", "PolyCaller",
            "NonfinalCaller", "AliasCaller", "OtherCaller"]
        let symbols = names.map { name in
            IndexedSymbol(usr: "s:" + name, name: name, kind: name.contains(".") ? .method :
                (["Base", "Changed", "Sibling", "Nonfinal"].contains(name) ? .classType : .function),
                module: "Fixture", location: .init(path: path, line: 1, column: 1),
                parentUSR: name.contains(".") ? "s:" + String(name.split(separator: ".")[0]) : nil)
        }
        let references = [
            ref("s:Changed.send", "s:Base.send", .overrides),
            ref("s:Sibling.send", "s:Base.send", .overrides),
            ref("s:Base.shared", "s:Base.send", .call, line: 10, receiver: "s:Base"),
            ref("s:Base.alias", "s:Base.send", .call, line: 11, receiver: "s:Base"),
            ref("s:Base.other", "s:Base.send", .call, line: 12, receiver: "s:Base"),
            ref("s:ChangedCaller", "s:Base.shared", .call, line: 20, receiver: "s:Changed"),
            ref("s:SiblingCaller", "s:Base.shared", .call, line: 21, receiver: "s:Sibling"),
            ref("s:PolyCaller", "s:Base.shared", .call, line: 22, receiver: "s:Base"),
            ref("s:NonfinalCaller", "s:Base.shared", .call, line: 23, receiver: "s:Nonfinal"),
            ref("s:AliasCaller", "s:Base.alias", .call, line: 24, receiver: "s:Sibling"),
            ref("s:OtherCaller", "s:Base.other", .call, line: 25, receiver: "s:Sibling"),
        ]
        return IndexSnapshot(symbols: symbols, references: references, dispatchReceiverFiles: [
            .init(path: path, finalClassUSRs: ["s:Changed", "s:Sibling"], selfCalls: [
                .init(callerUSR: "s:Base.shared", calleeUSR: "s:Base.send",
                    location: .init(path: path, line: 10, column: 1))
            ])
        ])
    }
}
