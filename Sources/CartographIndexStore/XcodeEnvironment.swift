import Foundation

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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
