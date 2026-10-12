enum RecursiveMessageInfo {
    case message

    init(error: Int, type: Bool) {
        if error > 1 {
            self.init(error: error - 1, type: type)
        } else if error == 1 {
            self.init(error: 0, type: type)
        } else {
            self = .message
        }
    }

    func makeErrorMessage(_ depth: Int) -> Int {
        if depth > 0 {
            return makeErrorMessage(depth - 1)
        }
        return 0
    }
}

func formatMessage() -> Int {
    let message = RecursiveMessageInfo(error: 2, type: true)
    return message.makeErrorMessage(2)
}

func renderMessage() -> Int {
    formatMessage()
}

func unusedRecursion(_ depth: Int) -> Int {
    if depth > 0 {
        return unusedRecursion(depth - 1)
    }
    return 0
}

@main
struct RecursiveCallsApp {
    static func main() {
        precondition(renderMessage() == 0)
        print("recursive calls completed")
    }
}
