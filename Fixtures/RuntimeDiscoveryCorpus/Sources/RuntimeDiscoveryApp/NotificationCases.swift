import Foundation
import Combine
import AppKit
import AVFoundation

extension Notification.Name {
    static let corpusReady = Notification.Name("corpus.static.ready")
}

final class NotificationTarget: NSObject {
    @objc func selectorNotice(_ note: Notification) {}
    @objc func filteredNotice(_ note: Notification) {}
}

func installSelectorObserver(_ target: NotificationTarget) {
    NotificationCenter.default.addObserver(
        target,
        selector: #selector(NotificationTarget.selectorNotice(_:)),
        name: Notification.Name("corpus.selector.ready"),
        object: nil
    )
}

func postSelectorNotification() {
    NotificationCenter.default.post(name: Notification.Name("corpus.selector.ready"), object: nil)
}

func installClosureObserver() {
    _ = NotificationCenter.default.addObserver(
        forName: Notification.Name("corpus.closure.ready"),
        object: nil,
        queue: nil
    ) { _ in }
}

func installPublisherSubscription() -> AnyCancellable {
    NotificationCenter.default.publisher(for: .corpusReady).sink { _ in }
}

func makeNotificationPublisher() -> NotificationCenter.Publisher {
    NotificationCenter.default.publisher(for: .corpusReady)
}

private func consumePublisher(_ publisher: NotificationCenter.Publisher) {}

func useCustomPublisherConsumer() {
    consumePublisher(NotificationCenter.default.publisher(for: .corpusReady))
}

func installFilteredPublisherSubscription(_ filter: NSObject) -> AnyCancellable {
    NotificationCenter.default.publisher(for: .corpusReady, object: filter).sink { _ in }
}

private struct CustomPublisherCenter {
    func publisher(for name: Notification.Name) -> Int { 0 }
}

func customPublisherIsNotSystem() {
    _ = CustomPublisherCenter().publisher(for: .corpusReady)
}

func postClosureNotification() {
    NotificationCenter.default.post(name: Notification.Name("corpus.closure.ready"), object: nil)
}

func postDifferentNotification() {
    NotificationCenter.default.post(name: Notification.Name("corpus.different"), object: nil)
}

func installFilteredObserver(_ target: NotificationTarget, filter: NSObject) {
    NotificationCenter.default.addObserver(
        target,
        selector: #selector(NotificationTarget.filteredNotice(_:)),
        name: Notification.Name("corpus.filtered"),
        object: filter
    )
}

func postFilteredNotification() {
    NotificationCenter.default.post(name: Notification.Name("corpus.filtered"), object: nil)
}

func installCustomCenterObserver() {
    let center = NotificationCenter()
    _ = center.addObserver(
        forName: Notification.Name("corpus.custom"),
        object: nil,
        queue: nil
    ) { _ in }
}

func postCustomCenterNotification() {
    let center = NotificationCenter()
    center.post(name: Notification.Name("corpus.custom"), object: nil)
}

func installStaticReadyObserver() {
    _ = NotificationCenter.default.addObserver(forName: .corpusReady, object: nil, queue: nil) { _ in }
}

func postStaticReadyNotification() {
    NotificationCenter.default.post(name: .corpusReady, object: nil)
}

final class NotificationCounter: @unchecked Sendable {
    var value = 0
}

func installApplicationSDKObserver(_ counter: NotificationCounter) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
    ) { _ in counter.value += 1 }
}

func postApplicationSDKNotification() {
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
}

func installWorkspaceSDKObserver(_ counter: NotificationCounter) -> NSObjectProtocol {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: nil
    ) { _ in counter.value += 1 }
}

func postWorkspaceSDKNotification() {
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didLaunchApplicationNotification,
        object: nil
    )
}

func installCaptureSDKObserver(_ counter: NotificationCounter, session: NSObject) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: .AVCaptureSessionDidStartRunning,
        object: session,
        queue: nil
    ) { _ in counter.value += 1 }
}

func postCaptureSDKNotification(_ session: NSObject) {
    NotificationCenter.default.post(
        name: .AVCaptureSessionDidStartRunning,
        object: session
    )
}

func exerciseLocalCenterAndObjectNotification() -> Int {
    let center = NotificationCenter()
    let object = NSObject()
    let other = NSObject()
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: Notification.Name("corpus.local.identity"),
        object: object,
        queue: nil
    ) { _ in counter.value += 1 }
    center.post(name: Notification.Name("corpus.local.identity"), object: object)
    center.post(name: Notification.Name("corpus.local.identity"), object: other)
    center.removeObserver(token)
    return counter.value
}

func branchSeparatedLocalNotification(_ installs: Bool) {
    let center = NotificationCenter()
    let object = NSObject()
    if installs {
        _ = center.addObserver(
            forName: Notification.Name("corpus.branch.identity"),
            object: object,
            queue: nil
        ) { _ in }
    } else {
        center.post(name: Notification.Name("corpus.branch.identity"), object: object)
    }
}

func exercisePostBeforeLocalObserver() -> Int {
    let center = NotificationCenter()
    let object = NSObject()
    let counter = NotificationCounter()
    center.post(name: Notification.Name("corpus.local.post-first"), object: object)
    let token = center.addObserver(
        forName: Notification.Name("corpus.local.post-first"),
        object: object,
        queue: nil
    ) { _ in counter.value += 1 }
    let alias = token
    center.removeObserver(alias)
    return counter.value
}

func exerciseBranchNotificationRemoval(_ removes: Bool) -> Int {
    let center = NotificationCenter.default
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: Notification.Name("corpus.branch.lifecycle"),
        object: nil,
        queue: nil
    ) { _ in counter.value += 1 }
    if removes {
        center.removeObserver(token)
        center.post(name: Notification.Name("corpus.branch.lifecycle"), object: nil)
    } else {
        center.post(name: Notification.Name("corpus.branch.lifecycle"), object: nil)
    }
    center.removeObserver(token)
    return counter.value
}

func exerciseDoDeferredRemoval() -> Int {
    let center = NotificationCenter.default
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: Notification.Name("corpus.defer.do"), object: nil, queue: nil
    ) { _ in counter.value += 1 }
    do {
        defer { center.removeObserver(token) }
        _ = token
    }
    center.post(name: Notification.Name("corpus.defer.do"), object: nil)
    return counter.value
}

func exerciseFunctionDeferredRemoval() -> Int {
    let center = NotificationCenter.default
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: Notification.Name("corpus.defer.function"), object: nil, queue: nil
    ) { _ in counter.value += 1 }
    defer { center.removeObserver(token) }
    center.post(name: Notification.Name("corpus.defer.function"), object: nil)
    return counter.value
}

func exerciseCancelledNotificationPublisher() -> Int {
    let center = NotificationCenter.default
    let counter = NotificationCounter()
    let token = center.publisher(for: Notification.Name("corpus.combine.cancelled")).sink { _ in
        counter.value += 1
    }
    let alias = token
    alias.cancel()
    center.post(name: Notification.Name("corpus.combine.cancelled"), object: nil)
    return counter.value
}

func consumeAsyncNotifications() async {
    for await _ in NotificationCenter.default.notifications(
        named: Notification.Name("corpus.async.sequence")
    ) { break }
}

func postAsyncNotification() {
    NotificationCenter.default.post(name: Notification.Name("corpus.async.sequence"), object: nil)
}

private struct CustomAsyncNotificationCenter {
    func notifications(named: Notification.Name) -> AsyncStream<Notification> {
        AsyncStream { $0.finish() }
    }
}

func consumeCustomAsyncNotifications() async {
    for await _ in CustomAsyncNotificationCenter().notifications(
        named: Notification.Name("corpus.async.custom")
    ) { break }
}

func makeBareAsyncNotificationSequence() {
    _ = NotificationCenter.default.notifications(named: Notification.Name("corpus.async.bare"))
}

func exerciseRemovedLocalObserver() -> Int {
    let center = NotificationCenter()
    let object = NSObject()
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: Notification.Name("corpus.local.removed"),
        object: object,
        queue: nil
    ) { _ in counter.value += 1 }
    center.removeObserver(token)
    center.post(name: Notification.Name("corpus.local.removed"), object: object)
    return counter.value
}
