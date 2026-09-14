import AppKit
import Foundation

print("runtime discovery corpus")
let kvcTarget = KVCSupportedTarget()
let kvcBefore = supportedKVCRead(kvcTarget) ?? "nil"
supportedKVCWrite(kvcTarget)
print("kvc=\(kvcBefore)->\(kvcTarget.title)")
let aliasGetter = objectiveCAliasAccessorKVCRead(KVCObjectiveCAliasAccessorTarget()) ?? "nil"
let propertyGetter = propertyAccessorKVCRead(KVCPropertyAccessorTarget()) ?? "nil"
let aliasPropertyGetter = objectiveCAliasPropertyKVCRead(KVCObjectiveCAliasPropertyTarget()) ?? "nil"
print("kvc-priority=\(aliasGetter),\(propertyGetter),\(aliasPropertyGetter)")

let appCounter = NotificationCounter()
let appToken = installApplicationSDKObserver(appCounter)
postApplicationSDKNotification()
NotificationCenter.default.removeObserver(appToken)

let workspaceCounter = NotificationCounter()
let workspaceToken = installWorkspaceSDKObserver(workspaceCounter)
postWorkspaceSDKNotification()
NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)

let captureCounter = NotificationCounter()
let captureObject = NSObject()
let captureToken = installCaptureSDKObserver(captureCounter, session: captureObject)
postCaptureSDKNotification(captureObject)
NotificationCenter.default.removeObserver(captureToken)

let localCount = exerciseLocalCenterAndObjectNotification()
print("notification-identity=\(appCounter.value),\(workspaceCounter.value),\(captureCounter.value),\(localCount)")
let postFirstCounts = [exercisePostBeforeLocalObserver(), exercisePostBeforeLocalObserver()]
print("notification-post-before-observer=\(postFirstCounts[0]),\(postFirstCounts[1])")
let removedCounts = [exerciseRemovedLocalObserver(), exerciseRemovedLocalObserver()]
print("notification-removed-before-post=\(removedCounts[0]),\(removedCounts[1])")
let branchCounts = [exerciseBranchNotificationRemoval(true), exerciseBranchNotificationRemoval(false)]
print("notification-branch-removal=\(branchCounts[0]),\(branchCounts[1])")
print("notification-defer=\(exerciseDoDeferredRemoval()),\(exerciseFunctionDeferredRemoval())")
print("notification-combine-cancel=\(exerciseCancelledNotificationPublisher())")
