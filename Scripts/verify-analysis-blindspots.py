#!/usr/bin/env python3
"""실제 Swift 인덱스로 상수·IB·선택적 Needle 런타임 경계를 재현한다."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


CONSTANT_SOURCE = r'''func install() {
    let direct = "direct"
    let alias = direct
    let concat = "com.example/" + "camera"
    let parens = ("parenthesized")
    let channel1 = FlutterMethodChannel(name: direct, binaryMessenger: 0)
    let channel2 = FlutterMethodChannel(name: alias, binaryMessenger: 0)
    let channel3 = FlutterMethodChannel(name: concat, binaryMessenger: 0)
    let channel4 = FlutterMethodChannel(name: parens, binaryMessenger: 0)
    channel1.setMethodCallHandler { call, result in
        if call.method == "run" { result(1) }
    }
    channel2.setMethodCallHandler { call, result in
        if call.method == "run" { result(1) }
    }
    channel3.setMethodCallHandler { call, result in
        if call.method == "run" { result(1) }
    }
    channel4.setMethodCallHandler { call, result in
        if call.method == "run" { result(1) }
    }
}
install()
print(CompileTimeNames.used)
'''
STUB_SOURCE = '''struct FlutterMethodCall { let method: String }
struct FlutterMethodChannel {
    init(name: String, binaryMessenger: Int) {}
    func setMethodCallHandler(_ handler: (FlutterMethodCall, (Int) -> Void) -> Void) {}
}
'''
SCREEN_SOURCE = '''final class RuntimeScreen {}
final class DeadScreen {}
enum CompileTimeNames {
    static let used = "runtime-branch"
    static let unused = "unused"
}
'''
COMPONENT_SOURCE = '''import NeedleFoundation
final class LiveService { func run() -> String { "needle-ok" } }
final class DeadService { func unused() -> String { "dead" } }
protocol ChildDependency: Dependency { var service: LiveService { get } }
final class RootComponent: BootstrapComponent {
    var service: LiveService { shared { LiveService() } }
    var unusedValue: String { "unused" }
    var child: ChildComponent { ChildComponent(parent: self) }
}
final class ChildComponent: Component<ChildDependency> {
    func run() -> String { dependency.service.run() }
}
'''
# 공식 생성 코드의 등록 형태를 수기로 축소했다. generator 실행을 주장하지 않는다.
GENERATED_SOURCE = '''import NeedleFoundation
#if NEEDLE_DYNAMIC
extension RootComponent: Registration {
    func registerItems() { localTable["service-LiveService"] = { [unowned self] in self.service } }
}
extension ChildComponent: Registration {
    func registerItems() { keyPathToName[\\ChildDependency.service] = "service-LiveService" }
}
func registerProviderFactories() {}
#else
private final class ChildProvider: ChildDependency {
    private let root: RootComponent
    init(root: RootComponent) { self.root = root }
    var service: LiveService { root.service }
}
private func childFactory(_ component: Scope) -> AnyObject {
    ChildProvider(root: component.parent as! RootComponent)
}
private func emptyFactory(_ component: Scope) -> AnyObject { EmptyDependencyProvider(component: component) }
func registerProviderFactories() {
    __DependencyProviderRegistry.instance.registerDependencyProviderFactory(for: "^->RootComponent", emptyFactory)
    __DependencyProviderRegistry.instance.registerDependencyProviderFactory(
        for: "^->RootComponent->ChildComponent", childFactory)
}
#endif
'''


def write(root, relative, content):
    destination = root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content)


def run(command, root):
    return subprocess.run(command, cwd=root, check=True, capture_output=True, text=True, timeout=300).stdout


def build(root, scratch=".build", dynamic=False):
    command = ["swift", "build", "--scratch-path", scratch]
    if dynamic:
        command += ["-Xswiftc", "-DNEEDLE_DYNAMIC"]
    write(root, scratch.removeprefix(".") + ".log", run(command, root))
    # Xcode SwiftPM은 요청 플래그 대신 실제 out 스토어를 사용한다.
    return root / scratch / "out"


def query(binary, root, subject, store):
    command = [str(binary), "query", subject, "--project", str(root), "--index-store", str(store)]
    document = json.loads(run(command, root))
    if document.get("status") == "ambiguous":
        candidate = next(item for item in document["candidates"] if item["kind"] != "extension")
        return query(binary, root, candidate["usr"], store)
    return document


def state(document):
    return document["result"]["reachability"]["state"]


def constants_and_ib(binary, root):
    write(root, "Package.swift", '// swift-tools-version: 6.0\nimport PackageDescription\n'
          'let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")])\n')
    write(root, "Sources/Probe/main.swift", CONSTANT_SOURCE)
    write(root, "Sources/Probe/Stub.swift", STUB_SOURCE)
    write(root, "Sources/Probe/Screens.swift", SCREEN_SOURCE)
    storyboard = ('<document><viewController storyboardIdentifier="runtime-branch" '
                  'customClass="RuntimeScreen"/></document>')
    write(root, "Main.storyboard", storyboard)
    store = build(root)
    facts = json.loads(run([str(binary), "bridges", "--target", "flutter", "--project", str(root)], root))
    registrations = [(fact["channel"], fact["dynamic"]) for fact in facts["facts"]
                     if fact["kind"] == "channel-register"]
    expected = [("direct", False), ("direct", False), ("concat", True), ("parenthesized", False)]
    assert registrations == expected, registrations
    screen = query(binary, root, "RuntimeScreen", store)
    assert screen["result"]["reachability"].get("reason") == "interfaceBuilder", screen
    assert state(query(binary, root, "DeadScreen", store)) == "unreachable"
    constants = query(binary, root, "CompileTimeNames", store)
    members = [item for item in constants["result"]["members"] if item["name"] in ["used", "unused"]]
    assert {item["name"] for item in members} == {"used", "unused"}
    for member in members:
        observed = state(query(binary, root, member["usr"], store))
        assert observed == ("reachable" if member["name"] == "used" else "unreachable"), (member, observed)
    write(root, "Main.storyboard", '<document><viewController storyboardIdentifier="runtime-branch"/></document>')
    assert state(query(binary, root, "RuntimeScreen", store)) == "unreachable"
    write(root, "Main.storyboard", storyboard)
    write(root, "bridges.json", json.dumps(facts, indent=2))
    return {"constants": registrations, "storyboardClass": "retained", "identifierOnly": "unreachable"}


def needle(binary, root, source_root):
    shutil.copytree(source_root / "Sources/NeedleFoundation", root / "Sources/NeedleFoundation")
    write(root, "Package.swift", '// swift-tools-version: 5.10\nimport PackageDescription\n'
          'let package = Package(name: "NeedleProbe", platforms: [.macOS(.v14)], targets: ['
          '.target(name: "NeedleFoundation"), .executableTarget(name: "App", dependencies: ["NeedleFoundation"])], '
          'swiftLanguageVersions: [.v5])\n')
    write(root, "Sources/App/Components.swift", COMPONENT_SOURCE)
    write(root, "Sources/App/NeedleGenerated.swift", GENERATED_SOURCE)
    write(root, "Sources/App/main.swift", 'registerProviderFactories()\nprint(RootComponent().child.run())\n')
    configuration = 'include:\n  - "Sources/App/**"\n'
    write(root, ".cartograph.yml", configuration)
    results = {}
    for mode in ["static", "dynamic"]:
        store = build(root, ".build-" + mode, dynamic=mode == "dynamic")
        assert run([str(store / "Products/Debug/App")], root).strip() == "needle-ok"
        component = query(binary, root, "RootComponent", store)
        member = next(item for item in component["result"]["members"] if item["name"] == "service")
        service = query(binary, root, member["usr"], store)
        assert state(service) == "reachable", service
        assert state(query(binary, root, "DeadService", store)) == "unreachable"
        results[mode] = {"runtime": "needle-ok", "service": "reachable", "deadService": "unreachable"}
        write(root, mode + "-service.json", json.dumps(service, indent=2))
        if mode == "static":
            write(root, ".cartograph.yml", configuration + 'exclude:\n  - "Sources/App/NeedleGenerated.swift"\n')
            filtered = query(binary, root, member["usr"], store)
            assert state(filtered) == "unreachable", filtered
            assert any(item.startswith("configured-path-filter:") for item in filtered["limitations"])
            results["generatedFileExcluded"] = "unreachable with configured-path-filter limitation"
            write(root, "filtered-service.json", json.dumps(filtered, indent=2))
            write(root, ".cartograph.yml", configuration)
    return results



INTERPROCEDURAL_SUPPORT = '''struct FlutterMethodCall { let method: String }
struct FlutterMethodChannel {
    let name: String
    init(name: String, binaryMessenger: Int) { self.name = name }
    func setMethodCallHandler(_ body: (FlutterMethodCall, (Int) -> Void) -> Void) { print(name) }
}
func identity(_ value: String) -> String { value }
func literalName() -> String { "literal-return" }
func nestedName() -> String { literalName() }
func callbackName(_ callback: () -> String) -> String { callback() }
func recursiveName(_ depth: Int) -> String { depth == 0 ? "recursive" : recursiveName(depth - 1) }
func asyncName() async -> String { "async" }
func overwrite(_ value: inout String) { value = "overwritten" }
protocol NameProvider { func name() -> String }
struct ProviderA: NameProvider { func name() -> String { "provider-A" } }
struct ProviderB: NameProvider { func name() -> String { "provider-B" } }
func dispatchName(_ provider: any NameProvider) -> String { provider.name() }
func callbackLeaf() -> String { "callback" }
func leaf() { print("leaf") }
func middle() { leaf() }
func unusedLeaf() {}
func dropInput(_ input: String) -> String { "fixed" }
'''
INTERPROCEDURAL_SCENARIOS = '''func runScenarios() async {
    middle()
    let control = "control"
    let controlChannel = FlutterMethodChannel(name: control, binaryMessenger: 0)
    controlChannel.setMethodCallHandler { call, result in
        if call.method == "control" { result(1) }
    }
    let literalReturn = literalName()
    let literalReturnChannel = FlutterMethodChannel(name: literalReturn, binaryMessenger: 0)
    literalReturnChannel.setMethodCallHandler { call, result in
        if call.method == "literalReturn" { result(1) }
    }
    let identityA = identity("A")
    let identityAChannel = FlutterMethodChannel(name: identityA, binaryMessenger: 0)
    identityAChannel.setMethodCallHandler { call, result in
        if call.method == "identityA" { result(1) }
    }
    let identityB = identity("B")
    let identityBChannel = FlutterMethodChannel(name: identityB, binaryMessenger: 0)
    identityBChannel.setMethodCallHandler { call, result in
        if call.method == "identityB" { result(1) }
    }
    let nestedReturn = nestedName()
    let nestedReturnChannel = FlutterMethodChannel(name: nestedReturn, binaryMessenger: 0)
    nestedReturnChannel.setMethodCallHandler { call, result in
        if call.method == "nestedReturn" { result(1) }
    }
    let callbackReturn = callbackName(callbackLeaf)
    let callbackReturnChannel = FlutterMethodChannel(name: callbackReturn, binaryMessenger: 0)
    callbackReturnChannel.setMethodCallHandler { call, result in
        if call.method == "callbackReturn" { result(1) }
    }
    let recursiveReturn = recursiveName(2)
    let recursiveReturnChannel = FlutterMethodChannel(name: recursiveReturn, binaryMessenger: 0)
    recursiveReturnChannel.setMethodCallHandler { call, result in
        if call.method == "recursiveReturn" { result(1) }
    }
    let protocolReturn = dispatchName(ProviderA())
    let protocolReturnChannel = FlutterMethodChannel(name: protocolReturn, binaryMessenger: 0)
    protocolReturnChannel.setMethodCallHandler { call, result in
        if call.method == "protocolReturn" { result(1) }
    }
    let asyncReturn = await asyncName()
    let asyncReturnChannel = FlutterMethodChannel(name: asyncReturn, binaryMessenger: 0)
    asyncReturnChannel.setMethodCallHandler { call, result in
        if call.method == "asyncReturn" { result(1) }
    }
    let discardedInput = dropInput(identity("unused-input"))
    FlutterMethodChannel(name: discardedInput, binaryMessenger: 0).setMethodCallHandler { call, result in
        if call.method == "discardedInput" { result(1) }
    }
    var mutable = "before"
    overwrite(&mutable)
    FlutterMethodChannel(name: mutable, binaryMessenger: 0).setMethodCallHandler { call, result in
        if call.method == "mutated" { result(1) }
    }
    registerName("wrapped-A")
    registerName("wrapped-B")
}
func registerName(_ name: String) {
    FlutterMethodChannel(name: name, binaryMessenger: 0).setMethodCallHandler { call, result in
        if call.method == "wrapped" { result(1) }
    }
}
'''


def interprocedural(binary, root):
    write(root, "Package.swift", '// swift-tools-version: 5.10\nimport PackageDescription\n'
          'let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")], '
          'swiftLanguageVersions: [.v5])\n')
    write(root, "Sources/Probe/Support.swift", INTERPROCEDURAL_SUPPORT)
    write(root, "Sources/Probe/Scenarios.swift", INTERPROCEDURAL_SCENARIOS)
    write(root, "Sources/Probe/App.swift", '@main struct App { static func main() async { await runScenarios() } }\n')
    store = build(root)
    runtime = run([str(store / "Products/Debug/Probe")], root).splitlines()
    assert runtime == ["leaf", "control", "literal-return", "A", "B", "literal-return", "callback",
                       "recursive", "provider-A", "async", "fixed", "overwritten", "wrapped-A", "wrapped-B"], runtime
    facts = json.loads(run([str(binary), "bridges", "--target", "flutter", "--project", str(root)], root))
    methods = [fact for fact in facts["facts"] if fact["kind"] == "method-handle"]
    assert len(methods) == 12, methods
    assert len([fact for fact in methods if fact["method"] == "wrapped"]) == 1
    expected_channels = {"control": "control", "literalReturn": "literal-return",
        "identityA": "A", "identityB": "B", "nestedReturn": "literal-return", "callbackReturn": "callback",
        "recursiveReturn": "recursive", "protocolReturn": "provider-A", "asyncReturn": "async",
        "discardedInput": "fixed", "mutated": "overwritten"}
    for fact in methods:
        assert fact["dynamic"] == (fact["method"] == "wrapped"), fact
        if fact["method"] in expected_channels:
            assert fact["channel"] == expected_channels[fact["method"]], fact
    assert any(item.startswith("dynamic-method-names: 1 ") and "channel or method name" in item
               for item in facts["limitations"]), facts["limitations"]
    wrapped = json.loads(run([str(binary), "dataflow", "registerName", "--project", str(root)], root))
    selected = set(wrapped["selectedContexts"])
    names = {atom["literal"]["_0"]["string"]["_0"]
             for context in wrapped["graph"]["contexts"] if context["id"] in selected
             for atom in context["arguments"][0]["atoms"]}
    assert names == {"wrapped-A", "wrapped-B"}, wrapped
    assert not wrapped["graph"]["truncated"], wrapped
    write(root, "wrapped-contexts.json", json.dumps(wrapped, indent=2))
    observations = {}
    for subject in ["leaf", "middle", "callbackLeaf", "recursiveName", "unusedLeaf", "ProviderA", "ProviderB"]:
        document = query(binary, root, subject, store)
        expected = "unreachable" if subject in ["unusedLeaf", "ProviderB"] else "reachable"
        assert state(document) == expected, (subject, document)
        observations[subject] = document["result"]["reachability"]
        if subject in ["ProviderA", "ProviderB"]:
            method = next(item for item in document["result"]["members"] if item["name"] == "name()")
            method_document = query(binary, root, method["usr"], store)
            assert state(method_document) == expected, method_document
            observations[subject + ".name"] = method_document["result"]["reachability"]
    assert observations["leaf"]["path"] == ["Probe.main()", "Probe.runScenarios()", "Probe.middle()", "Probe.leaf()"]
    write(root, "bridges.json", json.dumps(facts, indent=2))
    write(root, "runtime.json", json.dumps(runtime, indent=2))
    write(root, "reachability.json", json.dumps(observations, indent=2))
    return {"runtimeValues": runtime[1:], "sourceMethodFacts": len(methods),
            "unresolvedValueFacts": 1, "symbolReachability": observations}

def contextual_literals(binary, root):
    write(root, "Package.swift", '// swift-tools-version: 5.10\nimport PackageDescription\n'
          'let package = Package(name: "LiteralProbe", targets: [.executableTarget(name: "LiteralProbe")])\n')
    write(root, "Sources/LiteralProbe/App.swift", '''
struct Token: ExpressibleByStringLiteral {
    let value: String
    init(stringLiteral value: String) { self.value = "converted" }
}
func nativeString() -> String { "source" }
func convertedString() -> Token { "source" }
func staticString() -> StaticString { "source" }
func acceptsStatic(_ value: StaticString) -> StaticString { value }
func capturedString() -> String {
    var value = "before"
    let body = { [value] in value }
    value = "after"
    return body()
}
@main struct App {
    static func main() {
        print(nativeString())
        print(convertedString().value)
        print(staticString())
        print(acceptsStatic("source"))
        print(capturedString())
    }
}
''')
    store = build(root)
    runtime = run([str(store / "Products/Debug/LiteralProbe")], root).splitlines()
    assert runtime == ["source", "converted", "source", "source", "before"], runtime
    results = {}
    for name in ["nativeString", "convertedString", "staticString", "acceptsStatic", "capturedString"]:
        document = json.loads(run([str(binary), "dataflow", name, "--project", str(root)], root))
        contexts = [context for context in document["graph"]["contexts"]
                    if context["id"] in document["selectedContexts"]]
        assert contexts and not document["graph"]["truncated"], document
        if name in ["nativeString", "capturedString"]:
            expected_string = "before" if name == "capturedString" else "source"
            assert all(context["result"]["atoms"] == [{"literal": {"_0": {"string": {"_0": expected_string}}}}]
                       and not context["result"]["unknownReasons"] for context in contexts), contexts
        else:
            assert all(context["result"]["unknownReasons"] for context in contexts), contexts
        results[name] = [context["result"] for context in contexts]
    write(root, "runtime.json", json.dumps(runtime, indent=2))
    write(root, "value-results.json", json.dumps(results, indent=2))
    return {"nativeString": "source", "customLiteral": "unknown", "staticString": "unknown"}


def main():
    parser = argparse.ArgumentParser(description="Verify bounded analysis cases with real Swift indices; no downloads.")
    parser.add_argument("binary", type=Path)
    parser.add_argument("--needle-source", type=Path, help="Needle checkout containing Sources/NeedleFoundation")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="cartograph-analysis-probe-"))
    binary = args.binary.resolve()
    results = {"local": constants_and_ib(binary, root / "local"),
               "interprocedural": interprocedural(binary, root / "interprocedural"),
               "contextualLiterals": contextual_literals(binary, root / "contextual-literals")}
    if args.needle_source:
        results["needle"] = needle(binary, root / "needle", args.needle_source.resolve())
    else:
        results["needle"] = "not run: supply --needle-source"
    write(root, "results.json", json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    print("Evidence:", root)


if __name__ == "__main__":
    main()
