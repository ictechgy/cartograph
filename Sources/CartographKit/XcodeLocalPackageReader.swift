import CartographCore
import Foundation

/// 문서만 캐시한다. 큰 object/record는 digest 확인 뒤 해제하고 각 proof 관측에서 다시 읽는다.
struct XcodeLocalPackageReader {
    let files: [String: XcodeLocalPackageProofFile]
    let buildRoot: String
    let indexStore: String
    let fileSystem: any FileSystem
    var used: Set<String> = []
    private var documents: [String: Data] = [:]

    init(files: [String: XcodeLocalPackageProofFile], buildRoot: String, indexStore: String, fileSystem: any FileSystem) throws {
        self.files = files; self.buildRoot = buildRoot; self.indexStore = indexStore; self.fileSystem = fileSystem
        var totals: [String: Int] = [:]
        guard files.count <= 1_024 else { throw XcodeLocalPackageIO.invalid("Package proof file count exceeds budget.") }
        for file in files.values {
            guard let maximum = Self.maximum[file.kind], file.bytes >= 0, file.bytes <= maximum,
                  file.sha256.utf8.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw XcodeLocalPackageIO.invalid("Invalid package proof file kind, digest or size.")
            }
            totals[file.kind, default: 0] += file.bytes
            guard totals[file.kind, default: 0] <= Self.totalMaximum[file.kind]! else {
                throw XcodeLocalPackageIO.invalid("Package proof aggregate byte budget exceeded.")
            }
        }
    }

    private static let maximum = ["document": 8 * 1_024 * 1_024, "object": 64 * 1_024 * 1_024,
                                  "record": 16 * 1_024 * 1_024]
    private static let totalMaximum = ["document": 32 * 1_024 * 1_024, "object": 256 * 1_024 * 1_024,
                                       "record": 64 * 1_024 * 1_024]

    mutating func read(_ path: String, kind: String) throws -> Data {
        let path = XcodeEvidencePath.physicalTemporaryAlias(path, fileSystem: fileSystem)
        guard let file = files[path], file.kind == kind,
              path.hasPrefix((kind == "record" ? indexStore : buildRoot) + "/"),
              let maximum = Self.maximum[kind] else { throw XcodeLocalPackageIO.invalid("Unbound package proof input: " + path) }
        if let document = documents[path] { return document }
        if used.contains(path), kind != "document" { return Data() }
        let data = try XcodeLocalPackageIO.bounded(path, maximum: maximum, fileSystem: fileSystem)
        guard data.count == file.bytes, TargetScopeStore.digest(data) == file.sha256 else {
            throw XcodeLocalPackageIO.invalid("Package proof file bytes changed: " + path)
        }
        used.insert(path)
        if kind == "document" { documents[path] = data }
        return data
    }

    mutating func fileList(_ path: String) throws -> [String] {
        let data = try read(path, kind: "document")
        guard let text = String(data: data, encoding: .utf8) else { throw XcodeLocalPackageIO.invalid("Invalid UTF-8 linker/source file list.") }
        var paths: [String] = []
        for line in text.components(separatedBy: "\n").filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let tokens = try XcodeEvidenceTokens.read(String(line), maximum: 2)
            guard tokens.count == 1, let value = tokens.first, value.hasPrefix("/"), paths.count < 1_024 else {
                throw XcodeLocalPackageIO.invalid("Unsupported or oversized linker/source file list.")
            }
            paths.append(XcodeEvidencePath.physicalTemporaryAlias(value, fileSystem: fileSystem))
        }
        guard !paths.isEmpty, Set(paths).count == paths.count else { throw XcodeLocalPackageIO.invalid("Empty or duplicate linker/source file list.") }
        return paths
    }

    mutating func arguments(_ argv: [String], sourceFileList: String? = nil) throws -> [String] {
        guard !argv.isEmpty, argv.count <= 1_000, argv.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw XcodeLocalPackageIO.invalid("Invalid or oversized compiler/linker command.")
        }
        var result: [String] = []
        func physicalToken(_ token: String) -> String {
            if token.hasPrefix("@/") { return "@" + XcodeEvidencePath.physicalTemporaryAlias(String(token.dropFirst()), fileSystem: fileSystem) }
            return XcodeEvidencePath.physicalTemporaryAlias(token, fileSystem: fileSystem)
        }
        for rawToken in argv {
            let token = result.last == "-index-unit-output-path" ? rawToken : physicalToken(rawToken)
            if token == "-Xlinker" || token == "-Xclang-linker" { continue }
            if !token.hasPrefix("@") || token == sourceFileList.map({ "@" + $0 }) || Self.runtimePath(token, previous: result.last) {
                result.append(token)
            } else {
                guard token.hasPrefix("@/") else { throw XcodeLocalPackageIO.invalid("Relative response-file input is unsupported.") }
                let data = try read(String(token.dropFirst()), kind: "document")
                guard let text = String(data: data, encoding: .utf8) else { throw XcodeLocalPackageIO.invalid("Invalid response-file encoding.") }
                let expanded = try XcodeEvidenceTokens.read(text, maximum: 1_000).filter { $0 != "-Xlinker" && $0 != "-Xclang-linker" }.map(physicalToken)
                guard !expanded.enumerated().contains(where: { index, value in
                    value.hasPrefix("@") && !Self.runtimePath(value, previous: index == 0 ? nil : expanded[index - 1])
                }) else {
                    throw XcodeLocalPackageIO.invalid("Nested response files are unsupported.")
                }
                result += expanded
            }
            guard result.count <= 1_000 else { throw XcodeLocalPackageIO.invalid("Expanded command exceeds token budget.") }
        }
        return result
    }

    private static func runtimePath(_ token: String, previous: String? = nil) -> Bool {
        ["@loader_path/", "@executable_path/", "@rpath/"].contains(where: token.hasPrefix)
            || (previous == "-rpath" && ["@loader_path", "@executable_path", "@rpath"].contains(token))
    }
}

/// shell을 실행하지 않고 Xcode의 quote/escape된 filelist와 response 토큰만 읽는다.
enum XcodeEvidenceTokens {
    static func read(_ text: String, maximum: Int) throws -> [String] {
        var output: [String] = [], token = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped {
                // shlex/POSIX double quotes preserve backslashes before ordinary characters.
                if quote == "\"", character != "\"", character != "\\" { token.append("\\") }
                token.append(character); escaped = false; started = true
            }
            else if character == "\\", quote != "'" { escaped = true; started = true }
            else if let delimiter = quote {
                if character == delimiter { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" { quote = character; started = true }
            else if [" ", "\t", "\r", "\n", "\r\n"].contains(character) {
                if started { output.append(token); token = ""; started = false }
            } else { token.append(character); started = true }
            guard output.count <= maximum, token.utf8.count <= 4_096 else {
                throw XcodeLocalPackageIO.invalid("Response token budget exceeded.")
            }
        }
        guard quote == nil, !escaped else { throw XcodeLocalPackageIO.invalid("Unterminated response quote or escape.") }
        if started { output.append(token) }
        guard output.count <= maximum, !output.contains(where: { $0.isEmpty || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw XcodeLocalPackageIO.invalid("Invalid response tokens.")
        }
        return output
    }
}

/// 완전한 map에서 양의 live owner만 사용한다. 목록의 부재나 dead-stripped 행은 범위 밖 증거가 아니다.
enum XcodeLinkMapEvidence {
    static func validate(_ data: Data, output: String, architecture: String, required: Set<String>,
                         fileSystem: (any FileSystem)? = nil) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw XcodeLocalPackageIO.invalid("Invalid linker map encoding.") }
        var objects: [Int: String] = [:], live: Set<Int> = [], referenced: Set<Int> = []
        var section = "", headers: Set<String> = [], lineCount = 0
        let objectPattern = try NSRegularExpression(pattern: #"^\[\s*([0-9]+)\]\s+(.+)$"#)
        let symbolPattern = try NSRegularExpression(pattern: #"^(?:0x[0-9a-fA-F]+|<<dead>>)\s+0x[0-9a-fA-F]+\s+\[\s*([0-9]+)\]\s+.+$"#)
        let sectionPattern = try NSRegularExpression(pattern: #"^0x[0-9a-fA-F]+\s+0x[0-9a-fA-F]+\s+\S+\s+\S+$"#)
        func physical(_ path: String) -> String {
            fileSystem.map { XcodeEvidencePath.physicalTemporaryAlias(path, fileSystem: $0) } ?? path
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineCount += 1
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineCount <= 100_000, line.utf8.count <= 16_384 else { throw XcodeLocalPackageIO.invalid("Link map line budget exceeded.") }
            if line.isEmpty { continue }
            if line.hasPrefix("# Path:") || line.hasPrefix("# Arch:") {
                let key = line.hasPrefix("# Path:") ? "path" : "arch"
                guard headers.insert(key).inserted,
                      (key == "path" ? "# Path: " + physical(String(line.dropFirst("# Path: ".count))) : line)
                        == (key == "path" ? "# Path: " + output : "# Arch: " + architecture) else {
                    throw XcodeLocalPackageIO.invalid("Link map path or architecture differs from its actual link step.")
                }
            } else if ["# Object files:", "# Sections:", "# Symbols:", "# Dead Stripped Symbols:"].contains(line) {
                guard headers.insert(line).inserted else { throw XcodeLocalPackageIO.invalid("Duplicate linker map section.") }
                section = line
            } else if line.hasPrefix("#") {
                let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard (section == "# Sections:" && columns == ["#", "Address", "Size", "Segment", "Section"])
                    || (["# Symbols:", "# Dead Stripped Symbols:"].contains(section)
                        && columns == ["#", "Address", "Size", "File", "Name"])
                    || (section == "# Dead Stripped Symbols:" && columns == ["#", "Size", "File", "Name"]) else {
                    throw XcodeLocalPackageIO.invalid("Link map column header is unknown or out of place.")
                }
            } else if section == "# Object files:" {
                guard let match = objectPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let number = Range(match.range(at: 1), in: line), let path = Range(match.range(at: 2), in: line),
                      let id = Int(line[number]), objects.updateValue(physical(String(line[path])), forKey: id) == nil else {
                    throw XcodeLocalPackageIO.invalid("Malformed or duplicate link map object owner.")
                }
            } else if section == "# Symbols:" || section == "# Dead Stripped Symbols:" {
                guard let match = symbolPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let number = Range(match.range(at: 1), in: line), let id = Int(line[number]) else {
                    throw XcodeLocalPackageIO.invalid("Unparsed linker map symbol row.")
                }
                referenced.insert(id)
                if section == "# Symbols:", !line.hasPrefix("<<dead>>") { live.insert(id) }
            } else if section == "# Sections:" {
                guard sectionPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
                    throw XcodeLocalPackageIO.invalid("Unparsed linker map section row.")
                }
            } else { throw XcodeLocalPackageIO.invalid("Unsupported linker map row or section.") }
        }
        guard ["path", "arch", "# Object files:", "# Sections:", "# Symbols:"].allSatisfy(headers.contains),
              Set(objects.values).count == objects.count, referenced.isSubset(of: Set(objects.keys)),
              required.isSubset(of: Set(live.compactMap { objects[$0] })) else {
            throw XcodeLocalPackageIO.invalid("Missing, unresolved or non-live package linker owners.")
        }
    }

}
