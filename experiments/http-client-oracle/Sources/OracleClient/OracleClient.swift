import Alamofire
import Foundation
import Moya

/// 오라클이 실행하는 합성 앱 클라이언트.
///
/// 요청마다 cartograph 사실이 놓이는 줄 끝에 `oracle:` 주석으로 case 식별자를 단다. 한 줄에 사실이 여럿이면
/// `식별자@case` 로 사실의 enum case 를 지목한다. 러너는 `caseIDs` 순서로 하나씩 실행하고 끝날 때까지 기다린다.
public final class OracleClient {
    let session: URLSession
    let af: Session
    let users: MoyaProvider<UserAPI>
    let paths: MoyaProvider<PathsAPI>

    public init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
        af = Session(configuration: configuration)
        users = MoyaProvider<UserAPI>(session: Session(configuration: configuration))
        paths = MoyaProvider<PathsAPI>(session: Session(configuration: configuration))
    }

    /// 실행 순서. 기록 서버는 이 순서로 받은 요청을 case 에 묶는다.
    public static let caseIDs = foundationCases + componentsCases + alamofireCases + routerCases + moyaCases

    public func run(_ id: String) async throws {
        if try await runFoundation(id) { return }
        if try await runComponents(id) { return }
        if try await runAlamofire(id) { return }
        if try await runRouter(id) { return }
        if try await runMoya(id) { return }
        throw URLError(.unsupportedURL)
    }
}
