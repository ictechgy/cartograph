import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("Xcode compiler 문서의 경계와 의미 검증")
struct XcodeLocalPackageReaderTests {
    @Test("bare loader path는 rpath 피연산자로만 허용하고 상대 response로 추측하지 않는다")
    func bareLoaderPath() throws {
        let fs = InMemoryFileSystem()
        var reader = try XcodeLocalPackageReader(files: [:], buildRoot: "/capture/DerivedData/Build",
            indexStore: "/capture/DerivedData/Index.noindex/DataStore", fileSystem: fs)
        #expect(try reader.arguments(["/tool/clang", "-Xlinker", "-rpath", "-Xlinker", "@loader_path"]) == ["/tool/clang", "-rpath", "@loader_path"])
        #expect(throws: (any Error).self) { try reader.arguments(["/tool/clang", "@loader_path"]) }
    }

    @Test("quote와 escape를 실행하지 않고 실제 토큰을 읽으며 잘림과 중첩을 거부한다")
    func tokenGrammar() throws {
        #expect(try XcodeEvidenceTokens.read(#"'/path with spaces' "quoted" escaped\ space"#, maximum: 3)
            == ["/path with spaces", "quoted", "escaped space"])
        #expect(try XcodeEvidenceTokens.read(#""ordinary\q" "quote\"" "slash\\""#, maximum: 3)
            == [#"ordinary\q"#, "quote\"", "slash\\"])
        #expect(try XcodeEvidenceTokens.read("a\r\nb\r\n", maximum: 2) == ["a", "b"])
        for text in ["'open", "trailing\\", "one two", "''", "a\u{0}b"] {
            #expect(throws: (any Error).self) { try XcodeEvidenceTokens.read(text, maximum: 1) }
        }
        #expect(throws: (any Error).self) { try XcodeEvidenceTokens.read(String(repeating: "x", count: 4_097), maximum: 1) }
        #expect(throws: (any Error).self) { try XcodeLocalPackageIO.argument("-o", in: ["-o", "a", "-o", "b"]) }
        #expect(throws: (any Error).self) { try XcodeLocalPackageIO.argument("-o", in: ["-o"]) }
    }

    @Test("파일 목록과 response는 현재 해시를 만족해도 잘못된 내용이면 거부한다",
        arguments: ["nested", "relative", "duplicate", "empty", "oversized", "non-utf8", "outside"])
    func rejectsMalformedDocuments(kind: String) throws {
        let path = kind == "outside" ? "/outside/list" : "/capture/DerivedData/Build/list"
        let bytes: Data
        switch kind {
        case "nested": bytes = Data("@/another/response".utf8)
        case "relative": bytes = Data("@relative-response".utf8)
        case "duplicate": bytes = Data("/p/a\n/p/a\n".utf8)
        case "empty": bytes = Data()
        case "oversized": bytes = Data(Array(repeating: "x", count: 1_001).joined(separator: " ").utf8)
        case "non-utf8": bytes = Data([0xff])
        default: bytes = Data("/p/a".utf8)
        }
        let fs = InMemoryFileSystem(); try fs.write(bytes, to: path)
        var reader = try XcodeLocalPackageReader(files: [path: .init(sha256: TargetScopeStore.digest(bytes),
            bytes: bytes.count, kind: "document")], buildRoot: "/capture/DerivedData/Build", indexStore: "/index", fileSystem: fs)
        #expect(throws: (any Error).self) {
            if ["nested", "relative", "oversized"].contains(kind) { _ = try reader.arguments(["clang", "@" + path]) }
            else { _ = try reader.fileList(path) }
        }
    }

    @Test("link map의 live owner만 허용하고 목록 존재나 unknown 행을 기여로 인증하지 않는다",
        arguments: ["dead", "owner", "duplicate", "unparsed", "path", "arch", "section", "duplicate-header"])
    func linkMapNegativeControls(kind: String) throws {
        var text = String(decoding: XcodeLocalPackageEvidenceTests.linkMap(output: "/out", owners: ["/object"]), as: UTF8.self)
        switch kind {
        case "dead": text = text.replacingOccurrences(of: "0x00000000\t0x00000008", with: "<<dead>>\t0x00000008")
        case "owner": text = text.replacingOccurrences(of: "\t[ 1] symbol0", with: "\t[ 9] symbol0")
        case "duplicate": text = text.replacingOccurrences(of: "[ 1] /object", with: "[ 1] /object\n[ 1] /other")
        case "unparsed": text += "not a symbol row\n"
        case "path": text = text.replacingOccurrences(of: "# Path: /out", with: "# Path: /wrong")
        case "arch": text = text.replacingOccurrences(of: "# Arch: arm64", with: "# Arch: x86_64")
        case "section": text = text.replacingOccurrences(of: "0x0 0x8 __TEXT __text", with: "unparsed section")
        default: text += "# Symbols:\n"
        }
        #expect(throws: (any Error).self) {
            try XcodeLinkMapEvidence.validate(Data(text.utf8), output: "/out", architecture: "arm64", required: ["/object"])
        }
    }

    @Test("허용한 proof의 object를 뒤의 map 읽기 중 바꾸면 마지막 관측에서 거부한다")
    func finalReadFindsMidValidationMutation() throws {
        let fixture = try XcodeLocalPackageEvidenceTests().fixture()
        let fs = MutatingProofFileSystem(base: fixture.base.fs, victim: fixture.object,
            trigger: "/capture/DerivedData/Build/Intermediates.noindex/Core.map")
        #expect(throws: (any Error).self) {
            try XcodeTargetScopeStore(fileSystem: fs).read(path: "/p/scope.json", root: "/p", fingerprint: fixture.base.fingerprint)
        }
        #expect(fs.didMutate)
    }

    @Test("receipt 조회 이후 object와 record를 고치면 generic fingerprint가 같아도 final proof를 거부한다",
        arguments: ["object", "record"])
    func finalProofIgnoresTimestampShortcut(kind: String) throws {
        let fixture = try XcodeLocalPackageEvidenceTests().fixture()
        let bytes = try fixture.base.fs.readData(at: "/p/scope.json")
        let proof = XcodeLocalPackageProof(path: "/p/scope.json", root: "/p", fingerprint: fixture.base.fingerprint,
            receiptDigest: TargetScopeStore.digest(bytes), indexStore: "/capture/DerivedData/Index.noindex/DataStore")
        try proof.verify(fileSystem: fixture.base.fs)
        try fixture.base.fs.write(text: "changed with unchanged mtime", to: kind == "object" ? fixture.object : fixture.record)
        #expect(throws: (any Error).self) { try proof.verify(fileSystem: fixture.base.fs) }
    }
}

private final class MutatingProofFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let victim: String
    let trigger: String
    private let lock = NSLock()
    private var mutated = false
    var didMutate: Bool { lock.withLock { mutated } }
    init(base: InMemoryFileSystem, victim: String, trigger: String) {
        self.base = base; self.victim = victim; self.trigger = trigger
    }
    func readData(at path: String) throws -> Data { try readData(at: path, maximumBytes: Int.max - 1) }
    func readData(at path: String, maximumBytes: Int) throws -> Data {
        let bytes = try base.readData(at: path, maximumBytes: maximumBytes)
        let change = lock.withLock {
            if path == trigger && !mutated { mutated = true; return true }
            return false
        }
        if change { try base.write(text: "concurrent replacement", to: victim) }
        return bytes
    }
    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String, maximumEntries: Int) throws -> [DirectoryEntry] {
        try base.directoryEntries(at: path, maximumEntries: maximumEntries)
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
