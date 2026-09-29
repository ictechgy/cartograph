import Alamofire
import Foundation

/// Alamofire 문서의 라우터 모양. `asURLRequest()` 가 `path` 를 base 에 `appendingPathComponent` 로 붙인다.
enum Router: URLRequestConvertible {
    case users
    case user(id: Int)
    case create

    static let baseURLString = "http://api.oracle.test/v3"

    var method: HTTPMethod {
        switch self {
        case .users, .user: return .get
        case .create: return .post
        }
    }

    var path: String {
        switch self {
        case .users: return "/users" // oracle: router.users
        case .user(let id): return "/users/\(id)" // oracle: router.user
        case .create: return "/users?draft" // oracle: router.create-question-mark
        }
    }

    func asURLRequest() throws -> URLRequest {
        let url = try Router.baseURLString.asURL()
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.method = method
        return request
    }
}

extension OracleClient {
    static let routerCases = ["router.users", "router.user", "router.create-question-mark"]

    func runRouter(_ id: String) async throws -> Bool {
        let route: Router
        switch id {
        case "router.users": route = .users
        case "router.user": route = .user(id: 5)
        case "router.create-question-mark": route = .create
        default: return false
        }
        _ = await af.request(route).serializingData().response
        return true
    }
}
