import Foundation
import IndexStore
import Testing

/// 합성 Xcode 빌드의 raw unit output 신원만 관찰한다. 제품 receipt를 만들지 않는다.
@Suite("로컬 패키지 Xcode unit 관찰", .serialized)
struct LocalPackageUnitObservationTests {
    @Test("실제 unit output과 성공한 record 읽기를 별도로 기록한다",
        .enabled(if: ProcessInfo.processInfo.environment["CARTOGRAPH_LOCAL_PACKAGE_PROBE"] != nil))
    func observeNativeUnits() async throws {
        let requestPath = try #require(ProcessInfo.processInfo.environment["CARTOGRAPH_LOCAL_PACKAGE_PROBE"])
        let request = try JSONDecoder().decode(Request.self, from: bounded(requestPath, maximum: 16_384))
        let root = canonical(request.projectRoot), build = canonical(request.buildRoot)
        try #require(root != build && !inside(build, root: root))
        try #require(inside(canonical(request.store), root: build))
        let developer = canonical(request.developerRoot)
        try #require(inside(canonical(request.library), root: developer))
        try #require(canonical(request.output) == canonical(requestPath).deletingLastPath + "/unit-observations.json")
        let library = try await IndexStoreLibrary.at(dylibPath: URL(fileURLWithPath: request.library))
        let store = try library.indexStore(at: URL(fileURLWithPath: request.store))
        var units: [Unit] = [], scanned = 0
        let modules: Set<String> = ["ArithmeticCore", "CoreKit", "ChecksModule", "OtherModule"]
        try store.unitNames(sorted: true).forEach { name in
            scanned += 1
            try #require(scanned <= 4_096)
            let unit = try store.unit(named: name.string)
            guard !unit.isSystemUnit, modules.contains(unit.moduleName.string) else { return .continue }
            let directory = unit.workingDirectory.string
            let main = resolved(unit.mainFile.string, relativeTo: directory)
            let outputIdentity = unit.outputFile.string
            let outputPath = resolved(outputIdentity, relativeTo: directory)
            var dependencies: [Dependency] = [], visited = 0
            try unit.dependencies.forEach { dependency in
                visited += 1
                try #require(visited <= 4_096)
                let path = resolved(dependency.filePath.string, relativeTo: directory)
                guard !dependency.isSystem, inside(path, root: root) else { return .continue }
                var count: Int?
                if dependency.kind == .record {
                    let record = try store.record(named: dependency.name.string)
                    var occurrences = 0
                    try record.occurrences.forEach { _ in
                        occurrences += 1
                        try #require(occurrences <= 100_000)
                        return .continue
                    }
                    count = occurrences
                }
                dependencies.append(.init(kind: dependency.kind.description, path: path,
                    module: dependency.moduleName.string, name: dependency.name.string,
                    successfullyReadOccurrences: count))
                return .continue
            }
            units.append(.init(name: name.string, module: unit.moduleName.string,
                mainFile: main, hasMainFile: unit.hasMainFile, outputIdentity: outputIdentity,
                resolvedOutputPath: outputPath, outputWithinBuildRoot: inside(outputPath, root: build),
                outputExists: FileManager.default.fileExists(atPath: outputPath),
                workingDirectory: directory, target: unit.target.string,
                provider: unit.providerIdentifier.string, providerVersion: unit.providerVersion.string,
                timestamp: unit.modificationDate.timeIntervalSince1970, dependencies: dependencies))
            try #require(units.count <= 256)
            return .continue
        }
        let document = Observation(scannedUnits: scanned, units: units,
            limitation: "Unit output is a compiler configuration identity, not proof of an object path or linker "
                + "contribution. No product receipt or test selector was issued.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(document)
        try #require(bytes.count <= 8 * 1_024 * 1_024)
        try bytes.write(to: URL(fileURLWithPath: request.output), options: .withoutOverwriting)
        // 실패해도 완성된 관찰 결과는 남긴다. 이것은 link 기여나 전체 소속 증명이 아니다.
        try #require(units.contains { $0.module == "ArithmeticCore" && $0.dependencies.contains {
            $0.kind == "Record" && $0.path.hasSuffix("/Packages/LocalMath/Sources/ArithmeticCore/Math.swift")
                && $0.successfullyReadOccurrences != nil
        } })
    }

    private struct Request: Decodable {
        let projectRoot: String
        let buildRoot: String
        let store: String
        let library: String
        let developerRoot: String
        let output: String
    }

    private struct Observation: Encodable {
        let scannedUnits: Int
        let units: [Unit]
        let limitation: String
    }

    private struct Unit: Encodable {
        let name: String
        let module: String
        let mainFile: String
        let hasMainFile: Bool
        let outputIdentity: String
        let resolvedOutputPath: String
        let outputWithinBuildRoot: Bool
        let outputExists: Bool
        let workingDirectory: String
        let target: String
        let provider: String
        let providerVersion: String
        let timestamp: Double
        let dependencies: [Dependency]
    }

    private struct Dependency: Encodable {
        let kind: String
        let path: String
        let module: String
        let name: String
        let successfullyReadOccurrences: Int?
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func resolved(_ path: String, relativeTo directory: String) -> String {
        guard !path.isEmpty else { return "" }
        return canonical(path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path))
    }

    private func inside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func bounded(_ path: String, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        try #require(data.count <= maximum)
        return data
    }
}

private extension String {
    var deletingLastPath: String { (self as NSString).deletingLastPathComponent }
}
