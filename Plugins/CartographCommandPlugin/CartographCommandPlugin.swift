import Foundation
import PackagePlugin

/// `swift package plugin cartograph …` 로 도구를 실행하는 커맨드 플러그인.
///
/// Swift 패키지에서는 설치가 아예 필요 없게 만드는 것이 목적이다. 의존성에
/// 추가하기만 하면 팀원과 CI 가 같은 버전을 쓰게 되고, 각자 brew 로 설치한
/// 버전이 제각각인 상황을 피할 수 있다.
///
/// 쓰기 권한은 선언하지 않는다. 분석은 읽기만 하면 되고, 권한을 선언하면
/// 실행할 때마다 사용자가 승인 플래그를 붙여야 한다. 파일로 남기려면
/// 리다이렉션을 쓰면 된다: `swift package plugin cartograph graph > graph.dot`
/// 파일을 직접 쓰는 명령(`--output`, `baseline`, `fix --apply`, `skill`, `init`)은 샌드박스가
/// 패키지 디렉터리 쓰기를 막아 실패하므로, 그 실행에만 `--allow-writing-to-package-directory` 로 허락한다.
@main
struct CartographCommandPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let tool = try context.tool(named: "cartograph")

        // 패키지 디렉터리를 기본 분석 대상으로 넣는다. 플러그인은 임의의 작업
        // 디렉터리에서 실행되므로, 이것이 없으면 현재 디렉터리 기본값이 엉뚱한 곳을 가리킨다.
        // `--project=/path` 처럼 한 토큰으로 준 경우도 알아봐야 한다. 놓치면 뒤에
        // 붙인 값이 이기므로, 사용자가 지정한 경로가 조용히 무시된다.
        let specifiesProject = arguments.contains {
            $0 == "--project" || $0 == "-p" || $0.hasPrefix("--project=") || $0.hasPrefix("-p=")
        }
        var forwarded = arguments
        if !specifiesProject {
            forwarded.append(contentsOf: ["--project", context.package.directoryURL.path])
        }

        let process = Process()
        process.executableURL = tool.url
        process.arguments = forwarded
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // 종료 코드를 그대로 전달할 길은 없다. SwiftPM 은 플러그인 실패를 모두 종료 코드 1 로
            // 바꾸고, 플러그인이 `exit(status)` 로 끝내도 "Plugin ended with exit code N" 과 함께 1 이다.
            // 1·2·64 의 구분은 이 오류의 설명 "cartograph exited with status N" 에만 남는다. README 가
            // 원래 상태를 읽을 자리로 이 문구를 안내하므로 바꾸지 않는다. 구분이 필요한 CI 는
            // 바이너리나 공식 액션을 쓴다(README 의 CI 절).
            throw CartographPluginError.toolFailed(status: process.terminationStatus)
        }
    }
}

enum CartographPluginError: Error, CustomStringConvertible {
    case toolFailed(status: Int32)

    var description: String {
        switch self {
        case let .toolFailed(status):
            "cartograph exited with status \(status)"
        }
    }
}
