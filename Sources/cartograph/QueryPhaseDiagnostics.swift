import CartographKit
import Foundation

/// 진단 소유권은 CLI에만 둔다. 배치에서 반복된 단계는 잠금 아래 합산한다.
final class QueryPhaseDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [QueryPhase: Duration] = [:]

    var observer: QueryPhaseObserver {
        { [self] phase, duration in record(phase, duration: duration) }
    }

    static func withDiagnostics<Value>(
        environment: [String: String],
        sink: FileHandle,
        _ body: (QueryPhaseObserver?) throws -> Value
    ) rethrows -> Value {
        let diagnostics = environment["CARTOGRAPH_DIAGNOSTIC_QUERY_PHASES"] == "1"
            ? QueryPhaseDiagnostics() : nil
        defer { diagnostics?.write(to: sink) }
        return try body(diagnostics?.observer)
    }

    func record(_ phase: QueryPhase, duration: Duration) {
        lock.withLock { durations[phase, default: .zero] += duration }
    }

    func line() -> String {
        let snapshot = lock.withLock { durations }
        let fields = QueryPhase.allCases.map { phase in
            let value = snapshot[phase].map(Self.seconds) ?? "not_run"
            return "\(phase.rawValue)=\(value)"
        }
        return "cartograph-query-phases-v1 " + fields.joined(separator: " ") + "\n"
    }

    /// 진단 실패로 이미 정해진 질의 결과나 원래 오류를 바꾸지 않는다.
    func write(to sink: FileHandle) {
        do {
            try sink.write(contentsOf: Data(line().utf8))
        } catch {
            // 닫힌 stderr 등에 진단 오류를 다시 쓰지 않는다. 관측만 조용히 포기한다.
            return
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}
