@testable import cartograph
import CartographCore
import Foundation
import Testing

/// 실제 git 저장소를 만들어 확인한다.
///
/// 이 계층의 결함은 전부 "보고가 조용히 좁혀져 문제 없음을 출력하는" 방향으로
/// 실패한다. 문자열 조작만으로는 재현되지 않으므로 진짜 저장소가 필요하다.
@Suite("변경 파일 목록")
struct ChangedFilesTests {
    @Test("리비전처럼 전달한 git 옵션은 실행하지 않는다")
    func doesNotInterpretReferenceAsAnOption() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let value = 1", to: "Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let destination = root.appendingPathComponent("unexpected")
        #expect(throws: CartographError.self) {
            try ChangedFiles.since("--output=\(destination.path)", workingDirectory: root.path)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path + "...HEAD"))
    }

    /// 임시 디렉터리는 심볼릭 링크 뒤에 있다. git 은 `/private/var/...` 를
    /// 돌려주는데 Foundation 의 정규화는 오히려 `/private` 을 떼어 `/var/...` 로
    /// 만든다. 두 표기를 직접 비교하면 안 되고, 실제 비교는 `ReportScope` 가
    /// 양쪽을 같은 방식으로 정규화해 수행한다. 테스트도 같은 기준으로 본다.
    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try run(["init", "-q", "."], in: root)
            try run(["config", "user.email", "t@example.com"], in: root)
            try run(["config", "user.name", "t"], in: root)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ChangedFilesTests.Git", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "git \(arguments.joined(separator: " ")) failed in \(directory.path): \(output)"])
        }
        return output
    }

    private func write(_ contents: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("커밋된 변경, 미커밋 변경, 새 파일을 모두 찾는다")
    func findsEveryKindOfChange() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try write("let t = 1", to: "Sources/Tracked.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        try write("let c = 2", to: "Sources/Committed.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "second"], in: root)
        // 추적 파일을 고치고 커밋하지 않는다. 미커밋 변경의 가장 흔한 형태다.
        try write("let t = 2", to: "Sources/Tracked.swift", in: root)
        try write("let n = 3", to: "Sources/Untracked.swift", in: root)

        let changed = try ChangedFiles.since(base, workingDirectory: root.path)
        let names = Set(changed.map { ($0 as NSString).lastPathComponent })
        #expect(names.contains("Committed.swift"))
        #expect(names.contains("Tracked.swift"))
        #expect(names.contains("Untracked.swift"))
        #expect(!names.contains("Base.swift"))
    }

    @Test("하위 디렉터리에서 실행해도 저장소 루트 기준으로 맞춘다")
    func resolvesPathsAgainstTheRepositoryRoot() throws {
        // `ls-files` 는 기본적으로 실행 디렉터리 기준 상대 경로를 낸다. 그대로
        // 루트에 이어 붙이면 존재하지 않는 경로가 되어 발견이 전부 숨겨진다.
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "pkg/Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try write("let n = 1", to: "pkg/Sources/New.swift", in: root)

        let changed = try ChangedFiles.since("HEAD", workingDirectory: root.appendingPathComponent("pkg").path)
        let expected = normalized(root.appendingPathComponent("pkg/Sources/New.swift").path)
        #expect(Set(changed.map(normalized)).contains(expected))
    }

    @Test("비ASCII 파일명도 실제 경로 그대로 준다")
    func handlesNonASCIIFileNames() throws {
        // git 의 core.quotePath 는 기본이 켜져 있어 한글 이름을 8진수로 이스케이프한다.
        // 그 문자열은 실제 경로와 절대 일치하지 않아 그 파일의 발견이 사라진다.
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try write("let k = 1", to: "Sources/새 기능.swift", in: root)

        let changed = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        let expected = normalized(root.appendingPathComponent("Sources/새 기능.swift").path)
        #expect(Set(changed.map(normalized)).contains(expected))
        // 이스케이프된 채로 나오면 실제 경로와 절대 일치하지 않는다.
        #expect(changed.allSatisfy { !$0.contains("\\") })
    }

    @Test("지워진 파일은 목록에 넣지 않는다")
    func excludesDeletedFiles() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Gone.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Gone.swift"))
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "remove"], in: root)

        let changed = try ChangedFiles.since(base, workingDirectory: root.path)
        #expect(changed.allSatisfy { !$0.hasSuffix("Gone.swift") })
    }

    @Test("영향 분석 범위는 삭제와 이름 변경의 양쪽 경로를 보존한다")
    func includesDeletedAndBothRenamePathsWhenRequested() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let gone = 1", to: "Sources/Gone.swift", in: root)
        try write("let original = 1", to: "Sources/Original.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Gone.swift"))
        try run(["mv", "Sources/Original.swift", "Sources/Renamed.swift"], in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "delete-and-rename"], in: root)

        let defaultChanged = try ChangedFiles.since(base, workingDirectory: root.path)
        #expect(defaultChanged.allSatisfy { !$0.hasSuffix("Gone.swift") })

        let impactSeeds = try ChangedFiles.since(
            base,
            workingDirectory: root.path,
            includingDeleted: true
        )
        let names = Set(impactSeeds.map { ($0 as NSString).lastPathComponent })
        #expect(names.contains("Gone.swift"))
        #expect(names.contains("Original.swift"))
        #expect(names.contains("Renamed.swift"))
    }

    @Test("git 준비 명령의 실패를 성공한 빈 출력으로 삼지 않는다")
    func rejectsFailedGitSetup() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try run(["rev-parse", "--verify", "missing-reference"], in: root)
            Issue.record("The deliberately invalid Git command unexpectedly succeeded")
        } catch {
            let reported = error as NSError
            #expect(reported.domain == "ChangedFilesTests.Git")
            #expect(reported.code != 0)
            #expect(reported.localizedDescription.contains("git rev-parse --verify missing-reference"))
        }
    }

    @Test("diff.relative 설정과 하위 실행 위치가 추적 파일의 변경 범위를 좁히지 않는다")
    func trackedChangesIgnoreRelativeConfiguration() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixes = ["", "pkg/Sources/"]
        let phases = ["Committed", "Staged", "Unstaged"]
        for prefix in prefixes {
            for phase in phases {
                try write("let \(phase.lowercased()) = 1", to: prefix + phase + ".swift", in: root)
            }
        }
        try write("let unchanged = 1", to: "pkg/Sources/Unchanged.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            try write("let committed = 2", to: prefix + "Committed.swift", in: root)
        }
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "tracked-committed"], in: root)
        for prefix in prefixes {
            try write("let staged = 2", to: prefix + "Staged.swift", in: root)
        }
        try run(["add", "-A"], in: root)
        for prefix in prefixes {
            try write("let unstaged = 2", to: prefix + "Unstaged.swift", in: root)
        }
        let all = Set(prefixes.flatMap { prefix in phases.map { prefix + $0 + ".swift" } }
            .map { normalized(root.appendingPathComponent($0).path) })
        let pending = Set(prefixes.flatMap { prefix in ["Staged", "Unstaged"].map { prefix + $0 + ".swift" } }
            .map { normalized(root.appendingPathComponent($0).path) })
        for relative in ["false", "true"] {
            try run(["config", "diff.relative", relative], in: root)
            for directory in [root, root.appendingPathComponent("pkg")] {
                for includingDeleted in [false, true] {
                    #expect(Set(try ChangedFiles.since(base, workingDirectory: directory.path,
                        includingDeleted: includingDeleted).map(normalized)) == all)
                    #expect(Set(try ChangedFiles.since("HEAD", workingDirectory: directory.path,
                        includingDeleted: includingDeleted).map(normalized)) == pending)
                }
            }
        }
    }

    @Test("하위 실행 위치에서도 이름 변경과 삭제의 두 모드가 설정에 독립적이다")
    func renameAndDeletionModesIgnoreRelativeConfiguration() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try run(["config", "diff.renames", "true"], in: root)
        // 삭제된 잎 경로에는 파일시스템 별칭 해석을 적용하지 않는다.
        // git 이 확인한 저장소 루트와 기대하는 상대 경로를 그대로 이어 비교한다.
        let repositoryRoot = try run(["rev-parse", "--show-toplevel"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["", "pkg/Sources/"]
        for prefix in prefixes {
            for name in ["CommittedOriginal", "StagedOriginal", "CommittedGone", "StagedGone", "UnstagedGone"] {
                try write("// \(prefix)\(name)\nlet value = 1", to: prefix + name + ".swift", in: root)
            }
        }
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            try run(["mv", prefix + "CommittedOriginal.swift", prefix + "CommittedRenamed.swift"], in: root)
            try run(["rm", prefix + "CommittedGone.swift"], in: root)
        }
        try run(["commit", "-qm", "committed-delete-and-rename"], in: root)
        for prefix in prefixes {
            try run(["mv", prefix + "StagedOriginal.swift", prefix + "StagedRenamed.swift"], in: root)
            try run(["rm", prefix + "StagedGone.swift"], in: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent(prefix + "UnstagedGone.swift"))
        }
        let surviving = Set(prefixes.flatMap { prefix in
            ["CommittedRenamed", "StagedRenamed"].map { prefix + $0 + ".swift" }
        }.map { (repositoryRoot as NSString).appendingPathComponent($0) })
        let removed = Set(prefixes.flatMap { prefix in
            ["CommittedOriginal", "StagedOriginal", "CommittedGone", "StagedGone", "UnstagedGone"]
                .map { prefix + $0 + ".swift" }
        }.map { (repositoryRoot as NSString).appendingPathComponent($0) })
        for relative in ["false", "true"] {
            try run(["config", "diff.relative", relative], in: root)
            for directory in [root, root.appendingPathComponent("pkg")] {
                let withoutDeleted = try ChangedFiles.since(base, workingDirectory: directory.path)
                let withDeleted = try ChangedFiles.since(
                    base, workingDirectory: directory.path, includingDeleted: true)
                let expectedWithDeleted = surviving.union(removed)
                #expect(withoutDeleted == surviving,
                    "diff.relative=\(relative), cwd=\(directory.path): actual=\(withoutDeleted.sorted()), expected=\(surviving.sorted())")
                #expect(withDeleted == expectedWithDeleted,
                    "diff.relative=\(relative), cwd=\(directory.path): actual=\(withDeleted.sorted()), expected=\(expectedWithDeleted.sorted())")
            }
        }
    }

    @Test("없는 기준점은 git 이 말한 이유를 그대로 전한다")
    func reportsWhatGitSaid() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)

        #expect(throws: CartographError.self) {
            try ChangedFiles.since("nosuchrevision", workingDirectory: root.path)
        }
    }

    // MARK: - 분석 대상 저장소가 고른 .git 설정의 명령 실행 차단 (D1)

    /// 분석 대상 저장소가 정의한 콘텐츠 필터는 실행하면 안 되는 명령이다. 표식을
    /// 남기는 무해한 필터를 꾸민다. 필터가 돌면 표식 파일이 생기므로, 표식 디렉터리가
    /// 비어 있으면 명령이 실행되지 않은 것이다. 표식은 작업 트리 밖에 둔다.
    private func makeMarkerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func markerCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? -1
    }

    /// 같은 내용을 새 inode 로 다시 써서(atomically) 체크아웃·압축 해제처럼 stat 을 어긋나게 한다.
    ///
    /// `--since` 의 작업 트리 diff 는 `diff.autoRefreshIndex=false` 라 stat 이 어긋난 항목을 다시 읽지 않고 변경으로
    /// 센다. 그래서 이 도우미를 쓰는 테스트는 refresh 를 끈 결과를 고정할 뿐, 필터 무력화는 시험하지 못한다
    /// (무력화를 빼도 통과한다). 무력화는 내용을 다시 읽는 racy 항목(`makeRacy`)으로 시험한다.
    private func restat(_ path: String, contents: String, in root: URL) throws {
        try write(contents, to: path, in: root)
    }

    /// 추적 파일들을 racy 항목으로 만든다. 인덱스의 stat 은 작업 트리와 같지만 항목 mtime 이 인덱스 파일보다 새롭다.
    ///
    /// git 은 racy 항목을 stat 만으로 믿지 않고 내용을 다시 읽으며, 그때 필터가 돈다. refresh 를 끈 작업 트리 diff
    /// 에서 필터가 불릴 수 있는 길은 이것뿐이다. mtime 을 미래로 옮기고 `update-index --refresh` 로 그 stat 을
    /// 인덱스에 기록한다(인덱스 파일은 지금 시각에 쓰여 항목보다 오래된다). refresh 가 필터를 돌리지 않도록
    /// 필터를 정의하기 전에 부른다.
    private func makeRacy(_ paths: [String], in root: URL) throws {
        let future = Date().addingTimeInterval(600)
        for relative in paths {
            try FileManager.default.setAttributes(
                [.modificationDate: future], ofItemAtPath: root.appendingPathComponent(relative).path)
        }
        try run(["update-index", "--refresh"], in: root)
    }

    @Test("racy 추적 파일을 다시 읽을 때도 저장소의 필터(점 든 이름, required=true 인 process)를 실행하지 않는다")
    func doesNotRunContentFiltersOnRacyEntries() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("*.swift filter=evil\n*.txt filter=proc\n", to: ".gitattributes", in: root)
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try write("text", to: "Docs/N.md", in: root)
        try write("plain", to: "Docs/P.txt", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try makeRacy(["Sources/A.swift", "Docs/N.md", "Docs/P.txt"], in: root)

        try run(["config", "filter.evil.clean", "touch '\(markers.path)/clean'; cat"], in: root)
        try run(["config", "filter.deep.name.clean", "touch '\(markers.path)/dotted'; cat"], in: root)
        // required=true 인 process 필터를 끄지 못하면 git 이 그 명령을 띄우고,
        // 필터 프로토콜을 모르는 명령이라 128 로 죽는다.
        try run(["config", "filter.proc.process", "touch '\(markers.path)/process'; cat"], in: root)
        try run(["config", "filter.proc.required", "true"], in: root)
        try "*.md filter=deep.name\n".write(
            to: root.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)

        for includingDeleted in [false, true] {
            let changed = try ChangedFiles.since(
                "HEAD", workingDirectory: root.path, includingDeleted: includingDeleted)
            // 필터 없이 다시 읽은 내용이 기록과 같으므로 변경이 아니다.
            #expect(changed.isEmpty, "includingDeleted=\(includingDeleted): \(changed.sorted())")
        }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("이름이 빈 필터 드라이버([filter \"\"])도 racy 추적 파일에서 실행하지 않는다")
    func doesNotRunEmptyNamedFilterOnRacyEntries() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try makeRacy(["Sources/A.swift"], in: root)
        // 키 `filter..clean` 은 `[filter ""]` 절이고, 값이 빈 속성 `filter=` 가 이 드라이버를 고른다.
        try run(["config", "filter..clean", "touch '\(markers.path)/empty'; cat"], in: root)
        try "* filter=\n".write(
            to: root.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)

        for includingDeleted in [false, true] {
            _ = try ChangedFiles.since("HEAD", workingDirectory: root.path, includingDeleted: includingDeleted)
        }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("설정 키에서 드라이버 이름을 떼어 낸다(빈 이름과 점 든 이름 포함)")
    func extractsDriverNamesFromConfigKeys() {
        #expect(ChangedFiles.driverName(fromConfigKey: "filter.evil.clean") == "evil")
        #expect(ChangedFiles.driverName(fromConfigKey: "filter.deep.name.process") == "deep.name")
        #expect(ChangedFiles.driverName(fromConfigKey: "filter..smudge") == "")
        // 부분절이 없는 `[filter] clean = …` 은 git 이 드라이버로 쓰지 않는다.
        #expect(ChangedFiles.driverName(fromConfigKey: "filter.clean") == nil)
        #expect(ChangedFiles.driverName(fromConfigKey: "diff.evil.textconv") == nil)
    }

    @Test("분석 대상 저장소의 clean 필터(점 든 이름 포함)를 실행하지 않는다")
    func doesNotRunContentFilters() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        // 속성은 base 커밋에 넣고 필터 값은 커밋 뒤에 정의한다. 그래야 add·commit 단계가
        // 아니라 분석 단계에서만 필터가 돌 수 있다(커밋 직후 같은 초라 추적 파일이 racy 하면
        // git 이 커밋 중에도 내용을 다시 읽어 필터를 실행해 설정 단계의 표식이 섞인다).
        try write("*.swift filter=evil\n", to: ".gitattributes", in: root)
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try write("text", to: "Docs/N.md", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)

        try run(["config", "filter.evil.clean", "touch '\(markers.path)/clean'; cat"], in: root)
        try run(["config", "filter.deep.name.clean", "touch '\(markers.path)/dotted'; cat"], in: root)
        try run(["config", "filter.evil.smudge", "touch '\(markers.path)/smudge'; cat"], in: root)
        // .git/info/attributes 는 커밋되지 않지만 git 이 읽는다. --attr-source 로는 막지 못한다.
        try "*.md filter=deep.name\n".write(
            to: root.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)

        try restat("Sources/A.swift", contents: "let a = 1", in: root)
        try restat("Docs/N.md", contents: "text", in: root)
        _ = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        try restat("Sources/A.swift", contents: "let a = 1", in: root)
        try restat("Docs/N.md", contents: "text", in: root)
        _ = try ChangedFiles.since("HEAD", workingDirectory: root.path, includingDeleted: true)
        #expect(markerCount(in: markers) == 0)
    }

    @Test("required=true 인 process 필터도 실행하지 않고 실패시키지 않는다")
    func disablesRequiredProcessFilters() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("*.swift filter=proc\n", to: ".gitattributes", in: root)
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try run(["config", "filter.proc.process", "touch '\(markers.path)/proc'; cat"], in: root)
        try run(["config", "filter.proc.required", "true"], in: root)

        try restat("Sources/A.swift", contents: "let a = 1", in: root)
        // required=true 를 끄지 않으면 git 이 128 로 죽는다. 무력화하면 그냥 성공해야 한다.
        _ = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        #expect(markerCount(in: markers) == 0)
    }

    @Test("`-c` 로 끌 수 없는 `=` 바이트는 결합 문자가 뒤따라도 fail-closed 로 거부한다",
          arguments: ["ev=il", "ev=\u{0301}il"])
    func failsClosedOnUndisableableFilterName(name: String) throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("*.swift filter=\(name)\n", to: ".gitattributes", in: root)
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        // 이름에 `=` 가 들어가면 `-c filter.<이름>.clean=` 의 키가 첫 `=` 에서 잘려 무력화되지 않는다.
        try run(["config", "filter.\(name).clean", "touch '\(markers.path)/eq'; cat"], in: root)

        try restat("Sources/A.swift", contents: "let a = 1", in: root)
        #expect(throws: CartographError.self) {
            try ChangedFiles.since("HEAD", workingDirectory: root.path)
        }
        #expect(throws: CartographError.self) {
            try ChangedLines.since("HEAD", workingDirectory: root.path)
        }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("UTF-8 이 아닌 필터 이름은 손실 변환 없이 두 조회 모두 실행 전에 거부한다")
    func failsClosedOnNonUTF8FilterName() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1\n", to: "A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        // 파일명은 정상 UTF-8 이고, Git 설정/속성 안의 드라이버 이름만 원시 바이트다.
        var attributes = Data("*.swift filter=".utf8)
        attributes.append(0xff)
        attributes.append(Data("\n".utf8))
        try attributes.write(to: root.appendingPathComponent(".gitattributes"))
        let configURL = root.appendingPathComponent(".git/config")
        var config = try Data(contentsOf: configURL)
        config.append(Data("\n[filter \"".utf8))
        config.append(0xff)
        config.append(Data("\"]\nclean = \"touch '\(markers.path)/clean'; cat\"\nrequired = true\n".utf8))
        try config.write(to: configURL)
        try restat("A.swift", contents: "let a = 2\n", in: root)
        #expect(throws: CartographError.self) { try ChangedFiles.since("HEAD", workingDirectory: root.path) }
        #expect(throws: CartographError.self) { try ChangedLines.since("HEAD", workingDirectory: root.path) }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("정규화상 같은 이름과 선행 결합 문자도 Git 의 원시 바이트별로 모두 무력화한다")
    func neutralizesCanonicallyEquivalentFilterNames() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1\n", to: "A.swift", in: root)
        try write("let b = 1\n", to: "B.swift", in: root)
        try write("let c = 1\n", to: "C.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"
        let leadingMark = "\u{0301}driver"
        try write("A.swift filter=\(nfc)\nB.swift filter=\(nfd)\nC.swift filter=\(leadingMark)\n",
                  to: ".gitattributes", in: root)
        let configURL = root.appendingPathComponent(".git/config")
        var config = try Data(contentsOf: configURL)
        for (name, marker) in [(nfc, "nfc"), (nfd, "nfd"), (leadingMark, "leading")] {
            config.append(Data("\n[filter \"\(name)\"]\nclean = \"touch '\(markers.path)/\(marker)'; cat\"\n".utf8))
        }
        try config.write(to: configURL)
        try restat("A.swift", contents: "let a = 2\n", in: root)
        try restat("B.swift", contents: "let b = 2\n", in: root)
        try restat("C.swift", contents: "let c = 2\n", in: root)
        let arguments = try #require(try ChangedFiles.filterNeutralizationArguments(
            workingDirectory: root.path, reference: "HEAD"))
        let keys = Set(arguments.filter { $0.utf8.starts(with: "filter.".utf8) }.map { Data($0.utf8) })
        let keyHex = keys.map { $0.map { String(format: "%02x", $0) }.joined() }.sorted()
        #expect(keys.count == 12, "override keys: \(keyHex)")
        _ = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        _ = try ChangedLines.since("HEAD", workingDirectory: root.path)
        let observedMarkers = try FileManager.default.contentsOfDirectory(atPath: markers.path)
        #expect(observedMarkers.isEmpty, "drivers executed: \(observedMarkers)")
    }

    @Test("서브모듈 로컬 저장소가 정의한 필터도 실행하지 않는다")
    func doesNotRunSubmoduleLocalFilters() throws {
        let library = try makeRepository()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("let l = 1", to: "L.swift", in: library)
        try run(["add", "-A"], in: library)
        try run(["commit", "-qm", "lib"], in: library)

        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "sub"], in: root)
        try run(["commit", "-qm", "sub"], in: root)
        // 서브모듈 저장소에만 있는 드라이버는 상위 저장소 설정에 없어 이름으로 무력화하지 못한다.
        // --ignore-submodules 로 서브모듈 안에서 git 을 다시 띄우지 않아야 막힌다.
        try run(["-C", "sub", "config", "filter.subevil.clean", "touch '\(markers.path)/sub'; cat"], in: root)
        try "* filter=subevil\n".write(
            to: root.appendingPathComponent(".git/modules/sub/info/attributes"), atomically: true, encoding: .utf8)

        try restat("sub/L.swift", contents: "let l = 1", in: root)
        _ = try ChangedFiles.since("HEAD", workingDirectory: root.path, includingDeleted: true)
        #expect(markerCount(in: markers) == 0)
    }

    // MARK: - partial clone 의 lazy fetch 차단

    /// 객체가 저장소에 없는지. 확인하는 git 이 그 객체를 받아 오지 않게 lazy fetch 를 끄고 묻는다.
    private func objectIsMissing(_ id: String, in root: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "cat-file", "-e", id]
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_NO_LAZY_FETCH": "1"]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("git cat-file could not start: \(error)")
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus != 0
    }

    /// 느슨한 객체 파일 하나를 지운다. partial clone 이 받지 않은 객체처럼 저장소에서 빠진다.
    private func removeLooseObject(_ id: String, in root: URL) throws {
        let directory = root.appendingPathComponent(".git/objects").appendingPathComponent(String(id.prefix(2)))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(String(id.dropFirst(2))))
    }

    @Test("partial clone 의 빠진 객체를 promisor 원격에서 받아 오지 않고, blobless 클론의 변경은 그대로 찾는다")
    func doesNotLazyFetchFromPromisorRemote() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-lazy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try run(["init", "-q", "."], in: source)
        try run(["config", "user.email", "t@example.com"], in: source)
        try run(["config", "user.name", "t"], in: source)
        // 이름 변경 감지가 옛 blob 내용을 요구하도록, 줄이 많은 파일을 옮기고 한 줄만 고친다.
        var lines = (1...300).map { "line number \($0)" }
        try write(lines.joined(separator: "\n"), to: "big.txt", in: source)
        try run(["add", "-A"], in: source)
        try run(["commit", "-qm", "A"], in: source)
        try run(["tag", "base"], in: source)
        try run(["mv", "big.txt", "big2.txt"], in: source)
        lines[149] = "changed line"
        try write(lines.joined(separator: "\n"), to: "big2.txt", in: source)
        try run(["commit", "-qam", "B"], in: source)
        let server = base.appendingPathComponent("server.git")
        try run(["clone", "-q", "--bare", source.path, server.path], in: base)
        try run(["config", "uploadpack.allowFilter", "true"], in: server)
        let clone = base.appendingPathComponent("clone")
        try run(["clone", "-q", "--filter=blob:none", "file://" + server.path, clone.path], in: base)
        let oldBlob = try run(["rev-parse", "base:big.txt"], in: clone)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(objectIsMissing(oldBlob, in: clone), "the blobless clone should not hold the old blob yet")
        // lazy fetch 가 일어나면 git 은 원격의 upload-pack 명령을 셸로 실행한다. `.git` 이 고를 수 있는 설정이다.
        let marker = base.appendingPathComponent("marker")
        try run(["config", "remote.origin.uploadpack", "touch '\(marker.path)'; git-upload-pack"], in: clone)

        let changed = try ChangedFiles.since("base", workingDirectory: clone.path)
        let seeds = try ChangedFiles.since("base", workingDirectory: clone.path, includingDeleted: true)
        #expect(Set(changed.map { ($0 as NSString).lastPathComponent }) == ["big2.txt"])
        #expect(Set(seeds.map { ($0 as NSString).lastPathComponent }) == ["big.txt", "big2.txt"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(objectIsMissing(oldBlob, in: clone))
    }

    @Test("줄 비교에 필요한 blob 이 없으면 필터링 성공이나 lazy fetch 로 넘어가지 않는다")
    func changedLinesDoNotFetchMissingBlobs() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1", to: "A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = try run(["rev-parse", "HEAD:A.swift"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("let a = 2", to: "A.swift", in: root)
        try run(["commit", "-qam", "current"], in: root)
        try removeLooseObject(blob, in: root)
        try run(["config", "remote.origin.url", root.path], in: root)
        try run(["config", "remote.origin.promisor", "true"], in: root)
        try run(["config", "remote.origin.uploadpack", "touch '\(markers.path)/fetch'; git-upload-pack"], in: root)
        #expect(throws: CartographError.self) { try ChangedLines.since(base, workingDirectory: root.path) }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("비교에 필요한 트리가 빠져 있으면 promisor 원격에서 받아 오지 않고 fail-closed 로 멈춘다")
    func failsClosedWhenComparisonNeedsAMissingTree() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = try makeMarkerDirectory()
        defer { try? FileManager.default.removeItem(at: markers) }
        try write("let a = 1", to: "Sources/A.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTree = try run(["rev-parse", "HEAD^{tree}"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("let b = 2", to: "Sources/B.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "second"], in: root)
        // 공격자가 배포한 `.git` 처럼 트리 하나를 빼고, promisor 원격의 upload-pack 을 표식 명령으로 둔다.
        try removeLooseObject(baseTree, in: root)
        try run(["config", "remote.origin.url", root.path], in: root)
        try run(["config", "remote.origin.promisor", "true"], in: root)
        try run(["config", "remote.origin.uploadpack", "touch '\(markers.path)/fetch'; git-upload-pack"], in: root)

        #expect(throws: CartographError.self) {
            try ChangedFiles.since(base, workingDirectory: root.path)
        }
        #expect(markerCount(in: markers) == 0)
    }

    @Test("정규화 필터로 내용이 바뀌던 파일은 stat 이 어긋나면 변경으로 포함한다")
    func normalizingFilterStaleFileCountsAsChanged() throws {
        // git-lfs 처럼 clean 이 내용을 바꾸던 파일은, 필터를 끈 채 stat 이 어긋나면
        // 변경으로 보인다. 발견을 숨기지 않는 보수적(상위집합) 방향이다.
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try run(["config", "filter.upper.clean", "tr a-z A-Z"], in: root)
        try write("*.txt filter=upper\n", to: ".gitattributes", in: root)
        try write("hello", to: "Sources/N.txt", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        // stat 을 확실히 어긋나게 한다. 빠뜨리면 쓰기와 인덱스 기록이 같은 초일 때(racy)만 통과한다.
        try restat("Sources/N.txt", contents: "hello", in: root)

        let changed = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        #expect(changed.contains { $0.hasSuffix("Sources/N.txt") })
    }
}
