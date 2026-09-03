// main.swift 의 최상위 문장이 실행 파일의 진입점이다.
import Corpus

let host = AccessorHost()
_ = host.fromGetter
var observedHost = AccessorHost()
observedHost.observed = 1
_ = enumerateModes()
_ = Money(rawValue: "1")?.default()
_ = Box(1).value
_ = Screen().render()
_ = BindingHost()
