import CartographAnalysis
import CartographCore
import CartographIndexStore
@testable import CartographKit
import CartographTestSupport
import Dispatch
import Foundation
import Testing

/// 프레임워크 전체의 의존성 모델을 보장하지 않고 실제 컴파일러 입력을 확인한다.
/// 일반 macOS CI 툴체인의 두 프레임워크를 사용하며 외부 패키지는 내려받지 않는다.
@Suite("실제 테스트 프레임워크의 컴파일러 근거", .serialized)
struct TestFrameworkCompilerEvidenceTests: Sendable {
    @Test("XCTest와 Swift Testing의 원시 속성과 생성 참조를 구문 보강 전에 기록한다")
    func capturesFrameworkEvidence() async throws {
        let fixture = try await blocking { try self.compile() }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try await blocking {
            try IndexStoreProvider(configuration: .init(
                storePath: fixture.store,
                databasePath: fixture.root.appendingPathComponent("UnusedDB").path,
                libraryPath: fixture.library,
                sourceRoots: [fixture.root.path], includeExternalSymbols: true, readerMode: .raw
            )).loadSnapshot()
        }
        let confirmation = try await blocking {
            try IndexStoreProvider(configuration: .init(
                storePath: fixture.store,
                databasePath: fixture.root.appendingPathComponent("UnusedDB").path,
                libraryPath: fixture.library,
                sourceRoots: [fixture.root.path], includeExternalSymbols: true, readerMode: .raw
            )).loadSnapshot()
        }
        let rootPath = try LocalFileSystem().realPath(at: fixture.root.path)
        let receipt = SwiftPMTargetEvidenceDocument(
            packageRoot: rootPath, descriptionPath: rootPath + "/description.json",
            toolchain: fixture.toolchain, configuration: "debug",
            describeArguments: ["swift", "package", "describe", "--type", "json"],
            buildArguments: ["swift", "build", "--package-path", rootPath,
                "--scratch-path", rootPath + "/.build", "--configuration", "debug",
                "--build-tests", "--enable-index-store", "--jobs", "2"],
            before: fixture.targetInputsBefore, after: fixture.targetInputsAfter,
            snapshotBefore: try SwiftPMTargetEvidenceStore.snapshotIdentity(snapshot),
            snapshotAfter: try SwiftPMTargetEvidenceStore.snapshotIdentity(confirmation)
        )
        let receiptEncoder = JSONEncoder()
        receiptEncoder.outputFormatting = [.sortedKeys]
        FileHandle.standardError.write(Data("SwiftPMTargetEvidence ".utf8)
            + (try receiptEncoder.encode(receipt)) + Data("\n".utf8))
        let targets = try SwiftPMTargetEvidenceStore().verify(receipt, snapshot: snapshot)
        let membership = TestTargetMembershipFacts(snapshot: snapshot, targets: targets)
        // 실제 빌드에서 나온 두 describe와 소스/인덱스 관찰만 묶는다. 일반 생산자 CLI는 아니다.
        #expect(receipt.before == receipt.after && receipt.snapshotBefore == receipt.snapshotAfter)
        let local = snapshot.symbols.filter {
            $0.location.path == fixture.productionPath || $0.location.path == fixture.testPath
        }
        // 빈 입력으로 통과하지 않으며 이름 추정으로 컴파일러 근거를 만들지 않는다.
        for name in ["ProductionProbe", "testConnection", "BaseCase", "AsyncCase", "testAsync",
                     "ShapeCase", "testStatic", "testClass", "testReturnsValue", "testArgument",
                     "ModernSuite", "asyncCase", "parameterized", "QualifiedSuite", "qualifiedCase",
                     "argumentProvider", "suiteInitHelper", "providerHelper", "lifecycleHelper",
                     "xctestHelper", "modernHelper", "qualifiedHelper", "productionHelper"] {
            let matches = local.filter { $0.name.split(separator: "(").first.map(String.init) == name }
            #expect(Set(matches.map(\.usr)).count == 1, "Missing or ambiguous compiler declaration: \(name)")
        }
        // Swift 6.3.3의 실제 수집에서 확인한 두 프레임워크의 차이를 별도 필드로 보존한다.
        for name in ["BaseCase", "AsyncCase", "testAsync()"] {
            let declaration = try #require(local.first { !$0.isExternal && $0.name == name })
            #expect(declaration.compilerUnitTest == true)
        }
        for name in ["ProductionProbe", "testConnection()", "ModernSuite", "QualifiedSuite",
                     "asyncCase()", "parameterized(_:)", "qualifiedCase()"] {
            let declaration = try #require(local.first { !$0.isExternal && $0.name == name })
            #expect(declaration.compilerUnitTest == false)
        }
        let identity = XCTestIdentityFacts(snapshot: snapshot)
        let expectedClasses = Set(local.filter {
            ["BaseCase", "AsyncCase", "ShapeCase", "DuplicateCase"].contains($0.name)
        }.map(\.usr))
        let expectedMethods = Set(local.filter { ["testAsync()", "testShared()"].contains($0.name) }.map(\.usr))
        #expect(expectedClasses.count == 5 && expectedMethods.count == 3)
        #expect(identity.classUSRs == expectedClasses)
        #expect(identity.methodUSRs == expectedMethods)
        let negativeMethods = Set(local.filter {
            ["testStatic()", "testClass()", "testReturnsValue()", "testArgument(_:)"].contains($0.name)
        }.map(\.usr))
        #expect(negativeMethods.count == 4)
        #expect(identity.uncertainUSRs.isSubset(of: negativeMethods))
        // 표시 이름이 같아도 컴파일러 USR·모듈·소유자 신원은 합치지 않는다.
        let graph = GraphBuilder(options: .init(level: .symbol, includeExternal: false)).build(from: snapshot)
        let query = GraphQueryIndex(graph: graph)
        for (name, kind) in [("DuplicateCase", SymbolKind.classType),
                             ("testShared()", .method), ("value", .property)] {
            let declarations = local.filter { !$0.isExternal && $0.name == name && $0.kind == kind }
            #expect(declarations.count == 2)
            #expect(Set(declarations.map(\.usr)).count == 2)
            #expect(Set(declarations.map(\.module)) == ["Probe", "ProbeTests"])
            guard case let .ambiguous(candidates) = query.resolve(name) else {
                Issue.record("동명 선언은 임의 선택하지 않고 두 후보를 반환해야 한다: \(name)")
                continue
            }
            #expect(Set(candidates.map(\.id)) == Set(declarations.map { NodeID($0.usr) }))
            for declaration in declarations {
                let subject = kind == .classType
                    ? "\(declaration.module).DuplicateCase"
                    : "\(declaration.module).DuplicateCase.\(name)"
                guard case let .found(selected) = query.resolve(subject) else {
                    Issue.record("모듈 한정 이름으로 원래 선언을 찾아야 한다: \(subject)")
                    continue
                }
                #expect(selected.usr == declaration.usr)
                #expect(selected.module == declaration.module)
                #expect(query.resolve(declaration.usr) == .found(selected))
            }
        }
        for module in ["Probe", "ProbeTests"] {
            let owner = try #require(local.first { $0.module == module && $0.name == "DuplicateCase" })
            let method = try #require(local.first { $0.module == module && $0.name == "testShared()" })
            let property = try #require(local.first { $0.module == module && $0.name == "value" })
            #expect(method.parentUSR == owner.usr && property.parentUSR == owner.usr)
            #expect(method.compilerUnitTest == true)
            #expect(identity.methodUSRs.contains(method.usr))
            if module == "ProbeTests" {
                #expect(membership.testUSRs.contains(method.usr))
                #expect(!membership.ordinaryUSRs.contains(method.usr))
            } else {
                #expect(membership.ordinaryUSRs.contains(method.usr))
                #expect(!membership.testUSRs.contains(method.usr))
            }
            #expect(snapshot.references.contains {
                $0.sourceUSR == method.usr && $0.targetUSR == property.usr && $0.origin == .compiler
            })
            let otherProperties = Set(local.filter { $0.module != module && $0.name == "value" }.map(\.usr))
            #expect(!snapshot.references.contains {
                $0.sourceUSR == method.usr && otherProperties.contains($0.targetUSR)
            })
        }
        // Probe는 일반 라이브러리다. 그 메서드의 프레임워크 신원은 테스트 타깃 소속 증명이 아니다.
        for (caller, callee) in [
            ("testConnection", "productionHelper"), ("setUp", "lifecycleHelper"),
            ("testAsync", "xctestHelper"), ("asyncCase", "modernHelper"),
            ("qualifiedCase", "qualifiedHelper"), ("argumentProvider", "providerHelper"),
        ] {
            let sources = Set(local.filter { $0.name.hasPrefix(caller + "(") }.map(\.usr))
            let targets = Set(local.filter { $0.name.hasPrefix(callee + "(") }.map(\.usr))
            #expect(!sources.isEmpty && !targets.isEmpty)
            #expect(snapshot.references.contains {
                sources.contains($0.sourceUSR) && targets.contains($0.targetUSR)
                    && $0.kind == .call && $0.origin == .compiler
            }, "Missing explicit compiler call \(caller) -> \(callee)")
        }
        let suite = try #require(local.first { $0.name == "ModernSuite" && $0.kind == .classType })
        let initializers = Set(local.filter { $0.parentUSR == suite.usr && $0.kind == .initializer }.map(\.usr))
        let initHelpers = Set(local.filter { $0.name == "suiteInitHelper()" }.map(\.usr))
        #expect(!initializers.isEmpty && !initHelpers.isEmpty)
        #expect(snapshot.references.contains {
            initializers.contains($0.sourceUSR) && initHelpers.contains($0.targetUSR) && $0.kind == .call
        })
        let base = try #require(local.first { $0.name == "BaseCase" && $0.kind == .classType })
        let inheritance = snapshot.references.filter { $0.sourceUSR == base.usr && $0.kind == .inheritance }
        #expect(!inheritance.isEmpty, "XCTest ancestry must come from compiler relations")
        // 명시한 소스에서 읽힌 관계와 SDK 대상의 정확한 신원을 남긴다.
        // 빌드 산출물 아래 생성 파일은 공급자에서 제외되므로 runner 전체를 포괄한다고 주장하지 않는다.
        // unitTest 속성과 생성된 provider/init 소유 관계는 관찰 전에 추측하여 단언하지 않는다.
        let localUSRs = Set(local.map(\.usr))
        let references = snapshot.references.filter {
            localUSRs.contains($0.sourceUSR) || localUSRs.contains($0.targetUSR)
        }
        let relatedUSRs = Set(references.flatMap { [$0.sourceUSR, $0.targetUSR] }).union(localUSRs)
        let symbols = snapshot.symbols.filter { relatedUSRs.contains($0.usr) }
        let symbolRows: [[String: Any]] = symbols.map {
            ["usr": $0.usr, "name": $0.name, "kind": $0.kind.rawValue, "module": $0.module,
             "parentUSR": $0.parentUSR ?? "", "external": $0.isExternal,
             "attributes": $0.attributes.map(\.rawValue).sorted(),
             "file": fixture.label($0.location.path), "line": $0.location.line]
        }
        let referenceRows: [[String: Any]] = references.map {
            ["sourceUSR": $0.sourceUSR, "targetUSR": $0.targetUSR, "kind": $0.kind.rawValue,
             "origin": $0.origin.rawValue, "file": $0.location.map { fixture.label($0.path) } ?? "",
             "line": $0.location?.line ?? 0]
        }
        let evidence: [String: Any] = [
            "schema": 1, "scope": "macOS active SwiftPM toolchain; admitted source records before enrichment; generated build files excluded; negative XCTest shapes indexed in ordinary library target",
            "toolchain": fixture.toolchain, "symbols": sortedRows(symbolRows),
            "references": sortedRows(referenceRows),
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        FileHandle.standardError.write(Data("TestFrameworkCompilerEvidence ".utf8) + data + Data("\n".utf8))
    }

    private func sortedRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.sorted {
            let left = (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) ?? Data()
            let right = (try? JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys])) ?? Data()
            return left.lexicographicallyPrecedes(right)
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let productionPath: String
        let testPath: String
        let store: String
        let library: String
        let toolchain: String
        let targetInputsBefore: SwiftPMTargetEvidenceDocument.Inputs
        let targetInputsAfter: SwiftPMTargetEvidenceDocument.Inputs

        func label(_ path: String) -> String {
            if path == productionPath { return "Sources/Probe/Probe.swift" }
            if path == testPath { return "Tests/ProbeTests/Frameworks.swift" }
            return "<external-or-generated>"
        }
    }

    private func compile() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-test-frameworks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let production = root.appendingPathComponent("Sources/Probe/Probe.swift")
            let tests = root.appendingPathComponent("Tests/ProbeTests/Frameworks.swift")
            for file in [production, tests] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            }
            let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "TestFrameworkEvidence", platforms: [.macOS(.v14)],
                targets: [.target(name: "Probe"), .testTarget(name: "ProbeTests", dependencies: ["Probe"])])
            """
            try Data(manifest.utf8).write(to: root.appendingPathComponent("Package.swift"))
            try Data(Self.production.utf8).write(to: production)
            try Data(Self.tests.utf8).write(to: tests)
            // 권한 불명확 상태는 실패로 남기고 실제 ESRCH 관찰만 종료로 인정한다.
            let probeChecks = try run(["/usr/bin/env", "python3", "-I", "-S", "-c",
                Self.supervisor, "--probe-tests"], in: root, timeout: 5, usesXcrun: false)
            FileHandle.standardError.write(Data(probeChecks.utf8))
            // 같은 감독 코드로 자식이 남는 시간 초과도 실제 확인한다.
            _ = try run(["/usr/bin/env", "python3", "-I", "-S", "-c", Self.timeoutProbe],
                in: root, timeout: 1, expected: 124, usesXcrun: false)
            let toolchain = try run(["swift", "--version"], in: root)
            let compiler = try run(["--find", "swiftc"], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let library = URL(fileURLWithPath: compiler).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("lib/libIndexStore.dylib").path
            let canonicalRoot = try LocalFileSystem().realPath(at: root.path)
            let evidenceStore = SwiftPMTargetEvidenceStore()
            let descriptionBefore = Data(try run(
                ["swift", "package", "describe", "--type", "json"], in: root).utf8)
            let inputsBefore = try evidenceStore.inputs(description: descriptionBefore, root: canonicalRoot)
            let common = ["swift", "build", "--package-path", canonicalRoot,
                          "--scratch-path", canonicalRoot + "/.build", "--configuration", "debug"]
            _ = try run(common + ["--build-tests", "--enable-index-store", "--jobs", "2"], in: root)
            let descriptionAfter = Data(try run(
                ["swift", "package", "describe", "--type", "json"], in: root).utf8)
            let inputsAfter = try evidenceStore.inputs(description: descriptionAfter, root: canonicalRoot)
            guard inputsBefore == inputsAfter else {
                throw CommandError.failed("SwiftPM description or producer inputs changed during the build.")
            }
            try descriptionAfter.write(to: root.appendingPathComponent("description.json"))
            let fileSystem = LocalFileSystem()
            let locator = IndexStoreLocator(fileSystem: fileSystem)
            let store = try locator.locate(explicitPath: nil, projectPath: root.path)
            let checkedLibrary = try locator.locateLibrary(explicitPath: library, developerDirectory: nil)
            return Fixture(root: root, productionPath: try fileSystem.realPath(at: production.path),
                testPath: try fileSystem.realPath(at: tests.path), store: store, library: checkedLibrary,
                toolchain: toolchain.trimmingCharacters(in: .whitespacesAndNewlines),
                targetInputsBefore: inputsBefore, targetInputsAfter: inputsAfter)
        } catch {
            // 종료 소유권이 확인되지 않았다면 실행 중일 수 있는 파일을 지우지 않는다.
            if case CommandError.cleanupUnverified = error {} else {
                try? FileManager.default.removeItem(at: root)
            }
            throw error
        }
    }

    private enum CommandError: Error {
        case cleanupUnverified(String)
        case failed(String)
    }

    private struct CommandReceipt: Decodable {
        let returncode: Int
        let timedOut: Bool
        let reaped: Bool
        let groupGone: Bool
        let python: String
        let group: Int
        let groupObservations: [String]
    }

    private func run(
        _ arguments: [String], in root: URL, timeout: Int = 120, expected: Int = 0,
        usesXcrun: Bool = true
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = root
        let receiptPath = root.appendingPathComponent("receipt-\(UUID().uuidString).json")
        let command = (usesXcrun ? ["/usr/bin/xcrun"] : []) + arguments
        process.arguments = ["python3", "-I", "-S", "-c", Self.supervisor,
                             receiptPath.path, String(timeout)] + command
        // 자식이 파이프를 붙잡아도 읽기가 멈추지 않도록 파일에 기록한다.
        let log = root.appendingPathComponent("command-\(UUID().uuidString).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + .seconds(timeout + 15)) == .success else {
            // 감독 자체가 응답하지 않으면 소유 그룹의 정리를 증명할 수 없다.
            throw CommandError.cleanupUnverified("Supervisor did not finish; preserved \(root.path)")
        }
        let message = try String(contentsOf: log, encoding: .utf8)
        let receiptText = (try? String(contentsOf: receiptPath, encoding: .utf8)) ?? "<missing>"
        guard let data = try? Data(contentsOf: receiptPath),
              let receipt = try? JSONDecoder().decode(CommandReceipt.self, from: data),
              receipt.reaped, receipt.groupGone else {
            throw CommandError.cleanupUnverified("Cleanup not verified; preserved \(root.path)\nReceipt: \(receiptText)\n\(message)")
        }
        if expected == 124 {
            let proof = message.split(separator: "\n").first { $0.hasPrefix("TimeoutProbe ") }
            let fields = proof?.split(separator: " ") ?? []
            guard fields.count == 3,
                  let child = Int(fields[1].dropFirst("child=".count)), child > 0,
                  fields[2] == "group=\(receipt.group)" else {
                throw CommandError.failed("Timeout control did not prove a spawned child in the owned group")
            }
        }
        FileHandle.standardError.write(Data(
            "TestFrameworkCommand python=\(receipt.python) exit=\(receipt.returncode) timeout=\(receipt.timedOut) reaped=true groupGone=true observations=\(receipt.groupObservations)\n".utf8
        ))
        guard process.terminationStatus == 0, receipt.returncode == expected,
              receipt.timedOut == (expected == 124) else {
            throw CommandError.failed("Command failed: \(arguments)\n\(message)")
        }
        return message
    }

    // 별도 세션으로 만든 그룹만 종료한다. 테스트 실행기나 다른 작업의 그룹에는 신호를 보내지 않는다.
    private static let supervisor = """
    import json, os, signal, subprocess, sys, time
    def probe_group(group, send=os.killpg):
        try:
            send(group, 0)
            return "alive"
        except ProcessLookupError:
            return "gone"
        except PermissionError:
            return "unknown"
    def wait_gone(probe, deadline, now=time.monotonic, pause=time.sleep):
        while True:
            state = probe()
            if state == "gone":
                return True
            if now() >= deadline:
                return False
            pause(min(0.02, max(0, deadline - now())))
    def signal_owned(process, group, value, probe=probe_group, send=os.killpg, get_group=os.getpgid):
        if process.poll() is not None or probe(group) != "alive":
            return False
        try:
            if get_group(process.pid) != group:
                return False
            send(group, value)
            return True
        except (ProcessLookupError, PermissionError):
            return False
    if sys.argv[1] == "--probe-tests":
        def denied(group, value):
            raise PermissionError()
        def missing(group, value):
            raise ProcessLookupError()
        assert probe_group(1, denied) == "unknown"
        assert probe_group(1, missing) == "gone"
        clock = [0.0]
        def pause(delta):
            clock[0] += delta
        assert not wait_gone(lambda: "unknown", 0.05, lambda: clock[0], pause)
        assert clock[0] == 0.05
        clock[0] = 0.0
        states = iter(["unknown", "unknown", "gone"])
        assert wait_gone(lambda: next(states), 0.05, lambda: clock[0], pause)
        assert clock[0] <= 0.05
        class Leader:
            pid = 1
            def poll(self):
                return None
        sent = []
        assert not signal_owned(Leader(), 1, signal.SIGKILL,
            probe=lambda _: "unknown", send=lambda *args: sent.append(args))
        assert not signal_owned(Leader(), 1, signal.SIGKILL,
            probe=lambda _: "alive", send=lambda *args: sent.append(args), get_group=lambda _: 2)
        assert not sent
        print("SupervisorProbeTests persistentUnknown=failed transientUnknownThenESRCH=passed unknownSignal=blocked")
        sys.exit(0)
    receipt, timeout = sys.argv[1], int(sys.argv[2])
    process = subprocess.Popen(sys.argv[3:], start_new_session=True)
    group = process.pid
    observations = set()
    def observe():
        state = probe_group(group)
        observations.add(state)
        return state
    timed_out = False
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out, code = True, 124
    if observe() != "gone":
        signal_owned(process, group, signal.SIGTERM)
        gone = wait_gone(observe, time.monotonic() + 1)
        if not gone:
            signal_owned(process, group, signal.SIGKILL)
    reaped = True
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        reaped = False
    gone = wait_gone(observe, time.monotonic() + 3)
    with open(receipt, "w") as stream:
        json.dump(dict(returncode=code, timedOut=timed_out, reaped=reaped,
                       groupGone=gone, groupObservations=sorted(observations),
                       python=sys.version.split()[0], group=group), stream)
    sys.exit(0 if reaped and gone else 125)
    """

    // 부모와 자식이 TERM을 무시해도 감독이 전용 그룹을 KILL하고 회수해야 한다.
    private static let timeoutProbe = """
    import os, signal, subprocess, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-I", "-S", "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"])
    print("TimeoutProbe child=" + str(child.pid) + " group=" + str(os.getpgid(child.pid)), flush=True)
    time.sleep(60)
    """

    // Process와 raw IndexStore는 cooperative executor 밖에서 기다린다.
    // 단언은 원래 테스트 태스크에 남기며 reader 전체 시간은 일반 coverage CI가 제한한다.
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // 잘못된 실행 형태는 일반 타깃에서 인덱싱해 SwiftPM 테스트 발견 코드의 컴파일과 분리한다.
    private static let production = """
    import XCTest

    public func productionHelper() {}
    public final class ProductionProbe {
        public init() {}
        public func testConnection() { productionHelper() }
    }
    class DuplicateCase: XCTestCase {
        var value: Int { 1 }
        func testShared() { _ = value }
    }
    class ShapeCase: XCTestCase {
        static func testStatic() {}
        class func testClass() {}
        func testReturnsValue() -> Int { 1 }
        func testArgument(_ value: Int) {}
    }
    """

    private static let tests = """
    import Probe
    import XCTest
    import Testing

    func lifecycleHelper() {}
    func xctestHelper() {}
    func suiteInitHelper() {}
    func modernHelper() {}
    func qualifiedHelper() {}
    func providerHelper() -> [Int] { [1, 2] }
    func argumentProvider() -> [Int] { providerHelper() }

    class BaseCase: XCTestCase {
        override func setUp() { lifecycleHelper() }
    }
    class DuplicateCase: XCTestCase {
        var value: Int { 2 }
        func testShared() { _ = value }
    }
    final class AsyncCase: BaseCase {
        func testAsync() async throws { xctestHelper() }
    }
    @Suite final class ModernSuite {
        init() { suiteInitHelper() }
        @Test func asyncCase() async throws { modernHelper() }
        @Testing.Test(arguments: argumentProvider())
        func parameterized(_ value: Int) { #expect(value > 0) }
    }
    @Testing.Suite struct QualifiedSuite {
        @Testing.Test func qualifiedCase() { qualifiedHelper() }
    }
    """
}
