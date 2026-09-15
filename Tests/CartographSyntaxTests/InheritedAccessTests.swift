import CartographCore
import CartographSyntax
import Testing

@Suite("선언 기본 접근 수준")
struct InheritedAccessTests {
    private func analyze(_ source: String) -> SourceFileFacts {
        SwiftSyntaxAnalyzer().analyze(source: source, path: "/p/Access.swift")
    }

    private func access(_ facts: SourceFileFacts, _ name: String) -> Accessibility? {
        facts.declaration(named: name)?.accessibility
    }

    @Test("public 프로토콜의 요구사항은 프로토콜 접근 수준을 물려받는다")
    func publicProtocolRequirementsInheritProtocolAccess() {
        let facts = analyze("""
            public protocol Contract {
                func run()
                var value: Int { get }
                associatedtype Element
                subscript(index: Int) -> Element { get }
                init(value: Int)
            }
            """)

        #expect(access(facts, "run") == .publicLevel)
        #expect(access(facts, "value") == .publicLevel)
        #expect(access(facts, "Element") == .publicLevel)
        #expect(access(facts, "subscript") == .publicLevel)
        #expect(access(facts, "init") == .publicLevel)
    }

    @Test("public extension의 멤버는 extension 접근 수준을 물려받는다")
    func publicExtensionMembersInheritExplicitAccess() {
        let facts = analyze("""
            public struct Host {}
            public extension Host {
                func exposed() {}
                var exposedValue: Int { 1 }
                private func hidden() {}
            }
            package extension Host {
                func packageMember() {}
            }
            """)

        #expect(access(facts, "exposed") == .publicLevel)
        #expect(access(facts, "exposedValue") == .publicLevel)
        #expect(access(facts, "hidden") == .privateLevel)
        #expect(access(facts, "packageMember") == .packageLevel)
    }

    @Test("public nominal 타입의 멤버 기본 접근은 internal이다")
    func publicNominalMembersRemainInternal() {
        let facts = analyze("""
            public struct Box {
                init() {}
                var value = 0
                func run() {}
            }
            public class Reference {
                init() {}
                var value = 0
                func run() {}
            }
            """)

        #expect(access(facts, "init") == .internalLevel)
        #expect(access(facts, "value") == .internalLevel)
        #expect(access(facts, "run") == .internalLevel)
        #expect(facts.declarations.filter { $0.name == "init" }.count == 2)
        #expect(facts.declarations.filter { $0.name == "value" }.count == 2)
        #expect(facts.declarations.filter { $0.name == "run" }.count == 2)
    }

    @Test("public enum의 case는 enum 접근 수준을 물려받는다")
    func publicEnumCasesInheritEnumAccess() {
        let facts = analyze("""
            public enum Status {
                case ready
                func render() {}
            }
            """)

        #expect(access(facts, "ready") == .publicLevel)
        #expect(access(facts, "render") == .internalLevel)
    }

    @Test("public 프로토콜의 무표시 extension 멤버는 internal이다")
    func unmarkedProtocolExtensionMembersRemainInternal() {
        let facts = analyze("""
            public protocol Contract {
                func run()
            }
            extension Contract {
                func helper() {}
            }
            """)

        #expect(access(facts, "run") == .publicLevel)
        #expect(access(facts, "helper") == .internalLevel)
    }

    @Test("private와 fileprivate nominal 타입은 멤버 접근을 제한한다")
    func privateAndFileprivateNominalsClampMembers() {
        let facts = analyze("""
            private struct PrivateBox {
                public func explicit() {}
                func inferred() {}
            }
            fileprivate class FileBox {
                public func explicit() {}
                func inferred() {}
            }
            """)

        #expect(access(facts, "explicit") == .privateLevel)
        #expect(access(facts, "inferred") == .privateLevel)
        #expect(facts.declarations.filter { $0.name == "explicit" }.count == 2)
        #expect(facts.declarations.filter { $0.name == "inferred" }.count == 2)
        #expect(facts.declarations.filter { $0.name == "explicit" }
            .last?.accessibility == .fileprivateLevel)
        #expect(facts.declarations.filter { $0.name == "inferred" }
            .last?.accessibility == .fileprivateLevel)
    }

    @Test("private extension의 기본 접근은 개별 public 멤버를 제한하지 않는다")
    func explicitMemberOverridesPrivateExtensionDefault() {
        let facts = analyze("""
            public struct Host {}
            private extension Host {
                public func exposed() {}
                func hidden() {}
            }
            """)
        #expect(access(facts, "exposed") == .publicLevel)
        #expect(access(facts, "hidden") == .privateLevel)
    }
}
