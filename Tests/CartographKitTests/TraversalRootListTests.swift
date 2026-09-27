@testable import CartographKit
import Foundation
import Testing

@Suite("--roots-from root 목록 형식")
struct TraversalRootListTests {
    private func parse(_ text: String) throws -> TraversalRootList.Parsed {
        try TraversalRootList.parse(Data(text.utf8))
    }

    @Test("줄 형식은 빈 줄과 # 주석을 건너뛰고 앞뒤 공백을 떼며 입력 순서대로 중복을 뺀다")
    func readsLineFormat() throws {
        let parsed = try parse("# isthmus capture roots\n\ns:B\n  s:A  \ns:B\n   \n#s:C\n")
        #expect(parsed.roots == ["s:B", "s:A"])
        #expect(parsed.factsWithoutUSR == 0)
    }

    @Test("CRLF 파일도 줄마다 나눈다 — Swift 는 CRLF 를 문자 하나로 본다")
    func splitsCRLFLines() throws {
        #expect(try parse("s:A\r\ns:B\r\n").roots == ["s:A", "s:B"])
    }

    @Test("탭과 홀로 선 CR 은 떼지 않고 남겨 제어 문자 검사가 거부하게 한다")
    func keepsControlCharactersForRejection() throws {
        #expect(try parse("\ts:A\n").roots == ["\ts:A"])
        #expect(try parse("s:A\rs:B\n").roots == ["s:A\rs:B"])
    }

    @Test("JSON 문자열 배열은 순서를 지키고 중복을 빼며, 앞의 공백과 BOM 을 허용한다")
    func readsJSONArray() throws {
        #expect(try parse(" \n[\"s:B\", \"s:A\", \"s:B\"]\n").roots == ["s:B", "s:A"])
        #expect(try parse("\u{FEFF}[\"s:A\"]").roots == ["s:A"])
        // 빈 문자열은 여기서 거르지 않는다. 위치 인자와 합친 뒤의 검사가 사용 오류로 알린다.
        #expect(try parse("[\"\"]").roots == [""])
    }

    @Test("문자열이 아닌 원소나 깨진 JSON 배열은 거부한다")
    func rejectsMalformedJSONArray() {
        for text in ["[\"s:A\", 1]", "[\"s:A\"", "[null]", "[[\"s:A\"]]"] {
            #expect(throws: TraversalRootListError.self) { try parse(text) }
        }
    }

    @Test("bridge-facts 문서는 사실의 symbol.usr 를 문서 순서대로 쓰고 usr 없는 사실은 세기만 한다")
    func readsBridgeFactsDocument() throws {
        let document = """
            {"format": "bridge-facts", "version": 1, "facts": [
              {"kind": "route-call", "symbol": {"usr": "s:B", "qualifiedName": "B"}},
              {"kind": "route-call", "symbol": {"qualifiedName": "OnlyName"}},
              {"kind": "route-call"},
              {"kind": "relation-use", "symbol": {"usr": "s:A"}},
              {"kind": "route-call", "symbol": {"usr": "s:B"}}
            ]}
            """
        let parsed = try parse(document)
        #expect(parsed.roots == ["s:B", "s:A"])
        #expect(parsed.factsWithoutUSR == 2)
    }

    @Test("잘린 JSON 은 모양 오류가 아니라 문법 오류로 알린다")
    func reportsMalformedJSONAsSyntaxError() {
        for text in ["[\"s:A\",", "{\"format\": \"bridge-facts\""] {
            #expect(throws: TraversalRootListError.self) { try parse(text) }
            do {
                _ = try parse(text)
            } catch {
                #expect("\(error)".contains("not valid JSON"))
            }
        }
        do {
            _ = try parse("[1]")
        } catch {
            #expect(!"\(error)".contains("not valid JSON"))
        }
    }

    @Test("bridge-facts 가 아닌 객체와 facts 배열이 없는 문서는 거부한다")
    func rejectsOtherObjects() {
        for text in ["{\"format\": \"language-traversal\", \"facts\": []}", "{\"format\": \"bridge-facts\"}", "{"] {
            #expect(throws: TraversalRootListError.self) { try parse(text) }
        }
    }

    @Test("16 MiB 까지 받고 넘으면 거부한다")
    func enforcesSizeLimit() throws {
        let limit = TraversalRootList.maximumByteCount
        var exact = Data(repeating: UInt8(ascii: " "), count: limit - 4)
        exact.append(contentsOf: Array("s:A\n".utf8))
        #expect(try TraversalRootList.parse(exact).roots == ["s:A"])
        exact.append(UInt8(ascii: " "))
        #expect(throws: TraversalRootListError.tooLarge) { try TraversalRootList.parse(exact) }
    }

    @Test("UTF-8 이 아닌 입력은 거부하고 원인 문구가 받는 형식을 알려 준다")
    func rejectsNonUTF8() {
        #expect(throws: TraversalRootListError.notUTF8) { try TraversalRootList.parse(Data([0xFF, 0xFE, 0x00])) }
        #expect("\(TraversalRootListError.notUTF8)".contains("one root per line"))
    }

    @Test("빈 입력과 주석뿐인 입력은 root 가 없다")
    func emptyInputHasNoRoots() throws {
        #expect(try parse("").roots.isEmpty)
        #expect(try parse("# nothing yet\n\n").roots.isEmpty)
    }
}
