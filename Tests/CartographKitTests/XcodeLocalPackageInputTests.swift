@testable import CartographKit
import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("실행하지 않는 로컬 패키지 입력 계약")
struct XcodeLocalPackageInputTests {
    @Test("admission의 기존 initializer 함수 참조와 nil 빈 문자열 결정적 정렬을 보존한다")
    func admissionCompatibilityAndOrdering() throws {
        let legacy: (String, String, String, String, Date) -> SourceRecordAdmission = SourceRecordAdmission.init
        let unknown = legacy("/p/A.swift", "A", "u", "r", .distantPast)
        let empty = SourceRecordAdmission(path: "/p/A.swift", module: "A", unit: "u", record: "r", timestamp: .distantPast,
            unitOutputIdentity: "", unitTargetTriple: "")
        #expect(SourceRecordAdmission.sorted([empty, unknown]) == [unknown, empty])
        #expect(SourceRecordAdmission.sorted([unknown, empty, unknown]) == [unknown, empty])
    }

    @Test("소스 수 깊이 manifest bytes 및 전체 subtree entry 상한을 넘기면 거부한다",
        arguments: ["sources", "depth", "manifest", "entries"])
    func boundedInventory(kind: String) throws {
        let fs = InMemoryFileSystem(files: ["/p/Package.swift": "manifest", "/p/Sources/Lib/A.swift": "source"])
        switch kind {
        case "sources":
            for i in 0..<256 { try fs.write(text: "", to: "/p/Sources/Lib/Source\(i).swift") }
        case "depth":
            try fs.write(text: "", to: "/p/Sources/Lib/" + Array(repeating: "d", count: 129).joined(separator: "/") + "/Deep.swift")
        case "manifest": try fs.write(Data(repeating: 32, count: 64 * 1_024 + 1), to: "/p/Package.swift")
        default:
            for i in 0..<4_096 { try fs.write(text: "", to: "/p/Sources/Lib/d\(i)/A.swift") }
        }
        #expect(throws: (any Error).self) {
            try XcodeLocalPackageInputs.inventory(root: "/p", module: "Lib", fileSystem: fs)
        }
    }
    private let text = """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "LocalMath", products: [.library(name: "ArithmeticProduct", targets: ["ArithmeticCore"])], targets: [.target(name: "ArithmeticCore")])
    """

    @Test("제품 이름과 모듈을 분리하고 주석 속 텍스트는 실행 구문으로 읽지 않는다")
    func literalAndComments() throws {
        let data = Data(text.utf8)
        let expected = XcodeLocalPackageInputs.Manifest(name: "LocalMath", product: "ArithmeticProduct", module: "ArithmeticCore")
        #expect(try XcodeLocalPackageInputs.manifest(data) == expected)
        let comments = text.replacingOccurrences(of: "let package", with: "/* outer /* nested */ text */ let package")
        #expect(try XcodeLocalPackageInputs.manifest(Data(comments.utf8)) == expected)
        #expect(try XcodeLocalPackageInputs.manifest(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)) == expected)
        for separator in ["\u{2028}", "\u{2029}"] {
            let changed = text.replacingOccurrences(of: "5.9\n", with: "5.9" + separator + "\n")
            #expect(throws: (any Error).self) { try XcodeLocalPackageInputs.manifest(Data(changed.utf8)) }
        }
    }

    @Test("계산식 보간 escape와 선언 뒤 실행 또는 미지원 타깃은 남김없이 거부한다",
        arguments: ["trailing", "expression", "interpolation", "escape", "macro", "dependency", "leading-newline", "unclosed-comment"])
    func refusesExecutableOrUnsupported(kind: String) throws {
        let changed: String
        switch kind {
        case "trailing": changed = text + "\nprint(1)"
        case "expression": changed = text.replacingOccurrences(of: "\"LocalMath\"", with: "compute()")
        case "interpolation": changed = text.replacingOccurrences(of: "\"LocalMath\"", with: #""Local\(run())""#)
        case "escape": changed = text.replacingOccurrences(of: "\"LocalMath\"", with: #""Local\u{004d}ath""#)
        case "macro": changed = text.replacingOccurrences(of: ".target(", with: ".macro(")
        case "dependency": changed = text.replacingOccurrences(of: ".target(name: \"ArithmeticCore\")", with: ".target(name: \"ArithmeticCore\", dependencies: [])")
        case "leading-newline": changed = "\n" + text
        default: changed = text + "\n/* unclosed"
        }
        #expect(throws: (any Error).self) { try XcodeLocalPackageInputs.manifest(Data(changed.utf8)) }
    }

    @Test("공유 오류 생성기로 의존을 분리해도 manifest 단계별 거부 이유를 유지한다",
        arguments: ["version", "comment", "trailing"])
    func parserErrorContract(kind: String) throws {
        let changed: String
        let reason: String
        switch kind {
        case "version":
            changed = text.replacingOccurrences(of: "5.9", with: "4.0")
            reason = "Unsupported tools version, manifest encoding or byte budget."
        case "comment":
            changed = text + "\n/* unclosed"
            reason = "Unterminated manifest comment."
        default:
            changed = text + "\nprint(1)"
            reason = "Unsupported manifest syntax."
        }
        #expect(throws: CartographError.invalidConfiguration(path: "xcode-local-package", reason: reason)) {
            try XcodeLocalPackageInputs.manifest(Data(changed.utf8))
        }
    }

    @Test("패키지 subtree 전체를 검사해 새 비 Swift 확장자와 resource 디렉터리를 놓치지 않는다",
        arguments: ["Sources/ArithmeticCore/Hidden.c", "Sources/ArithmeticCore/Hidden.cpp", "data.bin", ".config", "Resources/asset"])
    func allSubtreeEntries(path: String) throws {
        let fs = InMemoryFileSystem(files: ["/p/Package.swift": text, "/p/Sources/ArithmeticCore/Math.swift": "func value() {}"])
        let original = try XcodeLocalPackageInputs.inventory(root: "/p", module: "ArithmeticCore", fileSystem: fs)
        #expect(original["Sources"] == "directory")
        #expect(original["Sources/ArithmeticCore/Math.swift"] != nil)
        try fs.write(Data("unsupported".utf8), to: "/p/" + path)
        #expect(throws: (any Error).self) {
            try XcodeLocalPackageInputs.inventory(root: "/p", module: "ArithmeticCore", fileSystem: fs)
        }
    }

    @Test("이전 admission은 output 증거 없음으로 읽고 새 가상 신원은 실제 경로처럼 rebasing하지 않는다")
    func admissionCompatibility() throws {
        let previous = #"{"path":"/old/Math.swift","module":"ArithmeticCore","unit":"unit","record":"record","timestamp":0}"#
        let old = try JSONDecoder().decode(SourceRecordAdmission.self, from: Data(previous.utf8))
        #expect(old.unitOutputIdentity == nil && old.unitTargetTriple == nil)
        let fresh = SourceRecordAdmission(path: old.path, module: old.module, unit: old.unit, record: old.record,
            timestamp: old.timestamp, unitOutputIdentity: "/virtual/Math.o", unitTargetTriple: "arm64-apple-macos10.13")
        let rebased = fresh.rebased { $0.replacingOccurrences(of: "/old/", with: "/new/") }
        #expect(rebased.path == "/new/Math.swift")
        #expect(rebased.unitOutputIdentity == "/virtual/Math.o")
        #expect(rebased.unitTargetTriple == "arm64-apple-macos10.13")
        #expect(try JSONDecoder().decode(SourceRecordAdmission.self, from: JSONEncoder().encode(fresh)) == fresh)
    }
}
