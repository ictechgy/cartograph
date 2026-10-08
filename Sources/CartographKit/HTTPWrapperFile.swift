import CartographCore
import Foundation

/// `http-wrappers` v1/v2 선언 파일을 읽는다(`../isthmus/docs/HTTP-WRAPPERS.md`).
///
/// 모르는 필드와 잘못된 값은 조용히 무시하지 않고 거부한다. 낡은 선언을 무시하면 호출이 0건으로
/// 나오고, 소비자는 그것을 "호출 없음"으로 읽는다. 오류 문구에는 필드 이름과 위치만 싣고 값은
/// 싣지 않는다 — 선언 파일은 저장소 밖에 둘 수 있고 사용자가 내용을 공유하지 않았을 수 있다.
enum HTTPWrapperFile {
    /// 파일 형식 이름과 버전. 스키마는 isthmus 문서가 소유한다.
    static let format = "http-wrappers"
    static let versions: Set<Int> = [1, 2]
    static let maximumBytes = 1024 * 1024

    private static let topLevelKeys: Set<String> = ["format", "version", "wrappers"]
    private static let versionOneWrapperKeys: Set<String> = [
        "language", "kind", "owner", "name", "methodArg", "pathArg", "defaultMethod", "methodEnum", "pathAnchor", "service",
    ]
    private static let versionTwoWrapperKeys = versionOneWrapperKeys.union(["pathSuffix"])
    private static let languages: Set<String> = ["swift", "kotlin", "dart", "js", "go", "rust", "python"]

    /// 선언 전체를 읽는다. 다른 언어의 선언도 형식 검증은 같이 받는다 — 같은 파일을 자매 도구가 함께 쓴다.
    static func parse(_ data: Data, path: String) throws -> [HTTPWrapperDeclaration] {
        guard data.count <= maximumBytes else {
            throw fail(path, "The file exceeds 1 MiB.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail(path, "The file is not a JSON object.")
        }
        if let unknown = Set(root.keys).subtracting(topLevelKeys).sorted().first {
            throw fail(path, "Unknown top-level field \"\(unknown)\".")
        }
        guard root["format"] as? String == format,
              let version = integer(root["version"]), versions.contains(version) else {
            throw fail(path, "Expected \"format\": \"http-wrappers\" and \"version\": 1 or 2.")
        }
        guard let wrappers = root["wrappers"] as? [Any] else { throw fail(path, "\"wrappers\" must be an array.") }
        return try wrappers.enumerated().map { index, value in
            do {
                return try declaration(value, version: version)
            } catch let reason as DeclarationError {
                throw fail(path, "wrappers[\(index)]: \(reason.message)")
            }
        }
    }

    /// 파일 경로와 고칠 방향을 붙인 설정 오류.
    private static func fail(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason + " Fix the http-wrappers declaration file (supported versions: 1 and 2).")
    }

    /// 선언 하나의 오류. 위치를 붙이는 쪽이 파일 경로와 함께 감싼다.
    private struct DeclarationError: Error {
        let message: String
    }

    private static func declaration(_ value: Any, version: Int) throws -> HTTPWrapperDeclaration {
        guard let object = value as? [String: Any] else { throw DeclarationError(message: "must be an object.") }
        let wrapperKeys = version == 1 ? versionOneWrapperKeys : versionTwoWrapperKeys
        if let unknown = Set(object.keys).subtracting(wrapperKeys).sorted().first {
            throw DeclarationError(message: "unknown field \"\(unknown)\".")
        }
        let language = try requiredString(object, "language", allowed: languages)
        let kind = HTTPWrapperDeclaration.Kind(rawValue: try requiredString(object, "kind", allowed: ["constructor", "function"]))!
        let methodArg = try object["methodArg"].map { try binding($0, field: "methodArg") }
        let defaultMethod = try optionalVerb(object["defaultMethod"], field: "defaultMethod")
        guard methodArg != nil || defaultMethod != nil else {
            throw DeclarationError(message: "declare methodArg or defaultMethod; a wrapper without either has no verb.")
        }
        return HTTPWrapperDeclaration(
            language: language, kind: kind,
            owner: try requiredString(object, "owner"), name: try requiredString(object, "name"),
            methodArg: methodArg, pathArg: try binding(object["pathArg"] as Any, field: "pathArg"),
            defaultMethod: defaultMethod, methodEnum: try methodEnum(object["methodEnum"]),
            pathAnchor: HTTPPathAnchor(rawValue: try requiredString(object, "pathAnchor", allowed: ["root", "base"]))!,
            service: try object["service"].map { _ in try requiredString(object, "service") },
            pathSuffix: version == 2 ? try pathSuffix(object["pathSuffix"]) : []
        )
    }

    private static func pathSuffix(_ value: Any?) throws -> [HTTPWrapperDeclaration.PathSuffix] {
        guard let value else { return [] }
        guard let entries = value as? [Any],
              entries.count <= HTTPWrapperDeclaration.maximumPathSuffixEntries else {
            throw DeclarationError(
                message: "\"pathSuffix\" must be an array of at most "
                    + "\(HTTPWrapperDeclaration.maximumPathSuffixEntries) entries."
            )
        }
        return try entries.enumerated().map { index, value in
            guard let object = value as? [String: Any] else {
                throw DeclarationError(message: "\"pathSuffix[\(index)]\" must be an object.")
            }
            if Set(object.keys) == ["literal"] {
                return .literal(try suffixLiteral(object))
            }
            guard Set(object.keys) == ["argument", "shape"] else {
                throw DeclarationError(
                    message: "\"pathSuffix[\(index)]\" must contain only \"literal\", "
                        + "or exactly \"argument\" and \"shape\"."
                )
            }
            let shape = try requiredString(object, "shape", allowed: ["scalar", "array"])
            return .argument(
                try binding(object["argument"] as Any, field: "pathSuffix[\(index)].argument"),
                shape: HTTPWrapperDeclaration.PathSuffix.ArgumentShape(rawValue: shape)!
            )
        }
    }

    private static func suffixLiteral(_ object: [String: Any]) throws -> String {
        let text = try requiredString(object, "literal")
        guard text != ".", text != "..",
              !text.unicodeScalars.contains(where: { (0xD800...0xDFFF).contains($0.value) }) else {
            throw DeclarationError(
                message: "\"literal\" must be one decoded non-empty path segment other than \".\" or \"..\"."
            )
        }
        return text
    }

    private static func requiredString(_ object: [String: Any], _ field: String, allowed: Set<String>? = nil) throws -> String {
        guard let text = object[field] as? String, isSafe(text) else {
            throw DeclarationError(message: "\"\(field)\" must be a non-empty string without control characters.")
        }
        if let allowed, !allowed.contains(text) {
            throw DeclarationError(message: "\"\(field)\" must be one of \(allowed.sorted().joined(separator: ", ")).")
        }
        return text
    }

    private static func binding(_ value: Any, field: String) throws -> HTTPWrapperDeclaration.ArgumentBinding {
        guard let object = value as? [String: Any], !object.isEmpty,
              Set(object.keys).isSubset(of: ["index", "label"]) else {
            throw DeclarationError(message: "\"\(field)\" must be an object with \"index\", \"label\", or both.")
        }
        let index = object["index"]
        let label = object["label"]
        guard index == nil || (integer(index).map { $0 >= 0 } == true),
              label == nil || (label as? String).map(isSafe) == true else {
            throw DeclarationError(message: "\"\(field)\" needs a non-negative integer index and a non-empty label.")
        }
        return .init(index: integer(index), label: label as? String)
    }

    private static func optionalVerb(_ value: Any?, field: String) throws -> String? {
        guard let value else { return nil }
        guard let verb = value as? String, HTTPRouteTemplate.methods.contains(verb) else {
            throw DeclarationError(message: "\"\(field)\" must be one of \(HTTPRouteTemplate.methods.sorted().joined(separator: ", ")).")
        }
        return verb
    }

    private static func methodEnum(_ value: Any?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else { throw DeclarationError(message: "\"methodEnum\" must be an object.") }
        return try object.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty, let verb = try optionalVerb(entry.value, field: "methodEnum") else {
                throw DeclarationError(message: "\"methodEnum\" keys must be non-empty.")
            }
            result[entry.key] = verb
        }
    }

    /// JSON 정수면 그 값. 불리언(`true` 도 NSNumber 다)과 소수는 정수가 아니다.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e9 else { return nil }
        return number.intValue
    }

    /// 제어 문자 없는 비어 있지 않은 문자열인지. 한계 문구로 나갈 수 있는 이름이다.
    private static func isSafe(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }
}
