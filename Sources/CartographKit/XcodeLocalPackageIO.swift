import CartographCore
import Foundation

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
