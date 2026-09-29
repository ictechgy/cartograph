import Foundation

extension OracleClient {
    static let componentsCases = [
        "components.path-question-mark", "components.path-percent", "components.percent-encoded-path",
        "components.string-append", "components.interpolated",
    ]

    func runComponents(_ id: String) async throws -> Bool {
        switch id {
        case "components.path-question-mark": try await pathQuestionMark()
        case "components.path-percent": try await pathPercent()
        case "components.percent-encoded-path": try await percentEncodedPath()
        case "components.string-append": try await stringAppend()
        case "components.interpolated": try await componentsInterpolated(id: 7)
        default: return false
        }
        return true
    }

    private func pathQuestionMark() async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "api.oracle.test"
        components.path = "/v1/search?draft"
        components.queryItems = [URLQueryItem(name: "q", value: "x")]
        let request = URLRequest(url: components.url!) // oracle: components.path-question-mark
        _ = try await session.data(for: request)
    }

    private func pathPercent() async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "api.oracle.test"
        components.path = "/v1/a%20b"
        let request = URLRequest(url: components.url!) // oracle: components.path-percent
        _ = try await session.data(for: request)
    }

    private func percentEncodedPath() async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "api.oracle.test"
        components.percentEncodedPath = "/v1/a%2Fb"
        let request = URLRequest(url: components.url!) // oracle: components.percent-encoded-path
        _ = try await session.data(for: request)
    }

    private func stringAppend() async throws {
        var components = URLComponents(string: "http://api.oracle.test/v1")!
        components.path += "/users"
        _ = try await session.data(from: components.url!) // oracle: components.string-append
    }

    private func componentsInterpolated(id: Int) async throws {
        var components = URLComponents(string: "http://api.oracle.test")!
        components.path = "/v1/items/\(id)"
        let request = URLRequest(url: components.url!) // oracle: components.interpolated
        _ = try await session.data(for: request)
    }
}
