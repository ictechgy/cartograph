struct LivePlain {
    typealias Output = Int
    typealias Failure = Never

    func value() -> Int { 3 }
}
