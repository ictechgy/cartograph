import Foundation

final class PerformTarget: NSObject {
    @objc func referenced(_ sender: Any?) {}
    @objc func explicitAction() {}
    @objc func literalAction() {}
    @objc func aliasAction() {}
}

final class TypedPerformTarget: NSObject {
    @objc func typedAction() {}
}

final class ConstructedPerformTarget: NSObject {
    @objc func constructedAction() {}
}

@objcMembers
class BasePerformTarget: NSObject {
    dynamic func inheritedAction() {}
}

final class ChildPerformTarget: BasePerformTarget {
    override func inheritedAction() {}
}

final class SameSelectorA: NSObject {
    @objc func sharedAction() {}
}

final class SameSelectorB: NSObject {
    @objc func sharedAction() {}
}

final class TimerTarget: NSObject {
    @objc func timerFired(_ timer: Timer) {}
}

func literalSelectorToken() {
    _ = NSSelectorFromString("tokenOnly:")
}

func aliasSelectorToken() {
    let first = "token"
    let selector = first + "Alias:"
    _ = NSSelectorFromString(selector)
}

func selectorReferenceOnly() {
    _ = #selector(PerformTarget.referenced(_:))
}

func explicitPerform(_ target: PerformTarget) {
    _ = target.perform(#selector(PerformTarget.explicitAction))
}

func literalPerform(_ target: PerformTarget) {
    _ = target.perform(NSSelectorFromString("literalAction"))
}

func aliasPerform(_ target: PerformTarget) {
    let selector = NSSelectorFromString("aliasAction")
    _ = target.perform(selector)
}

func typedParameterPerform(_ target: TypedPerformTarget) {
    _ = target.perform(NSSelectorFromString("typedAction"))
}

func constructedReceiverPerform() {
    _ = ConstructedPerformTarget().perform(NSSelectorFromString("constructedAction"))
}

func inheritedDispatch(_ target: BasePerformTarget) {
    _ = target.perform(NSSelectorFromString("inheritedAction"))
}

func unknownReceiver(_ target: NSObject) {
    _ = target.perform(NSSelectorFromString("sharedAction"))
}

func timerRegistration(_ target: TimerTarget) {
    _ = Timer.scheduledTimer(
        timeInterval: 1,
        target: target,
        selector: #selector(TimerTarget.timerFired(_:)),
        userInfo: nil,
        repeats: false
    )
}
