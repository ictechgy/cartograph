#import <Foundation/Foundation.h>

@interface CGQuoteEngine : NSObject
+ (int)quote:(int)value NS_SWIFT_NAME(quote(_:));
+ (int)isolated:(int)value NS_SWIFT_NAME(isolated(_:));
@end
