import CartographCore
@testable import CartographSyntax
import Testing
import Foundation

@Suite("Objective-C Flutter 사실 스캐너")
struct ObjectiveCFlutterScannerTests {
    private func block(_ name: String = "@\"camera\"", body: String = "if ([call.method isEqualToString:@\"takePhoto\"]) { result(nil); }") -> String {
        """
        @implementation CameraPlugin
        + (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
            FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:\(name) binaryMessenger:[registrar messenger]];
            [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) { \(body) }];
        }
        @end
        """
    }

    private func scan(_ source: String) -> ObjectiveCBridgeScanResult {
        ObjectiveCFlutterScanner().scan(source: source, path: "/p/Plugin.m")
    }

    @Test("직접 등록과 메서드 분기를 ObjC 증거로 내고 Swift 심볼은 만들지 않는다")
    func blockRegistration() {
        let result = scan(block())
        #expect(result.facts.map(\.kind) == [.channelRegister, .methodHandle])
        #expect(result.facts.map(\.channel) == ["camera", "camera"])
        #expect(result.facts.last?.method == "takePhoto")
        #expect(result.facts.allSatisfy { $0.sourceLanguage == .objectiveC && $0.symbol == nil && !$0.isDynamic })
        #expect(result.opaqueHandlerChannels.isEmpty)
    }

    @Test("같은 파일의 정확한 FlutterPlugin 위임을 연결한다")
    func delegateRegistration() {
        let source = """
        @implementation CameraPlugin
        + (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
            FlutterMethodChannel *channel = [[FlutterMethodChannel alloc] initWithName:@"camera" binaryMessenger:[registrar messenger]];
            CameraPlugin *instance = [[CameraPlugin alloc] init];
            [registrar addMethodCallDelegate:instance channel:channel];
        }
        - (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
            if ([@"takePhoto" isEqualToString:[call method]]) { result(nil); }
        }
        @end
        """
        let result = scan(source)
        #expect(result.facts.map(\.kind) == [.channelRegister, .methodHandle])
        #expect(result.facts.last?.method == "takePhoto")
        #expect(result.opaqueHandlerChannels.isEmpty)
        #expect(scan(source.replacingOccurrences(of: "[FlutterMethodChannel alloc]", with: "[FlutterMethodChannel new]")).facts.count == 2)
        let missing = scan(source.replacingOccurrences(of: "[[CameraPlugin alloc] init]", with: "[UnknownPlugin new]"))
        #expect(missing.facts.map(\.kind) == [.channelRegister])
        #expect(missing.opaqueHandlerChannels == ["camera"])
    }

    @Test("파일 범위의 불변 문자열만 한 단계 해석하고 가려진 상수는 dynamic이다")
    func immutableConstant() {
        let prefix = "static NSString *const CHANNEL = @\"camera\";\n"
        let result = scan(prefix + block("CHANNEL"))
        #expect(result.facts.first?.channel == "camera")
        #expect(result.facts.first?.isDynamic == false)
        let shadowed = (prefix + block("CHANNEL")).replacingOccurrences(
            of: "FlutterMethodChannel *channel", with: "NSString *CHANNEL = @\"other\"; FlutterMethodChannel *channel"
        )
        #expect(scan(shadowed).facts.first?.isDynamic == true)
    }

    @Test("메서드 인자가 파일 상수를 가리면 그 리터럴로 조인하지 않는다")
    func methodParameterShadowsConstant() {
        let source = ("static NSString *const CHANNEL = @\"camera\";\n" + block("CHANNEL"))
            .replacingOccurrences(of: "registerWithRegistrar:", with: "install:(NSString *)CHANNEL registrar:")
        let result = scan(source)
        #expect(result.facts.first?.isDynamic == true)
        #expect(result.facts.first?.channel != "camera")
    }

    @Test("괄호와 형변환을 거친 nil도 등록 해제다")
    func parenthesizedNullIsNotARegistration() {
        let argument = "^(FlutterMethodCall *call, FlutterResult result) {  }"
        for null in ["(nil)", "((NULL))", "(FlutterMethodCallHandler)nil", "((void *)0)"] {
            #expect(scan(block(body: "").replacingOccurrences(of: argument, with: null)).facts.isEmpty)
        }
    }

    @Test("직접 비교를 읽었어도 메서드 이름의 별칭 사용은 공백으로 남긴다")
    func aliasesDoNotHideBehindAKnownBranch() {
        let result = scan(block(body: """
            NSString *name = call.method;
            if ([name isEqualToString:@"aliasMethod"]) {}
            if ([call.method isEqualToString:@"directMethod"]) {}
            """))
        #expect(result.facts.compactMap(\.method) == ["directMethod"])
        #expect(result.opaqueHandlerChannels == ["camera"])
    }

    @Test("동적 채널과 메서드는 다른 정적 리터럴로 바꾸지 않는다")
    func dynamicNames() {
        let dynamic = scan(block("getChannelName()", body: "if ([call.method isEqualToString:methodName]) {}"))
        #expect(dynamic.facts.count == 2)
        #expect(dynamic.facts.allSatisfy { $0.isDynamic })
        #expect(dynamic.facts.last?.method == "methodName")
        #expect(scan(block("@\"a\" @\"b\"")).facts.first?.isDynamic == true)
    }

    @Test("주석과 문자열 안의 가짜 핸들러를 읽지 않는다")
    func commentsAndStrings() {
        let source = block(body: """
            // if ([call.method isEqualToString:@"fake"]) {}
            /* // if ([call.method isEqualToString:@"fake2"]) {} */
            NSLog(@"if ([call.method isEqualToString:fake3]) {}");
            if ([call.method isEqualToString:@"real"]) {}
            """)
        #expect(scan(source).facts.compactMap(\.method) == ["real"])
    }

    @Test("문자열 이스케이프와 UTF-8 열 번호를 보존한다")
    func literalAndLocation() throws {
        let source = block(body: #"/* 사진 */ if ([call.method isEqualToString:@"a\"b\\c]"]) {}"#)
        let fact = try #require(scan(source).facts.last)
        #expect(fact.method == "a\"b\\c]")
        let line = String(source.split(separator: "\n")[fact.location.line - 1])
        let location = try #require(line.range(of: "@\"a"))
        #expect(fact.location.column == line[..<location.lowerBound].utf8.count + 1)
        #expect(scan(block("@\"a\\n\"")).facts.first?.isDynamic == true)
    }

    @Test("CR과 CRLF 줄바꿈에서도 주석 경계와 원본 위치가 맞는다")
    func carriageReturnLines() {
        for newline in ["\r", "\r\n"] {
            let source = ("// header\n" + block()).replacingOccurrences(of: "\n", with: newline)
            let result = scan(source)
            #expect(result.facts.count == 2)
            #expect(result.facts.last?.location.line == 5)
        }
    }

    @Test("조건부 컴파일과 API 가림과 깨진 토큰은 추측하지 않는다")
    func uncertainFileIsDeferred() {
        #expect(scan("#if FEATURE\n" + block() + "\n#endif").facts.isEmpty)
        #expect(scan("#define CHANNEL @\"camera\"\n" + block()).facts.isEmpty)
        #expect(scan("@interface FlutterMethodChannel : NSObject @end\n" + block()).facts.isEmpty)
        #expect(scan(block() + "/* unfinished").facts.isEmpty)
        #expect(scan(block() + "\"").facts.isEmpty)
        #expect(scan(block() + "}").facts.isEmpty)
    }

    @Test("부정 조건이나 복합 조건을 긍정 메서드 분기로 오인하지 않는다")
    func negationAndCompoundConditions() {
        for condition in ["![call.method isEqualToString:@\"x\"]", "[call.method isEqualToString:@\"x\"] && enabled"] {
            let result = scan(block(body: "if (\(condition)) {}"))
            #expect(result.facts.map(\.kind) == [.channelRegister])
            #expect(result.opaqueHandlerChannels == ["camera"])
        }
    }

    @Test("다른 객체의 method나 가려진 call을 핸들러 분기로 읽지 않는다")
    func shadowedCall() {
        let unrelated = scan(block(body: "if ([request.method isEqualToString:@\"DELETE\"]) {}"))
        #expect(unrelated.facts.compactMap(\.method).isEmpty)
        let shadowed = scan(block(body: "{ NSObject *call; if ([call.method isEqualToString:@\"fake\"]) {} }"))
        #expect(shadowed.facts.compactMap(\.method).isEmpty)
        #expect(shadowed.opaqueHandlerChannels == ["camera"])
        for prefix in ["rewrite(&call);", "{ CallAlias call;", "{ Wrapper<CallAlias> call;"] {
            let close = prefix.hasPrefix("{") ? "}" : ""
            let result = scan(block(body: prefix + " if ([call.method isEqualToString:@\"fake\"]) {}" + close))
            #expect(result.facts.compactMap(\.method).isEmpty)
        }
    }

    @Test("등록 해제와 생성만 한 객체는 등록 사실이 아니다")
    func unregisterAndConstructorOnly() {
        let source = block().replacingOccurrences(
            of: "[channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) { if ([call.method isEqualToString:@\"takePhoto\"]) { result(nil); } }];",
            with: "[channel setMethodCallHandler:nil];"
        )
        #expect(scan(source).facts.isEmpty)
        #expect(scan(source.replacingOccurrences(of: "[channel setMethodCallHandler:nil];", with: "")).facts.isEmpty)
    }

    @Test("재대입과 주소 전달 뒤에는 첫 채널 이름을 재사용하지 않는다")
    func mutationInvalidatesBinding() {
        for mutation in ["channel = other;", "replace(&channel);"] {
            let source = block().replacingOccurrences(of: "[channel setMethodCallHandler:", with: mutation + " [channel setMethodCallHandler:")
            let facts = scan(source).facts
            #expect(!facts.isEmpty)
            #expect(facts.allSatisfy { $0.isDynamic })
        }
    }

    @Test("한 홉 더 위임하는 본문은 공백으로 남긴다")
    func forwardedHandler() {
        let result = scan(block(body: "[self handleElsewhere:call result:result];"))
        #expect(result.facts.map(\.kind) == [.channelRegister])
        #expect(result.opaqueHandlerChannels == ["camera"])
    }
}
