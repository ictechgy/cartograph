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

    @Test("일반 Clang 구현 unit에는 module-name 플래그만으로 모듈을 만들어 붙이지 않는다")
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
            // -fmodule-name은 module 생성이 아닌 일반 .m compile unit의 모듈 근거가 아니다.
            // 실제 compiler도 빈 moduleName을 기록한다. 명령 옵션을 관측 사실로 바꾸지 않는다.
            #expect(symbol.location.moduleName.isEmpty)
        }
    }

    @Test("실제 Clang module map의 헤더 모듈은 보존하고 일반 소비자 구현은 unknown으로 남긴다")
    func nativeClangModuleMap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Caller.m")
        let header = root.appendingPathComponent("Library.h")
        try Data("int declaredValue(void);\n".utf8).write(to: header)
        try Data("module LocalClang { header \"Library.h\" export * }\n".utf8)
            .write(to: root.appendingPathComponent("module.modulemap"))
        try Data("@import LocalClang;\nint sample(void) { return declaredValue(); }\n".utf8).write(to: source)
        let store = root.appendingPathComponent("index")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-c", source.path, "-o", root.appendingPathComponent("Caller.o").path,
            "-index-store-path", store.path, "-fmodules", "-I", root.path,
            "-fmodules-cache-path=\(root.appendingPathComponent("module-cache").path)"]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        try process.run()
        let error = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(error)")
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        let result = try RawIndexStoreReader(storePath: store.path, libraryPath: library,
            fileSystem: LocalFileSystem()).read(in: [source.path, header.path])
        let declaration = try #require(result.occurrences.first {
            $0.symbol.name == "declaredValue" && $0.roles.contains(.declaration)
        })
        #expect(declaration.location.moduleName == "LocalClang")
        let caller = try #require(result.occurrences.first {
            $0.symbol.name == "sample" && $0.roles.contains(.definition)
        })
        #expect(caller.location.moduleName.isEmpty)
    }
}
