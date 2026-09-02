import CartographAnalysis
import CartographCore
import Foundation

/// 아키텍처 지표를 표 또는 JSON 으로 내보낸다.
///
/// 지표는 진단(문제)이 아니라 관측값이라 별도 표현이 필요하다.
/// 임계값을 넘은 항목만 진단으로 따로 나간다.
public struct MetricsRenderer: Sendable {
    private let tolerance: Double

    public init(tolerance: Double = 0.3) {
        self.tolerance = tolerance
    }

    /// 고정폭 표. 열 너비를 내용에 맞춰 계산해 정렬이 흐트러지지 않게 한다.
    public func renderTable(_ metrics: [NodeMetrics]) -> String {
        guard !metrics.isEmpty else { return "No nodes to measure.\n" }

        let headers = ["NODE", "Ca", "Ce", "I", "A", "D", "ZONE"]
        let rows = metrics.map { entry in
            [
                entry.name,
                String(entry.afferentCoupling),
                String(entry.efferentCoupling),
                Self.format(entry.instability),
                Self.format(entry.abstractness),
                Self.format(entry.distanceFromMainSequence),
                entry.zone(tolerance: tolerance).rawValue,
            ]
        }

        let widths = headers.indices.map { column in
            max(headers[column].count, rows.map { $0[column].count }.max() ?? 0)
        }
        func line(_ values: [String]) -> String {
            values.indices
                .map { index in
                    // 첫 열은 이름이라 왼쪽, 나머지 숫자는 오른쪽 정렬이 읽기 좋다.
                    index == 0
                        ? values[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
                        : String(repeating: " ", count: widths[index] - values[index].count) + values[index]
                }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }

        var output = [line(headers), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")]
        output.append(contentsOf: rows.map(line))
        output.append("")
        output.append(legend)
        return output.joined(separator: "\n") + "\n"
    }

    /// 지표와 임계값 위반을 한 문서에 담는다.
    ///
    /// 두 개의 JSON 문서를 이어 붙이면 어떤 파서도 읽지 못한다.
    public func renderJSON(
        _ metrics: [NodeMetrics],
        diagnostics: [Diagnostic] = [],
        suppressedCount: Int = 0
    ) throws -> String {
        struct Entry: Encodable {
            let node: String
            let name: String
            let afferentCoupling: Int
            let efferentCoupling: Int
            let instability: Double
            let abstractness: Double
            let distanceFromMainSequence: Double
            let zone: String
            let typeCount: Int
            let abstractTypeCount: Int
        }
        struct Document: Encodable {
            let tool: String
            let version: String
            let tolerance: Double
            let metrics: [Entry]
            let diagnostics: [Diagnostic]
            /// 베이스라인이 걸러 낸 진단 수. 텍스트 출력에만 있으면 기계 소비자가
            /// 억제 사실을 알 수 없다.
            let suppressedCount: Int
        }

        let document = Document(
            tool: Cartograph.toolName,
            version: Cartograph.version,
            tolerance: tolerance,
            metrics: metrics.map { entry in
                Entry(
                    node: entry.node.rawValue,
                    name: entry.name,
                    afferentCoupling: entry.afferentCoupling,
                    efferentCoupling: entry.efferentCoupling,
                    instability: Self.rounded(entry.instability),
                    abstractness: Self.rounded(entry.abstractness),
                    distanceFromMainSequence: Self.rounded(entry.distanceFromMainSequence),
                    zone: entry.zone(tolerance: tolerance).rawValue,
                    typeCount: entry.composition.total,
                    abstractTypeCount: entry.composition.abstract
                )
            },
            diagnostics: diagnostics.sorted(),
            suppressedCount: suppressedCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }

    private var legend: String {
        """
        Ca afferent coupling · Ce efferent coupling · I instability Ce/(Ca+Ce)
        A abstractness · D distance from the main sequence |A+I-1| (tolerance \(Self.format(tolerance)))
        """
    }

    /// 소수점 둘째 자리 고정. 표의 열이 흔들리지 않게 한다.
    static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
