import CartographCore
import Foundation

/// xcconfig를 실행하지 않는다. 제한된 literal 값과 로컬 include의 유한 폐쇄만 허용한다.
enum XcodeIOSInputs {
    static func validateConfigurations(objects: [String: [String: Any]], paths: [String: String], root: String,
                                       fileSystem: any FileSystem) throws {
        var visited: Set<String> = [], active: Set<String> = [], total = 0
        func read(_ path: String, depth: Int) throws {
            guard depth <= 16, XcodeScopeInputRules.relative(path), !active.contains(path) else {
                throw XcodeScopeInputRules.invalid("xcconfig include path, depth or cycle is unsupported.")
            }
            if visited.contains(path) { return }
            guard visited.count < 64 else { throw XcodeScopeInputRules.invalid("xcconfig include budget exceeded.") }
            let data = try XcodeLocalPackageIO.bounded(root + "/" + path, maximum: 64 * 1_024, fileSystem: fileSystem)
            total += data.count
            guard total <= 1_024 * 1_024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw XcodeScopeInputRules.invalid("xcconfig byte budget or encoding is unsupported.")
            }
            active.insert(path)
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("//") { continue }
                if line.hasPrefix("#include \"") && line.hasSuffix("\"") {
                    let name = String(line.dropFirst(10).dropLast())
                    let parent = (path as NSString).deletingLastPathComponent
                    try read([parent, name].filter { !$0.isEmpty }.joined(separator: "/"), depth: depth + 1)
                    continue
                }
                guard let equal = line.firstIndex(of: "=") else { throw XcodeScopeInputRules.invalid("Unsupported xcconfig directive.") }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                guard ["SWIFT_ACTIVE_COMPILATION_CONDITIONS", "GCC_PREPROCESSOR_DEFINITIONS"].contains(key),
                      !value.isEmpty, value.replacingOccurrences(of: "$(inherited)", with: "").unicodeScalars.allSatisfy({
                        CharacterSet.alphanumerics.contains($0) || "_ =\t".unicodeScalars.contains($0)
                      }) else { throw XcodeScopeInputRules.invalid("Only literal compilation definitions are supported in iOS xcconfig inputs.") }
            }
            active.remove(path); visited.insert(path)
        }
        for object in objects.values {
            if let reference = object["baseConfigurationReference"] {
                guard let id = reference as? String, let path = paths[id], path.hasSuffix(".xcconfig") else {
                    throw XcodeScopeInputRules.invalid("xcconfig reference is not a canonical local group member.")
                }
                try read(path, depth: 0)
            }
        }
    }
}
