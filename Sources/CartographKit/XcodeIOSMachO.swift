import CartographCore
import Foundation

/// 외부 도구를 실행하지 않고 실제 단일 아키텍처 Mach-O의 플랫폼·배포 하한·강한 load edge를 읽는다.
struct XcodeIOSMachO {
    let fileType: UInt32
    let minimum: UInt32
    let sdk: UInt32
    let loads: Set<String>
    let runpaths: Set<String>
    let installName: String?

    init(_ data: Data, architecture: String) throws {
        let bytes = Array(data)
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw XcodeLocalPackageIO.invalid("Truncated Mach-O word.") }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        guard ["arm64", "x86_64"].contains(architecture), bytes.count >= 32, try word(0) == 0xfeedfacf,
              try word(4) == (architecture == "arm64" ? 0x0100000c : 0x01000007) else {
            throw XcodeLocalPackageIO.invalid("Only the captured thin 64-bit iOS Simulator Mach-O architecture is supported.")
        }
        fileType = try word(12)
        let count = Int(try word(16)), size = Int(try word(20))
        guard count <= 1_024, size <= 4 * 1_024 * 1_024, 32 + size <= bytes.count else {
            throw XcodeLocalPackageIO.invalid("Mach-O load command budget exceeded.")
        }
        var offset = 32, builds: [(UInt32, UInt32)] = [], loads: Set<String> = [], paths: Set<String> = [], identity: String?
        for _ in 0..<count {
            let command = try word(offset), length = Int(try word(offset + 4))
            guard length >= 8, length % 8 == 0, offset + length <= 32 + size else {
                throw XcodeLocalPackageIO.invalid("Malformed Mach-O load command boundary.")
            }
            if command == 0x32 {
                guard length >= 24, try word(offset + 8) == 7, try word(offset + 20) <= 128,
                      24 + Int(try word(offset + 20)) * 8 == length else { throw XcodeLocalPackageIO.invalid("Mach-O is not an iOS Simulator image.") }
                builds.append((try word(offset + 12), try word(offset + 16)))
            }
            if [UInt32(0xc), 0xd, 0x8000001c].contains(command) {
                let start = Int(try word(offset + 8))
                guard start >= (command == 0x8000001c ? 12 : 24), start < length,
                      let end = bytes[(offset + start)..<(offset + length)].firstIndex(of: 0),
                      let text = String(bytes: bytes[(offset + start)..<end], encoding: .utf8), !text.isEmpty else {
                    throw XcodeLocalPackageIO.invalid("Malformed Mach-O image path command.")
                }
                if command == 0xc { guard loads.insert(text).inserted else { throw XcodeLocalPackageIO.invalid("Duplicate Mach-O load edge.") } }
                if command == 0x8000001c { paths.insert(text) }
                if command == 0xd { guard identity == nil else { throw XcodeLocalPackageIO.invalid("Duplicate Mach-O install identity.") }; identity = text }
            }
            offset += length
        }
        guard offset == 32 + size, builds.count == 1 else { throw XcodeLocalPackageIO.invalid("Missing or ambiguous Mach-O build version.") }
        minimum = builds[0].0; sdk = builds[0].1; self.loads = loads; runpaths = paths; installName = identity
    }

    static func version(_ text: String) -> UInt32? {
        guard text.range(of: #"^[0-9]+(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { UInt32($0) }
        guard numbers.count == parts.count, numbers[0] <= 65_535, numbers.dropFirst().allSatisfy({ $0 <= 255 }) else { return nil }
        return numbers[0] << 16 | (numbers.count > 1 ? numbers[1] << 8 : 0) | (numbers.count > 2 ? numbers[2] : 0)
    }
}
