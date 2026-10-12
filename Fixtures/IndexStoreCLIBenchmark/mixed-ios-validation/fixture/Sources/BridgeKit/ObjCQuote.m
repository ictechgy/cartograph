#import "CGQuoteEngine.h"
#include "CGCore.h"

@implementation CGQuoteEngine
+ (int)quote:(int)value {
    return CGBase(value);
}

+ (int)isolated:(int)value {
    return value + 900;
}
@end
