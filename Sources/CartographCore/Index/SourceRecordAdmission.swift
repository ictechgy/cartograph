import Foundation

/// 한 compiler unit에서 실제 읽기를 마친 source record. 파일 시각만으로는 admission이 되지 않는다.
public struct SourceRecordAdmission: Sendable, Codable, Hashable {
    public var path: String
    public let module: String
    public let unit: String
    public let record: String
    public let timestamp: Date
    /// 컴파일러의 원문 unit output 신원. 가상 경로일 수 있으므로 실제 파일 경로로 해석하지 않는다.
    public let unitOutputIdentity: String?
    /// 같은 아키텍처 이름을 가진 서로 다른 플랫폼/배포 대상을 혼합하지 않는다.
    public let unitTargetTriple: String?

    public init(path: String, module: String, unit: String, record: String, timestamp: Date) {
        self.init(path: path, module: module, unit: unit, record: record, timestamp: timestamp,
            unitOutputIdentity: nil, unitTargetTriple: nil)
    }

    /// 실제 unit 신원을 제공하는 새 호출자도 기존 initializer 함수 참조를 바꾸지 않는다.
    public init(path: String, module: String, unit: String, record: String, timestamp: Date,
                unitOutputIdentity: String?, unitTargetTriple: String?) {
        self.path = path
        self.module = module
        self.unit = unit
        self.record = record
        self.timestamp = timestamp
        self.unitOutputIdentity = unitOutputIdentity
        self.unitTargetTriple = unitTargetTriple
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
            // nil과 빈 문자열은 decode에서 구분되므로 정렬 키도 구분한다.
            let left = ($0.unitOutputIdentity.map { "1" + $0 } ?? "0", $0.unitTargetTriple.map { "1" + $0 } ?? "0")
            let right = ($1.unitOutputIdentity.map { "1" + $0 } ?? "0", $1.unitTargetTriple.map { "1" + $0 } ?? "0")
            if left != right { return left < right }
            return $0.timestamp < $1.timestamp
        }
    }
}
