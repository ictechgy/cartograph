import Foundation

// 상속 절에 Encodable 이 직접 없고 프로젝트 프로토콜을 거쳐 준수한다. 저장 프로퍼티는 합성 `encode(to:)` 만 읽는다.
// 상속 절의 글자만 보던 판정은 `password` 를 미사용으로 보고했고, 지우면 전송 페이로드가 바뀐다.
protocol SynthesizedCorpusRequest: Encodable {}

struct SynthesizedCorpusLogin: SynthesizedCorpusRequest {
    let password: String
}

// 사용자 별칭으로 쓴 조합 준수. 인덱스가 별칭을 실제 프로토콜 준수(s:SE·s:Se·s:SH)로 풀어 기록한다는 전제의 실증이다.
typealias SynthesizedCorpusModel = Codable & Hashable

struct SynthesizedCorpusRecord: SynthesizedCorpusModel {
    let identifier: Int
}

// 원시값 없는 Codable 열거형의 케이스는 합성 디코딩이 이름으로 만든다. 소스에서는 한 번도 만들지 않는다.
enum SynthesizedCorpusPaymentState: Codable {
    case pending
    case settled
}

struct SynthesizedCorpusPayment: Codable {
    let state: SynthesizedCorpusPaymentState
}

/// 합성 준수가 읽거나 만드는 선언을 진입점에서 도달하게 한다.
public func exerciseSynthesizedConformanceShapes() {
    let encoder = JSONEncoder()
    _ = try? encoder.encode(SynthesizedCorpusLogin(password: "secret"))
    _ = try? encoder.encode(SynthesizedCorpusRecord(identifier: 1))
    _ = try? JSONDecoder().decode(SynthesizedCorpusPayment.self, from: Data(#"{"state":{"settled":{}}}"#.utf8))
}
