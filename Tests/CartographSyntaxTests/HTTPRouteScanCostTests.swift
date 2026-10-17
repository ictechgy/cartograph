import CartographCore
@testable import CartographSyntax
import Testing

/// 파일 하나를 훑는 비용이 프로젝트 크기에 비례해 늘지 않는지 횟수와 표면으로 확인한다. 시간은 재지 않는다.
///
/// `routes` 는 파일마다 스캔한다. 파일마다 프로젝트 전체를 훑는 일이 하나라도 남으면 전체 비용이 파일 수의
/// 제곱으로 늘어, 4천 파일 앱에서 한 패스가 1분을 넘겼다.
@Suite("route-call 스캔 비용")
struct HTTPRouteScanCostTests {
    @Test("URL 재작성 어댑터 후보가 아닌 함수는 프로젝트 프로토콜을 훑어 준수 이름을 계산하지 않는다")
    func computesConformancesOnlyForAdapterCandidates() {
        let helpers = (0..<40).map { "    func helper\($0)(_ request: URLRequest) {}" }.joined(separator: "\n")
        let source = """
            import Alamofire
            protocol BaseInterceptor: RequestInterceptor {}
            final class Interceptor: BaseInterceptor {
                func adapt(_ urlRequest: URLRequest, for session: Session,
                           completion: @escaping (Result<URLRequest, Error>) -> Void) {
                    var request = urlRequest
                    request.url = URL(string: "https://mirror.example.com")
                    completion(.success(request))
                }
                func adapt(value: Int) {}
            \(helpers)
            }
            """
        let collector = HTTPRouteCallScanner(wrappers: []).collect(source: source, path: "/p/Interceptor.swift")
        #expect(collector.counts.urlRewriters == 1)
        #expect(collector.conformanceQueries == 1)
    }

    @Test("선언 표면에 이미 합친 파일은 스캔할 때 프로젝트 표면을 복사해 다시 합치지 않는다")
    func reusesProjectSurfaceForDeclaredFile() {
        let source = "struct Client { func load() {} }\nenum Route: String { case users = \"/users\" }"
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: source, path: "/p/Client.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(source: "struct Other {}", path: "/p/Other.swift"))
        let scanner = HTTPRouteCallScanner(wrappers: [], surface: surface)
        #expect(scanner.collect(source: source, path: "/p/Client.swift").surface == surface)
    }

    @Test("표면에 없는 파일과 경로 없이 만든 표면은 지금처럼 그 파일의 선언을 더해 훑는다")
    func mergesFilesOutsideTheSurface() {
        let source = "struct Client { func load() {} }"
        let other = HTTPRouteCallScanner.declarations(source: "struct Other {}", path: "/p/Other.swift")
        let merged = HTTPRouteCallScanner(wrappers: [], surface: other).collect(source: source, path: "/p/Client.swift")
        #expect(merged.surface.typeChains == ["Client", "Other"])
        #expect(merged.surface.functions["Client\0load"]?.count == 1)
        // 경로 없는 표면은 파일을 가를 수 없어 같은 소스라도 다시 합친다(시그니처 목록이 겹칠 뿐 판정은 같다).
        let unnamed = HTTPRouteCallScanner(wrappers: [], surface: HTTPRouteCallScanner.declarations(source: source))
        #expect(unnamed.collect(source: source, path: "").surface.functions["Client\0load"]?.count == 2)
    }

    @Test("이미 합친 파일을 다시 합치지 않아도 같은 파일 상수·enum 원시값 경로는 합칠 때와 같다")
    func skippingMergeKeepsScanResult() {
        let source = """
            import Foundation
            enum Route: String { case users = "/users" }
            enum API { static let base = "https://api.example.com"; typealias Path = Route }
            struct Client {
                func load() { _ = URLRequest(url: URL(string: API.base + Route.users.rawValue)!) }
                func alias() { _ = URLRequest(url: URL(string: API.base + API.Path.users.rawValue)!) }
            }
            """
        let path = "/p/Client.swift"
        let surface = HTTPRouteCallScanner.declarations(source: source, path: path)
        let declared = HTTPRouteCallScanner(wrappers: [], surface: surface)
        let standalone = HTTPRouteCallScanner(wrappers: [])
        let reused = declared.scan(source: source, path: path)
        #expect(reused == standalone.scan(source: source, path: path))
        #expect(reused.calls.map(\.fact.isDynamic) == [false, false])
    }
}
