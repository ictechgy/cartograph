import Foundation

/// 도구 실행 중 사용자에게 그대로 보여 줄 수 있는 오류.
///
/// 오류 메시지에는 원인과 다음 행동을 함께 담는다. 사용자는 대개
/// "인덱스 스토어를 못 찾았다"보다 "어떻게 만들면 되는지"를 알고 싶어 한다.
public enum CartographError: Error, Equatable, LocalizedError {
    /// 인덱스 스토어 경로를 찾지 못함.
    ///
    /// `derivedData` 는 DerivedData 를 훑어본 결과다. 이름이 하나도 맞지 않으면 후보
    /// 경로가 한 줄도 생기지 않아, 목록만으로는 그곳을 보기라도 했는지 알 수 없었다.
    case indexStoreNotFound(searchedPaths: [String], derivedData: DerivedDataSearch? = nil)
    /// 인덱스 스토어를 열지 못함.
    case indexStoreUnreadable(path: String, underlying: String)
    /// 인덱스는 열렸지만 이 프로젝트의 선언을 하나도 담고 있지 않음.
    ///
    /// 조용히 "발견 없음"으로 끝내면 `--strict` 가 0줄을 분석하고 통과한다.
    /// 그 초록불은 코드가 깨끗하다는 뜻으로 읽히므로, 도구 실패로 다룬다.
    case indexStoreEmpty(EmptyIndexFacts)
    /// 이름은 맞지만 어느 것이 이 프로젝트의 것인지 가릴 수 없는 DerivedData 가 여럿.
    ///
    /// 최근성으로 하나를 고르면 남의 인덱스로 분석하고도 아무 표시가 나지 않는다.
    case indexStoreAmbiguous(directories: [String], names: [String])
    /// libIndexStore 동적 라이브러리를 찾지 못함.
    case indexStoreLibraryNotFound(searchedPaths: [String])
    /// 설정 파일 해석 실패.
    case invalidConfiguration(path: String, reason: String)
    /// 베이스라인 파일 해석 실패.
    case invalidBaseline(path: String, reason: String)
    /// `--external-retentions` 파일 해석 실패.
    case invalidExternalRetentions(path: String, reason: String)
    /// 비어 있거나 제어 문자가 있는 이름은 bridge-facts v1로 내보낼 수 없다.
    case unsupportedBridgeName
    /// 설정에서 참조한 레이어 이름이 정의되지 않음.
    case unknownLayer(name: String, definedLayers: [String])
    /// 분석 결과 문제가 발견되어 실패로 종료(`--strict`).
    case thresholdExceeded(rule: String, message: String)
    /// 결과를 파일로 쓰지 못함.
    case outputUnwritable(path: String, underlying: String)
    /// `--since` 가 가리킨 기준점의 변경 목록을 구하지 못했다.
    case changedFilesUnavailable(reference: String, reason: String)

    /// `query --batch` 의 요청 파일을 읽을 수 없다.
    ///
    /// 인덱스를 열기 **전에** 던진다. 요청 하나가 잘못되었을 뿐인데 색인을 한 번 다 만든
    /// 뒤에 실패하면, 사용자는 몇 초를 기다린 대가로 오타 하나를 받는다.
    case invalidBatchRequests(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .indexStoreNotFound(searchedPaths, derivedData):
            return """
                Could not find an index store. Searched:
                \(searchedPaths.map { "  - \($0)" }.joined(separator: "\n"))\
                \(derivedData.map { "\n\($0.explanation)" } ?? "")
                Build first so the compiler writes an index store:
                  swift build
                  xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
                Then run again, or pass --index-store <path> to point at it directly.
                Note: with SwiftPM's Xcode-based build system, -Xswiftc -index-store-path is
                ignored; the store goes to <scratch path>/out.
                """
        case let .indexStoreUnreadable(path, underlying):
            return """
                Failed to open the index store at \(path): \(underlying)
                The store may have been written by a different toolchain, or a build may be \
                writing to it right now. Rebuild the index and try again.
                """
        case let .indexStoreEmpty(facts):
            // 탈출구는 원인을 모를 때만 안내한다. 오류의 마지막 줄은 가장 눈에 띄고,
            // 원인을 아는 상태에서 그것을 권하면 조사 대신 은폐를 시키는 셈이다.
            let hatch = facts.suggestsEscapeHatch
                ? "\nPass --allow-empty-index if this run is meant to analyse nothing."
                : ""
            return """
                The index store knows none of this project's declarations. Every analysis here \
                would report "no findings" over zero declarations, and --strict would pass.
                \(facts.summary)
                \(facts.remedy)\(hatch)
                """
        case let .indexStoreAmbiguous(directories, names):
            return """
                More than one DerivedData directory matches this project by name, and none of them \
                names it in its info.plist:
                \(directories.map { "  - \($0)" }.joined(separator: "\n"))
                Names tried: \(names.map { "'\($0)'" }.joined(separator: ", ")).
                Picking the most recent one would analyse another project's index without saying so. \
                Pass --index-store <path> to name the store you mean.
                """
        case let .indexStoreLibraryNotFound(searchedPaths):
            return """
                Could not locate libIndexStore.dylib. Searched:
                \(searchedPaths.map { "  - \($0)" }.joined(separator: "\n"))
                Make sure Xcode or a Swift toolchain is installed and `xcode-select -p` points at it.
                """
        case let .invalidConfiguration(path, reason):
            return "Invalid configuration at \(path): \(reason)"
        case let .invalidBaseline(path, reason):
            return "Invalid baseline at \(path): \(reason)"
        case let .invalidExternalRetentions(path, reason):
            return """
                Invalid external retentions at \(path): \(reason)
                Expected the 'external-retentions' format that `isthmus retentions --for cartograph` writes.
                """
        case .unsupportedBridgeName:
            return "Cannot export bridge-facts v1 with an empty or control-character-containing name. "
                + "Review channel/method expressions and the bridge-facts v1 name restrictions."
        case let .unknownLayer(name, definedLayers):
            return """
                Rule refers to undefined layer '\(name)'. Defined layers: \
                \(definedLayers.isEmpty ? "(none)" : definedLayers.joined(separator: ", "))
                """
        case let .thresholdExceeded(rule, message):
            return "Threshold exceeded for '\(rule)': \(message)"
        case let .invalidBatchRequests(path, reason):
            return """
                Cannot read the batch requests at \(path): \(reason). The file must be a JSON array \
                of 1-1000 non-empty strings, at most 1 MiB, for example ["ApiClient", "ApiClient.fetch"].
                """
        case let .changedFilesUnavailable(reference, reason):
            return "Could not list files changed since '\(reference)': \(reason)."
        case let .outputUnwritable(path, underlying):
            return "Could not write to \(path): \(underlying)"
        }
    }
}
