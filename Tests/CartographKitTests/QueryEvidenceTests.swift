import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("질의의 참조 위치와 출처")
struct QueryEvidenceTests {
    @Test("선언 위치와 실제 참조 위치를 구분하고 같은 발생은 중복하지 않는다")
    func returnsActualReferenceSites() throws {
        let reference = IndexedReference(sourceUSR: "caller", targetUSR: "target", kind: .call,
            location: SourceLocation(path: "/p/Caller.swift", line: 106, column: 9), origin: .compiler)
        let document = try query(references: [reference, reference])
        let result = try #require(document["result"] as? [String: Any])
        let callers = try #require(result["usedBy"] as? [[String: Any]])
        let caller = try #require(callers.first)
        #expect((caller["location"] as? [String: Any])?["line"] as? Int == 100)
        let evidence = try #require(caller["referenceEvidence"] as? [String: Any])
        let items = try #require(evidence["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect((items.first?["location"] as? [String: Any])?["line"] as? Int == 106)
        #expect(items.first?["sourceUSR"] as? String == "caller")
        #expect(items.first?["targetUSR"] as? String == "target")
        #expect(items.first?["viaUSR"] as? String == "target")
        #expect(items.first?["origin"] as? String == "compiler")
        #expect(evidence["totalCount"] as? Int == 1)
        #expect(evidence["omittedCount"] as? Int == 0)
    }

    @Test("전이 소비자는 실제 중간 심볼로 향하는 모든 최단 경로 근거를 준다")
    func returnsAllMinimumDepthHops() throws {
        let references = [
            IndexedReference(sourceUSR: "left", targetUSR: "target", kind: .call),
            IndexedReference(sourceUSR: "right", targetUSR: "target", kind: .reference),
            IndexedReference(sourceUSR: "caller", targetUSR: "left", kind: .call,
                location: SourceLocation(path: "/p/Caller.swift", line: 110, column: 1)),
            IndexedReference(sourceUSR: "caller", targetUSR: "right", kind: .reference,
                location: SourceLocation(path: "/p/Caller.swift", line: 111, column: 1)),
        ]
        let document = try query(references: references, depth: 2)
        let result = try #require(document["result"] as? [String: Any])
        let neighbors = try #require(result["usedBy"] as? [[String: Any]])
        let caller = try #require(neighbors.first { $0["usr"] as? String == "caller" })
        #expect(caller["depth"] as? Int == 2)
        let evidence = try #require(caller["referenceEvidence"] as? [String: Any])
        let items = try #require(evidence["items"] as? [[String: Any]])
        #expect(Set(items.compactMap { $0["viaUSR"] as? String }) == ["left", "right"])
        #expect(Set(items.compactMap { $0["targetUSR"] as? String }) == ["left", "right"])
        #expect(items.allSatisfy { $0["sourceUSR"] as? String == "caller" })
    }

    @Test("위치를 모르면 선언 위치로 대신 채우지 않고 출처도 추정하지 않는다")
    func keepsUnknownLocationsExplicit() throws {
        let document = try query(references: [
            IndexedReference(sourceUSR: "caller", targetUSR: "target", kind: .call),
            IndexedReference(sourceUSR: "caller", targetUSR: "target", kind: .reference,
                location: SourceLocation(path: "/p/Caller.swift", line: 0, column: 0)),
        ])
        let result = try #require(document["result"] as? [String: Any])
        let caller = try #require((result["usedBy"] as? [[String: Any]])?.first)
        let evidence = try #require(caller["referenceEvidence"] as? [String: Any])
        let items = try #require(evidence["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0["location"] == nil && $0["origin"] as? String == "unknown" })
    }

    @Test("참조 근거는 정렬해서 제한하고 생략 개수를 이웃 절단과 구분한다")
    func capsAndOrdersEvidence() throws {
        let references = (1...25).map { line in
            IndexedReference(sourceUSR: "caller", targetUSR: "target", kind: .call,
                location: SourceLocation(path: "/p/Caller.swift", line: line, column: 3))
        }
        let first = try query(references: references)
        let second = try query(references: references.reversed())
        let firstData = try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys])
        #expect(try firstData == JSONSerialization.data(withJSONObject: second, options: [.sortedKeys]))
        let result = try #require(first["result"] as? [String: Any])
        let caller = try #require((result["usedBy"] as? [[String: Any]])?.first)
        let evidence = try #require(caller["referenceEvidence"] as? [String: Any])
        let items = try #require(evidence["items"] as? [[String: Any]])
        #expect(items.count == 20)
        #expect(evidence["totalCount"] as? Int == 25)
        #expect(evidence["omittedCount"] as? Int == 5)
        #expect(items.compactMap { ($0["location"] as? [String: Any])?["line"] as? Int } == Array(1...20))
        #expect((result["truncated"] as? [String: Any])?["usedBy"] as? Bool == false)
    }

    @Test("응답 전체 근거 예산을 다 써도 나머지 이웃과 생략 사실을 보존한다")
    func capsTotalEvidenceWithoutDroppingNeighbors() throws {
        let references = (0..<13).flatMap { caller in
            (1...21).map { line in
                IndexedReference(sourceUSR: "user\(caller)", targetUSR: "target", kind: .call,
                    location: SourceLocation(path: "/p/Caller.swift", line: caller * 100 + line, column: 1))
            }
        }
        let document = try query(references: references)
        let result = try #require(document["result"] as? [String: Any])
        let callers = try #require(result["usedBy"] as? [[String: Any]])
        let evidence = callers.compactMap { $0["referenceEvidence"] as? [String: Any] }
        #expect(callers.count == 13)
        #expect(evidence.reduce(0) { $0 + (($1["items"] as? [Any])?.count ?? 0) } == 200)
        #expect(evidence.reduce(0) { $0 + ($1["omittedCount"] as? Int ?? 0) } == 73)
        #expect((result["truncated"] as? [String: Any])?["usedBy"] as? Bool == false)
    }

    @Test("의존 대상 방향도 실제 간선의 출발점과 도착점을 유지한다")
    func preservesOutgoingDirection() throws {
        let document = try query(references: [
            IndexedReference(sourceUSR: "target", targetUSR: "left", kind: .call),
            IndexedReference(sourceUSR: "left", targetUSR: "caller", kind: .call),
        ], depth: 2)
        let result = try #require(document["result"] as? [String: Any])
        let neighbors = try #require(result["dependsOn"] as? [[String: Any]])
        let caller = try #require(neighbors.first { $0["usr"] as? String == "caller" })
        let evidence = try #require(caller["referenceEvidence"] as? [String: Any])
        let item = try #require((evidence["items"] as? [[String: Any]])?.first)
        #expect(item["sourceUSR"] as? String == "left")
        #expect(item["targetUSR"] as? String == "caller")
        #expect(item["viaUSR"] as? String == "left")
    }

    @Test("이전 이웃과 인덱스 JSON은 새 필드 없이도 읽히고 출처는 unknown이다")
    func decodesLegacyDocumentsWithoutInventingEvidence() throws {
        let reference = try JSONDecoder().decode(IndexedReference.self,
            from: Data(#"{"sourceUSR":"caller","targetUSR":"target","kind":"call"}"#.utf8))
        #expect(reference.origin == .unknown)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
            as? [String: Any])
        #expect(encoded["origin"] == nil)
        let neighbor = SymbolQuery.Neighbor(name: "caller()", qualifiedName: "App.caller()", kind: "function",
            usr: "caller", module: "App", edges: ["call"], depth: 1, location: nil)
        let data = try JSONEncoder().encode(neighbor)
        #expect(try JSONDecoder().decode(SymbolQuery.Neighbor.self, from: data).referenceEvidence == nil)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["referenceEvidence"] == nil)
    }

    private func query(references: [IndexedReference], depth: Int = 1) throws -> [String: Any] {
        let names = Set(["target", "caller", "left", "right"] + references.flatMap { [$0.sourceUSR, $0.targetUSR] })
        let symbols = names.sorted().map { name in
            IndexedSymbol(usr: name, name: "\(name)()", kind: .function, module: "App",
                location: SourceLocation(path: "/p/Caller.swift", line: name == "caller" ? 100 : 1, column: 6))
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: references)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot)))
        let document = try service.queryDocument(symbol: "target", depth: depth)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
    }
}
