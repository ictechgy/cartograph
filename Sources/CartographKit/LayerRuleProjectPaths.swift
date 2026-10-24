import CartographCore
import Foundation

/// 레이어 분류용 별칭은 주입된 환경에서 입증하고 순수 평가기로 넘긴다.
enum LayerRuleProjectPaths {
    static func confirmed(projectPath: String, fileSystem: any FileSystem) -> [String] {
        let absolute = projectPath.hasPrefix("/") ? projectPath
            : (fileSystem.currentDirectoryPath as NSString).appendingPathComponent(projectPath)
        let physical = physicalPath(for: absolute, fileSystem: fileSystem)
        var candidates = [projectPath, absolute] + (physical.map { [$0] } ?? [])
        for path in candidates {
            // 후보 생성은 동등성의 증명이 아니다. 아래의 주입된 realPath 대조가 필수다.
            if path.hasPrefix("/private/") {
                candidates.append(String(path.dropFirst("/private".count)))
            } else if path.hasPrefix("/") {
                candidates.append("/private" + path)
            }
        }
        var result: [String] = []
        for candidate in candidates where !result.contains(candidate) {
            if candidate.utf8.elementsEqual(projectPath.utf8) {
                result.append(candidate)
            } else if let physical,
                      let resolved = physicalPath(for: candidate, fileSystem: fileSystem),
                      resolved.utf8.elementsEqual(physical.utf8) {
                result.append(candidate)
            }
        }
        return result
    }

    /// 존재하지 않는 끝 성분도 같은 실제 부모·같은 나머지 철자로만 연결한다.
    private static func physicalPath(for path: String, fileSystem: any FileSystem) -> String? {
        var current = path
        while current.count > 1, current.hasSuffix("/") { current.removeLast() }
        var missing: [String] = []
        for _ in 0..<256 {
            if fileSystem.directoryExists(at: current) {
                guard let resolved = try? fileSystem.realPath(at: current), resolved.hasPrefix("/") else {
                    return nil
                }
                let separator = resolved.hasSuffix("/") || missing.isEmpty ? "" : "/"
                return resolved + separator + missing.reversed().joined(separator: "/")
            }
            let parent = (current as NSString).deletingLastPathComponent
            let name = (current as NSString).lastPathComponent
            guard parent != current, !name.isEmpty, name != ".", name != ".." else { return nil }
            missing.append(name)
            current = parent
        }
        return nil
    }
}
