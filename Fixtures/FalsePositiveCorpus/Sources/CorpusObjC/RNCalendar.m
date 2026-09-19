// Objective-C 소스의 실제 Clang 그래프와 브리지 정체성을 검증한다.
//
// 소스 한계가 실제로 세어지고, React Native 매크로의 클래스·메서드에
// 유일한 컴파일러 USR이 붙는지 확인한다.
#import "CorpusObjC.h"

@implementation RNCalendar

RCT_EXPORT_MODULE(Calendar)

RCT_EXPORT_METHOD(addEvent:(NSString *)name) {
    NSLog(@"%@", name);
}

@end

// package_info_plus의 registrar 위임과 share_plus의 문자열 상수 형태를 축소한 회귀 사례.
static NSString *const CAMERA_CHANNEL = @"com.example/objc-camera";
@implementation ObjCCameraPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:CAMERA_CHANNEL binaryMessenger:[registrar messenger]];
    ObjCCameraPlugin *instance = [[ObjCCameraPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"nativePhoto"]) {
        result(nil);
    }
}
@end
