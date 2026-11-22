// 추적되는 죽은 코드. 무시된 링크(Links/DeadChain.swift)가 이 파일을 가리킨다. 링크를 무시 소스로 다시 읽으면
// 죽은 deadCaller 가 부르는 DeadCallee.run 이 "무시 소스가 쓴다" 로 살아남는다. 둘 다 보고되어야 한다.
func deadCaller() {
    DeadCallee.run()
}
