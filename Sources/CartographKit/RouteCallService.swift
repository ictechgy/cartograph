import CartographAnalysis
import CartographCore
import CartographSyntax
import Foundation

extension CartographService {
    /// Swift 소스에서 클라이언트 HTTP 호출을 모아 isthmus 가 읽는 http 호출 측 문서로 만든다.
    ///
    /// 인덱스는 URL 문자열을 모른다. 서버 라우트와 앱을 잇는 유일한 끈이 그 문자열이라 구문에서
    /// 읽는다. 인덱스는 감싸는 선언의 USR 을 붙이는 데와, 값 흐름 분석으로 파일 밖 상수를 푸는 데만
    /// 쓴다. 판정은 하지 않는다 — 읽지 못한 경로도 `dynamic` 으로 남기고, 사실로 만들지 못한 싱크는
    /// 호출 측 한계로 센다. 그래야 isthmus 가 "호출 없음"과 "못 봤음"을 가른다.
    ///
    /// - Parameters:
    ///   - wrappersPath: `http-wrappers` v1 선언 파일. 없으면 직접 요청만 읽는다.
    ///   - includeTests: 테스트 소스를 함께 읽고 사실에 `testSource` 를 단다.
    ///   - service: 문서의 서비스 신원. 매니페스트 없는 귀속 게이트의 입력이다.
    public func routeCalls(
        generatedAt: Date = Date(), wrappersPath: String? = nil, includeTests: Bool = false, service: String? = nil
    ) throws -> RouteCallsDocument {
        let project = try canonicalProjectForExchange()
        let wrappers = try wrappersPath.map(loadRouteWrappers) ?? []
        try validateRouteServices(service, wrappers: wrappers, path: wrappersPath)
        let snapshot = try routeIndexSnapshot()
        let sources = routeSources(includeTests: includeTests)
        var texts: [String: String] = [:]
        var unreadable = 0
        for source in sources {
            do { texts[source.path] = try environment.fileSystem.readText(at: source.path) } catch { unreadable += 1 }
        }
        var surface = HTTPDeclarationSurface()
        for source in sources {
            if let text = texts[source.path] { surface.merge(HTTPRouteCallScanner.declarations(source: text, path: source.path)) }
        }
        let scanner = HTTPRouteCallScanner(wrappers: wrappers.filter { $0.language == "swift" }, surface: surface)
        var pass = scanRoutes(scanner, sources: sources, texts: texts, resolvedValues: [:])
        if let snapshot, let resolved = routeValueFlowConstants(pass, snapshot: snapshot, texts: texts) {
            pass = scanRoutes(scanner, sources: sources, texts: texts, resolvedValues: resolved)
        }
        let resolver = BridgeSymbolResolver(snapshot: snapshot ?? IndexSnapshot())
        // 라우터 사실의 심볼(enum case)은 경로 분기와 다른 파일에 있을 수 있다. 선언 위치의 파일에서 찾는다.
        let facts = pass.calls.map { call in
            call.fact.attaching(resolver.symbol(for: call.declaration, at: call.declaration?.start ?? call.fact.location))
        }
        let limitations = routeLimitations(
            facts: facts, pass: pass, scanner: scanner, unreadable: unreadable, hasIndex: snapshot != nil
        )
        return RouteCallsDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: Self.bridgeTimestamp(generatedAt), project: project, facts: facts,
            includesTests: includeTests, service: service, limitations: limitations
        )
    }

    /// `routes` 명령. 소비자는 사람이 아니라 isthmus 라 기본은 JSON 이다.
    public func exportRouteCalls(
        generatedAt: Date = Date(), asText: Bool = false, wrappersPath: String? = nil,
        includeTests: Bool = false, service: String? = nil
    ) throws -> CommandOutcome {
        let document = try routeCalls(
            generatedAt: generatedAt, wrappersPath: wrappersPath, includeTests: includeTests, service: service
        )
        return CommandOutcome(output: asText ? document.renderText() : try Self.encodeSortedJSON(document))
    }

    // MARK: - 입력

    /// 교환 문서의 `project`. 소비자는 이 문자열을 바꾸지 않고 비교하므로 실제 경로로 푼다.
    func canonicalProjectForExchange() throws -> String {
        do {
            return try environment.fileSystem.realPath(at: projectPath)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "The provided FileSystem does not support realPath(at:). Implement it before exporting route calls.")
        } catch {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "Could not resolve the project root: \(error.localizedDescription). Check that it exists and is accessible.")
        }
    }

    private func loadRouteWrappers(_ path: String) throws -> [HTTPWrapperDeclaration] {
        let text: String
        do {
            text = try environment.fileSystem.readText(at: path)
        } catch {
            throw CartographError.invalidConfiguration(path: path, reason:
                "Could not read the http-wrappers file: \(error.localizedDescription). Check the --wrappers path.")
        }
        return try HTTPWrapperFile.parse(Data(text.utf8), path: path)
    }

    /// 문서와 사실의 service 가 다르면 소비자가 문서 전체를 거부한다. 내보내기 전에 막는다.
    private func validateRouteServices(_ service: String?, wrappers: [HTTPWrapperDeclaration], path: String?) throws {
        guard let service, let conflict = wrappers.first(where: { $0.language == "swift" && $0.service.map { $0 != service } == true })
        else { return }
        throw CartographError.invalidConfiguration(path: path ?? projectPath, reason:
            "Wrapper \(conflict.displayName) declares a service different from --service; isthmus rejects a fact whose "
                + "service differs from the document service. Drop --service or align the wrapper's service.")
    }

    /// 읽을 Swift 소스와 테스트 소스 여부. 기본은 테스트 소스를 읽지 않는다.
    private func routeSources(includeTests: Bool) -> [(path: String, isTest: Bool)] {
        let baseVariants = PathFilter.variants(of: projectPath)
        return schemaSourceFiles().compactMap { path in
            let isTest = Self.isTestSource(path, baseVariants: baseVariants)
            return isTest && !includeTests ? nil : (path, isTest)
        }
    }

    /// 테스트 소스 세트의 경로인지. 프로젝트 기준 상대 경로에서 `Tests` 이거나 `…Tests` 로 끝나는
    /// 디렉터리(`AppTests`·`AppUITests`), 또는 `…Tests.swift` 파일이다.
    ///
    /// 상대 경로로 보는 이유는 조상 디렉터리 이름 하나로 프로젝트 전체가 테스트가 되지 않게 하려는
    /// 것이다. 제외 글롭이 `~/DerivedData/App` 을 통째로 지운 적이 있다.
    static func isTestSource(_ path: String, baseVariants: [String]) -> Bool {
        let relative = SourceLocation(path: path, line: 1, column: 1).relative(toBaseVariants: baseVariants).path
        var components = relative.split(separator: "/").map(String.init)
        let file = components.popLast() ?? ""
        return file.hasSuffix("Tests.swift") || components.contains { $0 == "Tests" || $0.hasSuffix("Tests") }
    }

    // MARK: - 스캔

    /// 한 번의 스캔 결과를 문서 단위로 모은 것.
    struct RoutePass {
        var calls: [ScannedRouteCall] = []
        var counts = RouteCallScanCounts()
        var callsByWrapper: [Int: Int] = [:]
        var routerTables: [HTTPTargetMemberTable] = []
        var routerRecipes: [HTTPRouterRecipe] = []
    }

    private func scanRoutes(
        _ scanner: HTTPRouteCallScanner, sources: [(path: String, isTest: Bool)], texts: [String: String],
        resolvedValues: [SourceLocation: String]
    ) -> RoutePass {
        var pass = RoutePass()
        // 값 흐름 상수는 실제 경로로 기록된다. 재스캔은 같은 표기를 써야 위치가 맞는다.
        let canonical = !resolvedValues.isEmpty
        for source in sources {
            guard let text = texts[source.path] else { continue }
            let path = canonical ? LocalFileSystem.canonicalPath(source.path) : source.path
            let result = scanner.scan(source: text, path: path, isTestSource: source.isTest, resolvedValues: resolvedValues)
            pass.calls += result.calls
            pass.counts = pass.counts + result.counts
            pass.callsByWrapper.merge(result.callsByWrapper, uniquingKeysWith: +)
            pass.routerTables += result.routerTables
            pass.routerRecipes += result.routerRecipes
        }
        // 라우터 멤버는 여러 파일의 익스텐션에 흩어질 수 있어 모든 파일을 읽은 뒤 case 별 사실로 합친다.
        let wrapperOwners = Set(scanner.wrappers.compactMap(\.ownerComponents.last))
        let routers = HTTPRouteCallScanner.routerRouteCalls(
            tables: pass.routerTables, recipes: pass.routerRecipes, surface: scanner.surface,
            declaredWrapperOwners: wrapperOwners
        )
        pass.calls += routers.calls
        pass.counts = pass.counts + routers.counts
        return pass
    }

    /// 파일 밖 상수를 값 흐름으로 푼다. 인덱스보다 새 파일의 dynamic 호출만 있으면 돌지 않는다.
    ///
    /// `bridges` 와 같은 조건이다 — 값 흐름은 인덱스의 호출 관계를 쓰므로, 인덱스 뒤에 편집된
    /// 파일의 식은 위치가 어긋나 엉뚱한 값을 붙일 수 있다.
    private func routeValueFlowConstants(
        _ pass: RoutePass, snapshot: IndexSnapshot, texts: [String: String]
    ) -> [SourceLocation: String]? {
        let indexedDates = Dictionary((snapshot.indexedFileDates ?? [:]).map {
            (ValueFlowSourceLoader.canonicalPath($0.key), $0.value)
        }, uniquingKeysWith: min)
        let hasFreshDynamic = pass.calls.contains { call in
            guard call.fact.isDynamic, let indexed = indexedDates[ValueFlowSourceLoader.canonicalPath(call.fact.location.path)],
                  let modified = environment.fileSystem.modificationDate(at: call.fact.location.path) else { return false }
            return modified <= indexed
        }
        guard hasFreshDynamic else { return nil }
        let sourceCache = Dictionary(texts.map { (ValueFlowSourceLoader.canonicalPath($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        let loaded = ValueFlowSourceLoader(fileSystem: environment.fileSystem, projectPath: projectPath,
            pathFilter: configuration.pathFilter).load(snapshot: snapshot, sourceSnapshot: sourceCache)
        let resolved = ValueFlowBridgeConstants().resolve(in: ValueFlowAnalyzer().analyze(loaded.program))
        return resolved.isEmpty ? nil : resolved
    }

    // MARK: - 한계

    /// 이 문서가 보지 못한 것. 호출 측 접두사는 계약의 닫힌 목록에서만 쓴다 — 모르는 접두사는
    /// 소비자가 공백으로 읽지 않아, 알린 것이 아무 효과도 없게 된다.
    private func routeLimitations(
        facts: [RouteCallFact], pass: RoutePass, scanner: HTTPRouteCallScanner, unreadable: Int, hasIndex: Bool
    ) -> [String] {
        var result: [String] = []
        let counts = pass.counts
        if unreadable > 0 {
            result.append("route-call-coverage: \(unreadable) Swift source(s) could not be read; their HTTP calls are absent")
        }
        if counts.unreadableSinks > 0 {
            result.append("route-call-coverage: \(counts.unreadableSinks) direct request sink(s) build a URL that could not "
                + "be read statically, so they were not emitted")
        }
        if counts.unmodelledRouters > 0 {
            result.append("route-call-coverage: \(counts.unmodelledRouters) router type(s) (Moya TargetType or Alamofire "
                + "URLRequestConvertible) have no readable path member or request builder, so their cases were not emitted")
        }
        let unmodelled = counts.unmodelledClientImports
        if !unmodelled.isEmpty {
            result.append("route-call-coverage: \(unmodelled.values.reduce(0, +)) import(s) of HTTP client libraries that "
                + "routes does not model (\(unmodelled.keys.sorted().joined(separator: ", "))); requests made through them are absent")
        }
        if counts.unprovenReceiverCalls > 0 {
            result.append("route-call-coverage: \(counts.unprovenReceiverCalls) call(s) match a declared wrapper function's "
                + "name and labels but their receiver type could not be proven, so they were not emitted")
        }
        if counts.urlRewriters > 0 {
            result.append("url-rewrite-interceptors: \(counts.urlRewriters) custom Moya endpoint mapping(s) or Alamofire "
                + "request adapter(s) rewrite request URLs, so the emitted paths may differ from the paths sent")
        }
        if counts.generatedClientImports > 0 {
            result.append("generated-client-unscanned: \(counts.generatedClientImports) Swift source(s) import an OpenAPI "
                + "generated-client runtime; requests made through generated clients are not emitted")
        }
        let ambiguous = facts.count { $0.limitation == HTTPRouteComposer.ambiguousBaseJoin }
        if ambiguous > 0 {
            result.append("ambiguous-base-join: \(ambiguous) route call(s) append a relative path to a base URL that could "
                + "not be resolved statically")
        }
        if counts.undeclaredWrapperSinks > 0 {
            result.append("http-wrapper-undeclared: \(counts.undeclaredWrapperSinks) request sink(s) pass a function "
                + "parameter through as the path; declare the enclosing function in http-wrappers to resolve its callers")
        }
        let unresolved = scanner.wrappers.enumerated().filter { index, wrapper in
            !scanner.surface.declares(wrapper) || (pass.callsByWrapper[index] ?? 0) == 0
        }.map { $0.element.displayName }
        if !unresolved.isEmpty {
            result.append("http-wrapper-unresolved: \(unresolved.count) declared wrapper(s) matched no declaration or no "
                + "call in the scanned sources: \(unresolved.joined(separator: ", "))")
        }
        let missing = facts.count { $0.symbol?.usr == nil }
        if missing > 0 {
            result.append("missing-route-usrs: \(missing) route-call fact(s) lack indexed identities"
                + (hasIndex ? "" : "; no index store was found, so only qualified names are available"))
        }
        return result
    }
}
