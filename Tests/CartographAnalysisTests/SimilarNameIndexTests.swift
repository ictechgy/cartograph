@testable import CartographAnalysis
import CartographCore
import Testing

@Suite("notFound 추천 색인")
struct SimilarNameIndexTests {
    @Test("추천은 모든 이름 키를 전체 편집 거리로 비교하던 판정과 같은 후보를 같은 순서로 낸다")
    func candidatesMatchExhaustiveReference() {
        let graph = CodeGraph(level: .symbol, nodes: Self.mixedNodes(), edges: [])
        let index = GraphQueryIndex(graph: graph)
        let keys = Self.referenceKeys(in: graph)
        let sampled = graph.sortedNodes.enumerated().filter { $0.offset % 12 == 0 }.map(\.element)
        let subjects = sampled.flatMap { Self.typos(of: $0.baseName) } + Self.edgeSubjects
        var mismatches: [String] = []
        for subject in subjects {
            let expected = Self.reference(subject, keys: keys, graph: graph, limit: 50)
            for limit in [1, 5, 50] where index.similarCandidates(to: subject, limit: limit)
                != Array(expected.prefix(limit)) && mismatches.count < 10 {
                mismatches.append("\(subject) limit \(limit)")
            }
        }
        // 실패해도 처음 열 개만 보여 준다.
        #expect(mismatches.isEmpty)
        #expect(subjects.count > 100)
    }

    @Test("길이가 먼 이름을 두 배로 늘려도 추천이 살펴보는 키 수는 같다")
    func lengthWindowBoundsExaminedKeys() {
        func work(farNames: Int) -> SimilarNameWork {
            let near = (0..<20).map { GraphNode(id: NodeID("near\($0)"), name: "fetchUser\($0)", kind: .function) }
            let far = (0..<farNames).map {
                GraphNode(id: NodeID("far\($0)"), name: "presentNotificationSettingsScreen\($0)", kind: .function)
            }
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: near + far, edges: []))
            var observed = SimilarNameWork()
            _ = index.similarCandidates(to: "fetchUsr1", limit: 5) { observed = $0 }
            return observed
        }
        let small = work(farNames: 500)
        let large = work(farNames: 1_000)
        // 길이 창(9 ± 3) 안의 키는 가까운 이름 20개뿐이다. 먼 이름은 길이만 보고도 거리가 한도를 넘는다.
        #expect(small.examinedKeys == 20)
        #expect(large.examinedKeys == 20)
    }

    @Test("글자 구성이 전혀 다른 같은 길이의 이름에는 편집 거리를 계산하지 않는다")
    func characterSetBoundSkipsUnrelatedKeys() {
        let close = ["fetchUser", "fetchUsers", "fetchUse", "fetchUs"].enumerated().map {
            GraphNode(id: NodeID("close\($0.offset)"), name: $0.element, kind: .function)
        }
        // 바늘(fetchusr)에 없는 글자 다섯 종류로 시작하는 같은 길이 이름. 한쪽에만 있는 글자 종류 수가
        // 거리의 하한이라 DP 없이 한도(2)를 넘는다고 확정된다.
        let unrelated = (0..<200).map { ordinal in
            GraphNode(id: NodeID("unrelated\(ordinal)"), name: "qzxjv" + Self.letters(ordinal, count: 3),
                      kind: .function)
        }
        let graph = CodeGraph(level: .symbol, nodes: close + unrelated, edges: [])
        let index = GraphQueryIndex(graph: graph)
        var work = SimilarNameWork()
        let candidates = index.similarCandidates(to: "fetchUsr", limit: 5) { work = $0 }
        #expect(work.examinedKeys == close.count + unrelated.count)
        #expect(work.measuredKeys == close.count)
        #expect(candidates == Self.reference("fetchUsr", keys: Self.referenceKeys(in: graph), graph: graph, limit: 5))
        #expect(Set(candidates.map(\.id)) == Set(close.map(\.id)))
    }

    @Test("이름 조회만으로는 추천 색인을 만들지 않고, 추천을 여러 번 물어도 이름 키는 한 번만 정규화한다")
    func keysAreNormalizedOncePerIndex() {
        let nodes = (0..<50).map {
            GraphNode(id: NodeID("n\($0)"), name: "loadItem\($0)()", kind: .method, module: "App")
        }
        let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: nodes, edges: []))
        for node in nodes { #expect(index.resolve(node.baseName) == .found(node)) }
        var works: [SimilarNameWork] = []
        // 빈 이름과 너무 긴 이름은 추천을 계산하지 않으므로 색인도 만들지 않는다.
        _ = index.similarCandidates(to: "", limit: 5) { works.append($0) }
        _ = index.similarCandidates(to: String(repeating: "a", count: 300), limit: 5) { works.append($0) }
        for subject in ["loadItm1", "loadItem99", "lodItem3"] {
            _ = index.similarCandidates(to: subject, limit: 5) { works.append($0) }
        }
        // 값으로 복사한 색인도 만들어 둔 추천 색인을 나눠 쓴다.
        let copy = index
        _ = copy.similarCandidates(to: "loadItm2", limit: 5) { works.append($0) }
        // 정점마다 name·baseName·qualifiedName 세 키다.
        #expect(works.map(\.normalizedKeys) == [150, 0, 0, 0])
    }

    @Test("한도 안의 편집 거리는 비트 병렬 비교와 띠 DP 모두 전체 DP와 같고, 한도를 넘으면 nil 이다")
    func boundedDistanceMatchesFullDistance() {
        // 세 글자로 만든 4자 이하 낱말 전부, 두 글자로 만든 5자 낱말 전부(띠가 행을 따라 움직이는 경우)와
        // 스칼라 수가 글자 수와 다른 유니코드 낱말.
        var words = Self.allWords(over: "abc", lengths: 0...4) + Self.allWords(over: "ab", lengths: 5...5)
        words += ["i\u{307}stanbul", "istanbul", "e\u{301}cole", "ecole", "stra\u{DF}e", "strasse",
                  "\u{1F468}\u{200D}\u{1F469}"]
        var mismatches = Self.boundedMismatches(needles: words, keys: words, limits: 0...4)
        // 비트 병렬 비교의 경계(63·64·65 스칼라)와 그보다 긴 바늘. 64를 넘으면 띠 DP 로 간다.
        let letters = Array("abcdefgh")
        let long = (63...66).flatMap { length in
            let base = String((0..<length).map { letters[($0 * 5 + $0 / 3) % letters.count] })
            return [base, String(base.dropFirst()), base + "a", String(base.dropLast(2)) + "hh", "z" + base]
        }
        mismatches += Self.boundedMismatches(needles: long, keys: long, limits: 0...3)
        // 실패해도 처음 열 개만 보여 준다.
        #expect(Array(mismatches.prefix(10)).isEmpty)
    }

    /// 두 비교 경로가 전체 DP 와 다른 답을 낸 (바늘, 키, 한도, 경로) 목록.
    private static func boundedMismatches(
        needles: [String], keys: [String], limits: ClosedRange<Int>
    ) -> [String] {
        var mismatches: [String] = []
        for needle in needles {
            let scalars = needle.unicodeScalars.map(\.value)
            var paths = [
                BoundedEditDistance(needle: scalars), BoundedEditDistance(needle: scalars, allowsBitParallel: false),
            ]
            for key in keys {
                let full = GraphQueryIndex.editDistance(needle, key)
                let count = key.unicodeScalars.count
                for limit in limits {
                    let expected = full <= limit ? full : nil
                    for path in paths.indices where paths[path].distance(
                        to: key.unicodeScalars.lazy.map(\.value), scalarCount: count, limit: limit
                    ) != expected {
                        mismatches.append("\(needle)/\(key)/\(limit)/\(path)")
                    }
                }
            }
        }
        return mismatches
    }

    /// 예전 판정의 이름 키 하나: 원래 키, 소문자 키, 원래 키의 글자 수, 키의 첫 정점.
    private typealias ReferenceKey = (name: String, lowered: String, length: Int, node: NodeID)

    /// 예전 판정의 키: 정점마다 name·baseName·qualifiedName, 키마다 첫 정점이 대표다.
    private static func referenceKeys(in graph: CodeGraph) -> [ReferenceKey] {
        var names: [String: [NodeID]] = [:]
        for node in graph.sortedNodes {
            for name in Set([node.name, node.baseName, node.qualifiedName]) {
                names[name, default: []].append(node.id)
            }
        }
        return names.map { ($0.key, $0.key.lowercased(), $0.key.count, $0.value[0]) }
    }

    /// 예전 판정 그대로: 모든 이름 키를 돌며 전체 DP 로 거리를 재고, 정점마다 가장 앞선 (거리, 이름)을 쓴다.
    private static func reference(
        _ subject: String, keys: [ReferenceKey], graph: CodeGraph, limit: Int
    ) -> [GraphNode] {
        guard !subject.isEmpty else { return [] }
        let needle = subject.lowercased()
        guard needle.count <= 256 else { return [] }
        let threshold = max(2, needle.count / 3)
        var best: [NodeID: (distance: Int, name: String)] = [:]
        for key in keys where abs(key.length - needle.count) <= threshold {
            let distance = GraphQueryIndex.editDistance(needle, key.lowered)
            guard distance <= threshold else { continue }
            if let kept = best[key.node], (kept.distance, kept.name) <= (distance, key.name) { continue }
            best[key.node] = (distance, key.name)
        }
        return best.sorted { ($0.value.distance, $0.value.name) < ($1.value.distance, $1.value.name) }
            .prefix(limit).compactMap { graph.node($0.key) }
    }

    /// 흔한 Swift 이름과, 소문자화·글자 경계·스칼라 수가 서로 다른 유니코드 이름을 섞는다.
    private static func mixedNodes() -> [GraphNode] {
        let words = ["user", "profile", "view", "payment", "repository", "settings", "cell", "model", "service",
                     "fetch", "load", "update", "config", "item", "list", "detail", "cache", "image", "token"]
        var nodes: [GraphNode] = []
        for ordinal in 0..<240 {
            let first = words[ordinal % words.count]
            let second = words[(ordinal / words.count + ordinal) % words.count]
            let base = first + second.prefix(1).uppercased() + second.dropFirst()
            let name = ordinal % 3 == 0 ? base + "(id:)" : (ordinal % 3 == 1 ? base.uppercased() : base)
            let kind: SymbolKind = ordinal % 3 == 0 ? .method : .classType
            nodes.append(GraphNode(id: NodeID("s:\(ordinal)"), name: name, kind: kind,
                                   module: ordinal % 5 == 0 ? nil : "Module\(ordinal % 4)"))
        }
        let unicode = ["İstanbul", "ISTANBUL", "Straße", "STRASSE", "ΣΟΦΟΣ", "e\u{301}cole", "École", "naïve",
                       "café", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}Family", "사용자서비스", "ユーザー設定",
                       "(x)", "init()", "a", "ab", "fetch(id:completion:)", "ZOOM_LEVEL", "zoom_level", "_privateValue",
                       "line\r\nbreak", "Tab\tName", String(repeating: "a", count: 400),
                       String(repeating: "b", count: 341), String(repeating: "c", count: 342)]
        for (offset, name) in unicode.enumerated() {
            nodes.append(GraphNode(id: NodeID("u:\(offset)"), name: name, kind: .function, module: "Intl"))
        }
        return nodes
    }

    /// 한 글자 바꾸기·지우기·넣기, 대소문자 바꾸기, 새 글자 두 개로 바꾸기(글자 종류 하한의 경계)와
    /// 길이 차가 한도와 정확히 같도록 자르거나 늘리기(길이 창의 경계).
    private static func typos(of name: String) -> [String] {
        let characters = Array(name)
        guard characters.count > 2 else { return [name + "z"] }
        let middle = characters.count / 2
        var replaced = characters
        replaced[middle] = "q"
        var removed = characters
        removed.remove(at: middle)
        var inserted = characters
        inserted.insert("x", at: middle)
        var twice = characters
        twice[characters.count / 3] = "z"
        twice[2 * characters.count / 3] = "x"
        var shapes = [String(replaced), String(removed), String(inserted), name.uppercased(), String(twice)]
        // 남은 길이 n 의 한도가 잘라 낸 길이와 같으면 그 키는 길이 창의 위쪽 끝에 있다.
        if let kept = (1..<characters.count).last(where: { characters.count - $0 == max(2, $0 / 3) }) {
            shapes.append(String(characters.prefix(kept)))
        }
        // 늘린 길이의 한도가 늘린 글자 수와 같으면 그 키는 길이 창의 아래쪽 끝에 있다.
        if let added = (1...200).first(where: { $0 == max(2, (characters.count + $0) / 3) }) {
            shapes.append(name + String(repeating: "w", count: added))
        }
        return shapes
    }

    private static let edgeSubjects = [
        "", "a", "b", "ab", "x", "istanbul", "ISTANBUL", "i\u{307}stanbul", "strasse", "STRASSE", "σοφος", "ecole",
        "École", "naive", "cafe", "Family", "사용자서비", "ユーザー", "x)", "init", "fetch(id:)", "q", "zoom_levl",
        "ZOOMLEVEL", "_privateValu", "linebreak", "line\r\nbrek", "tabname",
        String(repeating: "a", count: 256), String(repeating: "a", count: 257), String(repeating: "b", count: 300),
        "a" + String(repeating: "\u{301}", count: 300), "s:7Combine9PublisherPAAE4sinkyyF",
    ]

    /// 주어진 글자로 만들 수 있는 길이 범위의 낱말 전부.
    private static func allWords(over alphabet: String, lengths: ClosedRange<Int>) -> [String] {
        var words: [String] = []
        var frontier = [""]
        for length in 0...lengths.upperBound {
            if lengths.contains(length) { words += frontier }
            frontier = frontier.flatMap { word in alphabet.map { word + String($0) } }
        }
        return words
    }

    /// 바늘(fetchusr)에 없는 글자만으로 만든 고유한 낱말.
    private static func letters(_ ordinal: Int, count: Int) -> String {
        let alphabet = Array("abdgijklmnopqvwxyz")
        var value = ordinal
        return String((0..<count).map { _ in
            defer { value /= alphabet.count }
            return alphabet[value % alphabet.count]
        })
    }
}
