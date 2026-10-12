func entry() -> Int { middle(1) } // oracle: entry
@main enum Runner {
    static func main() { print(entry()) } // oracle: main
}
