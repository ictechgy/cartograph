import CartographCore
@testable import CartographIndexStore
import Foundation
import Testing

@Suite("Clang 모듈의 기록과 unit 근거")
struct ClangModuleEvidenceTests {
    @Test("구현 unit 모듈을 보존하지만 공유 헤더에 소비자 모듈을 붙이지 않는다")
    func moduleEvidencePrecedence() {
        for suffix in ["swift", "m", "mm"] {
            #expect(RawIndexStoreReader.recordModule(dependencyModule: "", unitModule: "App",
                sourcePath: "/p/File.\(suffix)") == "App")
        }
        #expect(RawIndexStoreReader.recordModule(dependencyModule: "Library", unitModule: "App",
            sourcePath: "/p/File.h") == "Library")
        #expect(RawIndexStoreReader.recordModule(dependencyModule: "", unitModule: "App",
            sourcePath: "/p/File.h") == "")
        #expect(RawIndexStoreReader.recordModule(dependencyModule: "", unitModule: "",
            sourcePath: "/p/File.m") == "")
    }

    @Test("실제 Clang unit의 명시 모듈을 보존하며 없는 모듈을 추측하지 않는다")
    func nativeClangUnit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Caller.m")
        try Data("int sample(void) { return 1; }\n".utf8).write(to: source)
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        for explicit in [false, true] {
            let store = root.appendingPathComponent(explicit ? "named" : "unknown")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["clang", "-c", source.path, "-o", root.appendingPathComponent("Caller.o").path,
                "-index-store-path", store.path] + (explicit ? ["-fmodule-name=LocalClang"] : [])
            let diagnostics = Pipe()
            process.standardError = diagnostics
            try process.run()
            let error = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(error)")
            let result = try RawIndexStoreReader(storePath: store.path, libraryPath: library,
                fileSystem: LocalFileSystem()).read(in: [source.path])
            let symbol = try #require(result.occurrences.first {
                $0.symbol.name == "sample" && $0.roles.contains(.definition)
            })
            #expect(symbol.location.moduleName == (explicit ? "LocalClang" : ""))
        }
    }
}
