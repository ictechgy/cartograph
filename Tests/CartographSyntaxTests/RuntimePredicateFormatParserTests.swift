import CartographCore
@testable import CartographSyntax
import Testing

@Suite("Predicate 키 경로의 제한된 문법")
struct RuntimePredicateFormatParserTests {
    @Test("문자열 값과 연산자를 키로 오인하지 않고 모든 비교 경로를 돌려준다")
    func extractsOnlyComparedPaths() {
        #expect(RuntimePredicateFormatParser.keyPaths(
            in: "leaf.text == %@ AND (leaf.count >= 2 OR NOT enabled == TRUE)", arguments: [nil]
        ) == ["enabled", "leaf.count", "leaf.text"])
        #expect(RuntimePredicateFormatParser.keyPaths(
            in: "leaf.text CONTAINS[cd] 'fake.path' OR other.text == leaf.text"
        ) == ["leaf.text", "other.text"])
        #expect(RuntimePredicateFormatParser.keyPaths(in: "SELF.leaf.text == 'a\\\'b'") == ["leaf.text"])
    }

    @Test("키 치환은 같은 위치의 확인된 문자열만 사용한다")
    func bindsKeyArgumentsByPosition() {
        #expect(RuntimePredicateFormatParser.keyPaths(in: "%K == %@", arguments: ["leaf.text", nil]) == ["leaf.text"])
        #expect(RuntimePredicateFormatParser.keyPaths(
            in: "title == %@ AND %K > 0", arguments: ["not.a.key", "leaf.count"]
        ) == ["leaf.count", "title"])
        #expect(RuntimePredicateFormatParser.keyPaths(in: "%K == %@", arguments: [nil, "text"]) == nil)
        #expect(RuntimePredicateFormatParser.keyPaths(in: "title == %@") == nil)
    }

    @Test("함수와 집계와 깨진 문법은 부분 경로도 확정하지 않는다")
    func rejectsUnsupportedOrMalformedGrammar() {
        for format in [
            "ANY children.text == 'x'", "items.@count > 0", "FUNCTION(leaf, 'text') == 'x'",
            "SUBQUERY(children, $x, $x.text == 'x').@count > 0", "leaf..text == 'x'",
            "leaf.text == 'unterminated", "leaf.text == 'x' trailing", "(leaf.text == 'x'",
            "leaf.text == %s", "leaf.text == 'x'; TRUEPREDICATE", "leaf.text BETWEEN {1, 2}",
        ] {
            #expect(RuntimePredicateFormatParser.keyPaths(in: format) == nil)
        }
    }

    @Test("상수 predicate는 빈 경로이고 깊이나 크기를 넘으면 미결이다")
    func boundsParsingWithoutInventingProperties() {
        #expect(RuntimePredicateFormatParser.keyPaths(in: "TRUEPREDICATE") == [])
        #expect(RuntimePredicateFormatParser.keyPaths(in: "NOT FALSEPREDICATE") == [])
        #expect(RuntimePredicateFormatParser.keyPaths(in: String(repeating: "(", count: 1000) + "TRUEPREDICATE") == nil)
        #expect(RuntimePredicateFormatParser.keyPaths(in: String(repeating: "x", count: 5000)) == nil)
        let maximumPath = (1...16).map { "p\($0)" }.joined(separator: ".")
        #expect(RuntimeKeyPath.components(of: maximumPath)?.count == 16)
        #expect(RuntimeKeyPath.components(of: (1...17).map { "p\($0)" }.joined(separator: ".")) == nil)
    }
}
