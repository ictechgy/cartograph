import ArgumentParser
import CartographCore
import Foundation
@testable import cartograph
import Testing

@Suite("자동 런타임 수집")
struct RuntimeCollectTests {
    @Test("macOS collector는 arm64와 x86_64에서 로드할 수 있어야 한다")
    func compilesUniversalMacOSCollector() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-runtime-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = try RuntimeTraceProcess().compileCollector(in: directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-info", collector.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let description = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(description.contains("arm64"))
        #expect(description.contains("x86_64"))
    }

    @Test("관측 구간은 양수 밀리초 이상이며 전체 제한 시간보다 짧아야 한다")
    func validatesObservationDuration() throws {
        let base = ["--executable", "/tmp/Probe", "--output", "/tmp/trace.json", "--timeout", "5"]
        let valid = try RuntimeCollectCommand.parse(base + ["--duration", "0.25"])
        try valid.validate()
        for duration in ["0", "-1", "0.0001", "nan", "infinity", "5", "6"] {
            #expect(throws: (any Error).self) {
                let invalid = try RuntimeCollectCommand.parse(base + ["--duration", duration])
                try invalid.validate()
            }
        }
    }

    @Test("다른 DYLD 계측이 런타임 훅을 가릴 수 있는 환경은 거부한다")
    func rejectsCompetingInjection() throws {
        try RuntimeTraceProcess.validateInjectionEnvironment([:])
        try RuntimeTraceProcess.validateInjectionEnvironment(["DYLD_INSERT_LIBRARIES": ""])
        for key in ["DYLD_INSERT_LIBRARIES", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] {
            #expect(throws: RuntimeTraceProcessError.self) {
                try RuntimeTraceProcess.validateInjectionEnvironment([key: "/tmp/other.dylib"], simulator: true)
            }
        }
        #expect(throws: RuntimeTraceProcessError.self) {
            try RuntimeTraceProcess.validateInjectionEnvironment(["DYLD_INSERT_LIBRARIES": "/tmp/other.dylib"])
        }
    }

    @Test("UIKit의 nil 이름 조회 실패는 유효한 사건이고 이름 없는 성공은 거부한다")
    func preservesFailedNilLookups() {
        let parsed = RuntimeTraceLogParser.parse(Data("""
            {"api":"NSClassFromString","phase":"lookup","result":false}
            {"api":"NSSelectorFromString","phase":"lookup","result":false}
            {"api":"NSProtocolFromString","phase":"lookup","result":false}
            {"api":"NSClassFromString","phase":"lookup","result":true}
            """.utf8))
        #expect(parsed.events.count == 3)
        #expect(parsed.events.allSatisfy { $0.name == nil && $0.result == false })
        #expect(parsed.issues.count == 1)
    }

    @Test("시뮬레이터는 정확한 기기와 설치 앱을 함께 요구한다")
    func validatesSimulatorArguments() throws {
        let base = ["--executable", "/tmp/App", "--output", "/tmp/trace.json"]
        let device = "EF6654D7-B424-446C-98B1-F9163912AF01"
        let valid = try RuntimeCollectCommand.parse(base + [
            "--simulator", device, "--bundle-id", "dev.cartograph.Probe",
        ])
        try valid.validate()
        for arguments in [
            ["--simulator", device], ["--bundle-id", "dev.cartograph.Probe"],
            ["--simulator", "booted", "--bundle-id", "dev.cartograph.Probe"],
            ["--simulator", device, "--bundle-id", "-invalid"],
        ] {
            #expect(throws: (any Error).self) {
                let invalid = try RuntimeCollectCommand.parse(base + arguments)
                try invalid.validate()
            }
        }
    }

    @Test("시뮬레이터 실행 성공은 앱의 종료 코드 근거를 대신하지 않는다")
    func simulatorRequiresApplicationExitEvidence() throws {
        let pid = try #require(RuntimeSimulatorProcess.launchedProcessID(
            from: "dev.cartograph.Probe: 72\n", bundleID: "dev.cartograph.Probe"
        ))
        #expect(pid == 72)
        #expect(RuntimeSimulatorProcess.launchedProcessID(
            from: "other.App: 72\n", bundleID: "dev.cartograph.Probe"
        ) == nil)
        #expect(RuntimeSimulatorProcess.launchedProcessID(
            from: "dev.cartograph.Probe: 72\ndev.cartograph.Probe: 73\n", bundleID: "dev.cartograph.Probe"
        ) == nil)
        #expect(RuntimeSimulatorProcess.launchedProcessID(
            from: "dev.cartograph.Probe: -1\n", bundleID: "dev.cartograph.Probe"
        ) == nil)
        var data = Data("CTTRACE1".utf8)
        for value: UInt32 in [1, 72, 1, 1, 0, 0, 0, 0, 0, 0, 127, 0] { append(value, to: &data) }
        #expect(RuntimeCollectorStatus.decode(data)?.recordedExitCode == nil)
        data.replaceSubrange(52..<56, with: withUnsafeBytes(of: UInt32(8).littleEndian, Array.init))
        #expect(RuntimeCollectorStatus.decode(data)?.recordedExitCode == 7)
        data.replaceSubrange(52..<56, with: withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
        #expect(RuntimeCollectorStatus.decode(data)?.recordedExitCode == 0)
        data.replaceSubrange(52..<56, with: withUnsafeBytes(of: UInt32(257).littleEndian, Array.init))
        #expect(RuntimeCollectorStatus.decode(data) == nil)
    }

    @Test("조회와 반환된 호출을 구분하고 손상된 줄을 숨기지 않는다")
    func parsesPartialTraceWithoutPromotingLookup() throws {
        let lookup = #"{"api":"NSSelectorFromString","phase":"lookup","name":"open:","result":true}"#
        let invocation = #"{"api":"NSObject.performSelector:withObject","phase":"invocation-returned","name":"open:","#
            + #""result":true,"receiverClass":"Screen","receiverIsClass":false,"calleeImage":"/tmp/App","#
            + #""calleeSymbol":"$s4Test6ScreenC4openyyFTo"}"#
        let input = Data([lookup, "not-json", invocation].joined(separator: "\n").utf8)

        let parsed = RuntimeTraceLogParser.parse(input)

        #expect(parsed.events.count == 2)
        let first = try #require(parsed.events.first)
        let last = try #require(parsed.events.last)
        #expect(first.phase == "lookup")
        #expect(last.phase == "invocation-returned")
        #expect(last.calleeSymbol == "$s4Test6ScreenC4openyyFTo")
        #expect(parsed.issues.count == 1)
    }

    @Test("알 수 없는 단계와 제한을 넘긴 사건은 부분 수집으로 남긴다")
    func rejectsUnknownAndOversizedEvents() {
        let input = Data("""
            {"api":"NSClassFromString","phase":"guess","name":"A","result":true}
            {"api":"NSClassFromString","phase":"lookup","name":"A","result":true}
            {"api":"NSProtocolFromString","phase":"lookup","name":"B","result":true}

            """.utf8)

        let parsed = RuntimeTraceLogParser.parse(input, maxEventBytes: 256, maxEvents: 1)

        #expect(parsed.events.count == 1)
        #expect(parsed.issues.count == 2)
    }

    @Test("collector 상태는 magic과 버전이 맞아야 활성 근거가 된다")
    func validatesCollectorStatusHeader() {
        var data = Data("CTTRACE1".utf8)
        append(UInt32(1), to: &data)
        append(Int32(91), to: &data)
        append(UInt32(1), to: &data)
        append(UInt32(1), to: &data)
        append(UInt64(4), to: &data)
        append(UInt64(2), to: &data)
        append(UInt64(3), to: &data)
        append(UInt32(RuntimeCollectorStatus.expectedHookMask), to: &data)
        append(UInt32(0), to: &data)

        let status = RuntimeCollectorStatus.decode(data)

        #expect(status?.processID == 91)
        #expect(status?.emittedEvents == 4)
        #expect(status?.droppedEvents == 2)
        #expect(status?.truncatedValues == 3)
        #expect(RuntimeCollectorStatus.decode(Data("wrong".utf8)) == nil)
        var wrongVersion = data
        wrongVersion.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(2).littleEndian, Array.init))
        #expect(RuntimeCollectorStatus.decode(wrongVersion) == nil)
    }

    @Test("완전성 근거가 하나라도 빠지면 깨끗한 수집으로 보고하지 않는다")
    func requiresEveryCompletionSignal() {
        let event = RuntimeTraceEvent(api: "NSClassFromString", phase: "lookup", name: "Screen", result: true)
        let base = RuntimeTraceExecution(
            processID: 72,
            processExitCode: 0,
            timedOut: false,
            status: RuntimeCollectorStatus(
                processID: 72,
                active: true,
                complete: true,
                emittedEvents: 1,
                droppedEvents: 0,
                truncatedValues: 0,
                hookMask: RuntimeCollectorStatus.expectedHookMask
            ),
            log: RuntimeTraceLogParseResult(events: [event], issues: [], reportedDroppedEvents: 0)
        )
        let complete = document(from: base)
        #expect(complete.collectionComplete)
        #expect(complete.limitations == RuntimeTraceCompletion.scopeLimitations)

        let failures: [RuntimeTraceDocument] = [
            document(from: RuntimeTraceExecution(
                processID: base.processID,
                processExitCode: base.processExitCode,
                timedOut: base.timedOut,
                status: nil,
                log: base.log
            )),
            document(from: base.replacing(processExitCode: 7)),
            document(from: base.replacing(timedOut: true)),
            document(from: base.replacing(status: base.status?.replacing(processID: 99))),
            document(from: base.replacing(status: base.status?.replacing(complete: false))),
            document(from: base.replacing(status: base.status?.replacing(hookMask: 0))),
            document(from: base.replacing(status: base.status?.replacing(droppedEvents: 1))),
            document(from: base.replacing(status: base.status?.replacing(truncatedValues: 1))),
            document(from: base.replacing(log: .init(events: [event], issues: ["bad line"], reportedDroppedEvents: 0))),
            document(from: base, finalInput: "changed"),
            document(from: base, finalExecutable: "changed"),
            document(from: base.replacing(log: .init(
                events: [event], issues: [], reportedDroppedEvents: 1
            ))),
        ]
        #expect(failures.allSatisfy {
            !$0.collectionComplete && $0.limitations.count > RuntimeTraceCompletion.scopeLimitations.count
        })
        #expect(failures[0].collectorActive == false)
        #expect(failures[1].events == [event])
    }

    @Test("수집 명령은 출력·실행 파일을 요구하고 구분자 뒤 인자를 그대로 넘긴다")
    func validatesCollectionArguments() throws {
        let command = try RuntimeCollectCommand.parse([
            "--project", "/tmp/project", "--executable", "/tmp/App", "--output", "/tmp/trace.json",
            "--timeout", "2.5", "--", "--child", "value",
        ])
        try command.validate()
        #expect(command.forwardedApplicationArguments == ["--child", "value"])

        #expect(throws: (any Error).self) {
            let missingOutput = try RuntimeCollectCommand.parse(["--executable", "/tmp/App"])
            try missingOutput.validate()
        }
        #expect(throws: (any Error).self) {
            let invalidTimeout = try RuntimeCollectCommand.parse([
                "--executable", "/tmp/App", "--output", "/tmp/t.json", "--timeout", "0",
            ])
            try invalidTimeout.validate()
        }
        #expect(throws: (any Error).self) {
            let scoped = try RuntimeCollectCommand.parse([
                "--executable", "/tmp/App", "--output", "/tmp/t.json", "--since", "HEAD",
            ])
            try scoped.validate()
        }
        #expect(throws: (any Error).self) {
            let missingSeparator = try RuntimeCollectCommand.parse([
                "--executable", "/tmp/App", "--output", "/tmp/t.json", "value",
            ])
            try missingSeparator.validate()
        }
    }

    @Test("credential 파일만 거부하고 이름에 secret이 들어간 정상 실행 파일은 허용한다")
    func protectsCredentialPathsWithoutBroadNameMatching() {
        #expect(RuntimeTraceFingerprint.isSensitivePath("/tmp/.env"))
        #expect(RuntimeTraceFingerprint.isSensitivePath("/tmp/auth.json"))
        #expect(RuntimeTraceFingerprint.isSensitivePath("/tmp/signing.key"))
        #expect(!RuntimeTraceFingerprint.isSensitivePath("/tmp/SecretStore"))
    }

    @Test("정적 발견은 그대로 두고 trace 비교에는 실행 파일을 함께 요구한다")
    func discoverRequiresPairedTraceIdentity() throws {
        let staticOnly = try RuntimeDiscoverCommand.parse([])
        try staticOnly.validate()
        let compared = try RuntimeDiscoverCommand.parse([
            "--trace", "/tmp/trace.json", "--executable", "/tmp/App",
        ])
        try compared.validate()
        let coreData = try RuntimeDiscoverCommand.parse([
            "--coredata-build-evidence", "/tmp/coredata.json",
        ])
        try coreData.validate()
        #expect(coreData.coreDataBuildEvidencePath == "/tmp/coredata.json")
        #expect(throws: (any Error).self) {
            let traceOnly = try RuntimeDiscoverCommand.parse(["--trace", "/tmp/trace.json"])
            try traceOnly.validate()
        }
        #expect(throws: (any Error).self) {
            let executableOnly = try RuntimeDiscoverCommand.parse(["--executable", "/tmp/App"])
            try executableOnly.validate()
        }
        #expect(throws: (any Error).self) {
            let mixed = try RuntimeDiscoverCommand.parse([
                "--trace", "/tmp/trace.json", "--executable", "/tmp/App",
                "--coredata-build-evidence", "/tmp/coredata.json",
            ])
            try mixed.validate()
        }
    }

    private func document(
        from execution: RuntimeTraceExecution,
        finalInput: String? = "input",
        finalExecutable: String? = "executable"
    ) -> RuntimeTraceDocument {
        RuntimeTraceCompletion.document(
            inputFingerprint: "input",
            finalInputFingerprint: finalInput,
            executableFingerprint: "executable",
            finalExecutableFingerprint: finalExecutable,
            executablePath: "/tmp/App",
            execution: execution
        )
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private extension RuntimeTraceExecution {
    func replacing(
        processExitCode: Int? = nil,
        timedOut: Bool? = nil,
        status: RuntimeCollectorStatus? = nil,
        log: RuntimeTraceLogParseResult? = nil
    ) -> RuntimeTraceExecution {
        RuntimeTraceExecution(
            processID: processID,
            processExitCode: processExitCode ?? self.processExitCode,
            timedOut: timedOut ?? self.timedOut,
            status: status ?? self.status,
            log: log ?? self.log
        )
    }
}

private extension RuntimeCollectorStatus {
    func replacing(
        processID: Int32? = nil,
        complete: Bool? = nil,
        droppedEvents: UInt64? = nil,
        truncatedValues: UInt64? = nil,
        hookMask: UInt32? = nil
    ) -> RuntimeCollectorStatus {
        RuntimeCollectorStatus(
            processID: processID ?? self.processID,
            active: active,
            complete: complete ?? self.complete,
            emittedEvents: emittedEvents,
            droppedEvents: droppedEvents ?? self.droppedEvents,
            truncatedValues: truncatedValues ?? self.truncatedValues,
            hookMask: hookMask ?? self.hookMask
        )
    }
}
