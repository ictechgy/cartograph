import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("Core Data 버전 선택 입력 경계")
struct CoreDataVersionSelectionTests {
    private let marker = "/p/Store.xcdatamodeld/.xccurrentversion"
    private let model = "/p/Store.xcdatamodeld/V1.xcdatamodel/contents"
    private let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>_XCCurrentVersionName</key><string>V1.xcdatamodel</string></dict></plist>
        """

    @Test("표준 plist DTD는 허용하지만 XML entity와 지원하지 않는 문자 인코딩은 거부한다")
    func rejectsEntitiesAndUnsupportedEncodings() throws {
        let fs = InMemoryFileSystem()
        try fs.write(text: xml, to: marker)
        #expect(CoreDataVersionSelection.read(markerPath: marker, modelPaths: [model], fileSystem: fs)
            .selectedPath == model)
        let entity = xml.replacingOccurrences(of: "<!DOCTYPE plist PUBLIC", with:
            "<!ENTITY version 'V1.xcdatamodel'><!DOCTYPE plist PUBLIC")
        try fs.write(text: entity, to: marker)
        #expect(CoreDataVersionSelection.read(markerPath: marker, modelPaths: [model], fileSystem: fs)
            .reason?.contains("entity") == true)
        let utf16 = xml.replacingOccurrences(of: "UTF-8", with: "UTF-16").data(using: .utf16)!
        try fs.write(utf16, to: marker)
        #expect(CoreDataVersionSelection.read(markerPath: marker, modelPaths: [model], fileSystem: fs)
            .selectedPath == nil)
    }

    @Test("버전 파일 크기 제한은 실제 파일 시스템과 메모리 파일 시스템 모두 적용한다")
    func rejectsOversizedFiles() throws {
        let fs = InMemoryFileSystem()
        try fs.write(Data(repeating: 32, count: 65_537), to: marker)
        #expect(CoreDataVersionSelection.read(markerPath: marker, modelPaths: [model], fileSystem: fs)
            .reason?.contains("64 KiB") == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".xccurrentversion")
        try Data(repeating: 32, count: 65_537).write(to: file)
        #expect(CoreDataVersionSelection.read(markerPath: file.path, modelPaths: [], fileSystem: LocalFileSystem())
            .reason?.contains("64 KiB") == true)
    }

    @Test("버전 포인터 심볼릭 링크를 따라 외부 plist를 선택하지 않는다")
    func refusesSymlinkMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = directory.appendingPathComponent("Store.xcdatamodeld")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("outside.plist")
        try Data(xml.utf8).write(to: external)
        let link = container.appendingPathComponent(".xccurrentversion")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let selected = container.appendingPathComponent("V1.xcdatamodel/contents").path
        let selection = CoreDataVersionSelection.read(
            markerPath: link.path, modelPaths: [selected], fileSystem: LocalFileSystem()
        )
        #expect(selection.selectedPath == nil)
        #expect(selection.reason != nil)
    }
}
