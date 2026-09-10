import CartographCore
import Foundation
import Testing

@Suite("JSON 인코딩")
struct JSONEncodingTests {
    private struct Sample: Encodable {
        let path: String
        let apple: String
        let banana: String
    }

    @Test("키 순서를 고정하고 슬래시를 이스케이프하지 않는다")
    func sortsKeysAndPreservesSlashes() throws {
        let sample = Sample(path: "/Users/dev/cartograph/Sources/file.swift", apple: "A", banana: "B")
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        let data = try encoder.encode(sample)
        let json = try #require(String(data: data, encoding: .utf8))

        // 슬래시가 \/ 로 이스케이프되지 않아야 한다.
        #expect(json.contains("/Users/dev/cartograph/Sources/file.swift"))
        #expect(!json.contains("\\/"))

        // 키 순서가 사전순(apple -> banana -> path)으로 정렬되어야 한다.
        #expect(json == "{\"apple\":\"A\",\"banana\":\"B\",\"path\":\"/Users/dev/cartograph/Sources/file.swift\"}")
    }

    @Test("prettyPrinted 옵션에 따라 줄바꿈을 제어한다")
    func prettyPrintedOptionFormatsJSON() throws {
        let sample = Sample(path: "path/to/file", apple: "1", banana: "2")
        let prettyEncoder = JSONEncoder.cartographDefault(prettyPrinted: true)
        let prettyData = try prettyEncoder.encode(sample)
        let prettyJSON = try #require(String(data: prettyData, encoding: .utf8))

        #expect(prettyJSON.contains("\n"))
        #expect(prettyJSON.contains("\"apple\" : \"1\""))
    }
}
