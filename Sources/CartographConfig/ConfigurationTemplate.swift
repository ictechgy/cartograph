import CartographCore

/// `cartograph init` 이 생성하는 주석 달린 설정 템플릿.
///
/// 빈 파일을 만들어 주는 대신, 무엇을 켜고 끌 수 있는지 그 자리에서 보여 준다.
/// Periphery 의 대화형 `scan --setup` 이 좋았던 이유가 바로 이 발견 가능성이었다.
public enum ConfigurationTemplate {
    public static let yaml = """
        # Cartograph configuration
        # Docs: https://github.com/ictechgy/cartograph

        # Where the compiler wrote its index store.
        # Leave empty to auto-detect (.build/index/store, .build/out, DerivedData).
        # index_store_path: .build/index/store
        # Where CI put -derivedDataPath, if it is not the Xcode default.
        # derived_data_path: DerivedData

        # Default graph resolution: module | file | type | symbol
        level: module

        # Source paths to analyze. Empty means "everything the index store knows".
        include:
          - "Sources/**"
        exclude:
          - "**/.build/**"
          - "**/Pods/**"
          - "**/*.generated.swift"

        # Which edges to include. Empty means all of:
        # call, reference, inheritance, conformance, extends, overrides, member, import
        edge_kinds: []

        retention:
          # Turn on for libraries whose public API is consumed elsewhere.
          retain_public: false
          # Keep declarations reachable from the Objective-C runtime (recommended for UIKit apps).
          retain_objc_accessible: true
          retain_interface_builder: true
          retain_tests: true
          retain_previews: true
          retain_codable_properties: true
          retain_raw_representable_enum_cases: true
          retained_names: []
          retained_files: []

        # Architecture layers, matched against node name, module name and file path.
        layers: []
        #  - name: Presentation
        #    match: ["Features/**", "*ViewController", "*View"]
        #  - name: Domain
        #    match: ["Domain/**"]
        #  - name: Data
        #    match: ["Data/**", "*Repository"]

        rules: []
        #  - name: Presentation must not reach the data layer directly
        #    from: Presentation
        #    deny: [Data]
        #  - from: Domain
        #    allow: []

        thresholds: {}
        #  max_cycles: 0
        #  max_unused_symbols: 0
        #  max_rule_violations: 0
        #  max_instability: 0.8
        #  max_distance: 0.7

        # baseline_path: \(Cartograph.defaultBaselineFileName)
        report_format: text
        graph_format: dot
        strict: false
        """
}
