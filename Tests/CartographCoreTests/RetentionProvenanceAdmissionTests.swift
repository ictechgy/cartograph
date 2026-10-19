import CartographCore
import Foundation
import Testing

@Suite("외부 보존 출처의 이식 가능한 입력 경계")
struct RetentionProvenanceAdmissionTests {
    private func parse(_ json: String) throws -> ExternalRetentionProvenance {
        try RetentionProvenanceAdmission.parseEnvelope(Data(json.utf8))
    }

    @Test("순서 있는 객체 저장소는 JSON 값 없이도 동작하며 Unicode 키 신원을 구분한다")
    func storageDoesNotDependOnJSONValues() {
        let object = RetentionProvenanceObject<Int>([
            .init(key: "é", value: 1), .init(key: "e\u{0301}", value: 2)])
        #expect(object["é"] == 1)
        #expect(object["e\u{0301}"] == 2)
        #expect(object.values == [1, 2])
        #expect(object == RetentionProvenanceObject<Int>([
            .init(key: "e\u{0301}", value: 2), .init(key: "é", value: 1)]))
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

    /// 출처 경로 밖 문자열 token이 놓이는 자리. 값·배열 원소·키·찾는 경로의 형제 키를 모두 지난다.
    private static let unrelatedPlacements: [(template: String, snapshot: Bool)] = [
        (#"{"junk":TOKEN,"provenance":{"version":2}}"#, false),
        (#"{"junk":[1,{"k":TOKEN}],"provenance":{"version":2}}"#, false),
        (#"{"junk":{TOKEN:1},"provenance":{"version":2}}"#, false),
        (#"{TOKEN:1,"provenance":{"version":2}}"#, false),
        (#"{"snapshot":[TOKEN],"externalRetentions":{"provenance":{"version":2}}}"#, true),
        (#"{"externalRetentions":{"producedBy":TOKEN,"provenance":{"version":2}}}"#, true),
        (#"{"externalRetentions":{TOKEN:1,"provenance":{"version":2}}}"#, true),
        (#"{"externalRetentions":{"provenance":{"version":2}},"limitations":{TOKEN:TOKEN}}"#, true),
        ("\n {\n  \"junk\" : [ TOKEN ] ,\n  \"provenance\" : { \"version\" : 2 }\n} \n", false),
        ("\t{ \"snapshot\" : { \"k\" : TOKEN } ,\r\n"
            + " \"externalRetentions\" : { \"provenance\" : { \"version\" : 2 } } }", true),
    ]

    /// 오류를 비교할 문구로 바꾼다. NSError의 userInfo 출력 순서는 인스턴스마다 달라 키를 정렬한다.
    private static func fingerprint(_ error: any Error) -> String {
        guard case let DecodingError.dataCorrupted(context) = error else { return String(describing: error) }
        guard let underlying = context.underlyingError.map({ $0 as NSError }) else { return context.debugDescription }
        let details = underlying.userInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "\(context.debugDescription) \(underlying.domain) \(underlying.code) \(details)"
    }

    private static func readError(_ raw: String, snapshot: Bool) -> String? {
        do {
            let provenance = try RetentionProvenanceAdmission.read(from: Data(raw.utf8), snapshot: snapshot)
            return provenance?.version == 2 ? nil : "missing provenance"
        } catch { return fingerprint(error) }
    }

    /// 사전 검사가 스스로 내는 형식 오류. 원시 제어 문자와 구조 오류가 이 문구로 끝난다.
    private static let malformed = "External retention provenance is malformed or exceeds its bounds."

    /// 사전 검사는 원시 제어 문자를 스스로 거부하고, 나머지 문자열은 JSONDecoder의 문자열 계약을 따른다.
    private static func expectedError(_ token: String, rawControl: Bool) -> String? {
        guard !rawControl else { return malformed }
        do { _ = try JSONDecoder().decode(String.self, from: Data(token.utf8)); return nil }
        catch { return fingerprint(error) }
    }

    @Test("출처 경로 밖 문자열도 잘못된 escape·짝 없는 surrogate·원시 제어 문자를 예전 오류 그대로 거부한다")
    func validatesUnrelatedStringsLikeDecoder() {
        let decoderJudged = [#""\x41""#, #""\ud800""#, #""\udc00""#, #""\ud800\u0041""#, #""\udbff\ud800""#,
                             #""\u12""#, #""\u1\"x""#, #""\ud83d\ude0""#, "\"\\\n\"", #""\'""#,
                             #""\ud83d\ude00""#, #""\uD83D\uDE00""#, #""\u0000""#, #""\uffff""#, #""\u004e""#,
                             #""\/\b\f\n\r\t\"\\""#, #""한😀""#, #""""#]
        let scannerRejected = ["\"a\u{01}b\"", "\"\u{1f}\"", "\"\\x\u{0}\""]
        for (template, snapshot) in Self.unrelatedPlacements {
            for (tokens, rawControl) in [(decoderJudged, false), (scannerRejected, true)] {
                for token in tokens {
                    let raw = template.replacingOccurrences(of: "TOKEN", with: token)
                    let expected = Self.expectedError(token, rawControl: rawControl)
                    #expect(Self.readError(raw, snapshot: snapshot) == expected, "\(raw)")
                }
            }
        }
    }

    @Test("snapshot 한 번 순회에서도 compact 키 중복은 형제 값 검사와 inline 출처 검사 뒤에 거부한다")
    func keepsSnapshotRejectionOrder() throws {
        let stored = #""externalRetentionProvenanceJSON":"{\"version\":2}""#
        let source = #"{"format":"bridge-facts","version":1,"tool":{"name":"p","version":"1"},"platform":"swift","#
            + #""target":null,"project":"/p","generatedAt":"2024-02-30T00:00:00Z"}"#
        let badTimestamp = #"{"version":1,"limitations":[],"sources":["# + source + "]}"
        let timestampFirst = "{" + stored + "," + stored
            + #","externalRetentions":{"provenance":"# + badTimestamp + "}}"
        #expect(Self.readError(timestampFirst, snapshot: true)?.contains("outside the portable profile") == true)
        let laterEscape = "{" + stored + ","
            + stored.replacingOccurrences(of: #""{\"version\":2}""#, with: #""\x""#) + "}"
        #expect(Self.readError(laterEscape, snapshot: true) == Self.expectedError(#""\x""#, rawControl: false))
        let duplicate = "{" + stored + #","externalRetentions":{"provenance":{"version":2}},"# + stored + "}"
        #expect(Self.readError(duplicate, snapshot: true) == Self.malformed)
        let aliasedInline = #"{"externalRetentions":{},"externalRetention\u0073":{}}"#
        #expect(Self.readError(aliasedInline, snapshot: true) == Self.malformed)
    }

    @Test("따옴표를 품은 잘못된 스칼라 뒤에서는 compact 키를 예전 두 번째 순회 그대로 판정한다")
    func replaysStoredSearchAfterAmbiguousScalar() {
        let stored = #""externalRetentionProvenanceJSON":"{\"version\":2}""#
        // 멤버 순회는 x" 를 스칼라로 삼키지만, 예전 두 번째 순회의 건너뛰기는 " 를 문자열 시작으로 읽었다.
        let unterminated = #"{"externalRetentions":{"a":x"},"# + "\n" + stored + "}"
        #expect(Self.readError(unterminated, snapshot: true) == Self.malformed)
        let rebalanced = #"{"externalRetentions":{"a":x"y"},"# + stored + "}"
        #expect(Self.readError(rebalanced, snapshot: true) == nil)
    }
}
