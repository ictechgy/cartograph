import CartographCore
import Foundation

/// 의존성 없는 단일 HTML 파일.
///
/// 외부 CDN 을 전혀 쓰지 않는다. 사내망이나 CI 아티팩트처럼 네트워크가 막힌
/// 곳에서 열어야 하는 경우가 실제로 많고, 그림 하나 보자고 외부 스크립트를
/// 불러오는 것은 보안 검토를 통과하기도 어렵다.
public struct HTMLGraphRenderer: GraphRendering {
    /// 그릴 최대 정점 수.
    ///
    /// 힘 기반 배치는 매 프레임 정점 쌍을 모두 훑으므로 비용이 정점 수의 제곱에
    /// 비례한다. 심볼 레벨 그래프를 그대로 넘기면 브라우저가 멈춘다.
    /// 잘라 낸 사실은 페이지에 그대로 적어 사용자가 오해하지 않게 한다.
    public static let defaultNodeLimit = 400

    private let nodeLimit: Int

    public init(nodeLimit: Int = HTMLGraphRenderer.defaultNodeLimit) {
        self.nodeLimit = nodeLimit
    }

    public func render(_ graph: CodeGraph) throws -> String {
        let (limited, truncated) = Self.limiting(graph, to: nodeLimit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = String(decoding: try encoder.encode(GraphDocument(graph: limited)), as: UTF8.self)
        return Self.document(
            payload: payload,
            level: graph.level.rawValue,
            truncatedFrom: truncated ? graph.nodeCount : nil
        )
    }

    /// 상한을 넘으면 연결이 많은 정점부터 남긴다.
    ///
    /// 임의로 자르면 그림이 의미를 잃는다. 연결이 많은 정점이 구조를 가장 잘 설명한다.
    static func limiting(_ graph: CodeGraph, to limit: Int) -> (graph: CodeGraph, truncated: Bool) {
        guard graph.nodeCount > limit else { return (graph, false) }
        let ranked = graph.sortedNodes.sorted { lhs, rhs in
            let lhsDegree = graph.inDegree(of: lhs.id) + graph.outDegree(of: lhs.id)
            let rhsDegree = graph.inDegree(of: rhs.id) + graph.outDegree(of: rhs.id)
            return lhsDegree != rhsDegree ? lhsDegree > rhsDegree : lhs.id < rhs.id
        }
        let kept = Set(ranked.prefix(limit).map(\.id))
        return (graph.filteringNodes { kept.contains($0.id) }, true)
    }

    /// 데이터 안의 여는 꺾쇠를 전부 JSON 이스케이프로 바꾼다.
    ///
    /// `</` 만 막으면 부족하다. `<!--<script` 가 들어오면 HTML 토크나이저가
    /// script 이중 이스케이프 상태로 들어가, 문서에 실제로 있는 `</script>` 를
    /// 태그로 보지 않고 삼킨다. 그 뒤 페이지 전체가 스크립트 안으로 빨려 들어가
    /// 빈 화면이 된다. `\u003c` 는 적법한 JSON 문자열 이스케이프이므로
    /// 파싱 결과는 그대로이고, 토크나이저가 볼 꺾쇠는 하나도 남지 않는다.
    static func escapeForScriptTag(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func document(payload: String, level: String, truncatedFrom: Int?) -> String {
        let data = escapeForScriptTag(payload)
        let truncationNotice = truncatedFrom.map { total in
            "<span class=\"stat\">truncated from \(total) nodes, keeping the most connected — "
                + "use --format dot for the full graph</span>"
        } ?? ""

        return #"""
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Cartograph — \#(level) graph</title>
            <style>
              :root { color-scheme: light dark; --bg: #fbfbfd; --fg: #1d1d1f; --line: #d2d2d7; --accent: #0b64d0; }
              @media (prefers-color-scheme: dark) {
                :root { --bg: #16161a; --fg: #f2f2f7; --line: #3a3a3f; --accent: #6aa9ff; }
              }
              * { box-sizing: border-box; }
              body { margin: 0; background: var(--bg); color: var(--fg);
                     font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
              header { display: flex; gap: 16px; align-items: center; flex-wrap: wrap;
                       padding: 12px 16px; border-bottom: 1px solid var(--line); }
              h1 { font-size: 14px; margin: 0; font-weight: 600; }
              .stat { color: #8a8a8e; }
              input { padding: 5px 9px; border: 1px solid var(--line); border-radius: 6px;
                      background: transparent; color: inherit; min-width: 200px; }
              #canvas { display: block; width: 100vw; height: calc(100vh - 96px); cursor: grab; }
              #canvas:active { cursor: grabbing; }
              footer { position: fixed; bottom: 0; left: 0; right: 0; padding: 6px 16px;
                       border-top: 1px solid var(--line); background: var(--bg); }
              #details { font-family: ui-monospace, SFMono-Regular, monospace; }
            </style>
            </head>
            <body>
            <header>
              <h1>Cartograph</h1>
              <span class="stat" id="summary"></span>
              \#(truncationNotice)
              <input id="search" type="search" placeholder="Filter nodes by name" autocomplete="off">
            </header>
            <canvas id="canvas"></canvas>
            <footer><span id="details">Drag to pan, scroll to zoom, click a node for details.</span></footer>
            <script id="graph-data" type="application/json">\#(data)</script>
            <script>
            (function () {
              const graph = JSON.parse(document.getElementById('graph-data').textContent);
              const canvas = document.getElementById('canvas');
              const context = canvas.getContext('2d');
              const summary = document.getElementById('summary');
              const details = document.getElementById('details');
              const search = document.getElementById('search');

              summary.textContent = graph.level + ' level · ' + graph.nodeCount +
                ' nodes · ' + graph.edgeCount + ' edges';

              const indexById = new Map();
              const nodes = graph.nodes.map(function (node, index) {
                indexById.set(node.id, index);
                const angle = (index / graph.nodes.length) * Math.PI * 2;
                const radius = 60 + Math.sqrt(graph.nodes.length) * 22;
                return {
                  id: node.id, name: node.name, kind: node.kind, module: node.module || '',
                  x: Math.cos(angle) * radius, y: Math.sin(angle) * radius, vx: 0, vy: 0, degree: 0
                };
              });
              const links = [];
              graph.edges.forEach(function (edge) {
                const source = indexById.get(edge.source);
                const target = indexById.get(edge.target);
                if (source === undefined || target === undefined) { return; }
                links.push({ source: source, target: target, kind: edge.kind });
                nodes[source].degree += 1;
                nodes[target].degree += 1;
              });

              // 단순 힘 기반 배치. 라이브러리를 쓰지 않는 대신 반복 횟수를 제한한다.
              let alpha = 1;
              function step() {
                const repulsion = 5200;
                for (let i = 0; i < nodes.length; i++) {
                  for (let j = i + 1; j < nodes.length; j++) {
                    let dx = nodes[j].x - nodes[i].x;
                    let dy = nodes[j].y - nodes[i].y;
                    let distanceSquared = dx * dx + dy * dy || 0.01;
                    const force = repulsion / distanceSquared;
                    const distance = Math.sqrt(distanceSquared);
                    const fx = (dx / distance) * force;
                    const fy = (dy / distance) * force;
                    nodes[i].vx -= fx; nodes[i].vy -= fy;
                    nodes[j].vx += fx; nodes[j].vy += fy;
                  }
                }
                links.forEach(function (link) {
                  const a = nodes[link.source], b = nodes[link.target];
                  const dx = b.x - a.x, dy = b.y - a.y;
                  const distance = Math.sqrt(dx * dx + dy * dy) || 0.01;
                  const force = (distance - 130) * 0.02;
                  const fx = (dx / distance) * force, fy = (dy / distance) * force;
                  a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
                });
                nodes.forEach(function (node) {
                  node.vx -= node.x * 0.002; node.vy -= node.y * 0.002;
                  node.x += node.vx * alpha; node.y += node.vy * alpha;
                  node.vx *= 0.82; node.vy *= 0.82;
                });
                alpha *= 0.995;
              }

              const view = { x: 0, y: 0, scale: 1 };
              let highlight = '';

              function radiusOf(node) { return 4 + Math.min(10, Math.sqrt(node.degree) * 2.2); }

              function draw() {
                const ratio = window.devicePixelRatio || 1;
                canvas.width = canvas.clientWidth * ratio;
                canvas.height = canvas.clientHeight * ratio;
                context.setTransform(ratio, 0, 0, ratio, 0, 0);
                context.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
                context.save();
                context.translate(canvas.clientWidth / 2 + view.x, canvas.clientHeight / 2 + view.y);
                context.scale(view.scale, view.scale);

                context.lineWidth = 1 / view.scale;
                context.strokeStyle = 'rgba(128,128,140,0.35)';
                links.forEach(function (link) {
                  const a = nodes[link.source], b = nodes[link.target];
                  context.beginPath();
                  context.moveTo(a.x, a.y);
                  context.lineTo(b.x, b.y);
                  context.stroke();
                });

                nodes.forEach(function (node) {
                  const matched = highlight === '' ||
                    node.name.toLowerCase().indexOf(highlight) !== -1;
                  context.globalAlpha = matched ? 1 : 0.15;
                  context.beginPath();
                  context.arc(node.x, node.y, radiusOf(node), 0, Math.PI * 2);
                  context.fillStyle = node.kind === 'protocol' ? '#8a5cf6'
                    : node.kind === 'module' ? '#0b64d0'
                    : node.kind === 'enum' ? '#e08600' : '#3aa06a';
                  context.fill();
                  if (view.scale > 0.55 && matched) {
                    context.fillStyle = getComputedStyle(document.body).color;
                    context.font = (11 / view.scale) + 'px -apple-system, sans-serif';
                    context.fillText(node.name, node.x + radiusOf(node) + 3, node.y + 3);
                  }
                });
                context.globalAlpha = 1;
                context.restore();
              }

              function frame() {
                if (alpha > 0.02) { step(); }
                draw();
                requestAnimationFrame(frame);
              }

              let dragging = false, lastX = 0, lastY = 0;
              canvas.addEventListener('mousedown', function (event) {
                dragging = true; lastX = event.clientX; lastY = event.clientY;
              });
              window.addEventListener('mouseup', function () { dragging = false; });
              window.addEventListener('mousemove', function (event) {
                if (!dragging) { return; }
                view.x += event.clientX - lastX;
                view.y += event.clientY - lastY;
                lastX = event.clientX; lastY = event.clientY;
              });
              canvas.addEventListener('wheel', function (event) {
                event.preventDefault();
                view.scale = Math.max(0.15, Math.min(6, view.scale * (event.deltaY < 0 ? 1.1 : 0.9)));
              }, { passive: false });
              canvas.addEventListener('click', function (event) {
                const rect = canvas.getBoundingClientRect();
                const x = (event.clientX - rect.left - canvas.clientWidth / 2 - view.x) / view.scale;
                const y = (event.clientY - rect.top - canvas.clientHeight / 2 - view.y) / view.scale;
                let found = null;
                nodes.forEach(function (node) {
                  const dx = node.x - x, dy = node.y - y;
                  if (dx * dx + dy * dy < Math.pow(radiusOf(node) + 4, 2)) { found = node; }
                });
                details.textContent = found
                  ? found.kind + ' ' + (found.module ? found.module + '.' : '') + found.name +
                    ' · ' + found.degree + ' connections · ' + found.id
                  : 'Drag to pan, scroll to zoom, click a node for details.';
              });
              search.addEventListener('input', function () {
                highlight = search.value.trim().toLowerCase();
              });

              frame();
            })();
            </script>
            </body>
            </html>
            """#
    }
}
