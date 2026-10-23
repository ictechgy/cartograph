import CartographCore
import CryptoKit
import Foundation

/// 실행 가능한 manifest를 평가하지 않고 한정된 리터럴 계약만 읽는다.
struct XcodeLocalPackageInputs {
    struct Manifest: Equatable, Codable {
        let name: String
        let product: String
        let module: String
    }

    static func manifest(_ data: Data) throws -> Manifest {
        var parser = try Parser(data)
        return try parser.parse()
    }

    /// 일반 프로젝트 확장자 필터를 쓰지 않는다. 새 C/resource/config 입력도 빠짐없이 거부한다.
    static func inventory(root: String, module: String, fileSystem: any FileSystem) throws -> [String: String] {
        guard try fileSystem.realPath(at: root) == root, fileSystem.directoryExists(at: root) else {
            throw XcodeLocalPackageInputs.invalid("Package root must be a canonical local directory.")
        }
        var result: [String: String] = [:], pending = [(root, 0)], total = 0, entries = 0
        let prefix = "Sources/" + module + "/"
        while let (directory, depth) = pending.popLast() {
            guard depth <= 128 else { throw Self.invalid("Package subtree depth exceeds budget.") }
            for entry in try fileSystem.directoryEntries(at: directory, maximumEntries: 4_096 - entries) {
                entries += 1
                guard !entry.isSymbolicLink, entry.path.hasPrefix(directory + "/"),
                      !entry.path.dropFirst(directory.count + 1).contains("/") else {
                    throw XcodeLocalPackageInputs.invalid("Package subtree budget or symlink boundary exceeded.")
                }
                let relative = String(entry.path.dropFirst(root.count + 1))
                guard result[relative] == nil, try fileSystem.realPath(at: entry.path) == entry.path else {
                    throw XcodeLocalPackageInputs.invalid("Noncanonical package subtree entry.")
                }
                if entry.isDirectory {
                    guard ["Sources", "Sources/" + module].contains(relative) || relative.hasPrefix(prefix) else {
                        throw XcodeLocalPackageInputs.invalid("Unexpected package directory.")
                    }
                    result[relative] = "directory"
                    pending.append((entry.path, depth + 1))
                } else {
                    guard entry.isRegularFile, ["Package.swift", "README.md", "LICENSE"].contains(relative)
                        || relative.hasPrefix(prefix) && relative.hasSuffix(".swift") else {
                        throw XcodeLocalPackageInputs.invalid("Unexpected package source/resource/configuration file.")
                    }
                    let maximum = relative == "Package.swift" ? 64 * 1_024 : 4 * 1_024 * 1_024
                    let bytes = try fileSystem.readData(at: entry.path, maximumBytes: maximum)
                    total += bytes.count
                    guard bytes.count <= maximum, total <= 64 * 1_024 * 1_024 else {
                        throw XcodeLocalPackageInputs.invalid("Package subtree byte budget exceeded.")
                    }
                    result[relative] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        let sources = result.filter { $0.key.hasPrefix(prefix) && $0.value != "directory" }
        guard result["Package.swift"] != nil, (1...256).contains(sources.count) else {
            throw XcodeLocalPackageInputs.invalid("Package requires 1...256 explicit Swift source files.")
        }
        return result
    }

    private struct Parser {
        let tokens: [String]
        var position = 0

        init(_ data: Data) throws {
            guard data.count <= 64 * 1_024, String(data: data, encoding: .utf8) != nil,
                  String(decoding: data.prefix(while: { $0 != 10 && $0 != 13 }), as: UTF8.self)
                    .range(of: #"^//[ \t]*swift-tools-version:[ \t]*(?:5\.9|6\.[0-3])[ \t]*\z"#,
                                     options: .regularExpression) != nil else {
                throw XcodeLocalPackageInputs.invalid("Unsupported tools version, manifest encoding or byte budget.")
            }
            tokens = try Self.lex(Array(data))
        }

        mutating func parse() throws -> Manifest {
            try take(["import", "PackageDescription", "let", "package", "=", "Package", "(", "name", ":"])
            let name = try literal()
            try take([",", "products", ":", "[", ".", "library", "(", "name", ":"])
            let product = try literal()
            try take([",", "targets", ":", "["])
            let productTarget = try literal(module: true)
            comma(); try take(["]"])
            comma(); try take([")"])
            comma(); try take(["]", ",", "targets", ":", "[", ".", "target", "(", "name", ":"])
            let module = try literal(module: true)
            comma(); try take([")"])
            comma(); try take(["]"])
            comma(); try take([")"])
            guard position == tokens.count, module == productTarget else {
                throw XcodeLocalPackageInputs.invalid("Unconsumed manifest syntax or product target mismatch.")
            }
            return .init(name: name, product: product, module: module)
        }

        mutating func take(_ values: [String]) throws {
            for value in values {
                guard position < tokens.count, tokens[position] == value else {
                    throw XcodeLocalPackageInputs.invalid("Only one literal Package/library/Swift-target declaration is supported.")
                }
                position += 1
            }
        }

        mutating func comma() {
            if position < tokens.count, tokens[position] == "," { position += 1 }
        }

        mutating func literal(module: Bool = false) throws -> String {
            guard position < tokens.count, tokens[position].first == "\"", tokens[position].last == "\"" else {
                throw XcodeLocalPackageInputs.invalid("Computed manifest names are unsupported.")
            }
            let value = String(tokens[position].dropFirst().dropLast())
            let pattern = module ? #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"# : #"^[A-Za-z_][A-Za-z0-9_-]{0,127}$"#
            guard value.range(of: pattern, options: .regularExpression) != nil else {
                throw XcodeLocalPackageInputs.invalid("Unsupported package/product/module identifier.")
            }
            position += 1
            return value
        }

        static func lex(_ bytes: [UInt8]) throws -> [String] {
            var result: [String] = [], i = 0
            func starts(_ first: UInt8, _ second: UInt8) -> Bool {
                i + 1 < bytes.count && bytes[i] == first && bytes[i + 1] == second
            }
            while i < bytes.count {
                let byte = bytes[i]
                if [9, 10, 13, 32].contains(byte) { i += 1 }
                else if starts(47, 47) {
                    i += 2
                    while i < bytes.count && ![10, 13].contains(bytes[i]) { i += 1 }
                } else if starts(47, 42) {
                    var depth = 1
                    i += 2
                    while i < bytes.count && depth > 0 {
                        if starts(47, 42) { depth += 1; i += 2 }
                        else if starts(42, 47) { depth -= 1; i += 2 }
                        else { i += 1 }
                        guard depth <= 16 else { throw XcodeLocalPackageInputs.invalid("Manifest comment nesting exceeds budget.") }
                    }
                    guard depth == 0 else { throw XcodeLocalPackageInputs.invalid("Unterminated manifest comment.") }
                } else if byte == 34 {
                    let start = i
                    i += 1
                    while i < bytes.count && bytes[i] != 34 {
                        guard identifierByte(bytes[i]) || bytes[i] == 45 else {
                            throw XcodeLocalPackageInputs.invalid("Manifest string escapes, interpolation and non-identifier literals are unsupported.")
                        }
                        i += 1
                    }
                    guard i < bytes.count else { throw XcodeLocalPackageInputs.invalid("Unterminated manifest string.") }
                    i += 1
                    result.append(String(decoding: bytes[start..<i], as: UTF8.self))
                } else if identifierByte(byte) && !(48...57).contains(byte) {
                    let start = i
                    i += 1
                    while i < bytes.count && identifierByte(bytes[i]) { i += 1 }
                    result.append(String(decoding: bytes[start..<i], as: UTF8.self))
                } else if Array("().,:[]=".utf8).contains(byte) {
                    result.append(String(decoding: [byte], as: UTF8.self)); i += 1
                } else { throw XcodeLocalPackageInputs.invalid("Unsupported manifest syntax.") }
                guard result.count <= 256 else { throw XcodeLocalPackageInputs.invalid("Manifest token budget exceeded.") }
            }
            return result
        }

        static func identifierByte(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
        }
    }

    private static func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "xcode-local-package", reason: reason)
    }
}
