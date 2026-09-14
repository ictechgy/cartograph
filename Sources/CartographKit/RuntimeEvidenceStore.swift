import CartographCore
import Foundation

/// 실행 근거 파일의 크기와 계약을 인덱스를 읽기 전에 검증한다.
public struct RuntimeEvidenceStore: Sendable {
    private let fileSystem: any FileSystem
    public static let maximumByteCount = 2 * 1024 * 1024

    /// 실제 파일 읽기를 주입해 손상·누락 입력을 런타임 실행 없이 검증할 수 있게 한다.
    public init(fileSystem: any FileSystem = LocalFileSystem()) { self.fileSystem = fileSystem }

    /// 계약 ID와 필수 시나리오가 비면 아무것도 실행하지 않고 통과할 수 있으므로
    /// 거부한다.
    public func contracts(at path: String) throws -> RuntimeContractsDocument {
        let document: RuntimeContractsDocument = try read(at: path)
        try Self.validateContracts(document, path: path)
        return document
    }

    /// 관측이 비어 있어도 읽는다. 빈 관측은 검증할 실행이 없다는 의미이며
    /// 성공으로 간주하지 않는다.
    public func observations(at path: String) throws -> RuntimeObservationsDocument {
        let document: RuntimeObservationsDocument = try read(at: path)
        try Self.validateObservations(document, path: path)
        return document
    }

    /// 메모리로 전달된 계약도 파일 입력과 같은 스키마 규칙으로 검증한다.
    public static func validateContracts(
        _ document: RuntimeContractsDocument,
        path: String = "runtime contracts"
    ) throws {
        guard document.format == "runtime-contracts", document.version == 1,
              (1...1000).contains(document.contracts.count),
              Set(document.contracts.map(\.id)).count == document.contracts.count,
              document.contracts.allSatisfy(valid)
        else {
            throw invalid(path, "Expected runtime-contracts v1 with 1...1000 unique contracts and nonempty scenarios.")
        }
    }

    /// 메모리로 전달된 관측도 파일 입력과 같은 스키마 규칙으로 검증한다.
    public static func validateObservations(
        _ document: RuntimeObservationsDocument,
        path: String = "runtime observations"
    ) throws {
        guard document.format == "runtime-observations", document.version == 1,
              validFingerprint(document.planFingerprint),
              validFingerprint(document.executableFingerprint),
              validLabel(document.producer),
              document.observations.count <= 10_000,
              document.observations.allSatisfy(valid)
        else {
            throw invalid(
                path,
                "Expected runtime-observations v1 with plan and executable fingerprints, producer "
                    + "and valid scenario labels."
            )
        }
    }

    private func read<T: Decodable>(at path: String) throws -> T {
        let data: Data
        do { data = try fileSystem.readData(at: path) }
        catch {
            throw Self.invalid(path, "Could not read the runtime evidence file. Check the path and read permissions.")
        }
        guard data.count <= Self.maximumByteCount else {
            throw Self.invalid(path, "Runtime evidence exceeds 2 MiB. Split the scenario set into smaller documents.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            throw Self.invalid(
                path, "Runtime evidence is not valid JSON for this schema. Check format, version and required fields."
            )
        }
    }

    private static func valid(_ contract: RuntimeContract) -> Bool {
        validLabel(contract.id) && validSymbol(contract.target)
            && (contract.source.map(validSymbol) ?? true)
            && (1...100).contains(contract.requiredScenarios.count)
            && contract.requiredScenarios.allSatisfy(validLabel)
            && Set(contract.requiredScenarios).count == contract.requiredScenarios.count
            && (contract.expectedValue.map(validValue) ?? true)
    }

    private static func valid(_ observation: RuntimeObservation) -> Bool {
        validLabel(observation.contract)
            && validLabel(observation.scenario)
            && (observation.value.map(validValue) ?? true)
    }

    private static func validLabel(_ value: String) -> Bool { validSymbol(value) && value.utf8.count <= 256 }

    private static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func validValue(_ value: String) -> Bool {
        value.utf8.count <= 4096 && PrintableText.printable(value) == value
    }

    private static func validSymbol(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4096 && PrintableText.printable(value) == value
    }

    private static func invalid(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}
