import CartographCore
import Foundation

/// 실행하지 않은 SwiftPM 빌드 설명의 기대 소스를 캡처 관측과 비교한다.
/// 빌드 성공·현재 target membership·내용 신선도를 증명하거나 선택 실행을 허가하지 않는다.
struct SwiftPMModuleCoverage {
    let fileSystem: any FileSystem
    static let maximumBytes = 8 * 1024 * 1024

    /// 선택한 표준 SwiftPM index의 같은 configuration에 있는 파일만 후보로 삼는다.
    /// Xcode와 compiler override의 out 경로를 다른 빌드 설명에 임의로 연결하지 않는다.
    static func descriptionPath(storePath: String, projectPath: String, fileSystem: any FileSystem) -> String? {
        let store = fileSystem.canonicalPath(storePath)
        let root = fileSystem.canonicalPath(projectPath)
        guard store.hasSuffix("/index/store"), store.hasPrefix(root + "/") else { return nil }
        let path = String(store.dropLast("index/store".count)) + "description.json"
        guard fileSystem.canonicalPath(path).hasPrefix(root + "/") else { return nil }
        return path
    }

    func limitations(storePath: String, projectPath: String, sourcePaths: [String],
                     snapshot: IndexSnapshot) -> [String] {
        guard let path = Self.descriptionPath(storePath: storePath, projectPath: projectPath, fileSystem: fileSystem),
              fileSystem.fileExists(at: path) else { return [] }
        let context = "SwiftPM build description \(String(reflecting: path)); current target membership and build "
            + "content freshness are unverified. This observation cannot authorize import removal or test omission."
        do {
            // 주입된 메모리 파일 시스템은 stamp가 없을 수 있다. 디스크 장치·FIFO는 읽기 전 거부한다.
            if let stamp = fileSystem.fingerprintStamp(at: path), !stamp.isRegularFile {
                return ["build-module-coverage-unknown: nonregular metadata; " + context]
            }
            let data = try fileSystem.readData(at: path, maximumBytes: Self.maximumBytes)
            guard data.count <= Self.maximumBytes else {
                return ["build-module-coverage-unknown: metadata exceeds 8 MiB budget; " + context]
            }
            let description = try JSONDecoder().decode(Description.self, from: data)
            guard description.swiftCommands.count <= 4096,
                  description.swiftCommands.values.reduce(0, { $0 + $1.sources.count }) <= 50_000 else {
                return ["build-module-coverage-unknown: command/source budget exceeded; " + context]
            }
            return compare(description, path: path, storePath: storePath, projectPath: projectPath,
                           sourcePaths: sourcePaths, snapshot: snapshot, context: context)
        } catch {
            return ["build-module-coverage-unknown: metadata could not be decoded within the supported SwiftPM "
                + "description schema; " + context]
        }
    }

    private func compare(_ description: Description, path: String, storePath: String, projectPath: String,
                         sourcePaths: [String], snapshot: IndexSnapshot, context: String) -> [String] {
        let root = fileSystem.canonicalPath(projectPath)
        let store = fileSystem.canonicalPath(storePath)
        let included = Set(sourcePaths.map(fileSystem.canonicalPath))
        var expected: [String: Set<String>] = [:]
        var conflicting: Set<String> = []
        var invalidCommands = 0
        for command in description.swiftCommands.values {
            guard !command.moduleName.isEmpty, command.moduleName.utf8.count <= 256,
                  command.otherArguments.count <= 8192 else { invalidCommands += 1; continue }
            let flags = command.otherArguments.indices.filter { command.otherArguments[$0] == "-index-store-path" }
            guard flags.count == 1, let flag = flags.first, flag + 1 < command.otherArguments.count,
                  fileSystem.canonicalPath(command.otherArguments[flag + 1]) == store else { continue }
            var local: Set<String> = []
            for source in command.sources where source.hasPrefix("/") && source.hasSuffix(".swift")
                && source.utf8.count <= 4096 {
                let canonical = fileSystem.canonicalPath(source)
                guard canonical.hasPrefix(root + "/"), fileSystem.fileExists(at: canonical),
                      !fileSystem.directoryExists(at: canonical) else { continue }
                if let stamp = fileSystem.fingerprintStamp(at: canonical), !stamp.isRegularFile { continue }
                local.insert(canonical)
            }
            guard !local.isEmpty else { continue }
            if let prior = expected[command.moduleName], prior != local { conflicting.insert(command.moduleName) }
            expected[command.moduleName, default: []].formUnion(local)
        }
        guard !expected.isEmpty else {
            return ["build-module-coverage-unknown: no local Swift source command was bound to the selected index; "
                + "invalid/budget-limited commands: \(invalidCommands); " + context]
        }
        guard let dates = snapshot.sourceFreshnessDates else {
            return ["build-module-coverage-unknown: captured source-unit timestamps unavailable; " + context]
        }
        let observed = Set(dates.keys.map(fileSystem.canonicalPath))
        let metadataDate = fileSystem.modificationDate(at: path)
        let manifestDate = fileSystem.modificationDate(at: root + "/Package.swift")
        var rows: [String] = []
        for module in expected.keys.sorted() {
            let sources = expected[module]!
            if conflicting.contains(module) {
                rows.append("\(String(reflecting: module)): unknown conflicting command source membership")
                continue
            }
            let inScope = sources.intersection(included)
            let missing = inScope.subtracting(observed)
            guard !missing.isEmpty || inScope.count < sources.count else { continue }
            let newerSource = sources.contains { source in
                guard let metadataDate, let date = fileSystem.modificationDate(at: source) else { return false }
                return date > metadataDate
            }
            let staleManifest = metadataDate.flatMap { metadata in manifestDate.map { $0 > metadata } } ?? false
            let state = newerSource || staleManifest ? "stale-metadata-expectation"
                : (missing.isEmpty ? "outside-analysis" : "missing-observed-source-units")
            let paths = missing.sorted().prefix(3).map { String(reflecting: String($0.prefix(512))) }
                .joined(separator: ", ")
            rows.append("\(String(reflecting: module)): \(state), expected local sources \(sources.count), "
                + "outside analysis \(sources.count - inScope.count), without observed unit timestamp \(missing.count)"
                + (paths.isEmpty ? "" : ", examples [\(paths)]"))
        }
        if invalidCommands > 0 { rows.append("unknown invalid/budget-limited commands: \(invalidCommands)") }
        guard !rows.isEmpty else { return [] } // 관측 일치는 completeness 통과가 아니다.
        return ["build-module-coverage: \(rows.prefix(20).joined(separator: "; ")); omitted modules: "
            + "\(max(0, rows.count - 20)). " + context]
    }

    private struct Description: Decodable { let swiftCommands: [String: Command] }
    private struct Command: Decodable {
        let moduleName: String
        let sources: [String]
        let otherArguments: [String]
    }
}
