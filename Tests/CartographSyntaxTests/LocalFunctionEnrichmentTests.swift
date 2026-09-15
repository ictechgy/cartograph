import CartographCore
import CartographSyntax
import CartographTestSupport
import Foundation
import Testing

@Suite("컴파일러가 생략한 지역 함수")
struct LocalFunctionEnrichmentTests {
    private let path = "/p/Local.swift"

    @Test("실제 지역 함수 호출을 연결하고 본문 참조의 소유자를 바로잡는다")
    func bindsCalledLocalFunction() {
        let source = """
            func target() {}
            func outer() {
                func local() {
                    target()
                }
                local()
            }
            """
        let result = enrich(source)
        let local = result.symbols.first { $0.name == "local()" }
        #expect(local != nil)
        guard let local else { return }
        #expect(local.usr.hasPrefix("cartograph:local-function:"))
        #expect(local.location == SourceLocation(path: path, line: 3, column: 10))
        #expect(local.parentUSR == "outer")
        #expect(result.references.contains {
            $0.sourceUSR == "outer" && $0.targetUSR == local.usr && $0.kind == .call
        })
        #expect(result.references.contains {
            $0.sourceUSR == local.usr && $0.targetUSR == "target" && $0.kind == .call
        })
        #expect(!result.references.contains { $0.sourceUSR == "outer" && $0.targetUSR == "target" })
    }

    @Test("중첩 지역 함수와 형제 호출 사슬을 실제 소유자로 연결한다")
    func bindsNestedAndSiblingChains() {
        let result = enrich("""
            func target() {}
            func outer() {
                func handler() {
                    func leaf() { target() }
                    leaf()
                }
                handler()
            }
            """)
        let handler = result.symbols.first { $0.name == "handler()" }
        let leaf = result.symbols.first { $0.name == "leaf()" }
        #expect(handler != nil && leaf != nil)
        #expect(leaf?.parentUSR == handler?.usr)
        #expect(result.references.filter { $0.targetUSR == "target" }.map(\.sourceUSR) == [leaf?.usr])
    }

    @Test("익명 클로저와 함수 값 참조를 지나도 지역 함수 사용을 보존한다")
    func bindsClosureAndFunctionValueUses() {
        let result = enrich("""
            func target() {}
            func outer() {
                @Sendable func local() { let work = { target() }; work() }
                let callback = local
                callback()
            }
            """)
        let local = result.symbols.first { $0.name == "local()" }
        #expect(local != nil)
        #expect(result.references.contains { $0.sourceUSR == "outer" && $0.targetUSR == local?.usr
            && $0.kind == .reference })
        #expect(result.references.contains { $0.sourceUSR == local?.usr && $0.targetUSR == "target" })
    }

    @Test("호출되지 않은 지역 함수와 재귀만 있는 묶음은 기존 투영으로 남긴다", arguments: [
        "func local() { target() }",
        "func local() { target(); local() }",
        "func first() { target(); second() }; func second() { first() }",
    ])
    func preservesUnenteredLocals(_ body: String) {
        let result = enrich("func target() {}\nfunc outer() {\n    \(body)\n}")
        #expect(result.symbols.count == 2)
        #expect(result.references.allSatisfy { $0.sourceUSR == "outer" })
    }

    @Test("이름 가림이나 오버로드가 있으면 지역 호출을 추측하지 않는다", arguments: [
        "let local = { }; local()",
        "let callback = { (local: () -> Void) in local() }; callback({})",
        "func another(local: () -> Void) { local() }; another(local: {})",
        "func local(_ value: Int) {}; local()",
        "func other() { func local() {}; local() }; other()",
    ])
    func rejectsAmbiguousNames(_ usage: String) {
        let result = enrich("func target() {}\nfunc outer() {\n    func local() { target() }\n    \(usage)\n}")
        #expect(!result.symbols.contains { $0.name == "local()" })
        #expect(result.references.filter { $0.targetUSR == "target" }.allSatisfy { $0.sourceUSR == "outer" })
    }

    @Test("멤버 접근은 같은 이름의 지역 함수 호출이 아니다")
    func doesNotBindMemberAccessAsLocalCall() {
        let result = enrich("""
            func target() {}
            func outer() {
                func local() { target() }
                receiver.local()
            }
            """)
        #expect(result.symbols.count == 2)
    }

    @Test("지역 선언의 어휘 범위 밖에 있는 같은 이름의 사용은 연결하지 않는다")
    func requiresLexicalVisibility() {
        let result = enrich("""
            func target() {}
            func outer() {
                if flag { func local() { target() } }
                local()
            }
            """)
        #expect(result.symbols.count == 2)
    }

    @Test("한글·백틱·같은 줄의 함수에서도 UTF-8 식별자 위치를 사용한다")
    func bindsUTF8AndSameLineNames() {
        let result = enrich("""
            func target() {}
            func outer() {
                let 한글 = "값"; func `default`() { target() }; `default`()
            }
            """)
        let local = result.symbols.first { $0.name == "default()" }
        #expect(local != nil)
        #expect(result.references.filter { $0.targetUSR == "target" }.map(\.sourceUSR) == [local?.usr])
    }

    @Test("캐시 직렬화는 결정적이고 예전 캐시는 지역 함수 근거를 만들지 않는다")
    func deterministicFactsAndLegacyCache() throws {
        let facts = SwiftSyntaxAnalyzer().analyze(source: """
            func outer(z: Int, a: Int) {
                func local() {}; local()
            }
            """, path: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(facts)
        #expect(try bytes == encoder.encode(facts))
        #expect(try JSONDecoder().decode(SourceFileFacts.self, from: bytes) == facts)
        let legacy = try JSONDecoder().decode(SourceFileFacts.self,
            from: Data(#"{"path":"/p/Local.swift","declarations":[],"ignoresEntireFile":false}"#.utf8))
        #expect(legacy.localFunctionScopes == nil)
    }

    @Test("인덱스 소유자가 모호하거나 참조 위치가 없으면 귀속을 바꾸지 않는다")
    func requiresUniqueIndexedOwnerAndReferenceSite() {
        let source = "func target() {}\nfunc outer() {\n    func local() { target() }; local()\n}"
        let facts = [path: SwiftSyntaxAnalyzer().analyze(source: source, path: path)]
        let target = IndexedSymbol(usr: "target", name: "target()", kind: .function, module: "App",
            location: SourceLocation(path: path, line: 1, column: 6))
        let owner = IndexedSymbol(usr: "outer", name: "outer()", kind: .function, module: "App",
            location: SourceLocation(path: path, line: 2, column: 6))
        let other = IndexedSymbol(usr: "other", name: "outer()", kind: .function, module: "Other",
            location: owner.location)
        let reference = IndexedReference(sourceUSR: "outer", targetUSR: "target", kind: .call)
        let ambiguous = IndexSnapshot(symbols: [owner, other, target], references: [reference])
        let result = SnapshotEnricher.enrich(ambiguous, with: facts, freshSourcePaths: [path])
        #expect(result.symbols.count == 3)
        #expect(result.references == [reference])
        let unique = IndexSnapshot(symbols: [owner, target], references: [reference])
        let located = SnapshotEnricher.enrich(unique, with: facts, freshSourcePaths: [path])
        #expect(located.references.contains(reference))
        #expect(!located.references.contains { $0.sourceUSR != "outer" && $0.targetUSR == "target" })
    }

    @Test("지원하지 않는 구문 문맥을 세분하지 않는다", arguments: [
        "@Unknown func local() { target() }; local()",
        "#if DEBUG\nfunc local() { target() }; local()\n#endif",
        "func local() { target() }; #unknown(local())",
        "struct Nested { }; func local() { target() }; local()",
        "func local() { target() }; local(]",
    ])
    func rejectsUnsupportedContexts(_ body: String) {
        let result = enrich("func target() {}\nfunc outer() {\n    \(body)\n}")
        #expect(result.symbols.count == 2)
        #expect(result.references.allSatisfy { $0.sourceUSR == "outer" })
    }

    @Test("신선도 근거가 없거나 낡으면 기존 인덱스 소유자를 유지한다")
    func requiresFreshSourceEvidence() {
        let source = "func target() {}\nfunc outer() {\n    func local() { target() }; local()\n}"
        for (modified, indexed) in [(30.0, 20.0), (10.0, nil), (nil, 20.0)] as [(Double?, Double?)] {
            let result = enrich(source, sourceDate: modified.map(Date.init(timeIntervalSince1970:)),
                indexDate: indexed.map(Date.init(timeIntervalSince1970:)))
            #expect(result.symbols.count == 2)
            #expect(result.references.allSatisfy { $0.sourceUSR == "outer" })
        }
    }

    @Test("보완된 스냅샷도 소스가 낡아지면 원래 인덱스 투영으로 되돌린다")
    func restoresProjectionWhenReenrichedSourceIsStale() {
        let source = "func target() {}\nfunc outer() {\n    func local() { target() }; local()\n}"
        let fresh = enrich(source)
        #expect(fresh.symbols.count == 3)
        let fileSystem = InMemoryFileSystem(files: [path: source])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 30), for: path)
        let result = SnapshotEnricher(fileSystem: fileSystem).enrichWithDiagnostics(fresh)
        #expect(result.snapshot.symbols.count == 2)
        #expect(result.snapshot.references.allSatisfy { $0.sourceUSR == "outer" && $0.targetUSR == "target" })
        #expect(result.unresolvedLocalFunctionsByPath[path] == 1)
    }

    @Test("생성자의 인덱스 이름이 소스 타입 이름과 달라도 실제 위치로 소유자를 구분한다")
    func rehomesConstructorReference() {
        let source = "func outer() {\n    func local() { _ = Box() }; local()\n}\nstruct Box { init() {} }"
        let line = source.split(separator: "\n")[1]
        let range = line.range(of: "Box()")!
        let owner = IndexedSymbol(usr: "outer", name: "outer()", kind: .function, module: "App",
            location: SourceLocation(path: path, line: 1, column: 6))
        let initializer = IndexedSymbol(usr: "Box.init", name: "init()", kind: .initializer, module: "App",
            location: SourceLocation(path: path, line: 4, column: 14))
        let snapshot = IndexSnapshot(symbols: [owner, initializer], references: [
            IndexedReference(sourceUSR: "outer", targetUSR: "Box.init", kind: .call,
                location: SourceLocation(path: path, line: 2, column: line[..<range.lowerBound].utf8.count + 1)),
        ])
        let result = SnapshotEnricher.enrich(snapshot,
            with: [path: SwiftSyntaxAnalyzer().analyze(source: source, path: path)], freshSourcePaths: [path])
        let local = result.symbols.first { $0.name == "local()" }
        #expect(local != nil)
        #expect(result.references.filter { $0.targetUSR == "Box.init" }.map(\.sourceUSR) == [local?.usr])
    }

    @Test("호출·참조·포함 관계 중 하나를 제외한 그래프에는 원래 투영을 준다",
        arguments: [[EdgeKind.call], [.reference], [.call, .reference]])
    func preservesProjectionForFilteredEdges(_ kinds: [EdgeKind]) {
        let result = enrich("func target() {}\nfunc outer() {\n    func local() { target() }; local()\n}",
            edgeKinds: Set(kinds))
        #expect(result.symbols.count == 2)
        #expect(result.references.allSatisfy { $0.sourceUSR == "outer" })
    }

    @Test("같은 입력을 다시 보강해도 지역 키와 참조가 늘어나지 않는다")
    func producesStableIdempotentOutput() {
        let source = "func target() {}\nfunc outer() {\n    func local() { target() }; local()\n}"
        let first = enrich(source)
        let second = enrich(source)
        #expect(first == second)
        let fileSystem = InMemoryFileSystem(files: [path: source])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 10), for: path)
        #expect(SnapshotEnricher(fileSystem: fileSystem).enrich(first) == first)
    }

    private func enrich(
        _ source: String,
        sourceDate: Date? = Date(timeIntervalSince1970: 10),
        indexDate: Date? = Date(timeIntervalSince1970: 20),
        edgeKinds: Set<EdgeKind> = []
    ) -> IndexSnapshot {
        let fileSystem = InMemoryFileSystem(files: [path: source])
        if let sourceDate { fileSystem.setModificationDate(sourceDate, for: path) }
        let references = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap {
            index, line -> IndexedReference? in
            guard index > 0, let range = line.range(of: "target()") else { return nil }
            return IndexedReference(sourceUSR: "outer", targetUSR: "target", kind: .call,
                location: SourceLocation(path: path, line: index + 1,
                    column: line[..<range.lowerBound].utf8.count + 1))
        }
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "target", name: "target()", kind: .function, module: "App",
                location: SourceLocation(path: path, line: 1, column: 6)),
            IndexedSymbol(usr: "outer", name: "outer()", kind: .function, module: "App",
                location: SourceLocation(path: path, line: 2, column: 6), attributes: [.entryPoint]),
        ], references: references, indexedFileDates: indexDate.map { [path: $0] })
        return SnapshotEnricher(fileSystem: fileSystem).enrich(snapshot, edgeKinds: edgeKinds)
    }
}
