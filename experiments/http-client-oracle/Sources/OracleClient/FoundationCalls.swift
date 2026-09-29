import Foundation

enum Server {
    static let base = URL(string: "http://api.oracle.test/v1")!
}

extension OracleClient {
    static let foundationCases = [
        "urlsession.literal", "urlsession.post", "urlsession.apc-question-mark", "urlsession.apc-percent",
        "urlsession.apc-double-slash", "urlsession.apc-interpolated", "urlsession.apc-subdelims",
        "urlsession.append-component-slash", "urlsession.append-path-unicode", "urlsession.relative-to",
        "urlsession.relative-to-rooted", "urlsession.data-from", "urlsession.member-constant",
    ]

    func runFoundation(_ id: String) async throws -> Bool {
        switch id {
        case "urlsession.literal": try await literal()
        case "urlsession.post": try await postAssignment()
        case "urlsession.apc-question-mark": try await send(URLRequest(url: Server.base.appendingPathComponent("users?draft=1"))) // oracle: urlsession.apc-question-mark
        case "urlsession.apc-percent": try await send(URLRequest(url: Server.base.appendingPathComponent("a%20b"))) // oracle: urlsession.apc-percent
        case "urlsession.apc-double-slash": try await send(URLRequest(url: Server.base.appendingPathComponent("//x"))) // oracle: urlsession.apc-double-slash
        case "urlsession.apc-interpolated": try await interpolated(id: 42)
        case "urlsession.apc-subdelims": try await send(URLRequest(url: Server.base.appendingPathComponent("a!$&'()*+,;=:@~b"))) // oracle: urlsession.apc-subdelims
        case "urlsession.append-component-slash": try await send(URLRequest(url: Server.base.appending(component: "a/b"))) // oracle: urlsession.append-component-slash
        case "urlsession.append-path-unicode": try await send(URLRequest(url: Server.base.appending(path: "c d/é"))) // oracle: urlsession.append-path-unicode
        case "urlsession.relative-to": try await relative()
        case "urlsession.relative-to-rooted": try await send(URLRequest(url: URL(string: "/items", relativeTo: Server.base)!)) // oracle: urlsession.relative-to-rooted
        case "urlsession.data-from": _ = try await session.data(from: URL(string: "http://api.oracle.test/v1/feed")!) // oracle: urlsession.data-from
        case "urlsession.member-constant": try await send(URLRequest(url: Server.base.appendingPathComponent("items"))) // oracle: urlsession.member-constant
        default: return false
        }
        return true
    }

    private func literal() async throws {
        let request = URLRequest(url: URL(string: "http://api.oracle.test/v1/users")!) // oracle: urlsession.literal
        _ = try await session.data(for: request)
    }

    private func postAssignment() async throws {
        var request = URLRequest(url: URL(string: "http://api.oracle.test/v1/users")!) // oracle: urlsession.post
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
    }

    private func interpolated(id: Int) async throws {
        let request = URLRequest(url: Server.base.appendingPathComponent("users/\(id)")) // oracle: urlsession.apc-interpolated
        _ = try await session.data(for: request)
    }

    private func relative() async throws {
        let request = URLRequest(url: URL(string: "items", relativeTo: URL(string: "http://api.oracle.test/v1/"))!) // oracle: urlsession.relative-to
        _ = try await session.data(for: request)
    }

    func send(_ request: URLRequest) async throws {
        _ = try await session.data(for: request)
    }
}
