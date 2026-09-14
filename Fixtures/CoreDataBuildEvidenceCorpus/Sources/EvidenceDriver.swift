import CartographCore
import CartographKit
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 8 else {
    fatalError("usage: driver <create|verify> <evidence> <executable> <source-model> <generated-source> <module> <usr>")
}
do {
    let store = CoreDataBuildEvidenceStore()
    if arguments[1] == "create" {
        let request = CoreDataBuildEvidenceRequest(
            executablePath: arguments[3], sourceModelPath: arguments[4], persistentContainerName: "Store",
            declaredGeneratedMappings: [
                CoreDataDeclaredGeneratedMappingInput(
                    entityName: "Record", sourcePath: arguments[5], module: arguments[6],
                    declarationUSRs: [arguments[7]]
                ),
            ]
        )
        let evidence = try store.writeVerified(request: request, to: arguments[2])
        print("created=\(evidence.model.entities.count)")
    } else if arguments[1] == "verify" {
        let evidence = try store.readAndVerify(at: arguments[2])
        print("verified=\(evidence.model.entities.count)")
    } else {
        fatalError("unknown mode")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
