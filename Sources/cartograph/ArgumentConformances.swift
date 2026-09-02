import ArgumentParser
import CartographCore

// 도메인 열거형을 커맨드라인 인자로 직접 받기 위한 적합성.
//
// CLI 전용 열거형을 따로 두고 변환하는 방법도 있지만, 값이 하나 늘 때마다
// 두 곳을 고쳐야 하고 그 둘이 어긋나면 조용히 틀린 동작이 된다.
extension GraphLevel: ExpressibleByArgument {}
extension GraphFormat: ExpressibleByArgument {}
extension ReportFormat: ExpressibleByArgument {}
extension EdgeKind: ExpressibleByArgument {}
