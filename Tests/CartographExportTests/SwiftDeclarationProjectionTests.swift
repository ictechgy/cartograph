import CartographCore
@testable import CartographExport
import Foundation
import Testing

@Suite("Swift 공유 선언 projection")
struct SwiftDeclarationProjectionTests {
    @Test("명시 primary를 canonical로 고르고 raw graph·alias variant·occurrence를 모두 보존한다")
    func projectsSharedDeclarationsWithoutChangingRawGraph() throws {
        let symbols = [
            symbol("s:Core.Foo", name: "Foo", kind: .structType, module: "Core", line: 1,
                accessibility: .publicLevel, attributes: [.codable]),
            symbol("s:App.Foo", name: "Foo", kind: .structType, module: "App", line: 1,
                accessibility: .internalLevel, attributes: [.objc]),
            symbol("s:Core.Foo.m", name: "m()", kind: .method, module: "Core", line: 2,
                parent: "s:Core.Foo", accessibility: .publicLevel, attributes: [.dynamicDispatch]),
            symbol("s:App.Foo.m", name: "m()", kind: .method, module: "App", line: 2,
                parent: "s:App.Foo", accessibility: .internalLevel, attributes: [.objc]),
            symbol("s:Core.Helper", name: "Helper", kind: .classType, module: "Core", line: 5),
            symbol("s:App.Helper", name: "Helper", kind: .classType, module: "App", line: 5),
            symbol("s:Core.RealAlias", name: "RealAlias", kind: .typeAlias, module: "Core", line: 8),
        ]
        let appReference = IndexedReference(
            sourceUSR: "s:App.Foo.m", targetUSR: "s:App.Helper", kind: .call,
            location: .init(path: "/p/Shared/File.swift", line: 12, column: 7),
            targetKind: .classType, origin: .syntax, position: .body
        )
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            IndexedReference(
                sourceUSR: "s:Core.Foo.m", targetUSR: "s:Core.Helper", kind: .call,
                location: .init(path: "/p/Shared/File.swift", line: 11, column: 7),
                targetKind: .classType, origin: .compiler, position: .body
            ),
            appReference,
            appReference,
        ])
        let result = GraphBuilder(options: .init(level: .symbol)).buildResult(from: snapshot)
        let renderer = SwiftDeclarationProjectionRenderer(prettyPrinted: false)
        let output = try renderer.render(
            result: result, snapshot: snapshot, projectPath: "/p", primaryModule: "Core"
        )
        let repeated = try renderer.render(
            result: result, snapshot: snapshot, projectPath: "/p", primaryModule: "Core"
        )
        #expect(output == repeated)
        let document = try object(output)
        #expect(document["format"] as? String == "cartograph-declaration-projection")
        #expect(document["version"] as? Int == 1)
        #expect(document["level"] as? String == "symbol")

        let rawGraph = try #require(document["rawGraph"] as? [String: Any])
        let rawNodes = try #require(rawGraph["nodes"] as? [[String: Any]])
        #expect(Set(rawNodes.compactMap { $0["id"] as? String }) == Set(symbols.map(\.usr)))
        #expect((rawNodes.first { $0["id"] as? String == "s:App.Foo" }?["location"] as? [String: Any])?["path"]
            as? String == "/p/Shared/File.swift")
        let rawEdges = try #require(rawGraph["edges"] as? [[String: Any]])
        #expect(rawEdges.first { $0["source"] as? String == "s:App.Foo.m" }?["weight"] as? Int == 2)

        let projection = try #require(document["projection"] as? [String: Any])
        let nodes = try #require(projection["nodes"] as? [[String: Any]])
        let method = try #require(nodes.first { $0["id"] as? String == "s:Core.Foo.m" })
        #expect(method["state"] as? String == "merged")
        #expect(method["aliases"] as? [String] == ["s:App.Foo.m"])
        let variants = try #require(method["variants"] as? [[String: Any]])
        #expect(variants.count == 2)
        #expect(variants.first { $0["usr"] as? String == "s:Core.Foo.m" }?["attributes"] as? [String]
            == ["dynamicDispatch"])
        #expect(variants.first { $0["usr"] as? String == "s:App.Foo.m" }?["attributes"] as? [String]
            == ["objc"])
        #expect((variants[0]["location"] as? [String: Any])?["path"] as? String == "Shared/File.swift")

        let alias = try #require(nodes.first { $0["id"] as? String == "s:Core.RealAlias" })
        #expect(alias["state"] as? String == "raw")
        #expect((alias["aliases"] as? [String])?.isEmpty == true)

        let projectedEdges = try #require(projection["edges"] as? [[String: Any]])
        let edge = try #require(projectedEdges.first { $0["source"] as? String == "s:Core.Foo.m" })
        #expect(edge["target"] as? String == "s:Core.Helper")
        #expect(edge["weight"] as? Int == 3)
        #expect((edge["rawEdges"] as? [[String: Any]])?.count == 2)

        let evidence = try #require(document["evidence"] as? [[String: Any]])
        #expect(evidence.count == 3)
        #expect(evidence.filter { $0["sourceUSR"] as? String == "s:App.Foo.m" }.count == 2)
        #expect(evidence.allSatisfy { $0["source"] as? String == "s:Core.Foo.m" })
        #expect((evidence[0]["location"] as? [String: Any])?["path"] as? String == "Shared/File.swift")
        let limitations = try #require(document["limitations"] as? [String])
        #expect(limitations.contains { $0.hasPrefix("conditional-compilation-unverified: 3 ") })
    }

    @Test("primary가 없는 shared group과 parent key가 없는 선언은 raw로 남기고 개수를 알린다")
    func keepsUnresolvedGroupsRaw() throws {
        let symbols = [
            symbol("s:Core.Marker", name: "Marker", kind: .structType, module: "Core", line: 1),
            symbol("s:App.Shared", name: "Shared", kind: .classType, module: "App", line: 3),
            symbol("s:Extension.Shared", name: "Shared", kind: .classType, module: "Extension", line: 3),
            symbol("s:App.child", name: "child()", kind: .method, module: "App", line: 5,
                parent: "s:missing"),
        ]
        let snapshot = IndexSnapshot(symbols: symbols)
        let result = GraphBuilder(options: .init(level: .symbol)).buildResult(from: snapshot)
        let output = try SwiftDeclarationProjectionRenderer(prettyPrinted: false).render(
            result: result, snapshot: snapshot, projectPath: "/p", primaryModule: "Core"
        )
        let document = try object(output)
        let projection = try #require(document["projection"] as? [String: Any])
        let nodes = try #require(projection["nodes"] as? [[String: Any]])
        for usr in ["s:App.Shared", "s:Extension.Shared", "s:App.child"] {
            let node = try #require(nodes.first { $0["id"] as? String == usr })
            #expect(node["state"] as? String == "raw")
            #expect((node["aliases"] as? [String])?.isEmpty == true)
        }
        let limitations = try #require(document["limitations"] as? [String])
        #expect(limitations.contains { $0.hasPrefix("declaration-projection-unresolved: 1 ") })
        #expect(limitations.contains { $0.hasPrefix("declaration-projection-key-unavailable: 1 ") })
    }

    @Test("parent key 깊이 제한은 선언·탐색 순서와 무관하고 경계 밖 variant를 raw로 보존한다")
    func parentKeyDepthIsOrderIndependent() throws {
        let parentFirstSymbols = declarationChains(parentFirstUSR: true)
        let parentFirst = try projection(parentFirstSymbols)
        let reversedInput = try projection(parentFirstSymbols.reversed())
        let childFirst = try projection(declarationChains(parentFirstUSR: false))

        let expected = Dictionary(uniqueKeysWithValues: (0..<70).map { level in
            let states = level < 64
                ? ["merged:Primary,Secondary"]
                : ["raw:Primary", "raw:Secondary"]
            return ("Level\(level)", states)
        })
        #expect(projectionStates(parentFirst) == expected)
        #expect(projectionStates(reversedInput) == expected)
        #expect(projectionStates(childFirst) == expected)
        for value in [parentFirst, reversedInput, childFirst] {
            #expect(value.mergedGroupCount == 64)
            #expect(value.unresolvedGroupCount == 0)
            #expect(value.unavailableKeyCount == 12)
            #expect(value.nodes.count == 76)
            for node in value.nodes where node.state == .raw {
                #expect(node.aliases.isEmpty)
                #expect(node.variants.count == 1)
                #expect(value.rawToProjected[node.id] == node.id)
            }
        }
    }

    @Test("primary module 부재와 symbol 외 level은 명시적으로 거부한다")
    func rejectsMissingPrimaryAndWrongLevel() {
        let snapshot = IndexSnapshot(symbols: [
            symbol("s:App.A", name: "A", kind: .structType, module: "App", line: 1),
        ])
        let symbol = GraphBuilder(options: .init(level: .symbol)).buildResult(from: snapshot)
        #expect(throws: SwiftDeclarationProjectionError.self) {
            try SwiftDeclarationProjectionRenderer().render(
                result: symbol, snapshot: snapshot, projectPath: "/p", primaryModule: "Core"
            )
        }
        let module = GraphBuilder(options: .init(level: .module)).buildResult(from: snapshot)
        #expect(throws: SwiftDeclarationProjectionError.self) {
            try SwiftDeclarationProjectionRenderer().render(
                result: module, snapshot: snapshot, projectPath: "/p", primaryModule: "App"
            )
        }
    }

    private func symbol(
        _ usr: String,
        name: String,
        kind: SymbolKind,
        module: String,
        line: Int,
        parent: String? = nil,
        accessibility: Accessibility = .internalLevel,
        attributes: Set<SymbolAttribute> = []
    ) -> IndexedSymbol {
        IndexedSymbol(
            usr: usr,
            name: name,
            kind: kind,
            module: module,
            location: .init(path: "/p/Shared/File.swift", line: line, column: 1),
            parentUSR: parent,
            accessibility: accessibility,
            attributes: attributes
        )
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func declarationChains(parentFirstUSR: Bool) -> [IndexedSymbol] {
        ["Primary", "Secondary"].flatMap { module in
            (0..<70).map { level in
                let ordinal = parentFirstUSR ? level : 69 - level
                let parentOrdinal = parentFirstUSR ? level - 1 : 70 - level
                return IndexedSymbol(
                    usr: String(format: "s:%@.%02d", module, ordinal),
                    name: "Level\(level)",
                    kind: .classType,
                    module: module,
                    location: .init(path: "/p/Shared/Deep.swift", line: level + 1, column: 1),
                    parentUSR: level == 0 ? nil : String(format: "s:%@.%02d", module, parentOrdinal)
                )
            }
        }
    }

    private func projection<S: Sequence>(_ symbols: S) throws -> SwiftDeclarationProjection
    where S.Element == IndexedSymbol {
        let snapshot = IndexSnapshot(symbols: Array(symbols))
        let result = GraphBuilder(options: .init(level: .symbol)).buildResult(from: snapshot)
        return try SwiftDeclarationProjectionBuilder().build(
            result: result,
            snapshot: snapshot,
            projectPath: "/p",
            primaryModule: "Primary"
        )
    }

    private func projectionStates(_ projection: SwiftDeclarationProjection) -> [String: [String]] {
        Dictionary(grouping: projection.nodes, by: { $0.variants[0].name })
            .mapValues { nodes in
                nodes.map { node in
                    let modules = node.variants.compactMap(\.module).sorted().joined(separator: ",")
                    return "\(node.state.rawValue):\(modules)"
                }
                .sorted()
            }
    }
}
