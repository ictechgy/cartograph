import CartographAnalysis
import CartographCore
import Foundation

/// 정점 하나에 대한 질의 결과.
///
/// 그래프 전체를 덤프하면 간선이 수만 개다. 사람도 에이전트도 그것을 읽지 못한다.
/// 이 타입은 "이 심볼 하나"에 대한 사실만 작게 담는다.
///
/// **판정을 불리언으로 내지 않는다.** "지워도 된다"는 값은 이 도구가 데이터 구조의
/// 권위로 단언하는 것이 되는데, 분석이 보지 못하는 채널(Objective-C 소스, 컴파일되지
/// 않은 `#if` 분기, 매크로 확장)이 실재한다. 사람이 읽는 문장은 이미
/// "어떤 보존 루트에서도 도달할 수 없다"이지 "지워도 된다"가 아니다.
/// 기계가 읽는 답이 사람이 읽는 답보다 더 확신해서는 안 된다.
public struct SymbolQuery: Sendable, Equatable, Codable {
    /// 질의 대상 정점.
    public struct Subject: Sendable, Equatable, Codable {
        public let name: String
        public let qualifiedName: String
        public let kind: String
        public let module: String?
        public let usr: String?
        public let accessibility: String
        public let location: SourceLocation?
    }

    /// 이웃 정점 하나와 그 관계.
    public struct Neighbor: Sendable, Equatable, Codable {
        public let name: String
        public let qualifiedName: String
        public let kind: String
        public let usr: String?
        public let module: String?
        /// 이 이웃에 닿는 간선의 종류 전부.
        ///
        /// 하나만 골라 보고하면 나머지 관계가 응답에서 사라진다. 어떤 서브클래스가
        /// 부모를 호출하면서 동시에 오버라이드하고 있다면, 둘 중 하나만 보이는 답을
        /// 근거로 삭제를 결정하게 된다.
        public let edges: [String]
        /// `subject` 에서 몇 걸음 떨어져 있는지. 1 이면 직접 이웃이다.
        public let depth: Int
        public let location: SourceLocation?
    }

    /// 살아 있는지에 대한 사실. 판정이 아니라 관측이다.
    public struct Reachability: Sendable, Equatable, Codable {
        /// `retained`, `retainedByMember`, `reachable`, `unreachable`, `unknown`.
        public let state: String
        /// 보존 규칙이 살렸다면 그 근거. 산문이 아니라 규칙 이름이다.
        public let reason: RetentionReason?
        /// 도달했다면 뿌리에서 여기까지의 경로.
        public let path: [String]?
        /// 팀이 베이스라인으로 이미 알고 남겨 둔 것인지 여부.
        ///
        /// 이것이 없으면 에이전트가 팀의 결정을 다시 심사하게 된다.
        public let suppressedByBaseline: Bool
    }

    public let subject: Subject
    public let reachability: Reachability
    /// 이 정점을 쓰는 쪽.
    public let usedBy: [Neighbor]
    /// 이 정점이 쓰는 쪽.
    public let dependsOn: [Neighbor]
    /// 이 선언이 담고 있는 것들. 타입이면 그 멤버다.
    ///
    /// 담는 관계는 쓰는 관계가 아니므로 `dependsOn` 에 넣지 않는다. 그렇게 하면
    /// 도구가 "FooManager 가 fetchUser() 를 쓴다"고 말하게 되는데 사실이 아니다.
    /// 그렇다고 빼 버리면 클래스에 물었을 때 `dependsOn` 이 비어 나오고, 그것은
    /// "이 클래스는 아무것도 의존하지 않는다"로 읽힌다. 심볼 레벨 그래프에서
    /// 타입의 의존은 전부 멤버가 들고 있다. 이름을 따로 주는 것만이 비어 있지도
    /// 않고 거짓말도 아닌 유일한 방법이다.
    public let members: [Neighbor]
    /// 이 선언을 담고 있는 것. 메서드나 프로퍼티면 그것을 선언한 타입이다.
    public let declaredIn: Neighbor?
    /// 한도에 걸려 잘렸는지 여부. 잘린 사실을 숨기면 답이 거짓말이 된다.
    public let truncated: Truncation
    public struct Truncation: Sendable, Equatable, Codable {
        public let usedBy: Bool
        public let dependsOn: Bool
        public let members: Bool
    }

    public init(
        subject: Subject,
        reachability: Reachability,
        usedBy: [Neighbor],
        dependsOn: [Neighbor],
        members: [Neighbor],
        declaredIn: Neighbor?,
        truncated: Truncation
    ) {
        self.subject = subject
        self.reachability = reachability
        self.usedBy = usedBy
        self.dependsOn = dependsOn
        self.members = members
        self.declaredIn = declaredIn
        self.truncated = truncated
    }
}

/// `query` 명령이 실제로 내보내는 문서.
///
/// 이름이 여럿에 걸릴 때 하나를 골라 답하지 않는다. 사람이라면 목록을 보고 다시
/// 묻지만 에이전트는 받은 답을 그대로 행동으로 옮기므로, 추측한 답 하나가
/// 후보 목록보다 훨씬 위험하다.
public struct SymbolQueryDocument: Sendable, Equatable, Codable {
    /// 이름 하나에 걸린 후보. 다시 물을 때 쓸 USR 을 같이 준다.
    public struct Candidate: Sendable, Equatable, Codable {
        public let qualifiedName: String
        public let usr: String?

        public init(qualifiedName: String, usr: String?) {
            self.qualifiedName = qualifiedName
            self.usr = usr
        }
    }

    /// `found` / `ambiguous` / `notFound`.
    public let status: String
    /// 사용자가 물어본 문자열 그대로. 로그에서 질문과 답을 짝지을 수 있어야 한다.
    public let requested: String
    /// 어느 레벨의 그래프에서 답했는지. 심볼 레벨 답을 모듈 레벨로 읽으면 안 된다.
    public let level: String
    /// 이 분석이 보지 못하는 채널. 상태와 무관하게 모든 응답에 함께 보낸다.
    ///
    /// 문서에만 적어 두면 에이전트는 읽지 않는다. `notFound` 에도 필요하다.
    /// Objective-C 로 선언된 이름을 물었을 때 "그런 것 없다"는 답만 받으면,
    /// 없는 것과 이 도구가 못 보는 것을 구분할 수 없다.
    public let limitations: [String]
    public let result: SymbolQuery?
    public let candidates: [Candidate]?

    public init(
        status: String,
        requested: String,
        level: String,
        limitations: [String],
        result: SymbolQuery? = nil,
        candidates: [Candidate]? = nil
    ) {
        self.status = status
        self.requested = requested
        self.level = level
        self.limitations = limitations
        self.result = result
        self.candidates = candidates
    }
}

/// 여러 선언을 한 번에 물은 결과.
///
/// 43건을 쓸어보려면 프로세스를 43번 띄워야 했고 매번 인덱스를 다시 읽어 약 43초가 들었다.
/// 답 하나하나는 싸고 그 앞의 준비가 비싸다. 그래서 그래프와 도달성은 한 번만 만들고
/// 질문만 반복한다.
///
/// `results` 는 **요청 순서와 중복을 그대로 지킨다.** 중복을 접으면 부르는 쪽이 요청 배열과
/// 결과 배열을 인덱스로 짝지을 수 없다.
///
/// 형식은 자매 저장소 dartograph 가 먼저 출하한 `symbol-query-batch` v1 과 같다.
/// 에이전트가 언어마다 다른 응답을 배우게 하지 않기 위해서다.
public struct SymbolQueryBatchDocument: Sendable, Equatable, Codable {
    /// 교환 형식 이름. 소비자가 단일 `query` 응답과 구분할 수 있어야 한다.
    public let format: String
    /// 형식 버전.
    public let version: Int
    /// 요청 하나에 대한 답 하나. 각 원소는 단일 `query` 가 내는 문서와 같다.
    public let results: [SymbolQueryDocument]

    public init(results: [SymbolQueryDocument]) {
        self.format = "symbol-query-batch"
        self.version = 1
        self.results = results
    }
}

/// 배치 요청 파일을 읽는다.
///
/// **인덱스를 열기 전에** 검사한다. 색인을 다 만든 뒤에 "요청 배열이 비었다" 를 말하면,
/// 사용자는 몇 초를 기다린 대가로 오타 하나를 받는다.
public enum SymbolQueryBatchRequests {
    /// 한 번에 물을 수 있는 요청 수의 위와 아래.
    ///
    /// 위 한계가 없으면 요청 하나가 백만 개짜리 배열이어도 받아들이게 되고, 그때
    /// 실패하는 자리는 이 명령이 아니라 메모리다.
    public static let countRange = 1...1000
    /// 요청 파일의 최대 크기. 이름 목록이 1 MiB 를 넘으면 그것은 다른 문제다.
    public static let maximumByteCount = 1024 * 1024

    /// 요청 목록을 얻는다. 형식이 어긋나면 그 자리를 말하며 던진다.
    public static func parse(_ data: Data, path: String) throws -> [String] {
        guard data.count <= maximumByteCount else {
            throw CartographError.invalidBatchRequests(
                path: path, reason: "the file is \(data.count) bytes"
            )
        }
        let decoded: [String]
        do {
            decoded = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw CartographError.invalidBatchRequests(
                path: path, reason: "it is not a JSON array of strings"
            )
        }
        guard countRange.contains(decoded.count) else {
            throw CartographError.invalidBatchRequests(
                path: path, reason: "it holds \(decoded.count) request(s)"
            )
        }
        if let index = decoded.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw CartographError.invalidBatchRequests(
                path: path, reason: "request \(index) is empty"
            )
        }
        return decoded
    }
}
