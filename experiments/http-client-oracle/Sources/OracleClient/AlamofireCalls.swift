import Alamofire
import Foundation

extension OracleClient {
    static let alamofireCases = [
        "alamofire.request-post", "alamofire.request-interpolated", "alamofire.upload-default-post",
        "alamofire.download-get", "alamofire.urlrequest-init", "alamofire.components",
    ]

    func runAlamofire(_ id: String) async throws -> Bool {
        switch id {
        case "alamofire.request-post": _ = await af.request("http://api.oracle.test/v2/users", method: .post).serializingData().response // oracle: alamofire.request-post
        case "alamofire.request-interpolated": try await requestInterpolated(id: 9)
        case "alamofire.upload-default-post": _ = await af.upload(Data("x".utf8), to: "http://api.oracle.test/v2/upload").serializingData().response // oracle: alamofire.upload-default-post
        case "alamofire.download-get": _ = await af.download("http://api.oracle.test/v2/export").serializingDownloadedFileURL().response // oracle: alamofire.download-get
        case "alamofire.urlrequest-init": try await urlRequestInit()
        case "alamofire.components": try await componentsRequest()
        default: return false
        }
        return true
    }

    private func requestInterpolated(id: Int) async throws {
        _ = await af.request("http://api.oracle.test/v2/users/\(id)").serializingData().response // oracle: alamofire.request-interpolated
    }

    private func urlRequestInit() async throws {
        let request = try URLRequest(url: "http://api.oracle.test/v2/put", method: .put) // oracle: alamofire.urlrequest-init
        _ = await af.request(request).serializingData().response
    }

    private func componentsRequest() async throws {
        var components = URLComponents(string: "http://api.oracle.test")!
        components.path = "/v2/c?x"
        _ = await af.request(components).serializingData().response // oracle: alamofire.components
    }
}
