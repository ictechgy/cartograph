#import <Foundation/Foundation.h>

// React Native 없이 매크로의 모양만 재현한 스텁. 스캐너는 텍스트만 본다.
#define RCT_EXPORT_MODULE(...) + (NSString *)moduleName { return @"" #__VA_ARGS__; }
#define RCT_EXPORT_METHOD(method) - (void)method
#define RCT_EXPORT_VIEW_PROPERTY(name, type)

@interface RNCalendar : NSObject
@end

// Flutter SDK 없이 실제 Objective-C 등록 구문을 컴파일한다. 구현은 런타임에 실행하지 않는다.
typedef void (^FlutterResult)(id value);
@interface FlutterMethodCall : NSObject
@property(nonatomic, readonly) NSString *method;
@end
@interface FlutterMethodChannel : NSObject
+ (instancetype)methodChannelWithName:(NSString *)name binaryMessenger:(id)messenger;
- (void)setMethodCallHandler:(void (^)(FlutterMethodCall *, FlutterResult))handler;
@end
@protocol FlutterPluginRegistrar <NSObject>
- (id)messenger;
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel *)channel;
@end
@interface ObjCCameraPlugin : NSObject
@end
