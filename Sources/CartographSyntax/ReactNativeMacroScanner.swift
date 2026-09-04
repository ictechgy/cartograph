import CartographCore
import Foundation

/// Objective-C 소스에서 React Native 내보내기 매크로를 찾는다.
///
/// Swift 로 쓴 RN 모듈도 `RCT_EXTERN_MODULE` / `RCT_EXTERN_METHOD` 를 담은 `.m` 파일이
/// 하나 있어야 JS 에 보인다. 그 파일을 읽지 않으면 Swift 쪽 `@objc` 메서드가 어느
/// 모듈 이름으로 내보내졌는지 알 수 없다. `.m` 은 이 도구가 인덱스로 분석하지 않는
/// 유일한 소스라, Interface Builder 문서처럼 텍스트로 훑는다. 매크로는 형태가
/// 고정되어 있어 파서 없이도 정확하다.
public struct ReactNativeMacroScanner: Sendable {
    /// 훑을 파일 확장자.
    public static let sourceExtensions = ["m", "mm"]

    public init() {}

    /// 파일 내용에서 사실을 뽑아낸다. 위치는 매크로가 시작하는 자리다.
    public func scan(source: String, path: String) -> [BridgeFact] {
        var facts: [BridgeFact] = []
        for block in Self.implementationBlocks(in: Self.blankingDisabledRegions(Self.blankingNoise(source))) {
            facts += Self.facts(in: block, path: path)
        }
        return facts.sorted()
    }

    /// 주석과 문자열 리터럴의 내용을 공백으로 지운다. 줄 수는 그대로다.
    ///
    /// `/* … */`, `//` 줄 끝 주석, `"…"` 문자열을 한 번에 상태 기계로 훑는다. 따로 처리하면
    /// `// TODO /* note` 의 `/*` 가 블록 주석을 여는 것으로 읽혀 뒤의 살아 있는 매크로가 통째로
    /// 사라지고, 모듈 이름이 클래스 이름으로 바뀌어 isthmus 조인이 어긋난다. 문자열 안의
    /// `//` 와 `\"` 이스케이프도 같은 자리에서 다룬다. 지운 모듈을 주석으로 남겨 둔 파일과
    /// `NSLog(@"RCT_EXPORT_METHOD(fake)")` 는 실제로 있다.
    static func blankingNoise(_ source: String) -> String {
        enum State { case code, lineComment, blockComment, string }
        var state = State.code
        var result = ""
        var iterator = Array(source).makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let c = pending { pending = nil; return c }; return iterator.next() }
        while let character = next() {
            if character == "\n" { if state == .lineComment { state = .code }; result.append("\n"); continue }
            switch state {
            case .code:
                let following = next()
                if character == "/" && following == "/" { state = .lineComment; result.append("  ") }
                else if character == "/" && following == "*" { state = .blockComment; result.append("  ") }
                else if character == "\"" { state = .string; result.append(character); pending = following }
                else { result.append(character); pending = following }
            case .lineComment:
                result.append(" ")
            case .blockComment:
                if character == "*", let following = next() {
                    if following == "/" { state = .code; result.append("  ") } else { result.append(" "); pending = following }
                } else { result.append(" ") }
            case .string:
                if character == "\\" {
                    // 이스케이프된 문자는 통째로 건너뛴다. `\\"` 의 따옴표는 닫는 따옴표다.
                    result.append(" "); if let escaped = next() { result.append(escaped == "\n" ? "\n" : " ") }
                } else if character == "\"" { state = .code; result.append(character) }
                else { result.append(" ") }
            }
        }
        return result
    }

    /// `#if 0 … #endif` 안을 공백으로 지운다. 줄 수는 그대로다.
    ///
    /// 컴파일되지 않는 코드의 매크로는 사실이 아니다. 지운 모듈을 `#if 0` 으로 남겨 두는
    /// 것은 블록 주석만큼 흔하다. `#if 0` 만 본다. 다른 조건은 어느 구성인지 알 수 없어
    /// 살아 있는 쪽으로 둔다.
    static func blankingDisabledRegions(_ source: String) -> String {
        var depth = 0
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 0, trimmed == "#if 0" || trimmed.hasPrefix("#if 0 ") || trimmed.hasPrefix("#if 0\t") {
                depth = 1; lines.append(""); continue
            }
            if depth > 0 {
                if trimmed.hasPrefix("#if") { depth += 1 }
                else if trimmed.hasPrefix("#endif") { depth -= 1 }
                // `#if 0 … #else 살아 있는 코드 #endif`. else 가지는 컴파일된다.
                else if depth == 1, trimmed.hasPrefix("#else") { depth = 0 }
                lines.append(""); continue
            }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    struct ImplementationBlock {
        /// 클래스 이름. RN 은 `RCT_EXPORT_MODULE()` 에 인자가 없으면 이것을 모듈 이름으로 쓴다.
        let className: String
        /// 블록에 속한 줄들. 파일 기준 줄 번호(1부터)와 함께.
        let lines: [(number: Int, text: String)]
    }

    static func implementationBlocks(in source: String) -> [ImplementationBlock] {
        var blocks: [ImplementationBlock] = []
        var className: String?
        var lines: [(number: Int, text: String)] = []
        // `@end` 가 빠진 블록도 버리지 않는다. 컴파일은 안 되겠지만 사실은 사실이다.
        // 파일 끝에서도, 다음 `@implementation` 을 만났을 때도 같은 규칙이다.
        func flush() {
            if let name = className { blocks.append(ImplementationBlock(className: name, lines: lines)) }
            className = nil; lines = []
        }
        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let number = offset + 1
            if let match = line.firstMatch(of: implementationPattern) {
                flush(); className = String(match.output.1)
            } else if className == nil, let match = line.firstMatch(of: externModulePattern) {
                // Swift 모듈은 `@interface RCT_EXTERN_MODULE(Name, NSObject) … @end` 로 잇는다.
                // `@implementation` 이 없으므로 이 줄 자체가 블록의 시작이자 첫 사실이다.
                className = String(match.output.1); lines.append((number, line))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("@end") {
                flush()
            } else if className != nil {
                lines.append((number, line))
            }
        }
        flush()
        return blocks
    }

    /// 블록 하나의 사실. 모듈 이름을 먼저 정하고 메서드를 거기 귀속시킨다.
    ///
    /// `RCT_EXPORT_METHOD` 가 `RCT_EXPORT_MODULE(Name)` 보다 위에 올 수 있다. 위에서
    /// 아래로 한 번에 읽으면 앞쪽 메서드가 클래스 이름에, 뒤쪽이 `Name` 에 붙는다.
    static func facts(in block: ImplementationBlock, path: String) -> [BridgeFact] {
        let moduleName = exportedModuleName(in: block)
        var facts: [BridgeFact] = []
        var hasComponentExport = false
        for (number, line) in block.lines where !isComment(line) {
            for (pattern, kind) in macroPatterns {
                guard let match = line.firstMatch(of: pattern) else { continue }
                // 뷰 매니저는 프로퍼티마다 매크로가 있지만 내보내는 컴포넌트는 하나다.
                // 프로퍼티 열 개를 같은 사실 열 건으로 내면 소비자가 열 개의 컴포넌트로 센다.
                if kind == .viewProperty {
                    guard !hasComponentExport else { continue }
                    hasComponentExport = true
                }
                let column = line.distance(from: line.startIndex, to: match.range.lowerBound) + 1
                let location = SourceLocation(path: path, line: number, column: column)
                // 빈 캡처(`RCT_EXPORT_METHOD()`)는 이름이 없는 것이지 빈 이름이 아니다.
                let argument = match.output.1.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
                facts.append(fact(kind, argument: argument, module: moduleName, at: location))
            }
        }
        return facts
    }

    private static func fact(_ kind: MacroKind, argument: String?, module: String, at location: SourceLocation) -> BridgeFact {
        switch kind {
        case .module:
            return BridgeFact(kind: .moduleExport, target: .reactNative, channel: module, location: location)
        case .method:
            // 이름이 다음 줄로 넘어가 못 읽었으면 메서드 없는 핸들이 아니라 동적 이름이다.
            // 조인은 안 되지만 한계로 세어진다.
            return BridgeFact(
                kind: .methodHandle, target: .reactNative, channel: module, method: argument,
                isDynamic: argument == nil, location: location
            )
        case .viewProperty:
            return BridgeFact(kind: .componentExport, target: .reactNative, channel: module, location: location)
        }
    }

    /// 블록이 내보내는 모듈 이름. 명시한 이름이 있으면 그것, 없으면 클래스 이름.
    static func exportedModuleName(in block: ImplementationBlock) -> String {
        for (_, line) in block.lines where !isComment(line) {
            if let match = line.firstMatch(of: exportModulePattern), let name = match.output.1, !name.isEmpty {
                return String(name)
            }
            if let match = line.firstMatch(of: externModulePattern) {
                return String(match.output.1)
            }
        }
        return block.className
    }

    /// 주석 줄은 건너뛴다. 지운 모듈을 주석으로 남겨 둔 파일이 실제로 있다.
    static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    enum MacroKind { case module, method, viewProperty }

    // `Regex` 는 Sendable 이 아니라 저장 프로퍼티로 두면 Swift 6 이 거부한다.
    // 매번 만들어도 파일 몇 개에 매크로 몇 줄이라 비용은 없다.
    static var implementationPattern: Regex<(Substring, Substring)> {
        #/@implementation\s+([A-Za-z_][A-Za-z0-9_]*)/#
    }
    static var exportModulePattern: Regex<(Substring, Substring?)> {
        #/RCT_EXPORT_MODULE\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)/#
    }
    static var externModulePattern: Regex<(Substring, Substring)> {
        #/RCT_EXTERN_MODULE\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)/#
    }

    /// 매크로 → 사실 종류. 첫 캡처가 메서드 이름(있으면)이다.
    ///
    /// `RCT_EXPORT_METHOD(addEvent:(NSString *)name)` 의 JS 이름은 첫 셀렉터 조각 `addEvent`.
    /// `RCT_REMAP_METHOD(jsName, selector:)` 는 첫 인자가 JS 이름이다.
    static var macroPatterns: [(Regex<(Substring, Substring?)>, MacroKind)] { [
        (#/RCT_EXPORT_MODULE\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)/#, .module),
        (#/RCT_EXTERN_MODULE\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?/#, .module),
        (#/RCT_(?:EXPORT|EXTERN)_METHOD\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?/#, .method),
        (#/RCT_(?:EXTERN_)?REMAP_METHOD\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?/#, .method),
        (#/RCT_EXPORT_VIEW_PROPERTY\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)?/#, .viewProperty),
    ] }
}
