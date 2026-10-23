import CartographExport
import Foundation
import Testing

@Suite("JSON 한계 표시 모드")
struct JSONLimitationPresentationTests {
    @Test("기본 full은 JSON을 다시 읽거나 바이트를 바꾸지 않는다")
    func fullPreservesBytes() throws {
        for input in ["not JSON\n", "{  \"limitations\": [\"index-staleness: 3\"] }\n", ""] {
            let data = Data(input.utf8)
            #expect(try JSONLimitationPresentation.render(data) == data)
            #expect(try JSONLimitationPresentation.render(data, mode: .full) == data)
        }
    }

    @Test("숫자가 다른 같은 코드는 문장 빈도로만 묶고 unknown 코드와 안전 상태를 보존한다")
    func groupsMessagesWithoutInventingCounts() throws {
        let input: [String: Any] = [
            "status": "incomplete", "freshness": ["status": "stale"], "truncated": ["output": true],
            "limitations": ["index-staleness: 3 source files", "index-staleness: 12 source files",
                            "index-staleness: 3 source files", "future-boundary: unknown input", "Uncoded warning"],
            "result": ["reachability": ["state": "unknown"], "value": 9_007_199_254_740_993 as Int64],
        ]
        let output = try rendered(input)
        #expect(output["status"] as? String == "incomplete")
        #expect(NSDictionary(dictionary: output["freshness"] as! [String: Any])
            == NSDictionary(dictionary: input["freshness"] as! [String: Any]))
        #expect(NSDictionary(dictionary: output["truncated"] as! [String: Any])
            == NSDictionary(dictionary: input["truncated"] as! [String: Any]))
        #expect(NSDictionary(dictionary: output["result"] as! [String: Any])
            == NSDictionary(dictionary: input["result"] as! [String: Any]))
        let summary = try #require(output["limitationSummary"] as? [String: Any])
        #expect(summary["noteCount"] as? Int == 5)
        #expect(summary["groupCount"] as? Int == 3)
        let groups = try #require(summary["groups"] as? [[String: Any]])
        let stale = try #require(groups.first { $0["code"] as? String == "index-staleness" })
        #expect(stale["noteCount"] as? Int == 3)
        #expect(stale["distinctNoteCount"] as? Int == 2)
        let examples = try #require(stale["examples"] as? [[String: Any]])
        #expect(examples.map { $0["text"] as? String } == ["index-staleness: 12 source files",
                                                          "index-staleness: 3 source files"])
        #expect(examples.map { $0["occurrences"] as? Int } == [1, 2])
        #expect(groups.contains { $0["code"] as? String == "future-boundary" })
        #expect(groups.contains { $0["code"] is NSNull })
        #expect((output["limitations"] as? [String])?.contains { $0.contains("not a safety guarantee") } == true)
    }

    @Test("긴 유니코드 예시와 다른 문장 생략은 실제 개수와 바이트로 표시한다")
    func boundsExamplesAndReportsOmissions() throws {
        let notes = (0..<9).map { "unknown-bridge: \($0) " + String(repeating: "한", count: 600) }
        let output = try rendered(["limitations": notes + [notes[0]]])
        let summary = try #require(output["limitationSummary"] as? [String: Any])
        let groups = try #require(summary["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let examples = try #require(group["examples"] as? [[String: Any]])
        #expect(examples.count == 3)
        #expect(group["omittedNoteCount"] as? Int == 6)
        #expect(group["omittedDistinctNoteCount"] as? Int == 6)
        #expect(group["truncatedExampleCount"] as? Int == 3)
        #expect(summary["detailsOmitted"] as? Bool == true)
        for example in examples {
            let text = try #require(example["text"] as? String)
            #expect(text.utf8.count <= JSONLimitationPresentation.maximumExampleBytes)
            #expect(!text.contains("�"))
            #expect(example["originalBytes"] as? Int == notes[0].utf8.count)
            #expect(example["truncated"] as? Bool == true)
        }
    }

    @Test("배치와 MCP 봉투의 각 한계만 요약하고 순서와 중복 결과를 유지한다")
    func preservesNestedBatchAndEnvelope() throws {
        let answer: [String: Any] = ["requested": "missing", "status": "notFound",
                                   "limitations": ["unindexed-sources: 4"]]
        let output = try rendered(["session": ["generation": 4, "stale": true],
                                   "result": ["format": "symbol-query-batch", "version": 1,
                                              "results": [answer, answer]]])
        #expect((output["session"] as? [String: Any])?["generation"] as? Int == 4)
        let result = try #require(output["result"] as? [String: Any])
        let results = try #require(result["results"] as? [[String: Any]])
        #expect(results.count == 2)
        #expect(NSDictionary(dictionary: results[0]) == NSDictionary(dictionary: results[1]))
        #expect(results[0]["status"] as? String == "notFound")
        #expect((results[0]["limitationSummary"] as? [String: Any])?["noteCount"] as? Int == 1)
    }

    @Test("빈 한계와 생략된 한계는 원래 키 유무를 유지하며 요약 모드임을 표시한다")
    func emptyAndAbsentKeepShape() throws {
        let empty = try rendered(["limitations": [String](), "status": "found"])
        #expect((empty["limitations"] as? [String])?.isEmpty == true)
        let absent = try rendered(["status": "found", "diagnostics": [String]()])
        #expect(absent["limitations"] == nil)
        #expect((absent["limitationSummary"] as? [String: Any])?["noteCount"] as? Int == 0)
    }

    @Test("잘못된 한계와 기존 요약과 기계 입력 형식은 조용히 변환하지 않는다")
    func refusesInvalidOrEvidenceShapes() throws {
        let inputs: [[String: Any]] = [
            ["limitations": NSNull()], ["limitations": "unknown"], ["limitations": [1]],
            ["limitations": ["x"], "limitationSummary": [:]],
            ["format": "analysis-snapshot", "limitations": ["stale"]],
            ["result": ["format": "language-traversal", "limitations": ["unknown"]]],
        ]
        for input in inputs {
            #expect(throws: JSONLimitationPresentation.PresentationError.self) { try rendered(input) }
        }
        for input in ["[]", "12", "broken"] {
            #expect(throws: JSONLimitationPresentation.PresentationError.self) {
                try JSONLimitationPresentation.render(Data(input.utf8), mode: .summary)
            }
        }
    }

    @Test("입력·코드·값·깊이 예산 초과는 부분 요약 대신 명시적으로 실패한다")
    func refusesBudgetOverflow() throws {
        let tooLarge = Data(repeating: 32, count: JSONLimitationPresentation.maximumInputBytes + 1)
        #expect(throws: JSONLimitationPresentation.PresentationError.self) {
            try JSONLimitationPresentation.render(tooLarge, mode: .summary)
        }
        // 입력은 한도 안이지만 표시 메타데이터가 더해진 최종 문서가 한도를 넘는다.
        let nearLimit: [String: Any] = ["value": String(repeating: "a",
            count: JSONLimitationPresentation.maximumInputBytes - 64), "limitations": [String]()]
        let nearData = try JSONSerialization.data(withJSONObject: nearLimit)
        #expect(nearData.count <= JSONLimitationPresentation.maximumInputBytes)
        #expect(throws: JSONLimitationPresentation.PresentationError.self) {
            try JSONLimitationPresentation.render(nearData, mode: .summary)
        }
        let codes = (0...JSONLimitationPresentation.maximumGroups).map { "code-\($0): limitation" }
        #expect(throws: JSONLimitationPresentation.PresentationError.self) { try rendered(["limitations": codes]) }
        #expect(throws: JSONLimitationPresentation.PresentationError.self) {
            try rendered(["limitations": Array(repeating: "same: warning", count: 100_001)])
        }
        var nested: Any = "leaf"
        for _ in 0..<66 { nested = ["child": nested] }
        #expect(throws: JSONLimitationPresentation.PresentationError.self) { try rendered(["root": nested]) }
    }

    @Test("코드처럼 보이지 않는 접두사는 원문 예시로 남기고 모든 거부는 full 복구 경로를 알린다")
    func preservesUncodedPrefixesAndRecoveryMessages() throws {
        for note in [": empty", "9code: numeric", "UPPER: text", "space code: text",
                     String(repeating: "a", count: 129) + ": long", ""] {
            let output = try rendered(["limitations": [note]])
            let summary = try #require(output["limitationSummary"] as? [String: Any])
            let groups = try #require(summary["groups"] as? [[String: Any]])
            let group = try #require(groups.first)
            #expect(group["code"] is NSNull)
            #expect((group["examples"] as? [[String: Any]])?.first?["text"] as? String == note)
        }
        let errors: [JSONLimitationPresentation.PresentationError] = [
            .invalidDocument, .unsupportedFormat, .invalidLimitations, .budgetExceeded,
        ]
        for error in errors { #expect(error.errorDescription?.contains("--limitations full") == true) }
    }

    @Test("한계와 객체 입력 순서가 바뀌어도 요약 바이트는 같다")
    func stableOrdering() throws {
        let notes = ["new-code: c", "index-staleness: 2", "index-staleness: 1"]
        let first = try JSONSerialization.data(withJSONObject: ["limitations": notes, "status": "unknown"])
        let second = try JSONSerialization.data(withJSONObject:
            ["status": "unknown", "limitations": Array(notes.reversed())])
        #expect(try JSONLimitationPresentation.render(first, mode: .summary)
            == JSONLimitationPresentation.render(second, mode: .summary))
    }

    private func rendered(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let output = try JSONLimitationPresentation.render(data, mode: .summary)
        return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }
}
