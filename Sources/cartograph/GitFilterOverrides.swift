import CartographCore
import Foundation

/// macOS Process 는 argv 와 환경 값의 Unicode 를 정규화한다. Git subsection 의 정확한
/// 바이트 신원은 임시 설정 파일로 전달하고, 명령행에는 그 파일의 경로만 넘긴다.
struct GitFilterOverrides {
    let arguments: [String]
    private let directory: URL?

    static func prepare(_ options: [String], reference: String) throws -> Self {
        var remaining: [String] = []
        var configuration = Data()
        var index = 0
        while index < options.count {
            if options[index] == "-c", index + 1 < options.count,
               options[index + 1].utf8.starts(with: "filter.".utf8) {
                try append(options[index + 1], to: &configuration, reference: reference)
                index += 2
            } else {
                remaining.append(options[index])
                index += 1
            }
        }
        guard !configuration.isEmpty else { return Self(arguments: remaining, directory: nil) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-git-filters-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("overrides.config")
        var created = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            created = true
            guard FileManager.default.createFile(atPath: file.path, contents: configuration,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw failure(reference, "could not write private Git filter overrides; check the temporary directory")
            }
        } catch {
            if created { remove(directory) }
            throw failure(reference, "could not prepare private Git filter overrides: \(error); "
                + "check the temporary directory")
        }
        return Self(arguments: remaining + ["-c", "include.path=\(file.path)"], directory: directory)
    }

    /// 자식 프로세스가 끝날 때까지 파일을 유지한 호출자가 정리한다.
    func cleanup() {
        if let directory { Self.remove(directory) }
    }

    /// 설정 파일 전달과 드라이버 수집이 같은 바이트 경계를 사용해야 다른 키를 덮지 않는다.
    static func filterKeyComponents(
        _ bytes: [UInt8], allowsRequired: Bool = false
    ) -> (name: [UInt8], setting: String)? {
        // 점 뒤의 결합 문자가 Swift 의 Character 경계를 바꾸어도 Git 키의 바이트 경계는 같다.
        let prefix = Array("filter.".utf8)
        guard bytes.starts(with: prefix), let lastDot = bytes.lastIndex(of: 0x2E), lastDot >= prefix.count else {
            return nil
        }
        let suffix = String(decoding: bytes[(lastDot + 1)...], as: UTF8.self)
        guard ["clean", "smudge", "process"].contains(suffix) || (allowsRequired && suffix == "required") else {
            return nil
        }
        return (Array(bytes[prefix.count..<lastDot]), suffix)
    }

    private static func append(_ assignment: String, to data: inout Data, reference: String) throws {
        let bytes = Array(assignment.utf8)
        guard let equals = bytes.firstIndex(of: 0x3D),
              let key = filterKeyComponents(Array(bytes[..<equals]), allowsRequired: true),
              !key.name.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw failure(reference, "a Git filter override cannot be represented safely; use a fresh checkout")
        }
        let value = Array(bytes[(equals + 1)...])
        guard (key.setting == "required" && value == Array("false".utf8))
            || (key.setting != "required" && value.isEmpty) else {
            throw failure(reference, "Git filter overrides must disable commands; use a fresh checkout")
        }
        data.append(Data("[filter \"".utf8))
        for byte in key.name {
            if byte == 0x22 || byte == 0x5C { data.append(0x5C) }
            data.append(byte)
        }
        data.append(Data("\"]\n\t\(key.setting) = ".utf8))
        data.append(contentsOf: value)
        data.append(0x0A)
    }

    private static func remove(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            FileHandle.standardError.write(Data(("warning: could not remove temporary Git filter overrides at "
                + String(reflecting: directory.path) + ": \(error)\n").utf8))
        }
    }

    private static func failure(_ reference: String, _ reason: String) -> CartographError {
        .changedFilesUnavailable(reference: reference, reason: reason)
    }
}
