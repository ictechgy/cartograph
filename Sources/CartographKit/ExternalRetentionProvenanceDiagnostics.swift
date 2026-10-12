import CartographCore
import Foundation

/// 저장한 전체 출처와 화면 예산을 구분한다. 매치된 보존 근거는 어떤 한계에서도 취소하지 않는다.
enum ExternalRetentionProvenanceDiagnostics {
    static let maximumRecords = 64
    static let maximumBytes = 8192

    static func limitations(_ provenance: ExternalRetentionProvenance?) -> [String] {
        guard let provenance else {
            return ["external-retentions-provenance-unavailable: this legacy document has no upstream capture context or limitations; retained roots remain in effect and completeness is unknown"]
        }
        guard provenance.version == 1 else {
            return ["external-retentions-provenance-unsupported: provenance version \(provenance.version) is preserved but not interpreted; retained roots remain in effect and completeness is unknown"]
        }
        let sources = provenance.sources ?? []
        let limitations = provenance.limitations ?? []
        var result = ["external-retentions-provenance: \(sources.count) source capture(s), \(limitations.count) upstream limitation(s); conversion time is not source or compiler freshness, and empty limitations do not establish completeness"]
        if sources.isEmpty {
            result.append("external-retentions-source-context-unavailable: source capture headers are absent or empty; completeness and freshness are unknown")
        }
        // 전체 값의 UTF-8 바이트 신원으로 정렬한다. 정규화 동등 Unicode 문자열도 합치지 않는다.
        let records = limitations.map { "external-retentions-upstream: " + display($0.canonicalJSON) }
            + sources.map { "external-retentions-source: " + display($0.canonicalJSON) }
        let ordered = records.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var bytes = 0
        var shown = 0
        for record in ordered {
            guard shown < maximumRecords, bytes + record.utf8.count <= maximumBytes else { break }
            result.append(record)
            bytes += record.utf8.count
            shown += 1
        }
        if shown < ordered.count {
            result.append("external-retentions-provenance-display: \(shown) of \(ordered.count) context record(s) shown; \(ordered.count - shown) omitted from display, with full admitted context preserved in snapshots")
        }
        return result
    }

    private static func display(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if PrintableText.printable(String(scalar)).isEmpty || scalar.value == 0x2028 || scalar.value == 0x2029 {
                if scalar.value > 0xffff {
                    let adjusted = scalar.value - 0x10000
                    result += String(format: "\\u%04x\\u%04x", 0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff))
                } else { result += String(format: "\\u%04x", scalar.value) }
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
}
