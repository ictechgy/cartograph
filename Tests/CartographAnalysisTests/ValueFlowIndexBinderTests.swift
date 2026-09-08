import CartographAnalysis
import CartographCore
import Testing

@Suite("값 흐름 인덱스 결합")
struct ValueFlowIndexBinderTests {
    private let path = "/p/App.swift"

    private func location(_ line: Int, _ column: Int) -> CartographCore.SourceLocation {
        CartographCore.SourceLocation(path: path, line: line, column: column)
    }

    private func function(
        id: String = "f",
        name: String = "foo",
        indexName: String = "foo()",
        ownerType: String? = nil,
        location: CartographCore.SourceLocation? = nil,
        operations: [ValueFlowOperation] = []
    ) -> ValueFlowFunction {
        let instructions = operations.enumerated().map {
            ValueFlowInstruction(id: $0.offset, operation: $0.element, location: location ?? self.location(1, 1))
        }
        return ValueFlowFunction(
            id: id,
            name: name,
            indexName: indexName,
            location: location ?? self.location(1, 5),
            kind: .function,
            blocks: [ValueFlowBlock(id: 0, instructions: instructions, terminator: .return(nil))],
            ownerType: ownerType
        )
    }

    @Test("정확한 선언 위치와 call 발생 위치에만 USR과 종류를 붙인다")
    func bindsExactDeclarationAndReference() throws {
        let reference = ValueFlowSymbolReference(location: location(2, 9), spelling: "bar")
        let program = ValueFlowProgram(functions: [
            function(
                operations: [
                    .symbol(reference),
                    .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false)
                ]
            )
        ])
        let snapshot = IndexSnapshot(
            symbols: [
                IndexedSymbol(usr: "s:foo", name: "foo()", kind: .function, module: "App", location: location(1, 5)),
                IndexedSymbol(usr: "s:bar", name: "bar()", kind: .function, module: "App", location: location(3, 5))
            ],
            references: [
                IndexedReference(sourceUSR: "s:foo", targetUSR: "s:bar", kind: .call, location: location(2, 9)),
                IndexedReference(sourceUSR: "s:foo", targetUSR: "s:bar", kind: .call, location: location(2, 9))
            ]
        )
        let bound = ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: [path])
        let boundFunction = try #require(bound.functions.first)
        #expect(boundFunction.symbolUSR == "s:foo")
        guard case .symbol(let boundReference) = boundFunction.blocks[0].instructions[0].operation else {
            Issue.record("symbol operation이 사라졌다")
            return
        }
        #expect(boundReference.usr == "s:bar")
        #expect(boundReference.kind == .function)
    }

    @Test("낡거나 모호한 증거는 nearest fallback 없이 unavailable로 남는다")
    func rejectsStaleAndAmbiguousEvidence() throws {
        let site = location(2, 9)
        let reference = ValueFlowSymbolReference(location: site, spelling: "bar")
        let program = ValueFlowProgram(functions: [
            function(operations: [.symbol(reference), .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false)])
        ])
        let snapshot = IndexSnapshot(
            symbols: [
                IndexedSymbol(usr: "s:foo", name: "foo()", kind: .function, module: "App", location: location(1, 5)),
                IndexedSymbol(usr: "s:old", name: "bar()", kind: .function, module: "App", location: location(3, 5)),
                IndexedSymbol(usr: "s:new", name: "bar()", kind: .function, module: "App", location: location(4, 5))
            ],
            references: [
                IndexedReference(sourceUSR: "s:foo", targetUSR: "s:old", kind: .call, location: site),
                IndexedReference(sourceUSR: "s:foo", targetUSR: "s:new", kind: .call, location: site)
            ]
        )
        let bound = ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: [])
        let boundFunction = try #require(bound.functions.first)
        #expect(boundFunction.symbolUSR == nil)
        #expect(boundFunction.unavailableReason != nil)
        guard case .symbol(let boundReference) = boundFunction.blocks[0].instructions[0].operation else {
            Issue.record("symbol operation이 사라졌다")
            return
        }
        #expect(boundReference.usr == nil)
        #expect(bound.limitations.contains("value-flow binding unavailable: stale, missing, or ambiguous index evidence"))
    }

    @Test("개별 SDK 미지원 참조는 함수 전체를 폐기하지 않고 unknown operation으로 남긴다")
    func keepsUnknownReferenceLocal() throws {
        let reference = ValueFlowSymbolReference(location: location(2, 9), spelling: "sdkValue")
        let program = ValueFlowProgram(functions: [
            function(operations: [.symbol(reference)])
        ])
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:foo", name: "foo()", kind: .function, module: "App", location: location(1, 5))
        ])
        let bound = ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: [path])
        let result = try #require(bound.functions.first)
        #expect(result.unavailableReason == nil)
        guard case .unknown(let reason, _, true) = result.blocks[0].instructions[0].operation else {
            Issue.record("미지원 참조가 unknown operation으로 남지 않았다")
            return
        }
        #expect(reason.contains("binding unavailable"))
    }

    @Test("extension은 extends 증거로 실제 타입 owner에 정규화되고 override dispatch를 만든다")
    func canonicalizesExtensionAndDispatch() throws {
        let type = ValueFlowType(
            id: "type",
            name: "Box",
            location: location(1, 15),
            isReferenceType: true
        )
        let extensionType = ValueFlowType(
            id: "extension",
            name: "Box",
            location: location(1, 15),
            isReferenceType: true,
            isExtension: true
        )
        let method = function(
            id: "method",
            name: "read",
            indexName: "read()",
            ownerType: "extension",
            location: location(2, 9)
        )
        let program = ValueFlowProgram(functions: [method], types: [type, extensionType])
        let snapshot = IndexSnapshot(
            symbols: [
                IndexedSymbol(usr: "s:Box", name: "Box", kind: .classType, module: "App", location: type.location),
                IndexedSymbol(usr: "s:Ext", name: "Box", kind: .extensionDeclaration, module: "App", location: location(1, 1)),
                IndexedSymbol(usr: "s:read", name: "read()", kind: .method, module: "App",
                              location: method.location, parentUSR: "s:Ext"),
                IndexedSymbol(usr: "s:req", name: "read()", kind: .method, module: "App",
                              location: location(8, 1))
            ],
            references: [
                IndexedReference(sourceUSR: "s:Ext", targetUSR: "s:Box", kind: .extends, location: extensionType.location),
                IndexedReference(sourceUSR: "s:read", targetUSR: "s:req", kind: .overrides, location: method.location)
            ]
        )
        let bound = ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: [path])
        let boundMethod = try #require(bound.functions.first)
        #expect(boundMethod.symbolUSR == "s:read")
        #expect(boundMethod.ownerType == "type")
        #expect(bound.types.first(where: { $0.id == "extension" })?.symbolUSR == "s:Ext")
        #expect(bound.dispatch == [
            ValueFlowDispatch(requirementUSR: "s:req", implementation: "method", ownerType: "type")
        ])
    }

    @Test("합성 initializer는 parentUSR를 가진 유일한 실제 init으로만 결합된다")
    func bindsSyntheticInitializerOnlyWithParentEvidence() throws {
        let type = ValueFlowType(id: "type", name: "Box", location: location(1, 15), isReferenceType: true)
        let synthetic = ValueFlowFunction(
            id: "/p#synthetic-initializer:type",
            name: "init",
            indexName: "init()",
            location: type.location,
            kind: .initializer,
            blocks: [ValueFlowBlock(id: 0, terminator: .return(nil))],
            ownerType: "type"
        )
        let program = ValueFlowProgram(functions: [synthetic], types: [type])
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "s:Box", name: "Box", kind: .classType, module: "App", location: type.location),
            IndexedSymbol(usr: "s:init", name: "init()", kind: .initializer, module: "App",
                          location: location(2, 5), parentUSR: "s:Box")
        ])
        let bound = ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: [path])
        #expect(bound.functions.first?.symbolUSR == "s:init")
        #expect(bound.functions.first?.unavailableReason == nil)
    }
}
