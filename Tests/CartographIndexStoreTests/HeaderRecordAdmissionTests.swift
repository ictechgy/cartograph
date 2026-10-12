import CartographCore
@testable import CartographIndexStore
import Foundation
import Testing

@Suite("실제 Clang 프로젝트 헤더 레코드", .serialized)
struct HeaderRecordAdmissionTests {
    @Test("모든 관측 헤더 문맥을 읽고 네 inline 간선과 중복 문맥을 보존하며 외부·제외 헤더는 넣지 않는다")
    func admitsEveryScopedHeaderContextWithReaderParity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = fixture.provider(.raw)
        let paths = Set(provider.sourceFilePaths())
        let result = try RawIndexStoreReader(storePath: fixture.store.path,
            libraryPath: fixture.library, fileSystem: LocalFileSystem()).read(
                in: paths, trackedSourcePath: provider.trackedSourcePathPredicate(), includeProjectHeaderRecords: true)
        #expect(result.admittedHeaderPaths == [fixture.headerPath])
        let definitions = result.occurrences.filter { $0.roles.contains(.definition) }
        #expect(definitions.filter { $0.symbol.name == "CGHeaderRoute" }.count == 2)
        #expect(definitions.filter { $0.symbol.name == "CGHeaderCppRoute" }.count == 1)

        let raw = try provider.loadSnapshot()
        let database = try fixture.provider(.databaseBacked).loadSnapshot()
        #expect(raw.symbols == database.symbols)
        #expect(Set(raw.references) == Set(database.references))
        #expect(raw.admittedHeaderPaths == database.admittedHeaderPaths)
        #expect(raw.admittedHeaderPaths == [fixture.headerPath])
        let headers = raw.symbols.filter { $0.location.path == fixture.headerPath }
        #expect(headers.map(\.name).sorted() == ["CGHeaderCppRoute", "CGHeaderRoute"])
        #expect(headers.map(\.location.line).sorted() == [15, 19])
        #expect(!raw.symbols.contains { ["outsideValue", "excludedValue"].contains($0.name) })
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: raw)
        let calls = graph.edges.filter { $0.kind == .call }.map {
            "\(graph.node($0.source)?.name ?? "?")->\(graph.node($0.target)?.name ?? "?")"
        }.sorted()
        #expect(calls == ["CGBridge->CGHeaderRoute", "CGCppBridge->cppHelper", "CGHeaderCppRoute->CGBase",
            "CGHeaderRoute->CGBase", "duplicateCaller->CGHeaderRoute", "cppHelper->CGHeaderCppRoute"].sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try JSONDecoder().decode(IndexSnapshot.self, from: encoder.encode(raw)) == raw)
    }

    @Test("같은 헤더 USR도 서로 다른 컴파일 문맥의 호출을 합치고 어느 분기도 버리지 않는다")
    func sameHeaderUSRPreservesDifferentContextCalls() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let header = fixture.project.appendingPathComponent("Sources/BridgeKit/include/Contexts.h")
        try Data("""
            #include "CGCore.h"
            #ifdef __cplusplus
            extern "C" {
            #endif
            static inline int contextRoute(int x) {
            #ifdef ALTERNATE_HEADER
                return CGAlternate(x);
            #else
                return CGBase(x);
            #endif
            }
            #ifdef __cplusplus
            }
            #endif
            """.utf8).write(to: header)
        for (name, function, flags) in [
            ("ContextFirst.mm", "contextCallerFirst", [String]()),
            ("ContextSecond.mm", "contextCallerSecond", ["-DALTERNATE_HEADER"])
        ] {
            try Data("#include \"include/Contexts.h\"\nint \(function)(int x) { return contextRoute(x); }\n".utf8)
                .write(to: fixture.project.appendingPathComponent("Sources/BridgeKit/\(name)"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.currentDirectoryURL = fixture.project
            process.arguments = ["clang", "-c", "Sources/BridgeKit/\(name)", "-I", "Sources/BridgeKit/include",
                "-o", fixture.root.appendingPathComponent("Build/\(name).o").path,
                "-index-store-path", fixture.store.path] + flags
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        let provider = fixture.provider(.raw)
        let result = try RawIndexStoreReader(storePath: fixture.store.path,
            libraryPath: fixture.library, fileSystem: LocalFileSystem()).read(
                in: Set(provider.sourceFilePaths()), trackedSourcePath: provider.trackedSourcePathPredicate(),
                includeProjectHeaderRecords: true)
        let definitions = result.occurrences.filter {
            $0.symbol.name == "contextRoute" && $0.roles.contains(.definition)
        }
        #expect(definitions.count == 2)
        #expect(Set(definitions.map { $0.symbol.usr }).count == 1)
        let snapshot = try provider.loadSnapshot()
        let symbol = try #require(snapshot.symbols.first { $0.name == "contextRoute" })
        let targets = Set(snapshot.references.filter {
            $0.sourceUSR == symbol.usr && $0.kind == .call
        }.map(\.targetUSR))
        #expect(targets == ["c:@F@CGBase", "c:@F@CGAlternate"])
        #expect(snapshot.admittedHeaderPaths?.contains(try LocalFileSystem().realPath(at: header.path)) == true)
    }

    @Test("같은 헤더를 시스템 경로로 빌드한 문맥이 있으면 외부 필터의 누락 가능성을 감추지 않는다")
    func systemMarkedHeaderContextKeepsProjectionGap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.project.appendingPathComponent("Sources/System.m")
        try Data("#include <CGCore.h>\nint systemCaller(int x) { return CGHeaderRoute(x); }\n".utf8)
            .write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.currentDirectoryURL = fixture.project
        process.arguments = ["clang", "-c", "Sources/System.m", "-isystem", "Sources/BridgeKit/include",
            "-o", fixture.root.appendingPathComponent("Build/System.o").path,
            "-index-store-path", fixture.store.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let snapshot = try fixture.provider(.raw).loadSnapshot()
        #expect(snapshot.oldestIndexedFileDates?[fixture.headerPath] != nil)
        #expect(snapshot.admittedHeaderPaths == [])
    }

    @Test("같은 경로의 다른 유닛이 file-only이면 record 문맥의 성공으로 헤더 한계를 지우지 않는다")
    func mixedRecordAndFileOnlyContextsKeepProjectionGap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.project.appendingPathComponent("Sources/FileOnly.m")
        try Data("#include \"BridgeKit/include/CGCore.h\"\nint fileOnlyContext(void) { return 0; }\n".utf8)
            .write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.currentDirectoryURL = fixture.project
        process.arguments = ["clang", "-c", "Sources/FileOnly.m", "-DCG_CORE_H", "-Xclang", "-index-ignore-macros",
            "-o", fixture.root.appendingPathComponent("Build/FileOnly.o").path,
            "-index-store-path", fixture.store.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        for mode in [IndexStoreProvider.ReaderMode.raw, .databaseBacked] {
            let snapshot = try fixture.provider(mode).loadSnapshot()
            #expect(snapshot.oldestIndexedFileDates?[fixture.headerPath] != nil)
            #expect(snapshot.symbols.contains { $0.name == "CGHeaderRoute" })
            #expect(snapshot.admittedHeaderPaths == [])
        }
    }

    @Test("헤더 읽기를 꺼도 기존 번역 단위 그래프는 남고 삭제 헤더를 선언으로 되살리지 않는다")
    func disabledAndDeletedHeadersRemainUnadmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = fixture.provider(.raw)
        let reader = RawIndexStoreReader(storePath: fixture.store.path,
            libraryPath: fixture.library, fileSystem: LocalFileSystem())
        let legacy = try reader.read(in: Set(provider.sourceFilePaths()),
            trackedSourcePath: provider.trackedSourcePathPredicate())
        #expect(legacy.admittedHeaderPaths.isEmpty)
        #expect(!legacy.occurrences.contains { $0.symbol.name == "CGHeaderRoute" && $0.roles.contains(.definition) })
        try FileManager.default.removeItem(atPath: fixture.headerPath)
        let deleted = try provider.loadSnapshot()
        #expect(deleted.admittedHeaderPaths == [])
        #expect(deleted.oldestIndexedFileDates?[fixture.headerPath] != nil)
        #expect(!deleted.symbols.contains { $0.location.path == fixture.headerPath })
    }

    @Test("헤더의 한 관측 레코드만 깨져도 부분 admission 스냅샷을 성공으로 반환하지 않는다")
    func brokenHeaderContextFailsWholeSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let enumerator = try #require(FileManager.default.enumerator(
            at: fixture.store.appendingPathComponent("v5/records"), includingPropertiesForKeys: nil))
        let records = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("CGCore.h-") }
        #expect(records.count == 2)
        let corrupt = try #require(records.sorted { $0.path < $1.path }.last)
        try Data("corrupt one header context".utf8).write(to: corrupt)
        for mode in [IndexStoreProvider.ReaderMode.raw, .databaseBacked] {
            #expect(throws: (any Error).self) { try fixture.provider(mode).loadSnapshot() }
        }
    }

    private struct Fixture {
        let root: URL
        let project: URL
        let store: URL
        let library: String
        let headerPath: String

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appendingPathComponent("cartograph-headers-\(UUID().uuidString)")
            project = root.appendingPathComponent("Project")
            store = root.appendingPathComponent("IndexStore")
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/HeaderRecordCorpus")
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.copyItem(at: fixture, to: project)
            try manager.createDirectory(at: root.appendingPathComponent("Build"), withIntermediateDirectories: true)
            try manager.createDirectory(at: project.appendingPathComponent("Sources/Excluded"),
                withIntermediateDirectories: true)
            try Data("static inline int outsideValue(void) { return 1; }\n".utf8)
                .write(to: root.appendingPathComponent("Outside.h"))
            try Data("static inline int excludedValue(void) { return 2; }\n".utf8)
                .write(to: project.appendingPathComponent("Sources/Excluded/Excluded.h"))
            try Data("#include \"include/CGCore.h\"\nint duplicateCaller(int x) { return CGHeaderRoute(x); }\n".utf8)
                .write(to: project.appendingPathComponent("Sources/BridgeKit/Duplicate.m"))
            try Data("#include \"../../Outside.h\"\n#include \"Excluded/Excluded.h\"\n"
                .appending("int scopeCaller(void) { return outsideValue() + excludedValue(); }\n").utf8)
                .write(to: project.appendingPathComponent("Sources/Scope.m"))
            for name in ["BridgeKit/Core.m", "BridgeKit/CppBridge.mm", "BridgeKit/Duplicate.m", "Scope.m"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.currentDirectoryURL = project
                process.arguments = ["clang", "-c", "Sources/\(name)", "-I", "Sources/BridgeKit/include",
                    "-o", root.appendingPathComponent("Build/\((name as NSString).lastPathComponent).o").path,
                    "-index-store-path", store.path]
                let pipe = Pipe()
                process.standardError = pipe
                try process.run()
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "HeaderRecordAdmissionTests", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
            headerPath = try LocalFileSystem().realPath(at:
                project.appendingPathComponent("Sources/BridgeKit/include/CGCore.h").path)
        }

        func provider(_ mode: IndexStoreProvider.ReaderMode) -> IndexStoreProvider {
            IndexStoreProvider(configuration: .init(storePath: store.path,
                databasePath: root.appendingPathComponent("DB-\(mode)").path, libraryPath: library,
                sourceRoots: [project.path], pathFilter: PathFilter(exclude: ["**/Excluded/**"]),
                includeObjectiveCSources: true, readerMode: mode, dependencyRoots: [project.path]))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
