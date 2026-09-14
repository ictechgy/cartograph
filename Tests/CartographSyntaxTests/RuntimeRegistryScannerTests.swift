import CartographCore
@testable import CartographSyntax
import Testing

@Suite("Swift 불변 registry 경계 스캐너")
struct RuntimeRegistryScannerTests {
    private let path = "/p/Registry.swift"

    @Test("불변 Dictionary literal과 literal-key lookup의 정확한 위치를 보존한다")
    func capturesLiteralRegistryAndLookup() throws {
        let facts = scan("""
            let factories: [String: () -> any Service] = ["alpha": makeAlpha]
            func lookup() -> any Service { factories["alpha"]?()! }
            """)

        let entry = try #require(facts.boundaries.first { $0.kind == .registryEntry })
        let lookup = try #require(facts.boundaries.first { $0.kind == .registryLookup })
        #expect(entry.name == "alpha")
        #expect(entry.nameOrigin == .literal)
        #expect(entry.registryDeclarationLocation == location(1, 5))
        #expect(entry.referencedTargetLocation == location(1, 56))
        #expect(entry.reason == nil)
        #expect(lookup.name == "alpha")
        #expect(lookup.nameOrigin == .literal)
        #expect(lookup.registryDeclarationLocation == entry.registryDeclarationLocation)
        #expect(lookup.registryReferenceLocation == location(2, 32))
        #expect(lookup.calleeLocation == location(2, 41))
        #expect(lookup.reason == nil)
    }

    @Test("static registry와 immutable alias는 lexical identity를 유지한다")
    func capturesStaticRegistryAndAliasChain() throws {
        let facts = scan("""
            struct Router {
                static let routes: [String: () -> any Service] = ["alpha": makeAlpha]
                static func route() -> any Service { routes["alpha"]!() }
            }
            let alias = Router.routes
            func useAlias() -> any Service { alias["alpha"]!() }
            """)

        let entries = facts.boundaries.filter { $0.kind == .registryEntry }
        #expect(entries.count == 1)
        #expect(entries.first?.registryDeclarationLocation == location(2, 16))
        let aliases = facts.boundaries.filter { $0.kind == .registryAlias }
        #expect(aliases.count == 1)
        #expect(aliases.first?.registryDeclarationLocation == location(2, 16))
        #expect(aliases.first?.registryReferenceLocation == location(5, 20))
        let lookups = facts.boundaries.filter { $0.kind == .registryLookup }
        #expect(lookups.count == 2)
        #expect(lookups.allSatisfy { $0.registryDeclarationLocation == location(2, 16) })
    }

    @Test("mutable·dynamic·closure·method receiver·duplicate·conditional 후보를 확정하지 않는다")
    func preservesUnsupportedReasons() {
        let facts = scan("""
            let supported: [String: () -> any Service] = ["ok": makeAlpha]
            var mutable: [String: () -> any Service] = ["mutable": makeAlpha]
            let closure: [String: () -> any Service] = ["closure": { makeAlpha() }]
            struct Builder { func make() -> any Service { makeAlpha() } }
            let receiver: [String: () -> any Service] = ["receiver": Builder().make]
            func use(_ key: String) {
                supported[key]?()
                mutable["mutable"]?()
                closure["closure"]?()
                receiver["receiver"]?()
            }
            func duplicate() -> [String: () -> any Service] {
                let duplicate: [String: () -> any Service] = ["same": makeAlpha, "same": makeBeta]
                return duplicate
            }
            #if DEBUG
            let conditional: [String: () -> any Service] = ["branch": makeAlpha]
            #else
            let conditional: [String: () -> any Service] = ["branch": makeBeta]
            #endif
            """)

        let entries = facts.boundaries.filter { $0.kind == .registryEntry }
        #expect(entries.contains { $0.name == "ok" && $0.reason == nil })
        #expect(entries.contains { $0.name == "mutable" && $0.reason?.contains("mutable") == true })
        #expect(entries.contains { $0.name == "closure" && $0.referencedTargetLocation == nil })
        #expect(entries.contains { $0.name == "receiver" && $0.referencedTargetLocation == nil })
        #expect(entries.filter { $0.name == "same" }.count == 2)
        #expect(entries.filter { $0.name == "same" }.allSatisfy { $0.reason?.contains("duplicate") == true })
        #expect(entries.filter { $0.name == "branch" }.count == 2)
        #expect(entries.filter { $0.name == "branch" }.allSatisfy {
            $0.reason?.contains("conditional") == true
        })
        let dynamic = facts.boundaries.first { $0.kind == .registryLookup && $0.name == nil }
        #expect(dynamic?.nameOrigin == .dynamic)
        #expect(dynamic?.reason?.contains("literal string") == true)
    }

    @Test("registry 이름이 다른 lexical scope에 있으면 lookup을 연결하지 않는다")
    func rejectsMismatchedScope() throws {
        let facts = scan("""
            func define() {
                let local: [String: () -> any Service] = ["value": makeAlpha]
            }
            func use() -> any Service { local["value"]!() }
            """)

        let lookup = try #require(facts.boundaries.first { $0.kind == .registryLookup })
        #expect(lookup.registryDeclarationLocation == nil)
        #expect(lookup.reason?.contains("scope") == true)
    }

    @Test("일반 String subscript는 registry 이름을 추측해 경계로 만들지 않는다")
    func ignoresUnrelatedSubscripts() {
        let facts = scan("""
            let values = ["alpha"]
            let title = "Hello"
            let labels: [String: String] = ["title": title]
            let titleAlias = title
            func use() {
                _ = values[0]
                _ = labels["title"]
                _ = titleAlias
            }
            """)
        #expect(facts.boundaries.isEmpty)
        #expect(facts.limitations.isEmpty)
    }

    private func scan(_ source: String) -> RuntimeRegistryFacts {
        RuntimeRegistryScanner().scan(source: source, path: path)
    }

    private func location(_ line: Int, _ column: Int) -> CartographCore.SourceLocation {
        .init(path: path, line: line, column: column)
    }
}
