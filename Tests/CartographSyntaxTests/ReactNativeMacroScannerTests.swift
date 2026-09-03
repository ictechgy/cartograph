import CartographCore
@testable import CartographSyntax
import Testing

@Suite("React Native 매크로 스캐너")
struct ReactNativeMacroScannerTests {
    private func scan(_ source: String) -> [BridgeFact] {
        ReactNativeMacroScanner().scan(source: source, path: "/p/Module.m")
    }

    @Test("RCT_EXPORT_MODULE 에 이름이 없으면 클래스 이름이 모듈 이름이다")
    func defaultsModuleNameToClassName() {
        let source = """
            #import "CalendarManager.h"
            @implementation CalendarManager
            RCT_EXPORT_MODULE()
            RCT_EXPORT_METHOD(addEvent:(NSString *)name location:(NSString *)location) {}
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.kind) == [.moduleExport, .methodHandle])
        #expect(facts.map(\.channel) == ["CalendarManager", "CalendarManager"])
        #expect(facts[1].method == "addEvent")
        #expect(facts[0].location == SourceLocation(path: "/p/Module.m", line: 3, column: 1))
    }

    @Test("명시한 모듈 이름은 위쪽에 선언된 메서드에도 적용된다")
    func appliesExplicitModuleNameToEarlierMethods() {
        let source = """
            @implementation RNCalendar
            RCT_EXPORT_METHOD(addEvent:(NSString *)name) {}
            RCT_EXPORT_MODULE(Calendar)
            @end
            """
        let facts = scan(source)
        #expect(facts.allSatisfy { $0.channel == "Calendar" })
    }

    @Test("Swift 모듈을 잇는 RCT_EXTERN_MODULE / RCT_EXTERN_METHOD 를 읽는다")
    func readsExternMacros() {
        let source = """
            @interface RCT_EXTERN_MODULE(CalendarManager, NSObject)
            RCT_EXTERN_METHOD(addEvent:(NSString *)name location:(NSString *)location)
            RCT_EXTERN_REMAP_METHOD(listEvents, listEventsWithResolver:(RCTPromiseResolveBlock)resolve)
            @end
            """
        // `@interface … @end` 는 `@implementation` 이 아니라 블록으로 잡히지 않는다.
        // 실제 RN 문서의 형태 그대로 `@implementation` 없이 쓰이므로 그 경우도 읽어야 한다.
        let facts = scan(source)
        #expect(facts.map(\.kind) == [.moduleExport, .methodHandle, .methodHandle])
        #expect(facts.map(\.channel) == ["CalendarManager", "CalendarManager", "CalendarManager"])
        #expect(facts.map(\.method) == [nil, "addEvent", "listEvents"])
    }

    @Test("RCT_EXPORT_VIEW_PROPERTY 는 component-export 다")
    func recordsViewManagers() {
        let source = """
            @implementation MapViewManager
            RCT_EXPORT_MODULE(MapView)
            RCT_EXPORT_VIEW_PROPERTY(zoomEnabled, BOOL)
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.kind) == [.moduleExport, .componentExport])
        #expect(facts.last?.channel == "MapView")
    }

    @Test("주석 처리된 매크로는 읽지 않는다")
    func ignoresCommentedMacros() {
        let source = """
            @implementation Legacy
            // RCT_EXPORT_MODULE(OldName)
            RCT_EXPORT_MODULE()
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.channel) == ["Legacy"])
    }

    @Test("@implementation 이 여럿이면 각각의 모듈 이름을 쓴다")
    func separatesImplementations() {
        let source = """
            @implementation A
            RCT_EXPORT_MODULE()
            RCT_EXPORT_METHOD(one) {}
            @end
            @implementation B
            RCT_EXPORT_MODULE(Bee)
            RCT_EXPORT_METHOD(two) {}
            @end
            """
        let facts = scan(source).filter { $0.kind == .methodHandle }
        #expect(facts.map(\.channel) == ["A", "Bee"])
    }

    @Test("매크로가 없는 파일은 비어 있다")
    func emptyWithoutMacros() {
        #expect(scan("@implementation Foo\n- (void)bar {}\n@end").isEmpty)
    }
}
