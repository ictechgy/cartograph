import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("Xcode compiler 문서의 경계와 의미 검증")
struct XcodeLocalPackageReaderTests {
    @Test("관측한 Swift와 Clang wrapper만 같은 aggregate와 native live chain으로 허용한다",
        arguments: ["swift", "clang", "mixed", "duplicate", "driver", "mode", "relocatable", "dead",
                    "tampered", "missing", "install", "outside", "ordinary", "wrong-product"])
    func dynamicProductDriverForms(kind: String) throws {
        let fixture = try dynamicProductFixture(kind: kind)
        let scope = fixture.scope()
        #expect(scope.evidenceStatus == (["swift", "clang"].contains(kind) ? "matched-capture" : "unknown"))
    }

    private func dynamicProductFixture(kind: String) throws -> XcodeLocalPackageEvidenceTests.Fixture {
        var fixture = try XcodeLocalPackageEvidenceTests().fixture()
        let fs = fixture.base.fs, build = "/capture/DerivedData/Build", middle = build + "/Intermediates.noindex"
        let name = kind == "swift" ? "ArithmeticProduct" : kind == "ordinary" ? "CoreKit"
            : (kind == "wrong-product" ? "Foreign" : "ArithmeticProduct") + "_0123456789ABCDEF_PackageProduct"
        let parent = kind == "outside" ? "/outside" : kind == "ordinary" ? build + "/Products/Debug"
            : build + "/Products/Debug/PackageFrameworks"
        let bundle = parent + "/" + name + ".framework"
        let binary = bundle + "/Versions/A/" + name, info = bundle + "/Versions/A/Resources/Info.plist"
        let list = middle + "/Product.LinkFileList", map = middle + "/Product.map"
        var package = fixture.base.receipt["localPackage"] as! [String: Any]
        var files = package["files"] as! [String: Any]
        var products = fixture.base.receipt["products"] as! [String: String]
        func put(_ path: String, _ data: Data, kind: String) throws {
            try fs.write(data, to: path)
            files[path] = ["sha256": TargetScopeStore.digest(data), "bytes": data.count, "kind": kind]
        }
        try put(binary, Data("synthetic dynamic framework".utf8), kind: "object")
        try put(info, PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": name,
            "CFBundlePackageType": "FMWK"], format: .xml, options: 0), kind: "document")
        let input = kind == "missing" ? middle + "/Core.o" : fixture.aggregate
        try put(list, Data((input + "\n").utf8), kind: "document")
        try put(map, XcodeLocalPackageEvidenceTests.linkMap(output: binary,
            owners: kind == "dead" ? [] : [fixture.aggregate]), kind: "document")
        products[binary] = TargetScopeStore.digest(try fs.readData(at: binary))
        products[info] = TargetScopeStore.digest(try fs.readData(at: info))
        let installName = "@rpath/" + name + ".framework/Versions/A/" + name
        var argv = kind == "swift" ? ["/Xcode/swiftc", "-emit-library", "@" + list]
            : ["/Xcode/clang", "-dynamiclib", "-filelist", list]
        argv += ["-target", "arm64-apple-macos10.13", "-install_name", installName, "-map", map, "-o", binary]
        if kind == "mixed" { argv.append("-emit-library") }
        if kind == "duplicate" { argv.append("-dynamiclib") }
        if kind == "driver" { argv[0] = "/Xcode/unknown" }
        if kind == "relocatable" { argv.append("-r") }
        if kind == "install" { argv[argv.firstIndex(of: "-install_name")! + 1] = "@rpath/Wrong.framework/Wrong" }
        let mode = kind == "swift" || kind == "mode" ? "response" : "operand"
        let wrapper: [String: Any] = ["argv": argv, "fileList": list, "fileListMode": mode,
            "output": binary, "linkMap": map]
        package["dynamicProduct"] = ["link": wrapper, "bundle": bundle, "infoPlist": info, "installName": installName]
        package["aggregateCandidateFileLists"] = [middle + "/Package.LinkFileList", list]
        var links = package["links"] as! [[String: Any]]
        var native = links[0]["link"] as! [String: Any]
        var nativeArguments = native["argv"] as! [String]
        nativeArguments.append(binary); native["argv"] = nativeArguments
        try put(native["fileList"] as! String, Data((middle + "/Core.o\n").utf8), kind: "document")
        let nativeMap = XcodeLocalPackageEvidenceTests.linkMap(output: native["output"] as! String,
            owners: [middle + "/Core.o", binary])
        try put(native["linkMap"] as! String, nativeMap, kind: "document")
        links[0]["link"] = native; links[0]["packageInput"] = binary
        package["links"] = links; package["files"] = files
        fixture.base.receipt["localPackage"] = package; fixture.base.receipt["products"] = products
        if kind == "tampered" { try fs.write(text: "changed framework bytes", to: binary) }
        try fixture.base.write()
        return fixture
    }

    @Test("response 안의 package 입력도 현재 바이트와 live owner가 모두 입증될 때만 허용한다",
        arguments: ["valid", "missing", "nested", "duplicate-output", "dead", "tampered", "outside", "non-utf8"])
    func responseOnlyPackageInput(kind: String) throws {
        let root = "/capture/DerivedData/Build", object = root + "/Native.o"
        let package = root + "/Package with space.o", output = root + "/Native"
        let list = root + "/Native.LinkFileList", map = root + "/Native.map"
        let response = kind == "outside" ? "/outside/link.resp" : root + "/link.resp"
        var text = "\"\(package)\""
        if kind == "missing" { text = "-lswiftCore" }
        if kind == "nested" { text = "@" + root + "/nested.resp" }
        if kind == "duplicate-output" { text += " -o " + root + "/Other" }
        let data = kind == "non-utf8" ? Data([0xff]) : Data(text.utf8)
        let fs = InMemoryFileSystem()
        let rows: [String: Data] = [object: Data("native object".utf8), package: Data("package object".utf8),
            output: Data("actual output".utf8), list: Data((object + "\n").utf8), response: data,
            map: XcodeLocalPackageEvidenceTests.linkMap(output: output, owners: kind == "dead" ? [object] : [object, package])]
        var files: [String: XcodeLocalPackageProofFile] = [:]
        for (path, bytes) in rows {
            try fs.write(bytes, to: path)
            files[path] = .init(sha256: TargetScopeStore.digest(bytes), bytes: bytes.count,
                               kind: [object, package, output].contains(path) ? "object" : "document")
        }
        if kind == "tampered" { try fs.write(text: text + " -changed", to: response) }
        let link = XcodeLocalPackageEvidence.Link(argv: ["/tool/clang", "-target", "arm64-apple-macos14.0",
            "-filelist", list, "-map", map, "@" + response, "-o", output],
            fileList: list, output: output, linkMap: map, fileListMode: nil)
        var reader = try XcodeLocalPackageReader(files: files, buildRoot: root, indexStore: "/index", fileSystem: fs)
        if kind == "valid" {
            #expect(try XcodeLocalPackageEvidence.validateLink(link, required: [package], architecture: "arm64",
                relocatable: false, reader: &reader) == [object, package])
            #expect(reader.used.contains(response))
        } else {
            #expect(throws: (any Error).self) {
                try XcodeLocalPackageEvidence.validateLink(link, required: [package], architecture: "arm64",
                    relocatable: false, reader: &reader)
            }
        }
    }

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

    @Test("dead-stripped 표의 빈 Address 열은 읽되 제거된 owner는 live 기여가 아니다",
        arguments: ["# Address\tSize\tFile  Name", "#        \tSize    \tFile  Name"])
    func deadStrippedColumnHeaders(header: String) throws {
        let text = """
        # Path: /out
        # Arch: arm64
        # Object files:
        [ 1] /live.o
        [ 2] /dead.o
        # Sections:
        # Address Size Segment Section
        0x0 0x8 __TEXT __text
        # Symbols:
        # Address Size File Name
        0x0 0x8 [ 1] live
        # Dead Stripped Symbols:
        \(header)
        <<dead>> 0x8 [ 2] removed
        """
        try XcodeLinkMapEvidence.validate(Data(text.utf8), output: "/out", architecture: "arm64", required: ["/live.o"])
        #expect(throws: (any Error).self) {
            try XcodeLinkMapEvidence.validate(Data(text.utf8), output: "/out", architecture: "arm64", required: ["/dead.o"])
        }
        let malformed = text.replacingOccurrences(of: header, with: header + " Unknown")
        #expect(throws: (any Error).self) {
            try XcodeLinkMapEvidence.validate(Data(malformed.utf8), output: "/out", architecture: "arm64", required: ["/live.o"])
        }
        let misplaced = text.replacingOccurrences(of: "# Dead Stripped Symbols:\n\(header)", with: "#        \tSize    \tFile  Name")
        #expect(throws: (any Error).self) {
            try XcodeLinkMapEvidence.validate(Data(misplaced.utf8), output: "/out", architecture: "arm64", required: ["/live.o"])
        }
    }

    @Test("검증할 native host 이미지의 별칭 owner만 중복을 허용하고 source 기여에는 쓰지 않는다")
    func repeatedNativeHostOwners() throws {
        let text = """
        # Path: /out
        # Arch: arm64
        # Object files:
        [ 1] /source.o
        [ 2] /Host.debug.dylib
        [ 3] /Host.debug.dylib
        # Sections:
        # Address Size Segment Section
        0x0 0x8 __TEXT __text
        # Symbols:
        # Address Size File Name
        0x0 0x8 [ 1] source
        0x8 0x8 [ 2] host
        0x10 0x8 [ 3] hostAlias
        """
        let data = Data(text.utf8)
        try XcodeLinkMapEvidence.validate(data, output: "/out", architecture: "arm64", required: ["/source.o"],
            allowedRepeatedOwners: ["/Host.debug.dylib"])
        for allowed: Set<String> in [[], ["/unbound.dylib"]] {
            #expect(throws: (any Error).self) {
                try XcodeLinkMapEvidence.validate(data, output: "/out", architecture: "arm64", required: ["/source.o"],
                    allowedRepeatedOwners: allowed)
            }
        }
        #expect(throws: (any Error).self) {
            try XcodeLinkMapEvidence.validate(data, output: "/out", architecture: "arm64", required: ["/Host.debug.dylib"],
                allowedRepeatedOwners: ["/Host.debug.dylib"])
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
