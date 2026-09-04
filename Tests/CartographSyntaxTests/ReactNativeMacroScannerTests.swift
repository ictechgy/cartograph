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

    @Test("RCT_EXPORT_VIEW_PROPERTY 가 여럿이어도 component-export 는 컴포넌트당 하나다")
    func recordsViewManagersOnce() {
        let source = """
            @implementation MapViewManager
            RCT_EXPORT_MODULE(MapView)
            RCT_EXPORT_VIEW_PROPERTY(zoomEnabled, BOOL)
            RCT_EXPORT_VIEW_PROPERTY(region, MKCoordinateRegion)
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.kind) == [.moduleExport, .componentExport])
        #expect(facts.last?.channel == "MapView")
        #expect(facts.last?.location.line == 3)
    }

    @Test("주석 처리된 매크로는 줄 주석이든 블록 주석이든 읽지 않는다")
    func ignoresCommentedMacros() {
        let source = """
            @implementation Legacy
            // RCT_EXPORT_MODULE(OldName)
            /* removed:
            RCT_EXPORT_MODULE(Older)
            RCT_EXPORT_METHOD(gone) {}
            */
            RCT_EXPORT_MODULE()
            RCT_EXPORT_METHOD(kept) {}
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.channel) == ["Legacy", "Legacy"])
        #expect(facts.map(\.method) == [nil, "kept"])
        // 블록 주석을 지워도 줄 번호는 그대로여야 위치가 맞는다.
        #expect(facts.map(\.location.line) == [7, 8])
    }

    @Test("줄 끝 주석·문자열·#if 0 안의 매크로는 읽지 않는다")
    func ignoresInlineNoise() {
        let source = """
            @implementation A
            RCT_EXPORT_MODULE()
            NSLog(@"RCT_EXPORT_METHOD(fake)"); // RCT_EXPORT_METHOD(alsoFake)
            #if 0
            RCT_EXPORT_METHOD(disabled) {}
            #endif
            RCT_EXPORT_METHOD(real) {}
            @end
            """
        #expect(scan(source).filter { $0.kind == .methodHandle }.map(\.method) == ["real"])
    }

    @Test("@end 가 빠져도 앞 블록을 버리지 않는다")
    func keepsBlockWithoutEnd() {
        let source = """
            @implementation A
            RCT_EXPORT_MODULE()
            @implementation B
            RCT_EXPORT_MODULE()
            @end
            """
        #expect(scan(source).map(\.channel) == ["A", "B"])
    }

    @Test("메서드 이름이 다음 줄로 넘어가면 동적 이름으로 센다")
    func treatsUnreadableMethodNameAsDynamic() {
        let source = """
            @implementation A
            RCT_EXPORT_MODULE()
            RCT_EXPORT_METHOD(
                addEvent:(NSString *)name) {}
            RCT_EXPORT_METHOD()
            @end
            """
        let handled = scan(source).filter { $0.kind == .methodHandle }
        #expect(handled.count == 2)
        #expect(handled.allSatisfy { $0.isDynamic && $0.method == nil })
        #expect(handled.first?.method == nil)
        #expect(handled.first?.isDynamic == true)
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
