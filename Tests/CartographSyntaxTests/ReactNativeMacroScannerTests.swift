import CartographCore
@testable import CartographSyntax
import Testing

@Suite("React Native 매크로 스캐너")
struct ReactNativeMacroScannerTests {
    @Test("ObjC 구현 매크로에는 정확한 선언 줄을 붙이고 extern 선언은 구현으로 표시하지 않는다")
    func implementationIdentitySites() {
        let scanned = ReactNativeMacroScanner().scanDeclarations(source: """
            @implementation Camera
            RCT_EXPORT_MODULE(PublicCamera)
            RCT_REMAP_METHOD(capture, takePhoto:(id)value) {}
            @end
            @interface RCT_EXTERN_MODULE(SwiftCamera, NSObject)
            RCT_EXTERN_METHOD(capture)
            @end
            """, path: "/p/Camera.m")
        #expect(scanned.prefix(2).allSatisfy { $0.fact.sourceLanguage == .objectiveC })
        #expect(scanned[0].declaration?.line == 1)
        #expect(scanned[1].declaration?.line == 3)
        #expect(scanned[1].fact.method == "capture")
        #expect(scanned.suffix(2).allSatisfy { $0.declaration == nil && $0.fact.sourceLanguage == nil })
    }

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

    @Test("줄 주석 안의 /* 와 이스케이프된 따옴표, #else 가지를 바르게 다룬다")
    func handlesCommentAndStringEdgeCases() {
        let source = """
            @implementation RNCalendar
            // TODO: merge with /* the UIKit version
            RCT_EXPORT_MODULE(Calendar)
            NSLog(@"path\\\\"); // RCT_EXPORT_METHOD(fake)
            RCT_EXPORT_METHOD(addEvent:(NSString *)name) {}
            #if 0
            RCT_EXPORT_METHOD(old) {}
            #else
            RCT_EXPORT_METHOD(current) {}
            #endif
            @end
            """
        let facts = scan(source)
        #expect(facts.map(\.channel) == ["Calendar", "Calendar", "Calendar"])
        #expect(facts.map(\.method) == [nil, "addEvent", "current"])
        #expect(facts.map(\.location.line) == [3, 5, 9])
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

    /// 넘긴 정규식 묶음으로 훑고, 정규식을 실제로 댄 횟수를 함께 돌려준다.
    private func countingScan(_ lines: [String]) -> (facts: [ScannedBridgeFact], evaluations: Int) {
        let patterns = ReactNativeMacroScanner.Patterns()
        let facts = ReactNativeMacroScanner().scanDeclarations(
            source: lines.joined(separator: "\n"), path: "/p/Module.m", patterns: patterns
        )
        return (facts, patterns.evaluations)
    }

    @Test("RN 매크로가 없는 줄에는 정규식을 대지 않아 줄이 늘어도 평가 횟수가 같다")
    func evaluatesPatternsOnlyOnCandidateLines() {
        // 매크로 없는 ObjC 줄마다 정규식을 새로 만들어 대면 bridges 가 줄당 수백 µs 를 쓴다.
        let plain = (0..<200).map { "- (int)method\($0):(int)value { return value + \($0); } // note \($0)" }
        let macros = ["RCT_EXPORT_MODULE(Calendar)", "RCT_EXPORT_METHOD(addEvent:(NSString *)name) {}"]
        let compact = countingScan(["@implementation RNCalendar"] + macros + ["@end"])
        let padded = countingScan(["#import \"RNCalendar.h\"", "@implementation RNCalendar"] + plain + macros + plain
            + ["@end"] + plain)
        #expect(compact.evaluations > 0)
        #expect(padded.evaluations == compact.evaluations)
        #expect(padded.facts.map(\.fact.channel) == ["Calendar", "Calendar"])
        #expect(padded.facts.map(\.fact.method) == compact.facts.map(\.fact.method))
        #expect(padded.facts.map(\.fact.location.line) == [203, 204])
    }

    @Test("RN 매크로가 하나도 없는 ObjC 파일은 블록을 여는 줄에만 정규식을 댄다")
    func evaluatesOnlyImplementationLineWithoutMacros() {
        let plain = (0..<500).map { "    [self send:@\"value \($0)\"]; // RCT note without the macro prefix" }
        let scanned = countingScan(["@implementation Plain"] + plain + ["@end"])
        #expect(scanned.facts.isEmpty)
        #expect(scanned.evaluations == 1)
    }
}
