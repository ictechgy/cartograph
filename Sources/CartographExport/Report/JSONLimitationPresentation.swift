import Foundation

/// 분석 사실을 바꾸지 않고 명시적으로 요청한 JSON 한계의 표시만 줄인다.
/// 재입력되는 스냅샷·교환 문서는 이 표시 형식을 사용하지 않는다.
public enum JSONLimitationPresentation {
    /// 기본 full은 재인코딩도 하지 않아 기존 바이트 계약을 보존한다.
    public enum Mode: String, CaseIterable, Sendable {
        case full
        case summary
    }

    /// 요약을 만들 수 없으면 원문을 일부만 내보내지 않고 명시적으로 거부한다.
    public enum PresentationError: Error, LocalizedError {
        case invalidDocument
        case unsupportedFormat
        case invalidLimitations
        case budgetExceeded

        public var errorDescription: String? {
            switch self {
            case .invalidDocument:
                "--limitations summary requires a JSON report object; use JSON output or --limitations full."
            case .unsupportedFormat:
                "Limitation summaries cannot replace snapshot or exchange evidence; use --limitations full."
            case .invalidLimitations:
                "The report has an unsupported limitations shape; use --limitations full to retain "
                    + "the original evidence."
            case .budgetExceeded:
                "The report exceeds the limitation summary budget; use --limitations full to retain every note."
            }
        }
    }

    public static let maximumInputBytes = 16 * 1_024 * 1_024
    public static let maximumOutputBytes = 16 * 1_024 * 1_024
    public static let maximumGroups = 128
    public static let maximumExamplesPerGroup = 3
    public static let maximumExampleBytes = 512
    private static let maximumDepth = 64
    private static let maximumValues = 100_000

    /// 비용·출력 예산을 넘으면 실패하며 status·truncated·freshness 같은 판단 입력은 건드리지 않는다.
    /// noteCount는 경고 문장 수다. 문장 안의 파일·선언 수를 추측해서 합산하지 않는다.
    public static func render(_ data: Data, mode: Mode = .full) throws -> Data {
        guard mode == .summary else { return data }
        guard data.count <= maximumInputBytes else { throw PresentationError.budgetExceeded }
        guard let root = try? JSONSerialization.jsonObject(with: data), root is [String: Any] else {
            throw PresentationError.invalidDocument
        }
        var values = maximumValues
        var transformed = 0
        guard var result = try transform(root, depth: 0, values: &values, transformed: &transformed)
            as? [String: Any] else { throw PresentationError.invalidDocument }
        // 빈 배열을 생략하는 기존 보고서도 summary 요청 사실을 알린다. 원래 키의 부재는 유지한다.
        if transformed == 0 { result["limitationSummary"] = summary([]).metadata }
        let encoded = try JSONSerialization.data(withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= maximumOutputBytes else { throw PresentationError.budgetExceeded }
        return encoded
    }

    private static func transform(_ value: Any, depth: Int, values: inout Int,
                                  transformed: inout Int) throws -> Any {
        guard depth <= maximumDepth, values > 0 else { throw PresentationError.budgetExceeded }
        values -= 1
        if var object = value as? [String: Any] {
            if let format = object["format"] as? String, protectedFormats.contains(format) {
                throw PresentationError.unsupportedFormat
            }
            guard object["limitationSummary"] == nil else { throw PresentationError.invalidLimitations }
            if let raw = object["limitations"] {
                guard let notes = raw as? [String] else { throw PresentationError.invalidLimitations }
                guard notes.count <= values else { throw PresentationError.budgetExceeded }
                values -= notes.count
                let presentation = try boundedSummary(notes)
                object["limitations"] = presentation.notes
                object["limitationSummary"] = presentation.metadata
                transformed += 1
            }
            for key in object.keys.sorted() where key != "limitations" && key != "limitationSummary" {
                object[key] = try transform(object[key]!, depth: depth + 1, values: &values, transformed: &transformed)
            }
            return object
        }
        if let array = value as? [Any] {
            return try array.map { try transform($0, depth: depth + 1, values: &values, transformed: &transformed) }
        }
        return value
    }

    private static let protectedFormats: Set<String> = [
        "analysis-snapshot", "bridge-facts", "route-calls", "route-declarations", "relation-use",
        "schema-facts", "language-traversal", "runtime-trace", "runtime-contracts", "external-retentions",
        "coredata-build-evidence", "mechanical-fixes",
    ]

    private struct Presentation {
        let notes: [String]
        let metadata: [String: Any]
    }

    private static func boundedSummary(_ notes: [String]) throws -> Presentation {
        let codes = Set(notes.map(code))
        guard codes.count <= maximumGroups else { throw PresentationError.budgetExceeded }
        return summary(notes)
    }

    private static func summary(_ notes: [String]) -> Presentation {
        let grouped = Dictionary(grouping: notes, by: code)
        var detailsOmitted = false
        var output: [String] = []
        let groups: [[String: Any]] = grouped.keys.sorted().map { key in
            let messages = grouped[key]!
            let counts = Dictionary(grouping: messages, by: { $0 }).mapValues(\.count)
            let chosen = counts.keys.sorted().prefix(maximumExamplesPerGroup)
            var exampleNotes = 0
            var truncatedExamples = 0
            let examples: [[String: Any]] = chosen.map { note in
                let count = counts[note]!
                exampleNotes += count
                let text = boundedText(note)
                let truncated = text.utf8.count < note.utf8.count
                if truncated { truncatedExamples += 1 }
                return ["text": text, "occurrences": count, "originalBytes": note.utf8.count,
                        "truncated": truncated]
            }
            let omitted = messages.count - exampleNotes
            detailsOmitted = detailsOmitted || omitted > 0 || truncatedExamples > 0
            let label = key.isEmpty ? "uncoded-limitations" : key
            output.append("\(label): \(messages.count) limitation note(s), \(counts.count) distinct message(s). "
                + "See limitationSummary examples; use --limitations full for original details.")
            return ["code": key.isEmpty ? NSNull() : key as Any, "noteCount": messages.count,
                    "distinctNoteCount": counts.count, "examples": examples,
                    "omittedNoteCount": omitted, "omittedDistinctNoteCount": counts.count - examples.count,
                    "truncatedExampleCount": truncatedExamples]
        }
        if !notes.isEmpty {
            output.insert("limitation-summary: presentation only; results may be incomplete or stale. "
                + "An empty result is not a safety guarantee.", at: 0)
        }
        return Presentation(notes: output, metadata: [
            "version": 1, "mode": "summary", "noteCount": notes.count, "groupCount": groups.count,
            "detailsOmitted": detailsOmitted, "groups": groups,
            "countsDescribe": "limitation messages, not affected files or declarations",
            "maximumExamplesPerGroup": maximumExamplesPerGroup, "maximumExampleBytes": maximumExampleBytes,
        ])
    }

    /// 알려지지 않은 코드도 정확한 철자별로 묶고, 임의 산문은 코드로 추측하지 않는다.
    private static func code(_ note: String) -> String {
        guard let colon = note.firstIndex(of: ":") else { return "" }
        let prefix = note[..<colon]
        guard !prefix.isEmpty, prefix.utf8.count <= 128,
              prefix.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              prefix.utf8.first.map({ (97...122).contains($0) }) == true else { return "" }
        return String(prefix)
    }

    /// UTF-8 중간에서 자르지 않아 원문에 없던 대체 문자를 예시로 만들지 않는다.
    private static func boundedText(_ text: String) -> String {
        var count = 0
        return String(text.unicodeScalars.prefix { scalar in
            let next = String(scalar).utf8.count
            guard count + next <= maximumExampleBytes else { return false }
            count += next
            return true
        })
    }
}
