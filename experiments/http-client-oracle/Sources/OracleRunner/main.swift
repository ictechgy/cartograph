import Foundation
import OracleClient

// 사용법: OracleRunner <기록 서버 포트>
// 모든 요청을 127.0.0.1:<포트> 의 HTTP 프록시로 보낸다. 앱 코드의 host(api.oracle.test)는 그대로 두고
// 요청 줄(absolute-form)이 기록 서버에 닿는다. 각 요청 전에 제어 요청으로 case 를 알린다.
guard CommandLine.arguments.count == 2, let port = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: OracleRunner <recorder-port>\n".utf8))
    exit(64)
}
let configuration = URLSessionConfiguration.ephemeral
configuration.connectionProxyDictionary = [
    kCFNetworkProxiesHTTPEnable as String: true,
    kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
    kCFNetworkProxiesHTTPPort as String: port,
]
configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
let client = OracleClient(configuration: configuration)
let control = URLSession(configuration: .ephemeral)
let controlBase = "http://127.0.0.1:\(port)/__oracle__"
for id in OracleClient.caseIDs {
    _ = try await control.data(from: URL(string: "\(controlBase)/begin?case=\(id)")!)
    try await client.run(id)
}
_ = try await control.data(from: URL(string: "\(controlBase)/finish")!)
