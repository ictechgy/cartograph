import CartographCore
import SwiftParser
import SwiftSyntax

/// momc가 만드는 클래스 파일의 최소 구조를 구문으로 확인한 결과.
public struct CoreDataGeneratedClassInspection: Sendable, Equatable {
    public let className: String?
    public let runtimeName: String?
    public let location: CartographCore.SourceLocation?
    public let isGeneratorCompatible: Bool
    public let reason: String?

    /// 호환되지 않는 입력도 이유와 위치를 보존해 사용자가 정확한 생성 파일을
    /// 다시 지정하게 한다.
    public init(
        className: String? = nil,
        runtimeName: String? = nil,
        location: CartographCore.SourceLocation? = nil,
        isGeneratorCompatible: Bool,
        reason: String? = nil
    ) {
        self.className = className
        self.runtimeName = runtimeName
        self.location = location
        self.isGeneratorCompatible = isGeneratorCompatible
        self.reason = reason
    }
}

/// 파일명과 생성 주석 대신 선언 구조로 momc 클래스 파일을 제한한다.
public enum CoreDataGeneratedClassScanner {
    /// 빈 클래스 본문, NSManagedObject 상속, 노출 이름과 momc typealias를 모두 확인한다.
    public static func inspect(
        source: String,
        path: String,
        expectedClassName: String,
        expectedRuntimeName: String,
        module: String,
        expectedSuperclassName: String = "NSManagedObject"
    ) -> CoreDataGeneratedClassInspection {
        let tree = Parser.parse(source: source)
        let classes = tree.statements.compactMap { $0.item.as(ClassDeclSyntax.self) }
        guard classes.count == 1, let declaration = classes.first else {
            return rejected("Expected exactly one top-level generated class.")
        }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let location = sourceLocation(declaration.name, converter: converter)
        let className = SyntaxIdentifiers.unescaped(declaration.name.text)
        guard className == expectedClassName else {
            return rejected(
                "The generated class name does not match the compiled model.",
                className: className, location: location
            )
        }
        guard onlyGeneratedTopLevelDeclarations(tree, className: className) else {
            return rejected(
                "The generated class file contains unsupported declarations.",
                className: className, location: location
            )
        }
        guard declaration.memberBlock.members.isEmpty,
              declaration.genericParameterClause == nil,
              declaration.genericWhereClause == nil,
              declaration.modifiers.map({ $0.name.text }) == ["public"],
              declaration.inheritanceClause?.inheritedTypes.map({ $0.type.trimmedDescription })
                == [expectedSuperclassName]
        else {
            return rejected(
                "The generated class must be an empty public subclass of the verified model superclass.",
                className: className, location: location
            )
        }
        let objectiveCName = SyntaxAttributes.objectiveCName(in: declaration.attributes)
        let runtimeName = objectiveCName ?? "\(module).\(className)"
        guard runtimeName == expectedRuntimeName,
              supportedRuntimeExposure(objectiveCName, expectedRuntimeName: expectedRuntimeName) else {
            return rejected(
                "The generated class runtime name does not match the compiled model.",
                className: className, runtimeName: runtimeName, location: location
            )
        }
        return CoreDataGeneratedClassInspection(
            className: className,
            runtimeName: runtimeName,
            location: location,
            isGeneratorCompatible: true
        )
    }

    private static func onlyGeneratedTopLevelDeclarations(_ tree: SourceFileSyntax, className: String) -> Bool {
        var imports: Set<String> = []
        var typeAliases: [TypeAliasDeclSyntax] = []
        for item in tree.statements {
            if let declaration = item.item.as(ImportDeclSyntax.self) {
                imports.insert(declaration.path.trimmedDescription)
            } else if let declaration = item.item.as(TypeAliasDeclSyntax.self) {
                typeAliases.append(declaration)
            } else if item.item.as(ClassDeclSyntax.self) == nil {
                return false
            }
        }
        guard imports.isSuperset(of: ["Foundation", "CoreData"]), typeAliases.count == 1,
              let alias = typeAliases.first else { return false }
        return SyntaxIdentifiers.unescaped(alias.name.text) == "\(className)CoreDataClassSet"
            && alias.initializer.value.trimmedDescription == "NSSet"
    }

    private static func supportedRuntimeExposure(_ objectiveCName: String?, expectedRuntimeName: String) -> Bool {
        expectedRuntimeName.contains(".") ? objectiveCName == nil : objectiveCName == expectedRuntimeName
    }

    private static func sourceLocation(
        _ token: TokenSyntax,
        converter: SourceLocationConverter
    ) -> CartographCore.SourceLocation {
        let value = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return .init(path: value.file, line: value.line, column: value.column)
    }

    private static func rejected(
        _ reason: String,
        className: String? = nil,
        runtimeName: String? = nil,
        location: CartographCore.SourceLocation? = nil
    ) -> CoreDataGeneratedClassInspection {
        .init(
            className: className,
            runtimeName: runtimeName,
            location: location,
            isGeneratorCompatible: false,
            reason: reason
        )
    }
}
