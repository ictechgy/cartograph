import Combine

struct DeadForwarder<Upstream: Publisher>: Publisher {
    typealias Output = Upstream.Output
    typealias Failure = Upstream.Failure

    let upstream: Upstream

    func receive<S: Subscriber>(subscriber: S)
    where Upstream.Output == S.Input, Upstream.Failure == S.Failure {
        upstream.receive(subscriber: subscriber)
    }
}
