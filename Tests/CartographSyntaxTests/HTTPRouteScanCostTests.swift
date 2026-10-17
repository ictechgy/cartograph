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

    @Test("값 흐름 재스캔이 실제 경로 표기를 써도 같은 파일 상수·enum 원시값 경로는 1차 패스와 같다")
    func rescanUnderCanonicalSpellingMatchesFirstPass() {
        // 재스캔은 값 흐름 상수의 위치와 맞추려고 실제 경로를 쓴다. 표면은 1차 패스의 표기로 합쳐져 있어,
        // 그 파일의 선언을 다시 합치면 같은 선언이 위치 표기만 다른 두 벌이 되고 유일성 검사가 경로를 거부한다.
        let source = """
            import Foundation
            enum Route: String { case users = "/users" }
            enum API { static let base = "https://api.example.com" }
            func load() { _ = URLRequest(url: URL(string: API.base + Route.users.rawValue)!) }
            """
        let declared = "/link/App/Load.swift"
        let canonical = "/real/App/Load.swift"
        let surface = HTTPRouteCallScanner.declarations(source: source, path: declared)
        let scanner = HTTPRouteCallScanner(wrappers: [], surface: surface)
        let first = scanner.scan(source: source, path: declared)
        let rescan = scanner.scan(source: source, path: canonical, declaredPath: declared)
        #expect(first.calls.map(\.fact.isDynamic) == [false])
        #expect(rescan.calls.map(\.fact.channel) == first.calls.map(\.fact.channel))
        #expect(rescan.calls.map(\.fact.isDynamic) == [false])
        #expect(rescan.calls.map(\.fact.location.path) == [canonical])
        #expect(scanner.collect(source: source, path: canonical, declaredPath: declared).surface == surface)
    }

    /// 준수 이름 닫힘의 선형 정의. 상속 이름마다 마지막 구성 요소가 같은 프로젝트 프로토콜 사슬을 모두 훑는다.
    private func naiveConformedNames(of chain: String, in surface: HTTPDeclarationSurface) -> Set<String> {
        var seen: Set<String> = []
        var queue = Array(surface.inheritedNames[chain] ?? [])
        while let name = queue.popLast() {
            guard seen.insert(name).inserted else { continue }
            for protocolChain in surface.protocolChains
            where protocolChain.split(separator: ".").last == Substring(name) {
                queue.append(contentsOf: surface.inheritedNames[protocolChain] ?? [])
            }
        }
        return seen
    }

    @Test("라우터 사슬과 준수 이름은 프로토콜 이름 색인으로 구해도 선형 정의와 같다")
    func routerChainsMatchLinearDefinition() {
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            import Moya
            import Alamofire
            protocol BaseTarget: TargetType {}
            protocol AuthTarget: BaseTarget, Codable {}
            enum Outer { protocol BaseTarget: Sendable {} }
            enum Users: AuthTarget { case list }
            struct Login: Outer.BaseTarget {}
            enum Router: URLRequestConvertible { case home }
            protocol Cycle: Loop {}
            protocol Loop: Cycle {}
            struct Looping: Loop {}
            extension Login: BaseTarget {}
            """, path: "/p/Targets.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            protocol URLRequestConvertible {}
            enum Shadowed: URLRequestConvertible { case a }
            struct Plain: Codable {}
            """, path: "/p/Shadow.swift"))
        let naive = surface.typeChains.filter { chain in
            guard !surface.protocolChains.contains(chain) else { return false }
            let names = naiveConformedNames(of: chain, in: surface)
            return HTTPRouterKind.allCases.contains {
                names.contains($0.rawValue) && !surface.declaresTypeNamed($0.rawValue)
            }
        }.sorted()
        #expect(surface.routerChains == naive)
        #expect(surface.routerChains == ["Login", "Users"])
        for chain in surface.typeChains.sorted() {
            #expect(surface.conformedNames(of: chain) == naiveConformedNames(of: chain, in: surface), "\(chain)")
        }
    }

    @Test("접미 표기로 찾는 타입 사슬은 마지막 이름 색인으로 구해도 선형 대조와 같다")
    func suffixLookupMatchesLinearFilter() {
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            enum Paths { enum V1 { static let users = "/v1" } }
            enum V1 {}
            struct PathsV2 {}
            extension Outer.Paths { static let more = "/more" }
            """, path: "/p/A.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "enum Outer { enum Paths { static let users = \"/outer\" } }", path: "/p/B.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(source: "enum Paths {}", path: "/p/C.swift"))
        let types = [["Paths"], ["V1"], ["Paths", "V1"], ["Outer", "Paths"], ["Missing"], ["PathsV2"], ["Outer"], []]
        for type in types {
            let linear = surface.typeChains.filter { chain in
                let components = chain.split(separator: ".").map(String.init)
                return components.count >= type.count && Array(components.suffix(type.count)) == type
            }.sorted()
            #expect(surface.typeChains(endingWith: type) == linear, "\(type)")
        }
    }
}
