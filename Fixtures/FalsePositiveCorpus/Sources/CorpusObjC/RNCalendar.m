// Objective-C 소스. 이 도구는 이 파일을 인덱스로 분석하지 않는다.
//
// 두 가지를 확인한다. `query` 와 `bridges` 의 limitations 에 `objective-c-sources` 가
// 실제로 세어져 나오는지, 그리고 React Native 매크로가 텍스트로 읽히는지.
#import "CorpusObjC.h"

@implementation RNCalendar

RCT_EXPORT_MODULE(Calendar)

RCT_EXPORT_METHOD(addEvent:(NSString *)name) {
    NSLog(@"%@", name);
}

@end
