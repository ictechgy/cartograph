import ArgumentParser
import CartographKit
import Foundation

/// `impact --format language-traversal` 의 root 를 위치 인자와 `--roots-from` 에서 모은다.
///
/// 모든 실패는 `ValidationError`(종료 코드 64)다. root 파일이 잘못된 것은 인자의 문제이지 분석 도구가 죽은
/// 것이 아니다 — `query --batch` 와 같은 이유다. 검사는 인덱스를 열기 전에 끝난다.
enum TraversalRootInput {
    /// 계약의 root 상한(isthmus `language-traversal` v1).
    static let maximumRootCount = 10_000

    /// 위치 인자 root 뒤에 `--roots-from` 의 root 를 붙이고, 같은 문자열을 빼고, 교환 규칙으로 검사한다.
    ///
    /// - Parameters:
    ///   - positional: 명령줄의 root. 입력 순서가 root 인덱스가 되므로 앞에 둔다.
    ///   - rootsFrom: 파일 경로 또는 `-`(표준 입력). 없으면 위치 인자만 쓴다.
    ///   - quiet: 참이면 usr 없는 사실을 건너뛰었다는 안내를 stderr 에 쓰지 않는다.
    ///   - standardInput: `-` 일 때 읽을 핸들. 테스트가 파이프를 넣는다.
    /// - Returns: 순회에 넘길 root 목록.
    static func roots(
        positional: [String], rootsFrom: String?, quiet: Bool, standardInput: FileHandle = .standardInput
    ) throws -> [String] {
        guard let rootsFrom else { return try validated(positional) }
        let parsed: TraversalRootList.Parsed
        do {
            parsed = try TraversalRootList.parse(try read(rootsFrom, standardInput: standardInput))
        } catch let error as TraversalRootListError {
            throw ValidationError("--roots-from: \(error)")
        }
        let roots = try validated(TraversalRootList.unique(positional + parsed.roots))
        // 검사를 통과한 뒤에만 안내한다. 실패한 실행에 "건너뛰었다" 가 먼저 찍히면 처리된 것처럼 읽힌다.
        if parsed.factsWithoutUSR > 0, !quiet {
            // 표준 출력의 문서는 같은 root 를 위치 인자로 준 것과 바이트가 같아야 하므로 안내는 stderr 로만 낸다.
            FileHandle.standardError.write(Data(("note: --roots-from skipped \(parsed.factsWithoutUSR) bridge fact(s) "
                + "without symbol.usr; a qualified name alone is not an index USR\n").utf8))
        }
        return roots
    }

    /// 빈 목록·빈 root·제어 문자·개수 상한을 검사한다. isthmus 는 제어 문자가 든 id 가 있는 문서를 통째로 거부한다.
    static func validated(_ roots: [String]) throws -> [String] {
        guard !roots.isEmpty else {
            throw ValidationError("--roots-from holds no roots; give root declarations or a non-empty root list")
        }
        // 위치를 싣지 않는다. 중복을 뺀 뒤의 순번은 사용자가 쓴 어느 목록의 줄 번호와도 맞지 않는다.
        if roots.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw ValidationError("--roots-from holds an empty or whitespace-only root; remove it or pass the symbol.usr "
                + "from routes or bridges facts")
        }
        if let bad = roots.first(where: ExchangeText.containsControlCharacter) {
            throw ValidationError("--format language-traversal roots cannot contain control characters "
                + "(\(bad.debugDescription)); isthmus rejects such ids. Pass the symbol.usr from routes or bridges facts.")
        }
        guard roots.count <= maximumRootCount else {
            throw ValidationError("--format language-traversal accepts at most \(maximumRootCount) roots "
                + "(got \(roots.count)); split the roots across runs")
        }
        return roots
    }

    /// 파일이나 표준 입력을 상한 + 1 바이트까지만 읽는다. 끝없는 입력이 메모리를 채우지 않게 한다.
    static func read(_ path: String, standardInput: FileHandle) throws -> Data {
        let limit = TraversalRootList.maximumByteCount
        let handle: FileHandle
        if path == "-" {
            handle = standardInput
        } else {
            guard let opened = FileHandle(forReadingAtPath: path) else {
                throw ValidationError("--roots-from: cannot open \(path); check that the file exists and is readable")
            }
            handle = opened
        }
        var data = Data()
        do {
            // 파이프는 한 번에 요청한 만큼 주지 않을 수 있으므로 끝이나 상한까지 되풀이해 읽는다.
            while data.count <= limit, let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty {
                data.append(chunk)
            }
        } catch {
            throw ValidationError("--roots-from: cannot read \(path) (\(error.localizedDescription)); pass a regular file or -")
        }
        return data
    }
}
