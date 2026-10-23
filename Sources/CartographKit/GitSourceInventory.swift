import CartographCore
import Foundation

/// Git이 직접 해석한 추적 파일과 비무시 파일 목록. ignore 문법을 별도로 흉내 내지 않는다.
struct GitSourceInventory {
    let paths: Set<String>

    /// 주입된 파일 시스템에는 호스트 프로세스를 실행하지 않는다. 실패는 전체 walk로 폴백한다.
    static func load(fileSystem: any FileSystem, projectPath: String) -> GitSourceInventory? {
        guard fileSystem is LocalFileSystem else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-C", projectPath, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."]
        var environment = ProcessInfo.processInfo.environment
        // 외부 세션의 Git 저장소 재지정이 분석 루트를 바꾸지 못하게 한다.
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // ls-files는 object/filter/hook를 실행하지 않는다. 출력과 시간 모두 경계를 둔다.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        let maximumBytes = 16 * 1024 * 1024
        var data = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                data.append(chunk)
                if data.count > maximumBytes { process.terminate(); break }
            }
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= maximumBytes,
              data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        let root = (try? fileSystem.realPath(at: projectPath)) ?? fileSystem.canonicalPath(projectPath)
        let paths = text.split(separator: "\0").map(String.init)
        guard paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { return nil }
        return GitSourceInventory(paths: Set(paths.map { root + "/" + $0 }))
    }
}
