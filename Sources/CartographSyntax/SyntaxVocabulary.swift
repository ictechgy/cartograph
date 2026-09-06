import SwiftSyntax

/// 같은 파일 안에서 협력하는 방문자들이 함께 쓰는 어휘.
///
/// 방문자 하나에 static 으로 매달아 두면 다른 방문자가 그것을 부르면서 둘이 서로를
/// 참조하게 되고, 타입 레벨 그래프에 순환으로 나타난다. 실제로 이 저장소의 자기 분석에서
/// 그 형태가 두 건 나왔다. 공유하는 값은 어느 한쪽의 것이 아니므로 여기 둔다.

/// Flutter 브리지에서 이름으로 알아보는 타입들.
enum BridgeChannels {
    /// 메서드 브리지의 채널 타입.
    static let methodChannel = "FlutterMethodChannel"
    /// 스트림 브리지의 채널 타입. 읽지 않고 세기만 한다.
    static let eventChannel = "FlutterEventChannel"
    /// 메시지 브리지(Pigeon 산출물)의 채널 타입. 읽지 않고 세기만 한다.
    static let messageChannels: Set<String> = ["FlutterBasicMessageChannel", "BasicMessageChannel"]
    /// 핸들러가 받는 호출 타입. 이 타입의 인자를 가진 함수 안에서만 `call.method` 분기를 믿는다.
    static let methodCall = "FlutterMethodCall"
    /// 핸들러를 채널에 다는 메서드 이름들.
    static let handlerRegistrationMethods: Set<String> = ["setMethodCallHandler", "addMethodCallDelegate"]
    /// 채널 타입 이름 전부. 인스턴스 바인딩에서 채널 생성을 뺄 때 쓴다.
    static let all: Set<String> = messageChannels.union([methodChannel, eventChannel])
}

/// 속성 목록에서 값을 읽는다.
enum SyntaxAttributes {
    /// `@objc(Name)` 이 지정한 이름. 없으면 nil.
    static func objectiveCName(in attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard case let .attribute(attribute) = element,
                  attribute.attributeName.trimmedDescription == "objc",
                  case let .objCName(pieces) = attribute.arguments
            else { continue }
            // 셀렉터는 콜론까지 이어 붙인다. 부르는 쪽에서 첫 조각만 잘라 쓴다.
            let name = pieces.map { ($0.name?.text ?? "") + ($0.colon?.text ?? "") }.joined()
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// 이름이 같은 속성이 붙어 있는지.
    static func has(_ name: String, in attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case let .attribute(attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
    }
}

/// 트리비아에서 주석 줄을 뽑는다.
enum SyntaxComments {
    static func lines(in trivia: Trivia) -> [String] {
        trivia.compactMap { piece in
            switch piece {
            case let .lineComment(text), let .blockComment(text),
                 let .docLineComment(text), let .docBlockComment(text):
                text
            default:
                nil
            }
        }
    }
}
