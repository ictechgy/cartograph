import CartographCore
import Foundation

/// 외부 보존 근거 파일 입출력.
///
/// 베이스라인과 같은 이유로 형식과 버전을 검사한다. 조용히 아무것도 보존하지 않으면
/// 사용자는 isthmus 가 돌려준 결과가 반영됐다고 믿은 채 핸들러를 지운다.
public struct ExternalRetentionStore: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func load(from path: String) throws -> ExternalRetentionsDocument {
        guard fileSystem.fileExists(at: path) else {
            throw CartographError.invalidExternalRetentions(path: path, reason: "file not found")
        }
        let document: ExternalRetentionsDocument
        do {
            document = try JSONDecoder().decode(ExternalRetentionsDocument.self, from: fileSystem.readData(at: path))
        } catch {
            throw CartographError.invalidExternalRetentions(path: path, reason: "\(error)")
        }
        guard document.format == ExternalRetentionsDocument.expectedFormat else {
            throw CartographError.invalidExternalRetentions(
                path: path,
                reason: "format is '\(document.format)', expected '\(ExternalRetentionsDocument.expectedFormat)'"
            )
        }
        guard document.version == ExternalRetentionsDocument.supportedVersion else {
            throw CartographError.invalidExternalRetentions(
                path: path,
                reason: "format version \(document.version) is not supported "
                    + "(this build reads version \(ExternalRetentionsDocument.supportedVersion))"
            )
        }
        return document
    }

    /// 경로가 있으면 읽고, 없으면 nil. 경로를 줬는데 파일이 없으면 오류다.
    ///
    /// 베이스라인과 달리 "있으면 쓴다"가 아니다. 이 파일을 지정한 사용자는 그것이
    /// 반영되기를 기대하고, 반영되지 않은 결과로 삭제를 결정하면 앱이 깨진다.
    public func loadIfConfigured(at path: String?) throws -> ExternalRetentionsDocument? {
        try path.map(load(from:))
    }
}

/// 외부 보존 근거를 USR 과 정규화된 이름으로 빠르게 찾기 위한 색인.
public struct ExternalRetentionIndex: Sendable, Equatable {
    private let byUSR: [String: ExternalRetention]
    private let byQualifiedName: [String: ExternalRetention]
    private let retentions: [ExternalRetention]

    public init(_ retentions: [ExternalRetention]) {
        self.retentions = retentions
        // 같은 심볼에 근거가 여럿이면 첫 것을 쓴다. 어느 것이든 살리는 결론은 같다.
        byUSR = Dictionary(
            retentions.compactMap { retention in retention.symbol.usr.map { ($0, retention) } },
            uniquingKeysWith: { first, _ in first }
        )
        byQualifiedName = Dictionary(
            retentions.compactMap { retention in retention.symbol.qualifiedName.map { ($0, retention) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public static let empty = ExternalRetentionIndex([])

    public var count: Int { retentions.count }
    public var isEmpty: Bool { retentions.isEmpty }

    /// 정점에 해당하는 근거. USR 을 먼저 보고, 없으면 정규화된 이름으로 본다.
    ///
    /// USR 이 정확하다. 이름은 모듈이 같은 두 선언을 구분하지 못하지만, isthmus 가
    /// USR 없는 사실(Objective-C 등)로 만든 근거는 이름밖에 없다.
    public func retention(for node: GraphNode) -> ExternalRetention? {
        if let usr = node.usr, let match = byUSR[usr] { return match }
        return byQualifiedName[node.qualifiedName]
    }

    /// 그래프의 어느 정점과도 맞지 않는 근거의 수.
    ///
    /// 낡은 파일은 여기서 드러난다. 이름을 바꾼 핸들러는 근거가 더는 맞지 않고,
    /// 그 수를 알리지 않으면 사용자는 파일이 최신이라고 믿는다.
    public func unmatchedCount(in graph: CodeGraph) -> Int {
        let usrs = Set(graph.sortedNodes.compactMap(\.usr))
        let names = Set(graph.sortedNodes.map(\.qualifiedName))
        return retentions.count { retention in
            !(retention.symbol.usr.map(usrs.contains) ?? false)
                && !(retention.symbol.qualifiedName.map(names.contains) ?? false)
        }
    }
}
