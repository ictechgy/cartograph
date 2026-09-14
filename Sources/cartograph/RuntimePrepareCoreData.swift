import ArgumentParser
import CartographKit
import Foundation

/// 현재 앱 빌드의 Core Data 생성 클래스를 인덱스와 대조해 증거 파일을 만든다.
struct RuntimePrepareCoreDataCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare-coredata",
        abstract: "Bind generated Core Data classes to one built app and compiler index."
    )

    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("model"), help: "Selected source .xcdatamodel or .xcdatamodeld path.")
    var modelPath: String
    @Option(name: .customLong("container"), help: "Literal NSPersistentContainer name.")
    var containerName: String
    @Option(name: .customLong("executable"), help: "Executable inside the built .app bundle.")
    var executablePath: String
    @Option(
        name: .customLong("generated-source"),
        help: "Exact momc-generated class Swift file; repeat for each class-generated entity."
    )
    var generatedSources: [String] = []
    @Option(name: .customLong("module"), help: "Exact Swift module used to compile the generated sources.")
    var module: String?
    func validate() throws {
        try RuntimeOptionsValidation.validate(options)
        let values = [modelPath, containerName, executablePath] + generatedSources
        guard values.allSatisfy(Self.nonEmpty),
              options.outputPath.map(Self.nonEmpty) == true else {
            throw ValidationError(
                "Core Data preparation paths, container, module and generated sources cannot be empty"
            )
        }
        guard module.map(Self.nonEmpty) ?? true else {
            throw ValidationError("--module cannot be empty")
        }
        guard generatedSources.isEmpty || module.map(Self.nonEmpty) == true else {
            throw ValidationError("--module is required with --generated-source")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let cwd = context.fileSystem.currentDirectoryPath
        var emitOptions = options
        emitOptions.outputPath = nil
        try CommandSupport.emit(
            try context.service.prepareCoreDataBuildEvidence(
                executablePath: Self.absolute(executablePath, cwd: cwd),
                sourceModelPath: Self.absolute(modelPath, cwd: cwd),
                persistentContainerName: containerName,
                generatedSourcePaths: generatedSources.map { Self.absolute($0, cwd: cwd) },
                module: module,
                outputPath: Self.absolute(options.outputPath!, cwd: cwd)
            ),
            options: emitOptions,
            context: context
        )
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        GlobalOptions.absolutePath(path, relativeTo: cwd)
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
