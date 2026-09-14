import Foundation
import CryptoKit

@objc(CGProbeScreen)
final class ProbeScreen: NSObject {
    @objc func open() -> NSString { "opened" }
}

func dispatchScreen() -> String? {
    let screen = ProbeScreen()
    let selector = NSSelectorFromString("open")
    guard screen.responds(to: selector) else { return nil }
    return screen.perform(selector)?.takeUnretainedValue() as? String
}

func lookupScreen() -> String? {
    NSClassFromString("CGProbeScreen") == nil ? nil : "registered"
}

func observation(_ contract: String, value: String?) -> [String: Any] {
    var result: [String: Any] = [
        "contract": contract,
        "scenario": "launch",
        "outcome": value == nil ? "failed" : "observed",
    ]
    if let value { result["value"] = value }
    return result
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Pass the runtime plan fingerprint as the only argument.")
}
let executablePath = Bundle.main.executableURL?.path
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
let executableData = try Data(contentsOf: URL(fileURLWithPath: executablePath))
let executableFingerprint = SHA256.hash(data: executableData)
    .map { String(format: "%02x", $0) }.joined()
let document: [String: Any] = [
    "format": "runtime-observations",
    "version": 1,
    "planFingerprint": CommandLine.arguments[1],
    "executableFingerprint": executableFingerprint,
    "producer": "Foundation-selector-probe",
    "observations": [
        observation("selector-route", value: dispatchScreen()),
        observation("screen-registration", value: lookupScreen()),
    ],
]
let encoded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
