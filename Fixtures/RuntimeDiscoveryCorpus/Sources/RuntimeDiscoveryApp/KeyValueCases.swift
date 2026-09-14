import Foundation

final class KVCSupportedTarget: NSObject {
    @objc var title = "before"
    @objc let identifier = "fixed"
}

final class KVCAccessorTarget: NSObject {
    @objc var title = "property"
    @objc func getTitle() -> String { "getter" }
}

final class KVCObjectiveCAliasAccessorTarget: NSObject {
    @objc var title = "property"
    @objc(getTitle) func alternateGetter() -> String { "aliased-getter" }
}

final class KVCPropertyAccessorTarget: NSObject {
    @objc var title = "property"
    @objc var getTitle = "getter-property"
}

final class KVCObjectiveCAliasPropertyTarget: NSObject {
    @objc var title = "property"
    @objc(getTitle) var alternateProperty: String { "aliased-property" }
}

final class KVCReadOnlyTarget: NSObject {
    @objc var title: String { "fixed" }
}

final class KVCOverrideTarget: NSObject {
    @objc var title = "property"

    override func value(forKey key: String) -> Any? {
        key == "title" ? "override" : super.value(forKey: key)
    }
}

class KVCNonfinalTarget: NSObject {
    @objc var title = "value"
}

final class KVCShadowTarget {
    func value(forKey key: String) -> String { key }
}

func supportedKVCRead(_ target: KVCSupportedTarget) -> String? {
    target.value(forKey: "title") as? String
}

func supportedKVCWrite(_ target: KVCSupportedTarget) {
    target.setValue("after", forKey: "title")
}

func immutableKVCWrite(_ target: KVCSupportedTarget) {
    target.setValue("changed", forKey: "identifier")
}

func alternateAccessorKVCRead(_ target: KVCAccessorTarget) {
    _ = target.value(forKey: "title")
}

func objectiveCAliasAccessorKVCRead(_ target: KVCObjectiveCAliasAccessorTarget) -> String? {
    target.value(forKey: "title") as? String
}

func propertyAccessorKVCRead(_ target: KVCPropertyAccessorTarget) -> String? {
    target.value(forKey: "title") as? String
}

func objectiveCAliasPropertyKVCRead(_ target: KVCObjectiveCAliasPropertyTarget) -> String? {
    target.value(forKey: "title") as? String
}

func readOnlyComputedKVCWrite(_ target: KVCReadOnlyTarget) {
    target.setValue("changed", forKey: "title")
}

func overriddenKVCRead(_ target: KVCOverrideTarget) {
    _ = target.value(forKey: "title")
}

func nonfinalKVCRead(_ target: KVCNonfinalTarget) {
    _ = target.value(forKey: "title")
}

func shadowedKVCRead(_ target: KVCShadowTarget) {
    _ = target.value(forKey: "title")
}

func unsupportedKVCKeyPath(_ target: KVCSupportedTarget) {
    _ = target.value(forKey: "profile.name")
}
