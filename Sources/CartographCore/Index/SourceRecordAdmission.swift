import Foundation

/// 한 compiler unit에서 실제 읽기를 마친 source record. 파일 시각만으로는 admission이 되지 않는다.
public struct SourceRecordAdmission: Sendable, Codable, Hashable {
    public var path: String
    public let module: String
    public let unit: String
    public let record: String
    public let timestamp: Date

    public init(path: String, module: String, unit: String, record: String, timestamp: Date) {
        self.path = path
        self.module = module
        self.unit = unit
        self.record = record
        self.timestamp = timestamp
    }

    public func rebased(_ transform: (String) -> String) -> Self {
        var result = self
        result.path = transform(path)
        return result
    }

    public static func sorted(_ admissions: [Self]) -> [Self] {
        Array(Set(admissions)).sorted {
            if ($0.path, $0.module, $0.unit, $0.record) != ($1.path, $1.module, $1.unit, $1.record) {
                return ($0.path, $0.module, $0.unit, $0.record) < ($1.path, $1.module, $1.unit, $1.record)
            }
            return $0.timestamp < $1.timestamp
        }
    }
}
