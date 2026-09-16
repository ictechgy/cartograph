import ArgumentParser
@testable import cartograph
import Testing

/// `--level` 해상도의 적용 범위.
///
/// 그래프 해상도를 바꾸는 명령(`graph`·`cycles`·`metrics`·`rules`)만 듣는다.
/// 항상 심볼 레벨인 `dead`·`query`, 해상도가 없는 `bridges`, 명령마다 정해진
/// 해상도로 거두는 `baseline` 은 받으면 출력이 바이트까지 같아진다. 조용히
/// 받으면 `--since` 때와 같은 함정이므로 앞에서 거부한다.
@Suite("--level 적용 범위")
struct LevelValidationTests {
    @Test("dead는 --level을 받으면 사용 오류를 낸다")
    func deadRejectsLevel() {
        do {
            _ = try DeadCommand.parse(["--level", "module"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--level cannot be combined with dead"))
        }
    }

    @Test("query는 --level을 받으면 사용 오류를 낸다")
    func queryRejectsLevel() {
        do {
            _ = try QueryCommand.parse(["Foo", "--level", "module"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--level cannot be combined with query"))
        }
    }

    @Test("bridges는 --level을 받으면 사용 오류를 낸다")
    func bridgesRejectsLevel() {
        do {
            _ = try BridgesCommand.parse(["--level", "module"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--level cannot be combined with bridges"))
        }
    }

    @Test("bridges messages는 Flutter target만 허용한다")
    func bridgesMessagesRejectsReactNative() {
        #expect(throws: (any Error).self) {
            _ = try BridgesCommand.parse(["--messages", "--target", "react-native"])
        }
    }

    @Test("bridges messages 플래그를 파싱한다")
    func bridgesMessagesParses() throws {
        let command = try BridgesCommand.parse(["--messages", "--target", "flutter"])
        #expect(command.messages)
    }

    @Test("bridges events는 Flutter target만 허용한다")
    func bridgesEventsRejectsReactNative() {
        #expect(throws: (any Error).self) {
            _ = try BridgesCommand.parse(["--events", "--target", "react-native"])
        }
    }

    @Test("bridges events 플래그를 파싱한다")
    func bridgesEventsParses() throws {
        let command = try BridgesCommand.parse(["--events", "--target", "flutter"])
        #expect(command.events)
    }

    @Test("bridges는 --messages와 --events를 함께 받지 않는다")
    func bridgesRejectsMixedTransports() {
        #expect(throws: (any Error).self) {
            _ = try BridgesCommand.parse(["--messages", "--events"])
        }
    }

    @Test("baseline은 --level을 받으면 사용 오류를 낸다")
    func baselineRejectsLevel() {
        do {
            _ = try BaselineCommand.parse(["--level", "module"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--level cannot be combined with baseline"))
        }
    }

    @Test("해상도를 쓰는 명령은 그대로 통과한다")
    func levelConsumersPass() throws {
        _ = try GraphCommand.parse(["--level", "module"])
        _ = try CyclesCommand.parse(["--level", "type"])
        _ = try MetricsCommand.parse(["--level", "file"])
        _ = try RulesCommand.parse(["--level", "module"])
        _ = try DeadCommand.parse([])
    }
}
