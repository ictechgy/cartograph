import CartographCore
@testable import CartographKit
import Foundation
import Testing

@Suite("iOS SDK의 실제 버전 디렉터리와 제한된 별칭")
struct XcodeIOSSDKIdentityTests {
    @Test("Xcode의 unversioned와 versioned 이름만 같은 실제 SDK로 인정한다", arguments: [false, true])
    func knownAliases(versionedPhysical: Bool) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("cartograph-ios-sdk-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fs = LocalFileSystem()
        let root = URL(fileURLWithPath: try fs.realPath(at: temporary.path))
        defer { try? manager.removeItem(at: root) }
        let developer = root.appendingPathComponent("Developer")
        let sdks = developer.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs")
        let unversioned = sdks.appendingPathComponent("iPhoneSimulator.sdk")
        let versioned = sdks.appendingPathComponent("iPhoneSimulator27.0.sdk")
        let physical = versionedPhysical ? versioned : unversioned
        let alias = versionedPhysical ? unversioned : versioned
        try manager.createDirectory(at: physical, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: physical)
        let values = ["DEVELOPER_DIR": developer.path, "SDK_VERSION": "27.0",
                      "SDKROOT": unversioned.path, "SDK_DIR": versioned.path]
        let identity = try XcodeIOSSDKIdentity(settings: values, fileSystem: fs)
        #expect(identity.canonicalRoot == physical.path)
        #expect(try identity.matches(unversioned.path, fileSystem: fs))
        #expect(try identity.matches(versioned.path, fileSystem: fs))
        let arbitrary = root.appendingPathComponent("arbitrary.sdk")
        try manager.createSymbolicLink(at: arbitrary, withDestinationURL: physical)
        #expect(try !identity.matches(arbitrary.path, fileSystem: fs))
        #expect(try !identity.matches(sdks.appendingPathComponent("iPhoneSimulator28.0.sdk").path, fileSystem: fs))
        for change in [["SDK_DIR": arbitrary.path], ["SDK_VERSION": "28.0"], ["SDKROOT": arbitrary.path]] {
            #expect(throws: (any Error).self) {
                try XcodeIOSSDKIdentity(settings: values.merging(change) { _, new in new }, fileSystem: fs)
            }
        }
    }
}
