import CartographCore
import Darwin
import Foundation

/// 버전 포인터의 기본 선택을 읽되 제외된 버전이나 migration 사용을 추측하지 않는다.
struct CoreDataVersionSelection {
    let selectedPath: String?
    let reason: String?

    static func read(markerPath: String, modelPaths: [String], fileSystem: any FileSystem) -> Self {
        do {
            let data = try readBounded(markerPath, fileSystem: fileSystem)
            guard data.count <= 65_536 else {
                return .init(selectedPath: nil, reason: "Core Data current version file exceeds the 64 KiB limit.")
            }
            if !data.starts(with: Data("bplist00".utf8)) {
                guard let xml = String(data: data, encoding: .utf8), !xml.contains("\0") else {
                    return .init(selectedPath: nil,
                        reason: "Core Data current version file must be a binary plist or UTF-8 XML.")
                }
                // 표준 plist DTD는 허용하되 사용자 entity 선언을 파싱기에 넘기지 않는다.
                if xml.range(of: "<!ENTITY", options: .caseInsensitive) != nil {
                    return .init(selectedPath: nil,
                        reason: "Core Data current version file contains an XML entity declaration.")
                }
            }
            let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = value as? [String: Any],
                  let name = dictionary["_XCCurrentVersionName"] as? String,
                  !name.isEmpty, name.utf8.count <= 255, name.hasSuffix(".xcdatamodel"),
                  !name.contains("/"), !name.contains("\\"),
                  name != ".xcdatamodel", !name.contains("\0") else {
                return .init(selectedPath: nil, reason: "Core Data current version file has no valid model version name.")
            }
            let container = URL(fileURLWithPath: markerPath).deletingLastPathComponent()
            let selected = container.appendingPathComponent(name).appendingPathComponent("contents").path
            guard modelPaths.contains(selected) else {
                return .init(selectedPath: nil,
                    reason: "Core Data current version selects a missing or excluded model version.")
            }
            return .init(selectedPath: selected, reason: nil)
        } catch {
            return .init(selectedPath: nil, reason: "Core Data current version file is unreadable or not a valid plist.")
        }
    }

    private static func readBounded(_ path: String, fileSystem: any FileSystem) throws -> Data {
        if fileSystem is LocalFileSystem {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return try handle.read(upToCount: 65_537) ?? Data()
        }
        return try fileSystem.readData(at: path)
    }
}
