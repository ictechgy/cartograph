import Foundation

/// 자동 런타임 발견이 실제로 해석하는 리소스 종류다.
public enum RuntimeResourceKind: Sendable, Equatable {
    case interfaceBuilder
    case coreDataModel
    case coreDataVersionSelection
}

/// 일반 `contents` 파일을 모델로 오인하지 않게 리소스 경로 규칙을 한 곳에 둔다.
public enum RuntimeResourcePath {
    /// 열거·지문·snapshot이 같은 리소스 범위를 사용하도록 종류 판정을 공유한다.
    public static func kind(of path: String) -> RuntimeResourceKind? {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".xib") || lowercased.hasSuffix(".storyboard") {
            return .interfaceBuilder
        }
        if isCoreDataModelContents(path) { return .coreDataModel }
        return isCoreDataVersionSelection(path) ? .coreDataVersionSelection : nil
    }

    /// 분석할 수 없는 일반 리소스를 지원 입력으로 잘못 표시하지 않는다.
    public static func isSupported(_ path: String) -> Bool {
        kind(of: path) != nil
    }

    /// 같은 이름의 문서 파일을 모델로 읽지 않도록 직접 부모 확장자도 검사한다.
    public static func isCoreDataModelContents(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent.lowercased() == "contents"
            && url.deletingLastPathComponent().pathExtension.lowercased() == "xcdatamodel"
    }

    /// 모델과 버전 포인터를 같은 선택 범위로 묶는다.
    public static func coreDataModelContainer(_ path: String) -> String {
        let model = URL(fileURLWithPath: path).deletingLastPathComponent()
        let parent = model.deletingLastPathComponent()
        return parent.pathExtension.lowercased() == "xcdatamodeld" ? parent.path : model.path
    }

    /// 기본 버전 선택도 분석 입력이므로 다른 종류의 숨김 파일과 구별한다.
    public static func isCoreDataVersionSelection(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == ".xccurrentversion"
            && url.deletingLastPathComponent().pathExtension.lowercased() == "xcdatamodeld"
    }
}
