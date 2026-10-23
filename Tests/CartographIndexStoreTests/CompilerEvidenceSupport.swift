import CartographCore
import Dispatch
import Foundation
import IndexStoreDB

/// Test-only compiler execution and raw occurrence encoding shared by native evidence fixtures.
/// This keeps the selected-toolchain, process ownership and output budgets identical.
enum CompilerEvidenceSupport {
    /// 기존 계측 supervisor가 소유한 compiler 프로세스 그룹만 deadline/출력 예산으로 관리한다.
    /// Swift 쪽도 supervisor 완료를 유한하게 기다린다. 소유권이 불명확하면 임의 kill하지 않는다.
    static func compile(_ arguments: [String], in root: URL, repo: URL, logs: URL) throws -> String {
        let request = CompileRequest(arguments: arguments, cwd: root.path,
            stem: logs.appendingPathComponent("compiler").path,
            helper: repo.appendingPathComponent("Scripts/benchmark-indexstore-cli.py").path)
        let requestPath = logs.appendingPathComponent("compiler-request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: requestPath)
        let script = logs.appendingPathComponent("supervisor.py")
        try Data(Self.supervisor.utf8).write(to: script)
        let stdout = logs.appendingPathComponent("supervisor.stdout")
        let stderr = logs.appendingPathComponent("supervisor.stderr")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, requestPath.path]
        process.currentDirectoryURL = root
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        guard terminated.wait(timeout: .now() + 270) == .success else {
            try phase("supervisor-deadline-cleanup-unknown-no-kill", logs: logs)
            let message = "Compiler supervisor did not finish; cleanup unknown. Evidence: " + logs.path
            throw NSError(domain: "NativeCompilerEvidence", code: 124,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            try phase("toolchain-or-compiler-supervisor-failed", logs: logs)
            let message = "Toolchain lookup or compiler failed. Evidence: " + logs.path
            throw NSError(domain: "NativeCompilerEvidence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        let decoder = JSONDecoder()
        let receipt = try decoder.decode(CompileReceipt.self,
            from: Data(contentsOf: logs.appendingPathComponent("compiler.json")))
        let toolchain = try decoder.decode(ToolchainReceipt.self,
            from: Data(contentsOf: logs.appendingPathComponent("toolchain.json")))
        guard receipt.returncode == 0, !receipt.timed_out, receipt.owned_root_reaped,
              !receipt.ownership_lost, receipt.cleanup_errors.isEmpty,
              receipt.output_limit_exceeded == nil, receipt.exception_type == nil,
              toolchain.status == "completed", receipt.command.first == toolchain.compilerPath else {
            try phase("compiler-failed-or-cleanup-unconfirmed", logs: logs)
            let message = "Compiler failed or cleanup is incomplete. Evidence: " + logs.path
            throw NSError(domain: "NativeCompilerEvidence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        return toolchain.libraryPath
    }

    static func phase(_ name: String, logs: URL) throws {
        let path = logs.appendingPathComponent("phases.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path) }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let record = Phase(name: name, unixSeconds: Date().timeIntervalSince1970,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: encoder.encode(record) + Data([10]))
        FileHandle.standardError.write(Data(("native-compiler phase: \(name); evidence: \(logs.path)\n").utf8))
    }

    private struct CompileRequest: Encodable {
        let arguments: [String]
        let cwd: String
        let stem: String
        let helper: String
    }

    private struct CompileReceipt: Decodable {
        let command: [String]
        let returncode: Int?
        let timed_out: Bool
        let owned_root_reaped: Bool
        let ownership_lost: Bool
        let cleanup_errors: [String]
        let output_limit_exceeded: String?
        let exception_type: String?
    }

    private struct ToolchainReceipt: Decodable {
        let status: String
        let compilerPath: String
        let libraryPath: String
    }

    private struct Phase: Encodable {
        let name: String
        let unixSeconds: Double
        let uptimeSeconds: Double
    }

    private static let supervisor = #"""
    import importlib.util
    import json
    import os
    from pathlib import Path
    import sys
    import time

    request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    spec = importlib.util.spec_from_file_location("witness_compiler_base", request["helper"])
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    started = time.monotonic()
    logs = Path(request["stem"]).parent
    selection_path = logs / "toolchain.json"
    selection = {"status": "incomplete", "totalBudgetSeconds": 240,
                 "lookupTimeoutSeconds": 30, "lookupStreamLimitBytes": 4096}
    base.save(selection_path, selection)

    def phase(name):
        record = {"name": name, "unixSeconds": time.time(), "uptimeSeconds": time.monotonic()}
        with (logs / "phases.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        print(f"native-compiler phase: {name}; evidence: {logs}", file=sys.stderr, flush=True)

    try:
        phase("toolchain-lookup-start")
        lookup = base.run(["/usr/bin/xcrun", "--find", "swiftc"], Path(request["cwd"]),
                          logs / "toolchain-lookup", timeout=30, stream_limit=4096)
        lines = Path(lookup["stdout"]).read_text(encoding="utf-8").splitlines()
        if len(lines) != 1:
            raise ValueError("Compiler lookup must return exactly one absolute path")
        compiler = Path(lines[0])
        selection["compilerPath"] = str(compiler)
        if not compiler.is_absolute() or compiler.name != "swiftc":
            raise ValueError("Compiler lookup did not select an absolute swiftc path")
        if not compiler.is_file() or not os.access(compiler, os.X_OK):
            raise ValueError("Selected Swift compiler does not exist or is not executable")
        if compiler.parent.name != "bin" or compiler.parent.parent.name != "usr":
            raise ValueError("Selected Swift compiler has no adjacent usr/lib toolchain layout")
        usr = compiler.parent.parent.resolve(strict=True)
        canonical_compiler = compiler.resolve(strict=True)
        library = usr / "lib" / "libIndexStore.dylib"
        selection.update(compilerCanonicalPath=str(canonical_compiler), libraryPath=str(library))
        if not canonical_compiler.is_relative_to(usr) or not library.is_file():
            raise ValueError("Selected toolchain has no matching IndexStore library")
        canonical_library = library.resolve(strict=True)
        selection["libraryCanonicalPath"] = str(canonical_library)
        if not canonical_library.is_relative_to(usr):
            raise ValueError("IndexStore library resolves outside the selected compiler toolchain")
        phase("toolchain-bound")
        remaining = 240 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("Toolchain lookup exhausted the total compiler budget")
        selection.update(status="selected", compilerTimeoutSeconds=remaining)
        base.save(selection_path, selection)
        phase("compiler-start-with-selected-toolchain")
        base.run([str(compiler), *request["arguments"]], Path(request["cwd"]), Path(request["stem"]),
                 timeout=remaining, stream_limit=4 * 1024 * 1024)
        selection["status"] = "completed"
        base.save(selection_path, selection)
        phase("compiler-complete-with-selected-toolchain")
    except BaseException as error:
        selection.update(status="failed", exceptionType=type(error).__name__, error=str(error)[:2048])
        base.save(selection_path, selection)
        print(f"compiler supervisor: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
    """#

    struct Record: Encodable {
        let usr: String
        let name: String
        let kind: String
        let subKind: String
        let path: String
        let module: String
        let line: Int
        let column: Int
        let roles: UInt64
        let roleNames: [String]
        let relations: [Relation]

        init(_ occurrence: SymbolOccurrence) {
            usr = occurrence.symbol.usr
            name = occurrence.symbol.name
            kind = String(describing: occurrence.symbol.kind)
            subKind = String(describing: occurrence.symbol.subKind)
            path = URL(fileURLWithPath: occurrence.location.path).lastPathComponent
            module = occurrence.location.moduleName
            line = occurrence.location.line
            column = occurrence.location.utf8Column
            roles = UInt64(occurrence.roles.rawValue)
            roleNames = Self.names(occurrence.roles)
            relations = occurrence.relations.map {
                Relation(usr: $0.symbol.usr, name: $0.symbol.name,
                    kind: String(describing: $0.symbol.kind), subKind: String(describing: $0.symbol.subKind),
                    roles: UInt64($0.roles.rawValue), roleNames: Self.names($0.roles))
            }.sorted { ($0.usr, $0.roles) < ($1.usr, $1.roles) }
        }

        private static func names(_ roles: SymbolRole) -> [String] {
            let known: [(SymbolRole, String)] = [
                (.declaration, "declaration"), (.definition, "definition"), (.reference, "reference"),
                (.call, "call"), (.dynamic, "dynamic"), (.implicit, "implicit"), (.childOf, "childOf"), (.baseOf, "baseOf"),
                (.overrideOf, "overrideOf"), (.containedBy, "containedBy"), (.calledBy, "calledBy"),
                (.extendedBy, "extendedBy"), (.receivedBy, "receivedBy"),
            ]
            return known.filter { roles.contains($0.0) }.map(\.1)
        }
    }

    struct Relation: Encodable {
        let usr: String
        let name: String
        let kind: String
        let subKind: String
        let roles: UInt64
        let roleNames: [String]
    }
}
