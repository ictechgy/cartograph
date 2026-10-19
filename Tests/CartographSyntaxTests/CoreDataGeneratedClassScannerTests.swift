@testable import CartographSyntax
import Testing

@Suite("Core Data 생성 클래스 형태")
struct CoreDataGeneratedClassScannerTests {
    @Test("momc의 빈 NSManagedObject 클래스와 exact Objective-C 이름만 받아들인다")
    func acceptsGeneratedClassShape() {
        let source = """
            public import Foundation
            public import CoreData
            public typealias RecordCoreDataClassSet = NSSet
            @objc(Record)
            public class Record: NSManagedObject {
            }
            """
        let result = CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: "/generated/Record+CoreDataClass.swift",
            expectedClassName: "Record",
            expectedRuntimeName: "Record",
            module: "App"
        )
        #expect(result.isGeneratorCompatible)
        #expect(result.className == "Record")
        #expect(result.runtimeName == "Record")
        #expect(result.location?.line == 5)
    }

    @Test("모듈 한정 생성 클래스는 명시적 Objective-C 별칭 없이 exact 모듈 이름을 사용한다")
    func acceptsModuleQualifiedRuntimeName() {
        let source = """
            import Foundation
            import CoreData
            public typealias RecordCoreDataClassSet = NSSet
            public class Record: NSManagedObject {}
            """
        let result = CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: "/generated/Record.swift",
            expectedClassName: "Record",
            expectedRuntimeName: "App.Record",
            module: "App"
        )
        #expect(result.isGeneratorCompatible)
        #expect(result.runtimeName == "App.Record")
    }

    @Test("모델 상속 엔티티는 검증된 부모 생성 클래스를 exact superclass로 사용한다")
    func acceptsVerifiedGeneratedSuperclass() {
        let source = """
            import Foundation
            import CoreData
            public typealias ChildCoreDataClassSet = NSSet
            public class Child: Parent {}
            """
        let accepted = CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: "/generated/Child.swift",
            expectedClassName: "Child",
            expectedRuntimeName: "App.Child",
            module: "App",
            expectedSuperclassName: "Parent"
        )
        #expect(accepted.isGeneratorCompatible)
        #expect(!CoreDataGeneratedClassScanner.inspect(
            source: source,
            path: "/generated/Child.swift",
            expectedClassName: "Child",
            expectedRuntimeName: "App.Child",
            module: "App"
        ).isGeneratorCompatible)
    }

    @Test("생성 파일 이름·주석을 흉내 내도 메서드·다른 상속·추가 선언은 거부한다")
    func rejectsHandwrittenClassShapes() {
        let bodies = [
            "public class Record: NSManagedObject { public func custom() {} }",
            "public class Record: NSObject {}",
            "public class Record: NSManagedObject {}\n"
                + "public func sideEffect() {}",
        ]
        for body in bodies {
            let source = """
                // This file was automatically generated and should not be edited.
                import Foundation
                import CoreData
                public typealias RecordCoreDataClassSet = NSSet
                \(body)
                """
            let result = CoreDataGeneratedClassScanner.inspect(
                source: source,
                path: "/generated/Record+CoreDataClass.swift",
                expectedClassName: "Record",
                expectedRuntimeName: "App.Record",
                module: "App"
            )
            #expect(!result.isGeneratorCompatible)
            #expect(result.reason != nil)
        }
    }

    @Test("최상위 클래스 이름은 inspect 가 대조하는 이름과 같고, 최상위 클래스가 하나가 아니면 없다")
    func topLevelClassNameMatchesInspectedName() {
        let prefix = """
            import Foundation
            import CoreData
            public typealias RecordCoreDataClassSet = NSSet
            """
        let escaped = prefix + "\npublic class `Record`: NSObject {}"
        let inspected = CoreDataGeneratedClassScanner.inspect(
            source: escaped, path: "/generated/Record.swift",
            expectedClassName: "Other", expectedRuntimeName: "App.Other", module: "App"
        )

        #expect(CoreDataGeneratedClassScanner.topLevelClassName(source: escaped) == "Record")
        #expect(inspected.className == "Record")
        #expect(CoreDataGeneratedClassScanner.topLevelClassName(source: prefix) == nil)
        #expect(CoreDataGeneratedClassScanner.topLevelClassName(
            source: prefix + "\npublic class Record: NSManagedObject {}\npublic class Other: NSManagedObject {}"
        ) == nil)
    }

    @Test("동명 클래스가 둘이거나 런타임 별칭이 모델과 다르면 거부한다")
    func rejectsAmbiguousOrWrongRuntimeNames() {
        let prefix = """
            import Foundation
            import CoreData
            public typealias RecordCoreDataClassSet = NSSet
            """
        let duplicate = prefix + "\npublic class Record: NSManagedObject {}\npublic class Record: NSManagedObject {}"
        #expect(!CoreDataGeneratedClassScanner.inspect(
            source: duplicate, path: "/generated/Record.swift",
            expectedClassName: "Record", expectedRuntimeName: "App.Record", module: "App"
        ).isGeneratorCompatible)
        let wrongAlias = prefix + "\n@objc(Other) public class Record: NSManagedObject {}"
        #expect(!CoreDataGeneratedClassScanner.inspect(
            source: wrongAlias, path: "/generated/Record.swift",
            expectedClassName: "Record", expectedRuntimeName: "Record", module: "App"
        ).isGeneratorCompatible)
    }
}
