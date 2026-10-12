import CartographCore
import Foundation
import Testing

@Suite("외부 보존 출처의 이식 가능한 입력 경계")
struct RetentionProvenanceAdmissionTests {
    private func parse(_ json: String) throws -> ExternalRetentionProvenance {
        try RetentionProvenanceAdmission.parseEnvelope(Data(json.utf8))
    }

    @Test("숫자 coercion 전 지수·소수·음의 영·안전 범위 밖을 거부한다",
          arguments: ["1.5", "1.0", "1e0", "1e-400", "1e400", "9007199254740992", "-9007199254740992", "-0"])
    func rejectsNumericTokens(_ token: String) {
        #expect(throws: (any Error).self) { try parse("{\"version\":2,\"n\":\(token)}") }
    }

    @Test("모르는 버전도 중복 decoded 키·짝 없는 surrogate·잘못된 UTF8를 거부한다")
    func rejectsMalformedRawContext() {
        for text in [#"{"version":2,"a":1,"a":2}"#, #"{"version":2,"a":1,"\u0061":2}"#,
                     #"{"version":2,"s":"\ud800"}"#, #"{"version":2,"\udfff":1}"#,
                     "null", #"{"version":"1"}"#, #"{"version":1,"limitations":null}"#] {
            #expect(throws: (any Error).self) { try parse(text) }
        }
        #expect(throws: (any Error).self) { try RetentionProvenanceAdmission.parseEnvelope(Data([123, 34, 255, 34, 58, 49, 125])) }
    }

    @Test("typed 값도 전체 정규 문자열을 만들기 전에 정확한 바이트 상한을 검사한다")
    func typedValueBoundary() throws {
        func value(_ text: String) -> RetentionProvenanceValue {
            .object(.init([.init(key: "version", value: .integer(2)), .init(key: "text", value: .string(text))]))
        }
        let base = value("한😀\n")
        let exact = value("한😀\n" + String(repeating: "x", count: 1_048_576 - base.canonicalJSON.utf8.count))
        #expect(try ExternalRetentionProvenance(value: exact).value == exact)
        let over = value("한😀\n" + String(repeating: "x", count: 1_048_577 - base.canonicalJSON.utf8.count))
        #expect(throws: (any Error).self) { try ExternalRetentionProvenance(value: over) }
        #expect(throws: (any Error).self) {
            try ExternalRetentionProvenance(value: .object(.init([.init(key: "version", value: .integer(2)),
                .init(key: "version", value: .integer(3))])))
        }
    }

    @Test("timestamp profile은 원문 대소문자와 소수 자릿수를 보존하고 시계·offset 상한을 검사한다")
    func portableTimestampProfile() throws {
        func raw(_ timestamp: String) -> String {
            #"{"version":1,"limitations":[],"sources":[{"format":"bridge-facts","version":1,"tool":{"name":"p","version":"1"},"platform":"swift","target":null,"project":"/p","generatedAt":"\#(timestamp)"}]}"#
        }
        for timestamp in ["2024-02-29t00:00:00z", "2024-02-29T23:59:59+23:59", "2024-02-29T00:00:00.12345678901234567890Z"] {
            #expect(try parse(raw(timestamp)).sources?.first?.object?["generatedAt"]?.string == timestamp)
        }
        for timestamp in ["2024-02-29T24:00:00Z", "2024-02-29T00:00:00+24:00", "2024-02-29T00:00:00+00:60", "2024-02-29T23:60:00Z", "2016-12-31T23:59:60Z"] {
            #expect(throws: (any Error).self) { try parse(raw(timestamp)) }
        }
    }

    @Test("알려진 원본 헤더는 실제 달력 날짜와 v2 transport를 요구한다")
    func validatesSourceHeaders() throws {
        let header = #"{"format":"bridge-facts","version":2,"tool":{"name":"producer","version":"1"},"platform":"swift","target":null,"project":"/p","generatedAt":"2024-02-29T00:00:00Z","transport":"event-channel"}"#
        let raw = "{\"version\":1,\"limitations\":[],\"sources\":[\(header)]}"
        #expect(try parse(raw).sources?.count == 1)
        #expect(throws: (any Error).self) { try parse(raw.replacingOccurrences(of: "2024-02-29", with: "2025-02-29")) }
        #expect(throws: (any Error).self) { try parse(raw.replacingOccurrences(of: #","transport":"event-channel""#, with: "")) }
    }

    @Test("정규화 동등한 서로 다른 키와 문자열을 합치지 않고 compact 왕복한다")
    func keepsDistinctUnicodeSpellings() throws {
        let raw = #"{"version":2,"é":"é","e\u0301":"e\u0301"}"#
        let value = try parse(raw)
        #expect(value.value.object?.members.count == 3)
        #expect(value.value.object?["é"] != value.value.object?["e\u{301}"])
        let restored = try parse(value.value.canonicalJSON)
        #expect(restored == value)
        #expect(value.value.canonicalJSON.utf8.count == 35)
    }

    @Test("깊이 64는 허용하고 65는 재귀 정규화 전에 거부한다")
    func depthBoundary() throws {
        let exact = "{\"version\":2,\"a\":" + String(repeating: "[", count: 63) + "null" + String(repeating: "]", count: 63) + "}"
        #expect(try parse(exact).version == 2)
        #expect(throws: (any Error).self) { try parse(exact.replacingOccurrences(of: "null", with: "[null]")) }
    }

    @Test("키·멀티바이트·escape를 포함한 정확한 1MiB 경계를 검사한다")
    func byteBoundary() throws {
        let base = #"{"version":2,"text":"한😀/\n\t\"\\"}"#
        let count = try parse(base).value.canonicalJSON.utf8.count
        let exact = base.replacingOccurrences(of: "한", with: String(repeating: "x", count: 1_048_576 - count) + "한")
        #expect(try parse(exact).value.canonicalJSON.utf8.count == 1_048_576)
        #expect(throws: (any Error).self) { try parse(exact.replacingOccurrences(of: "한", with: "x한")) }
    }

    @Test("원본과 한계 배열 상한은 모르는 버전에서도 적용한다")
    func collectionBoundaries() throws {
        for (key, limit) in [("sources", 256), ("limitations", 4096)] {
            let exact = "{\"version\":2,\"\(key)\":[" + Array(repeating: "null", count: limit).joined(separator: ",") + "]}"
            #expect(try parse(exact).version == 2)
            #expect(throws: (any Error).self) { try parse(exact.replacingOccurrences(of: "]}", with: ",null]}")) }
        }
    }

    @Test("snapshot compact 출처 키의 중복·escaped alias와 두 표현의 충돌을 먼저 거부한다")
    func rejectsAmbiguousStoredContext() throws {
        let duplicate = #"{"externalRetentionProvenanceJSON":"{\"version\":2}","externalRetentionProvenanceJSON":"{\"version\":3}"}"#
        let alias = #"{"externalRetentionProvenanceJSON":"{\"version\":2}","externalRetentionProvenanceJSO\u004e":"{\"version\":3}"}"#
        let conflicting = #"{"externalRetentions":{"provenance":{"version":2}},"externalRetentionProvenanceJSON":"{\"version\":3}"}"#
        for raw in [duplicate, alias, conflicting, #"{"externalRetentionProvenanceJSON":null}"#] {
            #expect(throws: (any Error).self) {
                try RetentionProvenanceAdmission.read(from: Data(raw.utf8), snapshot: true)
            }
        }
        let equal = conflicting.replacingOccurrences(of: #"\"version\":3"#, with: #"\"version\":2"#)
        #expect(try RetentionProvenanceAdmission.read(from: Data(equal.utf8), snapshot: true)?.version == 2)
    }

    @Test("snapshot의 출처 범위 밖 실수와 지수는 기존 숫자 도메인을 유지한다")
    func scopesSnapshotTokenRules() throws {
        let raw = #"{"unrelated":1.5,"externalRetentions":{"provenance":{"version":2,"x":1}}}"#
        #expect(try RetentionProvenanceAdmission.read(from: Data(raw.utf8), snapshot: true)?.version == 2)
        #expect(throws: (any Error).self) {
            try RetentionProvenanceAdmission.read(from: Data(raw.replacingOccurrences(of: #""x":1"#, with: #""x":1e0"#).utf8), snapshot: true)
        }
        #expect(try RetentionProvenanceAdmission.read(from: Data(#"{"externalRetentions":null}"#.utf8), snapshot: true) == nil)
    }
}
