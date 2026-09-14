import Foundation

final class ProbeHandler: NSObject {
    var voidCalled = false
    var primitiveCalled = false

    @objc class func classGreeting() -> NSString {
        "class-greeting"
    }

    @objc func handle(_ value: Any?) -> NSString {
        "handled:\(value ?? "nil")" as NSString
    }

    @objc func handle(_ first: Any?, second: Any?) -> NSString {
        "handled:\(first ?? "nil"):\(second ?? "nil")" as NSString
    }

    @objc func markVoid() {
        voidCalled = true
    }

    @objc func primitiveValue() -> Int32 {
        primitiveCalled = true
        return 42
    }
}

final class ProbeObserver: NSObject {
    var received = false

    @objc func receive(_ notification: Notification) {
        received = notification.name.rawValue == "CartographRuntimeCollection"
    }
}

@inline(never)
func lookupClass(_ name: String) -> AnyClass? {
    NSClassFromString(name)
}

@inline(never)
func lookupProtocol(_ name: String) -> Protocol? {
    NSProtocolFromString(name)
}

@inline(never)
func makeSelector(_ name: String) -> Selector {
    NSSelectorFromString(name)
}

@inline(never)
func invokeWithoutArguments(on handler: ProbeHandler, selector: Selector) -> Bool {
    handler.perform(selector) != nil
}

@inline(never)
func invokeWithOneArgument(on handler: ProbeHandler, selector: Selector) -> Bool {
    handler.perform(selector, with: "one") != nil
}

@inline(never)
func invokeWithTwoArguments(on handler: ProbeHandler, selector: Selector) -> Bool {
    handler.perform(selector, with: "one", with: "two") != nil
}

@inline(never)
func invokeClass(selector: Selector) -> Bool {
    ProbeHandler.perform(selector) != nil
}

@inline(never)
func invokeIgnoringReturn(on handler: ProbeHandler, selector: Selector) {
    _ = handler.perform(selector)
}

@inline(never)
func registerObserver(_ observer: ProbeObserver, name: Notification.Name, selector: Selector) {
    NotificationCenter.default.addObserver(observer, selector: selector, name: name, object: nil)
}

if CommandLine.arguments.contains("--child-only") {
    let found = lookupClass("CartographChildOnlyMissingClass") != nil
    print("child-lookup=\(found)")
} else {
    let token = CommandLine.arguments.dropFirst().first ?? "none"
    let existingClass = lookupClass("NSObject") != nil
    let missingClass = lookupClass("CartographDefinitelyMissingClass") != nil
    let existingProtocol = lookupProtocol("NSCopying") != nil
    let missingProtocol = lookupProtocol("CartographDefinitelyMissingProtocol") != nil
    let missingSelector = makeSelector("cartographDefinitelyMissingSelector:")

    let handler = ProbeHandler()
    let zero = invokeWithoutArguments(on: handler, selector: makeSelector("description"))
    let one = invokeWithOneArgument(on: handler, selector: makeSelector("handle:"))
    let two = invokeWithTwoArguments(on: handler, selector: makeSelector("handle:second:"))
    let classCall = invokeClass(selector: makeSelector("classGreeting"))
    invokeIgnoringReturn(on: handler, selector: makeSelector("markVoid"))
    invokeIgnoringReturn(on: handler, selector: makeSelector("primitiveValue"))

    let observer = ProbeObserver()
    let notificationName = Notification.Name("CartographRuntimeCollection")
    registerObserver(observer, name: notificationName, selector: makeSelector("receive:"))
    NotificationCenter.default.post(name: notificationName, object: nil)
    NotificationCenter.default.removeObserver(observer)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--child-only"]
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    try child.run()
    child.waitUntilExit()

    print("stdout:\(token)")
    print("class=\(existingClass),missingClass=\(missingClass)")
    print("protocol=\(existingProtocol),missingProtocol=\(missingProtocol)")
    print("selector=\(NSStringFromSelector(missingSelector))")
    print("perform=\(zero),\(one),\(two),class=\(classCall)")
    print("ignoredReturns=void:\(handler.voidCalled),primitive:\(handler.primitiveCalled)")
    print("notification=\(observer.received),childExit=\(child.terminationStatus)")
    FileHandle.standardError.write(Data("stderr:\(token)\n".utf8))
    if token == "pause", CommandLine.arguments.count > 2 {
        let readyURL = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            try Data("ready".utf8).write(to: readyURL)
        } catch {
            FileHandle.standardError.write(Data("ready-file-error\n".utf8))
            exit(9)
        }
    }
    if token == "timeout" || token == "pause" {
        Thread.sleep(forTimeInterval: 2)
    }
    if token == "fail" {
        exit(7)
    }
}
