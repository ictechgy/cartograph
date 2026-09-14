import Foundation

final class LegacyTarget: NSObject {
    // BEGIN_LEGACY_METHOD
    @objc func legacyAction() {}
    // END_LEGACY_METHOD

    // BEGIN_RENAMED_METHOD
    @objc func renamedAction() {}
    // END_RENAMED_METHOD
}

func invokeLegacy(_ target: LegacyTarget) {
    // BEGIN_LEGACY_CALL
    _ = target.perform(#selector(LegacyTarget.legacyAction))
    // END_LEGACY_CALL

    // BEGIN_RENAMED_CALL
    _ = target.perform(#selector(LegacyTarget.renamedAction))
    // END_RENAMED_CALL
}
