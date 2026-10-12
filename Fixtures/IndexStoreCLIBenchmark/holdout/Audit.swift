struct AuditA {
    static func step(_ n: Int) -> Int { n > 0 ? AuditB.step(n - 1) : n } // oracle: audit_a
}
struct AuditB {
    static func step(_ n: Int) -> Int { n > 0 ? AuditA.step(n - 1) : n } // oracle: audit_b
}
