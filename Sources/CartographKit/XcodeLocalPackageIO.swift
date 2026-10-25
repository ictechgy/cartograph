import CartographCore
import Foundation

/// Foundation이 축약하는 macOS 임시 경로도 실제 filesystem 별칭인 경우에만 물리 신원으로 읽는다.
enum XcodeEvidencePath {
    static func physicalTemporaryAlias(_ path: String, fileSystem: any FileSystem) -> String {
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/var/folders/"),
              let resolved = try? fileSystem.realPath(at: path), resolved == "/private" + path else { return path }
        return resolved
    }
}

/// 공유 값과 IO 경계를 분리해 consumer와 reader의 역방향 의존을 만들지 않는다.
struct XcodeLocalPackageProofFile: Codable, Equatable {
    let sha256: String
    let bytes: Int
    let kind: String
}

enum XcodeLocalPackageIO {
    static func normalizedCommand(_ argv: [String]) -> [String] {
        if argv.count >= 3, ["builtin-SwiftDriver", "builtin-Swift-Compilation-Requirements", "builtin-Swift-Compilation"].contains(argv[0]),
           argv[1] == "--" { return Array(argv.dropFirst(2)) }
        return argv
    }
    static func argument(_ flag: String, in argv: [String]) throws -> String {
        let positions = argv.indices.filter { argv[$0] == flag }
        guard positions.count == 1, let index = positions.first, index + 1 < argv.count else {
            throw invalid("Missing or duplicate command operand: " + flag)
        }
        return argv[index + 1]
    }

    static func bounded(_ path: String, maximum: Int, fileSystem: any FileSystem) throws -> Data {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !isSensitiveAnalysisEvidencePath(path),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              try fileSystem.realPath(at: path) == path,
              fileSystem.fingerprintStamp(at: path)?.isRegularFile != false else {
            throw invalid("Noncanonical, sensitive or nonregular package evidence input.")
        }
        let data = try fileSystem.readData(at: path, maximumBytes: maximum)
        guard data.count <= maximum else { throw invalid("Package proof input exceeds its byte budget.") }
        return data
    }

    static func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "xcode-local-package", reason: reason)
    }
}

/// 상위 membership과 proof 타입을 역참조하지 않는 공통 입력 문법과 오류 계약이다.
enum XcodeScopeInputRules {
    static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.contains("$(") && !path.contains("${")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "xcode-target-scope", reason: reason)
    }

    static func validTriple(_ triple: String, architecture: String, iosSimulator: Bool) -> Bool {
        let suffix = iosSimulator ? #"-apple-ios[0-9]+(?:\.[0-9]+)*-simulator$"# : #"-apple-macos[0-9]+(?:\.[0-9]+)*$"#
        return triple.range(of: "^" + architecture + suffix, options: .regularExpression) != nil
    }
}
