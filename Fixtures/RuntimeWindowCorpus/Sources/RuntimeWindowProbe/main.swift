import Foundation
import Darwin

@objc(CartographWindowTarget)
final class WindowTarget: NSObject {
    @objc func early() -> NSString { "early" }
    @objc func late() -> NSString { "late" }
}

@inline(never)
func collectEarly(_ target: WindowTarget) {
    let name = ["Cartograph", "WindowTarget"].joined()
    precondition(NSClassFromString(name) != nil)
    let result = target.perform(NSSelectorFromString(["ear", "ly"].joined()))?.takeUnretainedValue()
    print("result:\(result as? NSString ?? "missing")")
    fflush(stdout)
}

let arguments = CommandLine.arguments
if arguments.contains("--exit-early") { exit(0) }
signal(SIGTERM, SIG_IGN)
let target = WindowTarget()
collectEarly(target)
if arguments.contains("--oversized-name") {
    _ = NSClassFromString(String(repeating: "UnknownRuntimeType", count: 100))
}
Thread.sleep(forTimeInterval: 4)
_ = target.perform(NSSelectorFromString("late"))
Thread.sleep(forTimeInterval: 30)
