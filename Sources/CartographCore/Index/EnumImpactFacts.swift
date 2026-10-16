import Foundation

/// Enum-decision evidence captured for one indexed Swift source file.
/// Absence of this record means unscanned, not an empty complete result.
public struct EnumImpactFileFacts: Codable, Sendable, Equatable {
    public let path: String
    public let status: String
    public let inventories: [EnumCaseInventory]
    public let decisions: [EnumDecisionFact]
    public let limitations: [String]

    public init(path: String, status: String, inventories: [EnumCaseInventory] = [],
                decisions: [EnumDecisionFact] = [], limitations: [String] = []) {
        self.path = path
        self.status = status
        self.inventories = inventories
        self.decisions = decisions
        self.limitations = Array(Set(limitations)).sorted()
    }

    /// Conflicting captures must never be unioned into a supposedly complete inventory.
    public static func merging(_ first: [Self]?, _ second: [Self]?) -> [Self]? {
        guard first != nil || second != nil else { return nil }
        let grouped = Dictionary(grouping: (first ?? []) + (second ?? []), by: \.path)
        return grouped.keys.sorted().map { path in
            let rows = grouped[path]!
            if rows.dropFirst().allSatisfy({ $0 == rows[0] }) { return rows[0] }
            return Self(path: path, status: "conflicted", limitations: ["conflicting-file-captures"])
        }
    }

    public func rebased(_ transform: (String) -> String) -> Self {
        func moved(_ location: SourceLocation) -> SourceLocation {
            .init(path: transform(location.path), line: location.line, column: location.column)
        }
        return Self(path: transform(path), status: status,
            inventories: inventories.map {
                .init(enumUSR: $0.enumUSR, caseUSRs: $0.caseUSRs, location: moved($0.location),
                      complete: $0.complete, limitations: $0.limitations)
            },
            decisions: decisions.map {
                .init(kind: $0.kind, location: moved($0.location), endLocation: moved($0.endLocation),
                      enumUSR: $0.enumUSR, ownerUSR: $0.ownerUSR,
                      explicitCaseUSRs: $0.explicitCaseUSRs, guardedCaseUSRs: $0.guardedCaseUSRs,
                      evidenceLocations: $0.evidenceLocations.map(moved),
                      operationTargetUSRs: $0.operationTargetUSRs,
                      status: $0.status, limitations: $0.limitations)
            }, limitations: limitations)
    }
}

/// Exact compiler identities observed under one enum declaration in one indexed build.
public struct EnumCaseInventory: Codable, Sendable, Equatable {
    public let enumUSR: String
    public let caseUSRs: [String]
    public let location: SourceLocation
    public let complete: Bool
    public let limitations: [String]

    public init(enumUSR: String, caseUSRs: [String], location: SourceLocation,
                complete: Bool, limitations: [String] = []) {
        self.enumUSR = enumUSR
        self.caseUSRs = Array(Set(caseUSRs)).sorted()
        self.location = location
        self.complete = complete
        self.limitations = Array(Set(limitations)).sorted()
    }
}

/// A located syntax pattern with separately recorded compiler attribution.
/// "resolved" establishes the enum identities, not runtime reachability or business intent.
public struct EnumDecisionFact: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case switchDefault
        case switchUnknownDefault
        case literalMembership
        case negatedLiteralMembership
    }
    public let kind: Kind
    public let location: SourceLocation
    public let endLocation: SourceLocation
    public let enumUSR: String?
    public let ownerUSR: String?
    public let explicitCaseUSRs: [String]
    public let guardedCaseUSRs: [String]
    public let evidenceLocations: [SourceLocation]
    public let operationTargetUSRs: [String]
    public let status: String
    public let limitations: [String]

    public init(kind: Kind, location: SourceLocation, endLocation: SourceLocation,
                enumUSR: String? = nil, ownerUSR: String? = nil,
                explicitCaseUSRs: [String] = [], guardedCaseUSRs: [String] = [],
                evidenceLocations: [SourceLocation] = [], operationTargetUSRs: [String] = [],
                status: String, limitations: [String] = []) {
        self.kind = kind
        self.location = location
        self.endLocation = endLocation
        self.enumUSR = enumUSR
        self.ownerUSR = ownerUSR
        self.explicitCaseUSRs = Array(Set(explicitCaseUSRs)).sorted()
        self.guardedCaseUSRs = Array(Set(guardedCaseUSRs)).sorted()
        self.evidenceLocations = Array(Set(evidenceLocations)).sorted {
            ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column)
        }
        self.operationTargetUSRs = Array(Set(operationTargetUSRs)).sorted()
        self.status = status
        self.limitations = Array(Set(limitations)).sorted()
    }
}
