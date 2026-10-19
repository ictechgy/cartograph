import CartographCore

/// Graphviz DOT 형식.
///
/// `dot -Tsvg graph.dot -o graph.svg` 로 어디서나 그림이 된다.
/// 대규모 그래프에서 유일하게 쓸 만한 자동 배치 도구이기도 하다.
public struct DOTGraphRenderer: GraphRendering {
    /// 모듈 단위로 클러스터를 묶을지 여부. 타입/심볼 레벨에서 읽기가 크게 좋아진다.
    private let clustersByModule: Bool

    public init(clustersByModule: Bool = true) {
        self.clustersByModule = clustersByModule
    }

    public func render(_ graph: CodeGraph) -> String {
        var lines = [
            "digraph Cartograph {",
            "  graph [rankdir=LR, splines=spline, overlap=false, fontname=\"Helvetica\"];",
            "  node [shape=box, style=rounded, fontname=\"Helvetica\", fontsize=10];",
            "  edge [fontname=\"Helvetica\", fontsize=8];",
        ]

        if clustersByModule, graph.level > .module {
            lines.append(contentsOf: clusterLines(graph))
        } else {
            lines.append(contentsOf: graph.sortedNodes.map { "  \(nodeLine($0))" })
        }

        for edge in graph.edges {
            let attributes = [
                EdgeStyle.dotStyle(for: edge.kind),
                edge.weight > 1 ? "label=\"\(edge.weight)\"" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            let (source, target) = (quoteIdentifier(edge.source.rawValue), quoteIdentifier(edge.target.rawValue))
            lines.append("  \(source) -> \(target) [\(attributes)];")
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 모듈별 subgraph 블록.
    private func clusterLines(_ graph: CodeGraph) -> [String] {
        let grouped = Dictionary(grouping: graph.sortedNodes) { $0.module ?? "" }
        return grouped.keys.sorted().flatMap { module -> [String] in
            let nodes = (grouped[module] ?? []).map { "    \(nodeLine($0))" }
            guard !module.isEmpty else { return nodes }
            return ["  subgraph \(quoteIdentifier("cluster_\(module)")) {", "    label=\(quote(module));"]
                + nodes + ["  }"]
        }
    }

    private func nodeLine(_ node: GraphNode) -> String {
        "\(quoteIdentifier(node.id.rawValue)) [label=\(quote(node.name)), shape=\(shape(for: node.kind))];"
    }

    private func shape(for kind: SymbolKind) -> String {
        switch kind {
        case .module: "box3d"
        case .file: "note"
        case .protocolType: "ellipse"
        case .enumType: "diamond"
        default: "box"
        }
    }

    /// 라벨을 DOT 문자열 리터럴로 감싼다. 큰따옴표와 역슬래시만 이스케이프하면 된다.
    ///
    /// 라벨은 파일 이름·선언 이름 그대로라 개행·ESC·양방향 재정의가 들어올 수 있다.
    /// 문법 탈출은 이스케이프가 막지만 그 문자들은 터미널과 뷰어로 그대로 가므로, 이스케이프 전에
    /// Core 의 필터로 뺀다. 남은 문자만 이스케이프해야 걸러 낸 자리가 이스케이프를 깨지 않는다.
    /// 라벨은 보이기만 하므로 걸러 낸 두 라벨이 같아져도 그래프 구조는 그대로다.
    private func quote(_ value: String) -> String {
        "\"\(escapeSyntax(PrintableText.printable(value)))\""
    }

    /// 정점 식별자와 클러스터 이름을 DOT 문자열 리터럴로 감싼다.
    ///
    /// 식별자는 라벨처럼 지우면 안 된다. 제어·형식 문자 하나만 다른 두 경로가 같은 ID 가 되고, DOT 에서
    /// 같은 ID 의 문장은 한 정점이라 Graphviz 가 둘을 합쳐 한쪽의 의존을 다른 쪽에 붙인다. 그래서 그
    /// 문자는 `\u{200B}` 같은 보이는 글자로 바꾼다. 역슬래시를 먼저 겹쳐 두므로 원래 그렇게 적힌 이름과도
    /// 겹치지 않는다(단사). 어느 문자를 숨길지는 Core 의 필터가 정하고, 깨끗한 값의 출력은 그대로다.
    private func quoteIdentifier(_ value: String) -> String {
        let escaped = escapeSyntax(value)
        // 필터가 아무것도 빼지 않으면 숨은 문자가 없다. 흔한 경우라 스칼라마다 판정하지 않는다.
        guard PrintableText.printable(escaped).unicodeScalars.count != escaped.unicodeScalars.count else {
            return "\"\(escaped)\""
        }
        var visible = ""
        for scalar in escaped.unicodeScalars {
            guard PrintableText.printable(String(scalar)).isEmpty else {
                visible.unicodeScalars.append(scalar)
                continue
            }
            visible += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        }
        return "\"\(visible)\""
    }

    /// DOT 문자열 리터럴 안에서 뜻을 갖는 역슬래시와 큰따옴표를 이스케이프한다. 역슬래시가 먼저다.
    private func escapeSyntax(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
