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
@main
struct CartographCommandPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let tool = try context.tool(named: "cartograph")

        // 패키지 디렉터리를 기본 분석 대상으로 넣는다. 플러그인은 임의의 작업
        // 디렉터리에서 실행되므로, 이것이 없으면 현재 디렉터리 기본값이 엉뚱한 곳을 가리킨다.
        var forwarded = arguments
        if !arguments.contains("--project"), !arguments.contains("-p") {
            forwarded.append(contentsOf: ["--project", context.package.directoryURL.path])
        }

        let process = Process()
        process.executableURL = tool.url
        process.arguments = forwarded
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // 종료 코드를 그대로 전달해야 CI 에서 --strict 가 의미를 갖는다.
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
