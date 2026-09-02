import CartographCore

/// 코드 그래프를 특정 형식의 텍스트로 바꾼다.
public protocol GraphRendering: Sendable {
    func render(_ graph: CodeGraph) throws -> String
}

/// 형식에 맞는 렌더러를 만든다.
public enum GraphRendererFactory {
    public static func make(_ format: GraphFormat) -> any GraphRendering {
        switch format {
        case .dot: DOTGraphRenderer()
        case .mermaid: MermaidGraphRenderer()
        case .json: JSONGraphRenderer()
        case .html: HTMLGraphRenderer()
        }
    }
}

/// 간선 종류별 표현 규칙. 모든 렌더러가 같은 시각 언어를 쓰도록 한 곳에 모은다.
enum EdgeStyle {
    /// Graphviz 선 모양.
    static func dotStyle(for kind: EdgeKind) -> String {
        switch kind {
        case .inheritance: "style=solid, arrowhead=empty"
        case .conformance: "style=dashed, arrowhead=empty"
        case .extends: "style=dotted"
        case .overrides: "style=dashed"
        case .member: "style=dotted, arrowhead=none"
        case .importDeclaration: "style=bold"
        case .retention: "style=dashed, color=gray"
        case .call, .reference: "style=solid"
        }
    }

    /// Mermaid 화살표 모양.
    static func mermaidArrow(for kind: EdgeKind) -> String {
        switch kind {
        case .inheritance, .conformance: "-.->"
        case .member: "---"
        case .extends, .overrides, .retention: "-.->"
        case .call, .reference, .importDeclaration: "-->"
        }
    }
}
