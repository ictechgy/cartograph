struct CycleA {
    static func hop(_ n: Int) -> Int { n > 0 ? CycleB.hop(n - 1) : n } // oracle: cycle_a
}
struct CycleB {
    static func hop(_ n: Int) -> Int { n > 0 ? CycleA.hop(n - 1) : n } // oracle: cycle_b
}
