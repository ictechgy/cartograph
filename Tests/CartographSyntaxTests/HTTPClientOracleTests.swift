import CartographCore
@testable import CartographSyntax
import Foundation
import Testing

/// 실제 요청 기록(`experiments/http-client-oracle/recorded.json`)과 route-call 사실을 대조한다.
///
/// 기록은 합성 클라이언트가 Alamofire 5.12.2·Moya 15.0.3·Foundation 으로 보낸 요청을 로컬 기록 서버가 받은
/// 요청 줄 그대로다(`record.sh`). 이 테스트는 네트워크 없이 기록 파일과 클라이언트 소스만 읽는다. 사실의
/// 템플릿을 기록된 경로에 대입(`{}` 는 비지 않은 세그먼트 하나)해 맞아야 하고, 동사가 같아야 한다. 규칙이
/// 라이브러리 의미와 어긋나면(예: `appendingPathComponent` 의 `?` 를 query 로 자르면) 여기서 실패한다.
@Suite("HTTP 라이브러리 오라클")
struct HTTPClientOracleTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("experiments/http-client-oracle")

    /// 기록된 요청 하나.
    private struct Record {
        let caseID: String
        let method: String
        let host: String
        let path: String
    }

    /// 소스의 `// oracle: <id>[@case]` 표시 하나.
    private struct Marker {
        let path: String
        let line: Int
        let caseName: String?
    }

    private static func records() throws -> [Record] {
        let data = try Data(contentsOf: root.appendingPathComponent("recorded.json"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(document["records"] as? [[String: Any]])
        return try records.map { record in
            Record(caseID: try #require(record["case"] as? String), method: try #require(record["method"] as? String),
                   host: try #require(record["host"] as? String), path: try #require(record["path"] as? String))
        }
    }

    private static func sources() throws -> [String: String] {
        let directory = root.appendingPathComponent("Sources/OracleClient")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            let url = directory.appendingPathComponent(name)
            return (url.path, try String(contentsOf: url, encoding: .utf8))
        })
    }

    private static func markers(in sources: [String: String]) -> [String: Marker] {
        var result: [String: Marker] = [:]
        for (path, text) in sources {
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard let range = line.range(of: "// oracle: ") else { continue }
                for token in line[range.upperBound...].split(separator: " ") {
                    let parts = token.split(separator: "@", maxSplits: 1).map(String.init)
                    result[parts[0]] = Marker(path: path, line: index + 1, caseName: parts.count > 1 ? parts[1] : nil)
                }
            }
        }
        return result
    }

    /// 여러 파일을 한 문서처럼 읽어 라우터 사실까지 합친다(`routes` 의 조립 순서와 같다).
    private static func facts(_ sources: [String: String]) -> [ScannedRouteCall] {
        var surface = HTTPDeclarationSurface()
        for (path, source) in sources { surface.merge(HTTPRouteCallScanner.declarations(source: source, path: path)) }
        let scanner = HTTPRouteCallScanner(wrappers: [], surface: surface)
        var calls: [ScannedRouteCall] = []
        var tables: [HTTPTargetMemberTable] = []
        var recipes: [HTTPRouterRecipe] = []
        for path in sources.keys.sorted() {
            let result = scanner.scan(source: sources[path] ?? "", path: path)
            calls += result.calls
            tables += result.routerTables
            recipes += result.routerRecipes
        }
        return calls + HTTPRouteCallScanner.routerRouteCalls(tables: tables, recipes: recipes, surface: surface).calls
    }

    /// 템플릿을 기록된 경로에 대입한다. root 는 전체가, base 는 경로의 끝부분이 맞아야 한다.
    static func matches(template: String, anchor: HTTPPathAnchor, recordedPath: String) -> Bool {
        let expected = template.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        let actual = HTTPRouteTemplate.normalize(recordedPath).dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard anchor == .root ? expected.count == actual.count : expected.count <= actual.count else { return false }
        return zip(expected, actual.suffix(expected.count)).allSatisfy { pattern, segment in
            pattern == "{}" ? !segment.isEmpty : pattern == segment
        }
    }

    @Test("기록된 모든 요청이 표시한 줄의 사실 하나와 동사·경로가 맞는다")
    func recordedRequestsAgreeWithFacts() throws {
        let records = try Self.records()
        let sources = try Self.sources()
        let markers = Self.markers(in: sources)
        let facts = Self.facts(sources)
        // 표시와 기록이 한쪽만 늘어나면 대조가 조용히 줄어든다.
        #expect(Set(records.map(\.caseID)) == Set(markers.keys))
        #expect(records.count >= 35)
        for record in records {
            let marker = try #require(markers[record.caseID], "\(record.caseID): no marker in the client sources")
            let candidates = facts.filter { call in
                call.fact.location.path == marker.path && call.fact.location.line == marker.line
                    && (marker.caseName == nil || call.declaration?.name == marker.caseName)
            }
            let call = try #require(candidates.count == 1 ? candidates.first : nil,
                                    "\(record.caseID): expected one fact at line \(marker.line), found \(candidates.count)")
            let fact = call.fact
            #expect(!fact.isDynamic, "\(record.caseID): the fact is dynamic")
            #expect(fact.method == record.method, "\(record.caseID): method \(fact.method ?? "nil") != \(record.method)")
            let template = fact.channel ?? ""
            #expect(Self.matches(template: template, anchor: fact.pathAnchor, recordedPath: record.path),
                    "\(record.caseID): \(template) (\(fact.pathAnchor.rawValue)) does not match \(record.path)")
            if let authority = fact.authority { #expect(authority == record.host, "\(record.caseID): authority") }
        }
    }

    @Test("대입 규칙은 root 전체와 base 끝부분을 세그먼트 단위로 맞춘다")
    func substitutionRule() {
        #expect(Self.matches(template: "/v1/users/{}", anchor: .root, recordedPath: "/v1/users/42"))
        #expect(!Self.matches(template: "/v1/users/{}", anchor: .root, recordedPath: "/v1/users/"))
        #expect(!Self.matches(template: "/users", anchor: .root, recordedPath: "/v1/users"))
        #expect(Self.matches(template: "/users", anchor: .base, recordedPath: "/v1/users"))
        #expect(Self.matches(template: "/v1/a%2520b", anchor: .root, recordedPath: "/v1/a%2520b"))
        #expect(!Self.matches(template: "/v1/users", anchor: .root, recordedPath: "/v1/users%3Fdraft=1"))
    }
}
