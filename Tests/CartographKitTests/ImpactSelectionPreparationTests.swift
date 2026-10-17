import CartographAnalysis
import CartographCore
@testable import CartographKit
import Testing

@Suite("영향 선택의 이름 색인 준비")
struct ImpactSelectionPreparationTests {
    @Test("파일·리소스 선택은 큰 무관 그래프에서도 이름 색인을 만들지 않고 선택과 오류를 보존한다")
    func fileAndArtifactSelectionsSkipNameIndex() {
        for noiseCount in [0, 20_000] {
            let graph = Self.graph(noiseCount: noiseCount)
            var builds = 0
            let makeIndex: (CodeGraph) -> GraphQueryIndex = {
                builds += 1
                return GraphQueryIndex(graph: $0)
            }
            let selection = ImpactSelection(
                symbols: [], files: ["Selected.swift", "./Selected.swift", "UI.storyboard", "Missing.swift"],
                projectPath: "/p", graph: graph,
                artifactTargets: ["/p/UI.storyboard": ["outside"]], makeQueryIndex: makeIndex
            )

            #expect(builds == 0)
            #expect(selection.requestedSymbolCount == 0)
            #expect(selection.selected == ["owner", "direct", "outside"])
            #expect(selection.nodes == ["owner", "member", "direct", "outside"])
            #expect(selection.files == ["/p/Missing.swift", "/p/Selected.swift", "/p/UI.storyboard"])
            #expect(selection.status == "incomplete")
            #expect(selection.issues == [
                .init(requested: "/p/Missing.swift", kind: "file", status: "unindexed", candidates: nil),
            ])

            let artifact = ImpactSelection(
                symbols: [], files: ["UI.storyboard"], projectPath: "/p", graph: graph,
                artifactTargets: ["/p/UI.storyboard": ["outside"]], makeQueryIndex: makeIndex
            )
            #expect(builds == 0)
            #expect(artifact.selected == ["outside"] && artifact.nodes == ["outside"])
            #expect(artifact.status == "found" && artifact.issues.isEmpty)
            #expect(artifact.files == ["/p/UI.storyboard"] && artifact.requestedSymbolCount == 0)

            // 계측 closure가 실제 이름 색인 생성도 세는지 양성 대조한다.
            // 전수 파일 선택 비용은 남는다. 0회 주장은 이름 색인 준비에만 해당한다.
            let eagerIndex = makeIndex(graph)
            #expect(builds == 1)
            #expect(eagerIndex.resolve("Owner") == .found(graph.node("owner")!))
        }
    }

    @Test("빈 입력은 이름 색인 없이 noChanges와 기존 선택 문제를 구별한다")
    func emptySelectionPreservesStatusAndIssues() {
        let graph = Self.graph()
        var builds = 0
        let makeIndex: (CodeGraph) -> GraphQueryIndex = {
            builds += 1
            return GraphQueryIndex(graph: $0)
        }
        let empty = ImpactSelection(
            symbols: [], files: [], projectPath: "/p", graph: graph, makeQueryIndex: makeIndex
        )
        #expect(empty.status == "noChanges")
        #expect(empty.selected.isEmpty && empty.nodes.isEmpty && empty.files.isEmpty && empty.issues.isEmpty)
        #expect(empty.requestedSymbolCount == 0)

        let issue = ImpactDocument.SelectionIssue(
            requested: "route", kind: "runtimeContract", status: "missingTarget", candidates: nil
        )
        let incomplete = ImpactSelection(
            symbols: [], files: [], projectPath: "/p", graph: graph,
            extraIssues: [issue], makeQueryIndex: makeIndex
        )
        #expect(incomplete.status == "incomplete")
        #expect(incomplete.selected.isEmpty && incomplete.nodes.isEmpty && incomplete.files.isEmpty)
        #expect(incomplete.issues == [issue])
        #expect(incomplete.requestedSymbolCount == 0)
        #expect(builds == 0)
    }

    @Test("여러 심볼과 파일을 함께 골라도 실제 해석기를 한 번 만들고 모호함·누락을 보존한다")
    func symbolAndMixedSelectionsBuildOneRealIndex() {
        let graph = Self.graph()
        let missing = String(repeating: "x", count: 300)
        for files in [[], ["Selected.swift"]] {
            var builds = 0
            let selection = ImpactSelection(
                symbols: ["Owner", "duplicate", missing, "member", "Owner"],
                files: files, projectPath: "/p", graph: graph,
                makeQueryIndex: {
                    builds += 1
                    return GraphQueryIndex(graph: $0)
                }
            )
            #expect(builds == 1)
            #expect(selection.requestedSymbolCount == 5)
            let expected: Set<NodeID> = files.isEmpty ? ["owner", "member"] : ["owner", "member", "direct"]
            #expect(selection.selected == expected)
            #expect(selection.nodes == expected)
            #expect(selection.files == (files.isEmpty ? [] : ["/p/Selected.swift"]))
            #expect(selection.status == "incomplete")
            #expect(selection.issues.map(\.requested) == ["duplicate", missing])
            #expect(selection.issues.map(\.kind) == ["symbol", "symbol"])
            #expect(selection.issues.map(\.status) == ["ambiguous", "notFound"])
            #expect(selection.issues.first?.candidates?.compactMap(\.usr) == ["direct", "outside"])
            #expect(selection.issues.last?.candidates == nil)
            #expect(selection.issues.allSatisfy { $0.candidatesOmitted == nil })
        }
    }

    private static func graph(noiseCount: Int = 0) -> CodeGraph {
        let rows: [(String, String, SymbolKind, String)] = [
            ("owner", "Owner", .structType, "/p/Selected.swift"),
            ("member", "member", .method, "/p/Member.swift"),
            ("direct", "duplicate", .function, "/p/Selected.swift"),
            ("outside", "duplicate", .function, "/p/Else.swift"),
        ]
        let nodes = rows.map { id, name, kind, path in
            GraphNode(id: NodeID(id), name: name, kind: kind, usr: id,
                location: CartographCore.SourceLocation(path: path, line: 1, column: 1))
        } + (0..<noiseCount).map {
            GraphNode(id: NodeID("noise-\($0)"), name: "Noise\($0)", kind: .function,
                location: CartographCore.SourceLocation(path: "/p/Noise.swift", line: $0 + 1, column: 1))
        }
        return CodeGraph(level: .symbol, nodes: nodes, edges: [
            GraphEdge(source: "owner", target: "member", kind: .member),
        ])
    }
}
