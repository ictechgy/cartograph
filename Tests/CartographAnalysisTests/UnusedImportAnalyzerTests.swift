import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("미사용 import 분석")
struct UnusedImportAnalyzerTests {
    /// 파일 하나의 import와 모듈 사용 근거를 담은 스냅샷을 만든다.
    /// 심볼 하나를 넣어 파일이 인덱스됐다는 사실을 세운다.
    private func snapshot(
        imports: [(module: String, line: Int)],
        usage: FileModuleUsage?,
        file: String = "/project/Sources/App/A.swift",
        module: String = "App"
    ) -> IndexSnapshot {
        var builder = SnapshotBuilder(module: module, path: file)
        builder.symbol("s:3App1SV", name: "S", module: module)
        for entry in imports {
            builder.importDecl(entry.module, path: file, line: entry.line)
        }
        if let usage {
            builder.fileModuleUsage(
                path: file, owningModule: usage.owningModule,
                referencedModules: usage.referencedModules,
                hasUnattributedReferences: usage.hasUnattributedReferences)
        }
        return builder.build()
    }

    private func analyze(_ snapshot: IndexSnapshot) -> [IndexedImport] {
        UnusedImportAnalyzer.analyze(snapshot)
    }

    @Test("참조가 없는 import만 미사용으로 보고한다")
    func reportsOnlyUnreferencedImport() {
        let snapshot = snapshot(
            imports: [("Foundation", 1), ("UnusedKit", 2)],
            usage: FileModuleUsage(owningModule: "App", referencedModules: ["App", "Foundation"])
        )
        let findings = analyze(snapshot)
        #expect(findings.map(\.module) == ["UnusedKit"])
    }

    @Test("재수출·조건부·무시 표식이 있는 import는 보고하지 않는다")
    func skipsMarkedImports() {
        var builder = SnapshotBuilder()
        builder.symbol("s:3App1SV", module: "App")
        builder.importDecl("Foundation", line: 1, isReexported: true)
        builder.importDecl("Glibc", line: 2, isConditional: true)
        builder.importDecl("UnusedKit", line: 3, isIgnored: true)
        builder.importDecl("Reported", line: 4)
        builder.fileModuleUsage(owningModule: "App", referencedModules: ["App"])
        #expect(analyze(builder.build()).map(\.module) == ["Reported"])
    }

    @Test("귀속 못 한 참조가 있는 파일의 import는 보고하지 않는다")
    func suppressesWhenUnattributed() {
        // Objective-C/clang 심볼은 USR에 모듈이 없다 — 그 참조가 바로 보고
        // 하려던 모듈의 선언일 수 있으므로 그 파일의 import는 전부 억제한다.
        let snapshot = snapshot(
            imports: [("UnusedKit", 1)],
            usage: FileModuleUsage(owningModule: "App",
                referencedModules: ["App"], hasUnattributedReferences: true)
        )
        #expect(analyze(snapshot).isEmpty)
    }

    @Test("import 없이 참조된 모듈이 있으면 외부 import를 보고하지 않는다")
    func suppressesExternalWhenUnexplained() {
        // 파일이 Foundation 심볼을 쓰는데 import Foundation이 없다 — 어떤
        // import가 재수출로 Foundation을 공급한 것이다. 외부 모듈의 내부는
        // 볼 수 없으므로 어느 import든 그 통로일 수 있다.
        let snapshot = snapshot(
            imports: [("UnusedExt", 1)],
            usage: FileModuleUsage(owningModule: "App",
                referencedModules: ["App", "Foundation"])
        )
        #expect(analyze(snapshot).isEmpty)
    }

    @Test("프로젝트 모듈은 재수출 폐포로 통로 여부를 판정한다")
    func projectModuleConduitCheck() {
        // 미설명 모듈이 있어도, 그것을 재수출하지 않는 프로젝트 모듈 import는
        // 통로가 아니므로 그대로 보고한다. 모듈이 프로젝트 소속이라는 사실은
        // 스냅샷에 그 모듈의 심볼이 있는 것으로 증명한다.
        var builder = SnapshotBuilder()
        builder.symbol("s:3App1SV", module: "App")
        builder.symbol("s:10UnusedProj1TV", module: "UnusedProj",
                       path: "/project/Sources/UnusedProj/T.swift")
        builder.importDecl("UnusedProj", line: 1)
        builder.fileModuleUsage(owningModule: "App",
            referencedModules: ["App", "Foundation"])
        #expect(analyze(builder.build()).map(\.module) == ["UnusedProj"])
    }

    @Test("미설명 모듈을 재수출하는 프로젝트 모듈은 통로로 보고 억제한다")
    func projectModuleReexportSuppresses() {
        // Reexporter 프로젝트 모듈의 파일이 `@_exported import Foundation`을 한다.
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:3App1SV", module: "App")
        // Reexporter 프로젝트 모듈의 파일이 Foundation을 재수출한다.
        builder.symbol("s:10Reexporter1RV", module: "Reexporter",
                       path: "/project/Sources/Reexporter/R.swift")
        builder.importDecl("Foundation", path: "/project/Sources/Reexporter/R.swift",
                           line: 1, isReexported: true)
        builder.fileModuleUsage(path: "/project/Sources/Reexporter/R.swift",
            owningModule: "Reexporter", referencedModules: ["Reexporter"])
        // A.swift는 Foundation을 import 없이 쓰고 Reexporter를 import한다.
        builder.importDecl("Reexporter", line: 1)
        builder.fileModuleUsage(owningModule: "App", referencedModules: ["App", "Foundation"])
        #expect(analyze(builder.build()).isEmpty)
    }

    @Test("재수출 사슬이 순환해도 사슬 끝 모듈의 통로 import를 억제한다")
    func cyclicReexportSuppressesConduit() {
        // Alpha → N, N → {M, D}, M → N 순환에서 M의 폐포는 {M, N, D}다.
        // 재귀가 Alpha→N→M 순서로 M을 먼저 메모하면 절단된 {N}만 남아
        // D가 빠지고, 그 결과 App의 `import M`이 통로가 아니라는 오판이
        // 나온다. 고정점 폐포는 경로와 무관하게 전체 도달 집합을 구한다.
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:3App1SV", module: "App")
        builder.symbol("s:5Alpha1AV", module: "Alpha", path: "/p/Alpha/A.swift")
        builder.symbol("s:1N1NV", module: "N", path: "/p/N/N.swift")
        builder.symbol("s:1M1MV", module: "M", path: "/p/M/M.swift")
        builder.symbol("s:1D1DV", module: "D", path: "/p/D/D.swift")
        builder.importDecl("N", path: "/p/Alpha/A.swift", line: 1, isReexported: true)
        builder.fileModuleUsage(path: "/p/Alpha/A.swift",
            owningModule: "Alpha", referencedModules: ["Alpha"])
        builder.importDecl("M", path: "/p/N/N.swift", line: 1, isReexported: true)
        builder.importDecl("D", path: "/p/N/N.swift", line: 2, isReexported: true)
        builder.fileModuleUsage(path: "/p/N/N.swift",
            owningModule: "N", referencedModules: ["N"])
        builder.importDecl("N", path: "/p/M/M.swift", line: 1, isReexported: true)
        builder.fileModuleUsage(path: "/p/M/M.swift",
            owningModule: "M", referencedModules: ["M"])
        // App 파일은 M만 import하고 D 심볼을 쓴다 — M → N → D 통로다.
        builder.importDecl("M", line: 1)
        builder.fileModuleUsage(owningModule: "App",
            referencedModules: ["App", "D"])
        #expect(analyze(builder.build()).isEmpty)
    }

    @Test("외부 모듈을 재수출하는 프로젝트 모듈은 어떤 미설명 모듈이든 전달할 수 있다")
    func externalReexportIsWildcard() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:3App1SV", module: "App")
        builder.symbol("s:6Bridge1BV", module: "Bridge",
                       path: "/project/Sources/Bridge/B.swift")
        // Bridge가 외부 모듈을 재수출하면 그 안의 재수출까지 볼 수 없다.
        builder.importDecl("SomeExternal", path: "/project/Sources/Bridge/B.swift",
                           line: 1, isReexported: true)
        builder.fileModuleUsage(path: "/project/Sources/Bridge/B.swift",
            owningModule: "Bridge", referencedModules: ["Bridge"])
        builder.importDecl("Bridge", line: 1)
        builder.fileModuleUsage(owningModule: "App",
            referencedModules: ["App", "Foundation"])
        #expect(analyze(builder.build()).isEmpty)
    }

    @Test("사용 근거가 없는 파일의 import는 보고하지 않는다")
    func skipsFilesWithoutUsage() {
        let snapshot = snapshot(imports: [("UnusedKit", 1)], usage: nil)
        #expect(analyze(snapshot).isEmpty)
    }

    @Test("하위 모듈 import는 탑레벨 모듈 참조로 사용 판정한다")
    func submoduleMatchesTopModule() {
        var builder = SnapshotBuilder()
        builder.symbol("s:3App1SV", module: "App")
        builder.importDecl("Foundation.Networking", line: 1)
        builder.fileModuleUsage(owningModule: "App",
            referencedModules: ["App", "Foundation"])
        #expect(analyze(builder.build()).isEmpty)
    }

    @Test("발견은 파일·줄 순으로 정렬된다")
    func deterministicOrder() {
        var builder = SnapshotBuilder()
        builder.symbol("s:3App1SV", module: "App")
        builder.importDecl("Second", path: "/b/B.swift", line: 2)
        builder.importDecl("First", path: "/a/A.swift", line: 5)
        builder.importDecl("Earlier", path: "/a/A.swift", line: 1)
        builder.fileModuleUsage(path: "/b/B.swift", owningModule: "App", referencedModules: ["App"])
        builder.fileModuleUsage(path: "/a/A.swift", owningModule: "App", referencedModules: ["App"])
        let findings = analyze(builder.build())
        #expect(findings.map(\.module) == ["Earlier", "First", "Second"])
    }

    @Test("import 목록이 비면 아무것도 보고하지 않는다")
    func emptyWithoutImports() {
        var builder = SnapshotBuilder()
        builder.symbol("s:3App1SV", module: "App")
        builder.fileModuleUsage(owningModule: "App", referencedModules: ["App"])
        #expect(analyze(builder.build()).isEmpty)
    }
}
