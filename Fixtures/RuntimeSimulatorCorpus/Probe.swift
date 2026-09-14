import UIKit

@objc(CartographSimulatorTarget)
final class RuntimeTarget: NSObject {
    @objc func work() -> NSString { "called" }
}

@objc(CartographSimulatorScene)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { fatalError("Expected a window scene") }
        exerciseRuntime()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ignore-term") { signal(SIGTERM, SIG_IGN) }
        if arguments.contains("--wait") { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if arguments.contains("--crash") { abort() }
            if arguments.contains("--immediate-exit") { _exit(0) }
            exit(arguments.contains("--fail") ? 7 : 0)
        }
    }

    func exerciseRuntime() {
        let className = ["Cartograph", "SimulatorTarget"].joined()
        let selectorName = ["wo", "rk"].joined()
        guard NSClassFromString(className) != nil else { fatalError("Missing runtime class") }
        let target = RuntimeTarget()
        let result = target.perform(NSSelectorFromString(selectorName))?.takeUnretainedValue()
        print("probe-result:\(result as? NSString ?? "missing")")
        fflush(stdout)
    }
}

@objc(CartographSimulatorDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {}

@main
struct Bootstrap {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--exit-before-scenario") { exit(0) }
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }
}
