#import <Foundation/Foundation.h>

// React Native 없이 매크로의 모양만 재현한 스텁. 스캐너는 텍스트만 본다.
#define RCT_EXPORT_MODULE(...) + (NSString *)moduleName { return @"" #__VA_ARGS__; }
#define RCT_EXPORT_METHOD(method) - (void)method
#define RCT_EXPORT_VIEW_PROPERTY(name, type)

@interface RNCalendar : NSObject
@end
