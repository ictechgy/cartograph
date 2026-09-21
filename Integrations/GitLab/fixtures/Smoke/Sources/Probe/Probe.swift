@main
struct Probe {
    static func main() {
        print("Cartograph GitLab integration probe")
    }
}

// 미사용 진단을 일부러 만든다. 파이프라인의 빈 보고서 성공을 막는 표식이다.
struct UnusedService {
    func request() -> String { "unused" }
}

func unusedHelper() -> Int { 42 }
