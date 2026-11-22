// 죽은 deadCaller 만 부른다. 호출이 다른 파일에 있어야 링크 회귀가 드러난다(같은 파일 안의 참조는 세지 않는다).
enum DeadCallee {
    static func run() {}
}
