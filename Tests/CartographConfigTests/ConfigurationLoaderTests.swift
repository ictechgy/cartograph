import CartographConfig
import CartographCore
import CartographTestSupport
import Testing

@Suite("ConfigurationLoader")
struct ConfigurationLoaderTests {
    private let sampleYAML = """
        level: type
        include:
          - "Sources/**"
        exclude:
          - "**/Generated/**"
        edge_kinds: [call, conformance]
        retention:
          retain_public: true
          retain_objc_accessible: false
          retained_names: ["*.shared"]
        layers:
          - name: Presentation
            match: ["Features/**"]
          - name: Data
            match: ["Data/**"]
        rules:
          - name: 프레젠테이션은 데이터에 직접 접근하지 않는다
            from: Presentation
            deny: [Data]
            severity: warning
        thresholds:
          max_cycles: 0
          max_instability: 0.75
        baseline: .cartograph-baseline.json
        report_format: github-actions
        graph_format: mermaid
        strict: true
        """

    @Test("YAML 을 설정 값으로 해석한다")
    func decodesFullConfiguration() throws {
        let result = try ConfigurationLoader().load(yaml: sampleYAML, path: "/p/.cartograph.yml")
        let configuration = result.configuration
        #expect(configuration.level == .type)
        #expect(configuration.include.map(\.pattern) == ["Sources/**"])
        #expect(configuration.exclude.map(\.pattern) == ["**/Generated/**"])
        #expect(configuration.edgeKinds == [.call, .conformance])
        #expect(configuration.retention.retainPublic)
        #expect(!configuration.retention.retainObjectiveCAccessible)
        #expect(configuration.retention.retainedNames.map(\.pattern) == ["*.shared"])
        #expect(configuration.layers.count == 2)
        #expect(configuration.rules.first?.severity == .warning)
        #expect(configuration.rules.first?.deny == ["Data"])
        #expect(configuration.thresholds.maxCycles == 0)
        #expect(configuration.thresholds.maxInstability == 0.75)
        #expect(configuration.baselinePath == ".cartograph-baseline.json")
        #expect(configuration.reportFormat == .githubActions)
        #expect(configuration.graphFormat == .mermaid)
        #expect(configuration.strict)
        #expect(result.warnings.isEmpty)
    }

    @Test("명시되지 않은 항목은 기본값을 유지한다")
    func missingKeysFallBackToDefaults() throws {
        let result = try ConfigurationLoader().load(yaml: "level: file\n", path: "/p/.cartograph.yml")
        #expect(result.configuration.level == .file)
        #expect(result.configuration.exclude == CartographConfiguration.defaultExcludes)
        #expect(result.configuration.retention == RetentionOptions.default)
        #expect(!result.configuration.strict)
    }

    @Test("빈 파일은 기본 설정이 된다")
    func emptyFileYieldsDefaults() throws {
        let result = try ConfigurationLoader().load(yaml: "\n  \n", path: "/p/.cartograph.yml")
        #expect(result.configuration == .default)
        #expect(result.path == "/p/.cartograph.yml")
    }

    @Test("알 수 없는 키는 오류가 아니라 경고다")
    func unknownKeysBecomeWarnings() throws {
        let yaml = """
            level: module
            retain_public: true
            retention:
              retain_evertyhing: true
            thresholds:
              max_cyles: 3
            """
        let result = try ConfigurationLoader().load(yaml: yaml, path: "/p/.cartograph.yml")
        #expect(result.warnings.count == 3)
        #expect(result.warnings.contains { $0.contains("'retain_public'") })
        #expect(result.warnings.contains { $0.contains("'retention.retain_evertyhing'") })
        #expect(result.warnings.contains { $0.contains("'thresholds.max_cyles'") })
    }

    @Test("잘못된 타입은 고칠 위치를 알려 주는 오류가 된다")
    func typeMismatchReportsPath() {
        #expect(throws: CartographError.self) {
            try ConfigurationLoader().load(yaml: "level: 42\n", path: "/p/.cartograph.yml")
        }
        do {
            _ = try ConfigurationLoader().load(yaml: "strict: \"nope\"\n", path: "/p/.cartograph.yml")
            Issue.record("오류가 발생해야 한다")
        } catch let error as CartographError {
            #expect(error.errorDescription?.contains("/p/.cartograph.yml") == true)
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("정의되지 않은 레이어를 참조하면 로드가 실패한다")
    func undefinedLayerFailsValidation() {
        let yaml = """
            layers:
              - name: Presentation
                match: ["Features/**"]
            rules:
              - from: Presentation
                deny: [Data]
            """
        #expect(throws: CartographError.self) {
            try ConfigurationLoader().load(yaml: yaml, path: "/p/.cartograph.yml")
        }
    }

    @Test("설정 파일을 디렉터리에서 찾는다")
    func discoversConfigurationFile() {
        let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yml": "level: file"])
        let loader = ConfigurationLoader(fileSystem: fileSystem)
        #expect(loader.discoverConfigurationFile(in: "/p") == "/p/.cartograph.yml")
        #expect(loader.discoverConfigurationFile(in: "/other") == nil)
    }

    @Test("yml 이 없으면 yaml 확장자를 찾는다")
    func discoversYAMLExtension() {
        let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yaml": "level: file"])
        #expect(
            ConfigurationLoader(fileSystem: fileSystem).discoverConfigurationFile(in: "/p")
                == "/p/.cartograph.yaml"
        )
    }

    @Test("설정 파일이 없으면 기본값으로 진행한다")
    func missingConfigurationIsNotAnError() throws {
        let loader = ConfigurationLoader(fileSystem: InMemoryFileSystem())
        let result = try loader.load(explicitPath: nil, searchDirectory: "/p")
        #expect(result.configuration == .default)
        #expect(result.path == nil)
    }

    @Test("발견한 파일을 실제로 읽는다")
    func loadsDiscoveredFile() throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yml": "level: symbol\n"])
        let result = try ConfigurationLoader(fileSystem: fileSystem)
            .load(explicitPath: nil, searchDirectory: "/p")
        #expect(result.configuration.level == .symbol)
        #expect(result.path == "/p/.cartograph.yml")
    }

    @Test("읽을 수 없는 명시 경로는 오류다")
    func unreadableExplicitPathThrows() {
        let loader = ConfigurationLoader(fileSystem: InMemoryFileSystem())
        #expect(throws: CartographError.self) {
            try loader.load(explicitPath: "/nope.yml", searchDirectory: "/p")
        }
    }
}

@Suite("설정 덮어쓰기")
struct ConfigurationOverridesTests {
    @Test("지정한 항목만 덮어쓴다")
    func onlySpecifiedValuesAreOverridden() {
        var base = CartographConfiguration.default
        base.level = .module
        base.strict = false
        let overrides = ConfigurationOverrides(level: .symbol, strict: true)
        let result = base.applying(overrides)
        #expect(result.level == .symbol)
        #expect(result.strict)
        #expect(result.exclude == base.exclude)
    }

    @Test("빈 덮어쓰기는 아무것도 바꾸지 않는다")
    func emptyOverridesChangeNothing() {
        let base = CartographConfiguration.default
        #expect(base.applying(ConfigurationOverrides()) == base)
    }

    @Test("모든 항목을 덮어쓸 수 있다")
    func allFieldsCanBeOverridden() {
        let overrides = ConfigurationOverrides(
            indexStorePath: "/store",
            projectPath: "/p",
            level: .file,
            include: ["A/**"],
            exclude: ["B/**"],
            edgeKinds: [.call],
            baselinePath: "/b.json",
            reportFormat: .sarif,
            graphFormat: .html,
            strict: true,
            retainPublic: true
        )
        let result = CartographConfiguration.default.applying(overrides)
        #expect(result.indexStorePath == "/store")
        #expect(result.projectPath == "/p")
        #expect(result.level == .file)
        #expect(result.include.map(\.pattern) == ["A/**"])
        #expect(result.exclude.map(\.pattern) == ["B/**"])
        #expect(result.edgeKinds == [.call])
        #expect(result.baselinePath == "/b.json")
        #expect(result.reportFormat == .sarif)
        #expect(result.graphFormat == .html)
        #expect(result.strict)
        #expect(result.retention.retainPublic)
    }
}

@Suite("설정 템플릿")
struct ConfigurationTemplateTests {
    @Test("템플릿은 그대로 로드된다")
    func templateIsValid() throws {
        let result = try ConfigurationLoader().load(
            yaml: ConfigurationTemplate.yaml,
            path: "/p/.cartograph.yml"
        )
        #expect(result.warnings.isEmpty)
        #expect(result.configuration.level == .module)
        #expect(result.configuration.retention.retainObjectiveCAccessible)
    }
}
