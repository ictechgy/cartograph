import CartographCore
import Foundation

/// Git이 직접 해석한 추적 파일과 비무시 파일 목록. ignore 문법을 별도로 흉내 내지 않는다.
///
/// 값만 담는다. 선택 절차는 `GitSourceSelection` 에 있다 — 둘을 한 타입에 두면 선택 결과가 목록을 싣고
/// 목록이 선택 결과를 돌려주어 타입 그래프에 순환이 생긴다(`cycles --level type --strict` 가 잡았다).
struct GitSourceInventory: Equatable {
    /// 추적되거나 무시되지 않은 파일의 절대 경로.
    let paths: Set<String>
}

/// Git 선택을 시도한 결과.
///
/// 실패를 nil 하나로 접으면 "저장소가 아니다"와 "저장소인데 시간·크기 상한에 걸렸다"가 구분되지 않는다.
/// 후자는 전체 walk 로 폴백해 무시 파일까지 섞이므로, 같은 커밋에서 실행마다 결과가 흔들린다. 그 사실을
/// 한계로 알리려면 이유가 필요하다.
enum GitSourceSelection: Equatable {
    /// 추적 파일과 무시되지 않은 파일 목록.
    case selected(GitSourceInventory)
    /// 선택을 시도하지 않았다 — 주입된 파일 시스템이거나 Git 저장소 밖이다. 실패가 아니다.
    case notApplicable
    /// 저장소 안인데 선택을 끝내지 못했다. 호출자는 전체 walk 로 폴백한다.
    case unavailable(reason: String)

    /// 선택에 성공했을 때의 목록. 시도하지 않았거나 실패했으면 nil 이고, 호출자는 전체 walk 로 폴백한다.
    var inventory: GitSourceInventory? {
        guard case let .selected(inventory) = self else { return nil }
        return inventory
    }

    /// Git 선택을 시도하고, 끝내지 못했으면 그 이유를 돌려준다.
    static func select(
        fileSystem: any FileSystem, projectPath: String, timeoutSeconds: Double = 5
    ) -> GitSourceSelection {
        guard fileSystem is LocalFileSystem else { return .notApplicable }
        guard isInsideRepository(projectPath, fileSystem: fileSystem) else { return .notApplicable }
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
        do { try process.run() } catch { return .unavailable(reason: "git could not be started") }
        // ls-files는 object/filter/hook를 실행하지 않는다. 출력과 시간 모두 경계를 둔다.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        let maximumBytes = 16 * 1024 * 1024
        var data = Data()
        var exceededOutputBudget = false
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                data.append(chunk)
                if data.count > maximumBytes { exceededOutputBudget = true; process.terminate(); break }
            }
        } catch {
            if process.isRunning { process.terminate() }
            return .unavailable(reason: "git ls-files output could not be read")
        }
        process.waitUntilExit()
        return selection(from: data, process: process, exceededOutputBudget: exceededOutputBudget,
            timeoutSeconds: timeoutSeconds, projectPath: projectPath, fileSystem: fileSystem)
    }

    /// 끝난 `git ls-files` 의 출력과 종료 상태를 선택 결과로 바꾼다.
    private static func selection(
        from data: Data, process: Process, exceededOutputBudget: Bool, timeoutSeconds: Double,
        projectPath: String, fileSystem: any FileSystem
    ) -> GitSourceSelection {
        if exceededOutputBudget { return .unavailable(reason: "git ls-files output exceeded 16 MiB") }
        if process.terminationReason == .uncaughtSignal {
            return .unavailable(reason: "git ls-files was stopped after \(Int(timeoutSeconds)) seconds or by a signal")
        }
        guard process.terminationStatus == 0 else {
            return .unavailable(reason: "git ls-files exited with status \(process.terminationStatus)")
        }
        guard data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else {
            return .unavailable(reason: "git ls-files output was not NUL-terminated UTF-8")
        }
        let root = (try? fileSystem.realPath(at: projectPath)) ?? fileSystem.canonicalPath(projectPath)
        let paths = text.split(separator: "\0").map(String.init)
        guard paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            return .unavailable(reason: "git ls-files returned paths outside the project")
        }
        return .selected(GitSourceInventory(paths: Set(paths.map { root + "/" + $0 })))
    }

    /// 프로젝트 경로나 그 조상에 `.git` 이 있는지.
    ///
    /// 저장소 밖 프로젝트에서 `git ls-files` 가 실패하는 것은 정상이라 알리지 않는다. 알리면 Git 을 쓰지 않는
    /// 프로젝트에 매번 붙는 경보가 되고, 매번 붙는 경보는 읽히지 않는다.
    private static func isInsideRepository(_ projectPath: String, fileSystem: any FileSystem) -> Bool {
        var directory = (try? fileSystem.realPath(at: projectPath)) ?? fileSystem.canonicalPath(projectPath)
        while true {
            let marker = directory + "/.git"
            if fileSystem.fileExists(at: marker) || fileSystem.directoryExists(at: marker) { return true }
            let parent = (directory as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != directory else { return false }
            directory = parent
        }
    }
}
