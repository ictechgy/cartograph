import Foundation

extension JSONEncoder {
    /// 키 순서를 고정하고 슬래시를 이스케이프하지 않는 Cartograph 기본 JSON 인코더.
    ///
    /// Foundation 의 기본 JSONEncoder 는 객체 키 순서를 보장하지 않아 실행마다 diff 가 생기고,
    /// 슬래시(`/`)를 이스케이프(`\/`)하여 파일 경로와 URL 의 가독성을 떨어뜨린다.
    /// 이 메서드는 두 옵션을 모두 기본 적용하여 기계와 사람 모두에게 일관된 JSON 을 생성한다.
    public static func cartographDefault(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
