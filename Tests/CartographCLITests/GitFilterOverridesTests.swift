@testable import cartograph
import CartographCore
import Foundation
import Testing

@Suite("Git 필터 설정의 바이트 전달")
struct GitFilterOverridesTests {
    @Test("임시 include 는 정규화·따옴표·역슬래시 이름을 정확히 전달하고 비공개 파일을 정리한다")
    func preservesExactSubsectionsAndCleansUp() throws {
        let names = ["\u{00E9}", "e\u{0301}", "\u{0301}driver", "quote\"name", "slash\\name", "both\"\\", ""]
        let input = names.flatMap { ["-c", "filter.\($0).clean=", "-c", "filter.\($0).required=false"] }
        let overrides = try GitFilterOverrides.prepare(input, reference: "HEAD")
        defer { overrides.cleanup() }
        let assignment = try #require(overrides.arguments.last)
        let file = String(assignment.dropFirst("include.path=".count))
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let parent = (file as NSString).deletingLastPathComponent
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: parent)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let data = try ChangedFiles.output(of: ["config", "-z", "--list"],
                                           in: parent, reference: "HEAD", globalOptions: overrides.arguments)
        var values: [Data: Data] = [:]
        for entry in data.split(separator: 0) {
            if let newline = entry.firstIndex(of: 0x0A) {
                values[Data(entry[..<newline])] = Data(entry[entry.index(after: newline)...])
            }
        }
        for name in names {
            #expect(values[Data("filter.\(name).clean".utf8)] == Data())
            #expect(values[Data("filter.\(name).required".utf8)] == Data("false".utf8))
        }
        overrides.cleanup()
        #expect(!FileManager.default.fileExists(atPath: parent))
    }

    @Test("콘텐츠 명령·제어 문자·알 수 없는 설정은 파일 생성 전에 거부한다")
    func rejectsUnsafeAssignments() {
        for assignment in ["filter.n.clean=echo", "filter.n.required=true", "filter.n.unknown=",
                           "filter.n.clean", "filter.\u{1}.clean=", "filter.line\nname.clean="] {
            #expect(throws: CartographError.self) {
                try GitFilterOverrides.prepare(["-c", assignment], reference: "HEAD")
            }
        }
    }

    @Test("필터가 없는 전역 옵션은 임시 파일 없이 보존한다")
    func preservesOtherOptions() throws {
        let options = ["--literal-pathspecs", "-c", "diff.autoRefreshIndex=false"]
        let overrides = try GitFilterOverrides.prepare(options, reference: "HEAD")
        defer { overrides.cleanup() }
        #expect(overrides.arguments == options)
    }
}
