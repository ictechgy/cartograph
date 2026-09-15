import Foundation
import Dispatch

/// Xcode 개발자 디렉터리를 알아낸다.
///
/// libIndexStore 는 툴체인 안에 있고, 그 위치는 시스템마다 다르다.
/// 환경 변수를 먼저 보고, 없으면 `xcode-select -p` 를 물어본다.
public enum XcodeEnvironment {
    /// 개발자 디렉터리 경로. 알아내지 못하면 nil.
    public static func developerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty { return override }
        return runXcodeSelect()
    }

    /// `xcode-select -p` 의 출력. 실행할 수 없으면 nil.
    private static func runXcodeSelect() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        return output(from: process)
    }

    /// 표준 출력이 먼저 닫혀도 실제 성공 종료를 확인한 경로만 사용한다.
    static func output(from process: Process) -> String? {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // waitUntilExit의 런루프 폴링 지연이 짧은 명령보다 길 수 있다. EOF를
        // 성공으로 간주하지 않고 실제 종료 통지를 기다려 같은 계약을 유지한다.
        terminated.wait()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
