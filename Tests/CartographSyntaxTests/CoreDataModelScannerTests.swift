import CartographCore
@testable import CartographSyntax
import Testing

@Suite("Core Data 모델 런타임 스캐너")
struct CoreDataModelScannerTests {
    private let path = "/p/Model.xcdatamodel/contents"

    @Test("실제 모델의 representedClassName만 클래스 선택 근거로 쓴다")
    func capturesManualEntityClasses() {
        let facts = CoreDataModelScanner.scan(source: """
            <model>
              <entity name="Person" representedClassName="App.Person"/>
              <entity name="Legacy" representedClassName="Legacy.Record" codeGenerationType="none"/>
            </model>
            """, path: path)

        #expect(facts.boundaries.map(\.kind) == [.coreDataEntityClass, .coreDataEntityClass])
        #expect(facts.boundaries.map(\.api) == ["representedClassName", "representedClassName"])
        #expect(facts.boundaries.map(\.name) == ["App.Person", "Legacy.Record"])
        #expect(facts.boundaries.map(\.resourceObjectID) == ["Person", "Legacy"])
        #expect(facts.boundaries.allSatisfy { $0.reason == nil && $0.nameOrigin == .resource })
    }

    @Test("자동 생성과 클래스 누락과 속성 충돌은 연결 후보로 승격하지 않는다")
    func preservesUnresolvedEntityConfigurations() {
        let facts = CoreDataModelScanner.scan(source: """
            <model>
              <entity name="Generated" representedClassName="Generated" codeGenerationType="class"/>
              <entity name="Missing"/>
              <entity name="UnsupportedManual" representedClassName="First" codeGenerationType="manual"/>
              <entity name="Current" representedClassName=".CurrentModuleClass"/>
              <entity representedClassName="Unnamed"/>
            </model>
            """, path: path)

        let reasons = facts.boundaries.compactMap(\.reason)
        #expect(reasons.count == 5)
        #expect(reasons.contains { $0.contains("automatic code generation") })
        #expect(reasons.contains { $0.contains("no represented class") })
        #expect(reasons.contains { $0.contains("unsupported code generation") })
        #expect(reasons.contains { $0.contains("module placeholder") })
        #expect(reasons.contains { $0.contains("has no name") })
        #expect(facts.boundaries.allSatisfy { $0.receiverTypeName == nil })
    }

    @Test("momc가 무시하는 customClass와 지원하지 않는 manual 문자열은 연결하지 않는다")
    func ignoresNonCoreDataClassAttributes() {
        let facts = CoreDataModelScanner.scan(source: """
            <model>
              <entity name="AliasOnly" customClass="WrongTarget"/>
              <entity name="Both" representedClassName="RealTarget" customClass="IgnoredTarget"/>
              <entity name="BadManual" representedClassName="WrongTarget" codeGenerationType="manual"/>
              <entity name="Extension" representedClassName="App.Record" codeGenerationType="category"/>
            </model>
            """, path: path)
        #expect(facts.boundaries[0].name == nil && facts.boundaries[0].reason != nil)
        #expect(facts.boundaries[1].name == "RealTarget" && facts.boundaries[1].reason == nil)
        #expect(facts.boundaries[2].reason?.contains("unsupported code generation") == true)
        #expect(facts.boundaries[3].reason == nil && facts.boundaries[3].coreDataCodeGeneration == "category")
    }

    @Test("중복 entity 이름과 model 직계가 아닌 entity를 연결하지 않는다")
    func rejectsDuplicateAndNestedEntities() {
        let facts = CoreDataModelScanner.scan(source: """
            <model>
              <entity name="Duplicate" representedClassName="First"/>
              <entity name="Duplicate" representedClassName="Second"/>
              <configuration><entity name="Nested" representedClassName="Nested"/></configuration>
            </model>
            """, path: path)

        #expect(facts.boundaries.count == 2)
        #expect(facts.boundaries.allSatisfy {
            $0.reason == "Core Data model contains duplicate entity name 'Duplicate'"
                && $0.receiverTypeName == nil
        })

        let wrongPath = CoreDataModelScanner.scan(
            source: "<model><entity name=\"Fake\" representedClassName=\"Fake\"/></model>",
            path: "/p/Documentation/contents"
        )
        #expect(wrongPath.boundaries.isEmpty)
        #expect(wrongPath.limitations == ["not a Core Data model contents path: /p/Documentation/contents"])
    }

    @Test("여러 모델 버전은 어느 contents도 현재 버전으로 추측하지 않는다")
    func keepsMultipleVersionsUnresolved() {
        let facts = CoreDataModelScanner.scan(
            source: "<model><entity name=\"Person\" representedClassName=\"Person\"/></model>",
            path: path,
            hasMultipleVersions: true
        )

        #expect(facts.boundaries.first?.reason?.contains("multiple versions") == true)
    }

    @Test("다른 루트 아래에 숨은 model과 중첩 model은 클래스 선택으로 읽지 않는다")
    func rejectsNonRootModels() {
        let wrapped = CoreDataModelScanner.scan(
            source: "<wrapper><model><entity name=\"Wrong\" representedClassName=\"Wrong\"/></model></wrapper>",
            path: path
        )
        #expect(wrapped.boundaries.isEmpty)
        #expect(!wrapped.limitations.isEmpty)
        let nested = CoreDataModelScanner.scan(
            source: "<model><model><entity name=\"Wrong\" representedClassName=\"Wrong\"/></model></model>",
            path: path
        )
        #expect(nested.boundaries.isEmpty)
    }

    @Test("fetch entityName 문자열만으로 Swift 클래스를 추측하지 않는다")
    func doesNotInferClassesFromFetchNames() {
        let facts = RuntimeFactScanner().scan(
            source: "_ = NSFetchRequest<Person>(entityName: \"Person\")",
            path: "/p/Fetch.swift"
        )

        #expect(!facts.boundaries.contains { $0.kind == .coreDataEntityClass })
    }

    @Test("손상된 XML과 DTD는 부분 entity도 반환하지 않는다")
    func rejectsMalformedAndExternalXML() {
        let malformed = CoreDataModelScanner.scan(
            source: "<model><entity name=\"Person\" representedClassName=\"Person\">",
            path: path
        )
        #expect(malformed.boundaries.isEmpty)
        #expect(malformed.limitations == ["malformed Core Data model XML: \(path)"])

        let external = CoreDataModelScanner.scan(
            source: "<!DOCTYPE model SYSTEM \"file:///tmp/model.dtd\"><model/>",
            path: path
        )
        #expect(external.boundaries.isEmpty)
        #expect(external.limitations == ["XML DTDs and external entities are disabled: \(path)"])

        let commented = CoreDataModelScanner.scan(
            source: "<!-- <!DOCTYPE ignored> --><model><entity name=\"Live\" representedClassName=\"Live\"/></model>",
            path: path
        )
        #expect(commented.boundaries.first?.name == "Live")
    }
}
