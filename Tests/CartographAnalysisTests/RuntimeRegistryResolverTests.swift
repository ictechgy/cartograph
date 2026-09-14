import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("Swift Dictionary registry 연결 해석")
struct RuntimeRegistryResolverTests {
    private let path = "/p/Registry.swift"
    private let dictionaryLiteralUSR = "s:SD17dictionaryLiteralSDyxq_Gx_q_td_tcfc"
    private let dictionaryGetterUSR = "s:SDyq_Sgxcig"
    private let dictionarySetterUSR = "s:SDyq_Sgxcip"

    @Test("표준 Dictionary subscript와 값 함수 reference가 모두 맞을 때 lookup을 연결한다")
    func resolvesStandardLookup() throws {
        let fixture = makeFixture()
        let report = resolve(fixture)
        let entry = try #require(report.findings.first { $0.boundary.kind == .registryEntry })
        let lookup = try #require(report.findings.first { $0.boundary.kind == .registryLookup })
        #expect(entry.status == .alreadyIndexed)
        #expect(entry.targets == [NodeID("alpha")])
        #expect(lookup.status == .resolved)
        #expect(lookup.source == NodeID("caller"))
        #expect(lookup.targets == [NodeID("alpha")])
        #expect(report.connections.contains {
            $0.kind == .registryLookup && $0.source == NodeID("caller") && $0.target == NodeID("alpha")
        })
        #expect(fixture.graph.edges.contains {
            $0.source == NodeID("registry") && $0.target == NodeID("alpha") && $0.kind == .reference
        })
    }

    @Test("custom dictionary subscript는 같은 syntax와 이름이어도 표준 Dictionary로 확정하지 않는다")
    func rejectsCustomSubscript() throws {
        let custom = RuntimeBoundary(
            kind: .registryLookup, api: "Dictionary.subscript", location: location(2, 5),
            calleeLocation: location(2, 14), name: "alpha", nameOrigin: .literal,
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(2, 5)
        )
        var fixture = makeFixture()
        fixture.snapshot.references = fixture.snapshot.references.filter {
            !($0.location == location(2, 14))
        }
        fixture.snapshot.references += [
            .init(sourceUSR: "caller", targetUSR: "custom-subscript", kind: .call, location: location(2, 14)),
            .init(sourceUSR: "caller", targetUSR: "custom-subscript", kind: .reference, location: location(2, 14)),
        ]
        let report = resolve(custom, fixture: fixture)
        #expect(report.findings.first { $0.boundary.location == location(2, 5) }?.status == .unresolved)
        #expect(report.connections.isEmpty)
    }

    @Test("dynamic key·duplicate entry·불완전 subscript proof는 연결을 만들지 않는다")
    func rejectsUnprovenShapes() {
        var fixture = makeFixture()
        let dynamic = RuntimeBoundary(
            kind: .registryLookup, api: "Dictionary.subscript", location: location(3, 5),
            calleeLocation: location(3, 14), registryDeclarationLocation: location(1, 5),
            registryReferenceLocation: location(3, 5)
        )
        let duplicateA = fixture.files[0].boundaries[0]
        let duplicateB = RuntimeBoundary(
            kind: .registryEntry, api: "Dictionary.literal", location: location(1, 50),
            name: "alpha", nameOrigin: .literal, referencedTargetLocation: location(1, 35),
            registryDeclarationLocation: location(1, 5)
        )
        let incomplete = RuntimeBoundary(
            kind: .registryLookup, api: "Dictionary.subscript", location: location(4, 5),
            calleeLocation: location(4, 14), name: "alpha", nameOrigin: .literal,
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(4, 5)
        )
        fixture.files[0] = .init(path: path, boundaries: [duplicateA, duplicateB, dynamic, incomplete])
        fixture.snapshot.references = fixture.snapshot.references.filter { $0.location != location(4, 14) }
        fixture.snapshot.references.append(.init(
            sourceUSR: "caller", targetUSR: dictionaryGetterUSR, kind: .call, location: location(4, 14)
        ))
        let report = resolve(fixture)
        let findings = report.findings
        #expect(findings.first { $0.boundary.location == location(3, 5) }?.status == .dynamic)
        #expect(findings.first { $0.boundary.location == location(1, 50) }?.status == .ambiguous)
        #expect(findings.first { $0.boundary.location == location(4, 5) }?.status == .unresolved)
        #expect(report.connections.isEmpty)
    }

    @Test("immutable alias는 alias reference chain이 정확할 때만 원 registry lookup을 연결한다")
    func resolvesImmutableAliasChain() throws {
        var fixture = makeFixture(includeLookup: false)
        let alias = RuntimeBoundary(
            kind: .registryAlias, api: "registry-alias", location: location(1, 60),
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(1, 68)
        )
        let lookup = RuntimeBoundary(
            kind: .registryLookup, api: "Dictionary.subscript", location: location(2, 5),
            calleeLocation: location(2, 14), name: "alpha", nameOrigin: .literal,
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(2, 5)
        )
        fixture.files = [.init(path: path, boundaries: fixture.files[0].boundaries + [alias, lookup])]
        fixture.snapshot.symbols.append(.init(
            usr: "alias", name: "alias", kind: .variable, module: "App", location: location(1, 60)
        ))
        fixture.snapshot.references += [
            .init(sourceUSR: "alias", targetUSR: "registry", kind: .reference, location: location(1, 68)),
            .init(sourceUSR: "caller", targetUSR: "alias", kind: .reference, location: location(2, 5)),
            .init(sourceUSR: "caller", targetUSR: "alias", kind: .call, location: location(2, 5)),
            .init(sourceUSR: "caller", targetUSR: dictionaryGetterUSR, kind: .call, location: location(2, 14)),
            .init(sourceUSR: "caller", targetUSR: dictionarySetterUSR, kind: .reference, location: location(2, 14)),
        ]
        fixture.graph = GraphBuilder(options: .init(level: .symbol)).build(from: fixture.snapshot)
        let report = resolve(fixture)
        #expect(report.findings.first { $0.boundary.kind == .registryAlias }?.status == .alreadyIndexed)
        #expect(report.findings.first { $0.boundary.kind == .registryLookup }?.status == .resolved)
        #expect(report.connections.contains { $0.target == NodeID("alpha") })
    }

    @Test("인덱스 정점이 없는 local alias도 compiler reference chain이 유일하면 lookup을 연결한다")
    func resolvesLocalAliasWithoutLocalSymbol() {
        var fixture = makeFixture(includeLookup: false)
        let alias = RuntimeBoundary(
            kind: .registryAlias, api: "registry-alias", location: location(6, 9),
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(6, 16)
        )
        let lookup = RuntimeBoundary(
            kind: .registryLookup, api: "Dictionary.subscript", location: location(7, 5),
            calleeLocation: location(7, 14), name: "alpha", nameOrigin: .literal,
            registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(7, 5)
        )
        fixture.files = [.init(path: path, boundaries: fixture.files[0].boundaries + [alias, lookup])]
        fixture.snapshot.symbols.append(.init(
            usr: "localCaller", name: "localLookup()", kind: .function, module: "App", location: location(7, 6)
        ))
        fixture.snapshot.references += [
            .init(sourceUSR: "localAliasUSR", targetUSR: "registry", kind: .reference, location: location(6, 16)),
            .init(sourceUSR: "localCaller", targetUSR: "localAliasUSR", kind: .call, location: location(7, 5)),
            .init(sourceUSR: "localCaller", targetUSR: "localAliasUSR", kind: .reference, location: location(7, 5)),
            .init(sourceUSR: "localCaller", targetUSR: dictionaryGetterUSR, kind: .call, location: location(7, 14)),
            .init(
                sourceUSR: "localCaller", targetUSR: dictionarySetterUSR,
                kind: .reference, location: location(7, 14)
            ),
        ]
        fixture.graph = GraphBuilder(options: .init(level: .symbol)).build(from: fixture.snapshot)
        let report = resolve(fixture)
        let finding = report.findings.first { $0.boundary.kind == .registryLookup }
        #expect(finding?.status == .resolved)
        #expect(finding?.source == NodeID("localCaller"))
        #expect(finding?.targets == [NodeID("alpha")])
    }

    @Test("stale factory declaration은 compiler proof가 있어도 resolved로 승격하지 않는다")
    func rejectsStaleTarget() {
        let fixture = makeFixture(freshness: [path: .fresh, "/p/Factory.swift": .sourceNewerThanIndex])
        let report = resolve(fixture)
        #expect(report.findings.first { $0.boundary.kind == .registryLookup }?.status == .stale)
        #expect(report.connections.isEmpty)
    }

    private struct Fixture {
        var snapshot: IndexSnapshot
        var files: [RuntimeFileFacts]
        var graph: CodeGraph
        let freshness: [String: RuntimeFreshness]
    }

    private func makeFixture(includeLookup: Bool = true, freshness: [String: RuntimeFreshness] = [:]) -> Fixture {
        let symbols = [
            IndexedSymbol(usr: "registry", name: "factories", kind: .variable, module: "App", location: location(1, 5)),
            IndexedSymbol(usr: "caller", name: "lookup()", kind: .function, module: "App", location: location(2, 6)),
            IndexedSymbol(
                usr: "alpha", name: "makeAlpha()", kind: .function, module: "App",
                location: .init(path: "/p/Factory.swift", line: 10, column: 6)
            ),
        ]
        var references = [
            IndexedReference(sourceUSR: "registry", targetUSR: dictionaryLiteralUSR,
                kind: .reference, location: location(1, 40)),
            IndexedReference(sourceUSR: "registry", targetUSR: "alpha", kind: .reference, location: location(1, 35)),
        ]
        var boundaries: [RuntimeBoundary] = [
            RuntimeBoundary(
                kind: .registryEntry, api: "Dictionary.literal", location: location(1, 30),
                name: "alpha", nameOrigin: .literal, referencedTargetLocation: location(1, 35),
                registryDeclarationLocation: location(1, 5)
            ),
        ]
        if includeLookup {
            boundaries.append(RuntimeBoundary(
                kind: .registryLookup, api: "Dictionary.subscript", location: location(2, 5),
                calleeLocation: location(2, 14), name: "alpha", nameOrigin: .literal,
                registryDeclarationLocation: location(1, 5), registryReferenceLocation: location(2, 5)
            ))
            references += [
                IndexedReference(sourceUSR: "caller", targetUSR: "registry", kind: .call, location: location(2, 5)),
                IndexedReference(
                    sourceUSR: "caller", targetUSR: "registry", kind: .reference, location: location(2, 5)
                ),
                IndexedReference(
                    sourceUSR: "caller", targetUSR: dictionaryGetterUSR, kind: .call, location: location(2, 14)
                ),
                IndexedReference(
                    sourceUSR: "caller", targetUSR: dictionarySetterUSR, kind: .reference, location: location(2, 14)
                ),
            ]
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: references)
        let effectiveFreshness = [path: RuntimeFreshness.fresh, "/p/Factory.swift": RuntimeFreshness.fresh]
            .merging(freshness) { _, new in new }
        return Fixture(
            snapshot: snapshot,
            files: [.init(path: path, boundaries: boundaries)],
            graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: effectiveFreshness
        )
    }

    private func resolve(_ fixture: Fixture) -> RuntimeDiscoveryReport {
        RuntimeRegistryResolver().resolve(
            files: fixture.files, snapshot: fixture.snapshot, graph: fixture.graph, freshness: fixture.freshness
        )
    }

    private func resolve(_ boundary: RuntimeBoundary, fixture: Fixture) -> RuntimeDiscoveryReport {
        RuntimeRegistryResolver().resolve(
            files: [.init(
                path: path,
                boundaries: fixture.files[0].boundaries.filter { $0.kind != .registryLookup } + [boundary]
            )],
            snapshot: fixture.snapshot,
            graph: fixture.graph,
            freshness: fixture.freshness
        )
    }

    private func location(_ line: Int, _ column: Int) -> CartographCore.SourceLocation {
        .init(path: path, line: line, column: column)
    }
}
