import CartographCore
@testable import CartographSyntax
import Testing

@Suite("정확한 self 호출의 소스·컴파일러 결합")
struct DispatchReceiverBinderTests {
    let path = "/p/Self.swift"
    let source = """
    class Base {
        func send() {}
        func run(_ other: Base) {
            send()
            self.send()
            other.send()
            let alias = self; alias.send()
            let closure = { self.send() }; closure()
            func local() { self.send() }; local()
        }
        static func typeCall() { print("not an instance") }
    }
    final class Child: Base {}
    """

    @Test("직접 self만 후보로 내고 정확한 caller와 UTF8 위치가 있는 발생만 결합한다")
    func exactPositions() throws {
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        let syntax = try #require(facts.dispatchReceiverSyntaxFacts)
        // Local closure/function invocations may be syntactically implicit, but
        // lack the independent compiler instance receiver required by the binder.
        let sites = syntax.selfCalls.filter { [4, 5].contains($0.location.line) }
        #expect(sites.count == 2)
        #expect(!syntax.selfCalls.contains { [6, 7].contains($0.location.line) })
        let run = try #require(facts.declarations.first { $0.name == "run" })
        let send = try #require(facts.declarations.first { $0.name == "send" })
        let child = try #require(facts.declarations.first { $0.name == "Child" })
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "s:send", name: "send()", kind: .method, module: "Fixture",
                location: try #require(send.nameLocation), parentUSR: "s:Base"),
            .init(usr: "s:run", name: "run(_:)", kind: .method, module: "Fixture",
                location: try #require(run.nameLocation), parentUSR: "s:Base"),
            .init(usr: "s:Child", name: "Child", kind: .classType, module: "Fixture",
                location: try #require(child.nameLocation)),
        ], references: sites.map {
            .init(sourceUSR: "s:run", targetUSR: "s:send", kind: .call, location: $0.location,
                origin: .compiler, receiverTypeUSR: "s:Base")
        })
        let joined = DispatchReceiverBinder.bind(snapshot: snapshot, files: [path: facts], freshPaths: [path])
        #expect(joined.first?.selfCalls.count == 2)
        #expect(joined.first?.finalClassUSRs == ["s:Child"])
        #expect(joined.first?.sourceDigest?.count == 64)
        #expect(DispatchReceiverBinder.bind(snapshot: snapshot, files: [path: facts], freshPaths: []).isEmpty)
        var wrong = snapshot
        wrong.references = snapshot.references.map {
            .init(sourceUSR: $0.sourceUSR, targetUSR: $0.targetUSR, kind: .call,
                location: .init(path: path, line: $0.location!.line, column: $0.location!.column + 1),
                origin: .compiler, receiverTypeUSR: "s:Base")
        }
        #expect(DispatchReceiverBinder.bind(snapshot: wrong, files: [path: facts], freshPaths: [path])
            .first?.selfCalls.isEmpty == true)
        wrong = snapshot
        wrong.references += snapshot.references.map {
            .init(sourceUSR: "s:other", targetUSR: $0.targetUSR, kind: .call, location: $0.location,
                origin: .compiler, receiverTypeUSR: "s:Base")
        }
        #expect(DispatchReceiverBinder.bind(snapshot: wrong, files: [path: facts], freshPaths: [path])
            .first?.selfCalls.isEmpty == true)
    }

    @Test("속성 불명·잘못된 구문·조건부 소스는 self 증명을 만들지 않는다")
    func unknownSources() {
        let malformed = SwiftSyntaxAnalyzer().analyze(source: "class C { func broken( {", path: path)
        #expect(malformed.dispatchReceiverSyntaxFacts == nil)
        let conditional = SwiftSyntaxAnalyzer().analyze(source: """
        #if FEATURE
        final class C { func f() { self.f() } }
        #endif
        """, path: path)
        #expect(conditional.dispatchReceiverSyntaxFacts?.selfCalls.isEmpty == true)
        #expect(conditional.dispatchReceiverSyntaxFacts?.finalClassLocations.isEmpty == true)
    }

    @Test("callable 값의 receivedBy를 implicit self 메서드 호출로 바꾸지 않는다")
    func callableValuesAreNotSelf() throws {
        let facts = SwiftSyntaxAnalyzer().analyze(source: """
        class Base {
            func callAsFunction() {}
            func run(_ other: Base) {
                other()
                let callAsFunction = other; callAsFunction()
                self.callAsFunction()
            }
        }
        """, path: path)
        let sites = try #require(facts.dispatchReceiverSyntaxFacts).selfCalls
        let caller = try #require(facts.declarations.first { $0.name == "run" })
        let callee = try #require(facts.declarations.first { $0.name == "callAsFunction" })
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "s:run", name: "run(_:)", kind: .method, module: "Fixture",
                location: try #require(caller.nameLocation), parentUSR: "s:Base"),
            .init(usr: "s:call", name: "callAsFunction()", kind: .method, module: "Fixture",
                location: try #require(callee.nameLocation), parentUSR: "s:Base"),
        ], references: sites.map {
            .init(sourceUSR: "s:run", targetUSR: "s:call", kind: .call, location: $0.location,
                origin: .compiler, receiverTypeUSR: "s:Base")
        })
        let joined = DispatchReceiverBinder.bind(snapshot: snapshot, files: [path: facts], freshPaths: [path])
        #expect(joined.first?.selfCalls.isEmpty == true)
    }
}
