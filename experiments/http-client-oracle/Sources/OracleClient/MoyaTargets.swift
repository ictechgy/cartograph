import Foundation
import Moya

/// Moya 타겟. `path` 의 `?`·`%` 는 `URL(target:)` 의 `appendingPathComponent` 가 인코딩한다.
enum UserAPI {
    case list
    case detail(id: Int)
    case search(query: String)
    case avatar
    case root
    case file(name: String)
}

extension UserAPI: TargetType {
    var baseURL: URL { URL(string: "http://api.oracle.test/v1")! }

    var path: String {
        switch self {
        case .list: return "/users" // oracle: moya.list
        case .detail(let id): return "/users/\(id)" // oracle: moya.detail
        case .search: return "users/search?draft=1" // oracle: moya.search-question-mark
        case .avatar: return "users/avatar" // oracle: moya.avatar
        case .root: return "" // oracle: moya.root
        case .file: return "files/a%20b" // oracle: moya.percent
        }
    }

    var method: Moya.Method {
        switch self {
        case .avatar, .root: return .post
        default: return .get
        }
    }

    var task: Task { .requestPlain }
    var headers: [String: String]? { nil }
}

/// 원시값을 경로로 쓰는 타겟.
enum PathsAPI: String, TargetType {
    case health
    case posts = "blog/posts"

    var baseURL: URL { URL(string: "http://api.oracle.test/v4")! }
    var path: String { rawValue } // oracle: moya.rawvalue-implicit@health moya.rawvalue-explicit@posts
    var method: Moya.Method { .get }
    var task: Task { .requestPlain }
    var headers: [String: String]? { nil }
}

extension OracleClient {
    static let moyaCases = [
        "moya.list", "moya.detail", "moya.search-question-mark", "moya.avatar", "moya.root", "moya.percent",
        "moya.rawvalue-implicit", "moya.rawvalue-explicit",
    ]

    func runMoya(_ id: String) async throws -> Bool {
        switch id {
        case "moya.list": await request(users, .list)
        case "moya.detail": await request(users, .detail(id: 3))
        case "moya.search-question-mark": await request(users, .search(query: "q"))
        case "moya.avatar": await request(users, .avatar)
        case "moya.root": await request(users, .root)
        case "moya.percent": await request(users, .file(name: "n"))
        case "moya.rawvalue-implicit": await request(paths, .health)
        case "moya.rawvalue-explicit": await request(paths, .posts)
        default: return false
        }
        return true
    }

    private func request<Target: TargetType>(_ provider: MoyaProvider<Target>, _ target: Target) async {
        await withCheckedContinuation { continuation in
            provider.request(target) { _ in continuation.resume() }
        }
    }
}
