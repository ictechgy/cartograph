import CartographCore
import Foundation

/// 의존성 없는 단일 HTML 파일.
///
/// 외부 CDN 을 전혀 쓰지 않는다. 사내망이나 CI 아티팩트처럼 네트워크가 막힌
/// 곳에서 열어야 하는 경우가 실제로 많고, 그림 하나 보자고 외부 스크립트를
/// 불러오는 것은 보안 검토를 통과하기도 어렵다.
public struct HTMLGraphRenderer: GraphRendering {
    public init() {}

    public func render(_ graph: CodeGraph) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = String(decoding: try encoder.encode(GraphDocument(graph: graph)), as: UTF8.self)
        return Self.document(payload: payload, level: graph.level.rawValue)
    }

    /// `</script>` 가 데이터 안에 들어가면 문서가 그 자리에서 끊긴다.
    static func escapeForScriptTag(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func document(payload: String, level: String) -> String {
        let data = escapeForScriptTag(payload)
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
