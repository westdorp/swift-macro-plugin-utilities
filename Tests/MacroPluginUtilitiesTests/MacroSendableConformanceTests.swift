import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Macro Sendable conformance")
struct MacroSendableConformanceTests {
    @Test(
        "Sendable generation partitions declaration kind, eligibility, and conformance",
        arguments: [
            SendableGenerationCase(
                source: "struct Target {}",
                canGenerateMembers: true,
                expectedExtensions: []
            ),
            SendableGenerationCase(
                source: "class Target {}",
                canGenerateMembers: false,
                expectedExtensions: []
            ),
            SendableGenerationCase(
                source: "class Target: Sendable {}",
                canGenerateMembers: true,
                expectedExtensions: []
            ),
            SendableGenerationCase(
                source: "class Target {}",
                canGenerateMembers: true,
                expectedExtensions: ["extension Target: Sendable {}"]
            ),
        ]
    )
    func sendableGenerationPartitionsEligibility(
        testCase: SendableGenerationCase
    ) throws {
        let declaration = try #require(parseDeclarationGroup(testCase.source))
        let type = parseType("Target")

        let extensions = try sendableExtensionIfNeeded(
            for: type,
            attachedTo: declaration,
            lexicalContext: [],
            when: { _ in testCase.canGenerateMembers }
        )

        #expect(extensions.map(\.trimmedDescription) == testCase.expectedExtensions)
    }

    @Test("Sendable generation uses visible sibling extensions")
    func sendableGenerationUsesVisibleSiblingExtension() throws {
        let sourceFile = Parser.parse(
            source: """
            class Target {}
            extension Target: Sendable {}
            """
        )
        let target = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(ClassDeclSyntax.self)
        )

        let extensions = try sendableExtensionIfNeeded(
            for: parseType("Target"),
            attachedTo: target,
            lexicalContext: [],
            when: { _ in true }
        )

        #expect(extensions.isEmpty)
    }

    @Test("Sendable generation preserves detached lexical qualification")
    func sendableGenerationPreservesDetachedLexicalQualification() throws {
        let sourceFile = Parser.parse(
            source: """
            enum Namespace {
                class Target {}
            }
            extension Namespace.Target: Sendable {}
            """
        )
        let namespace = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let target = try #require(
            namespace.memberBlock.members.first?
                .decl.as(ClassDeclSyntax.self)?
                .detached
        )

        let extensions = try sendableExtensionIfNeeded(
            for: parseType("Namespace.Target"),
            attachedTo: target,
            lexicalContext: [Syntax(namespace)],
            when: { _ in true }
        )

        #expect(extensions.isEmpty)
    }

    @Test(
        "Direct inheritance works for every declaration group",
        arguments: [
            "class Target: Sendable {}",
            "struct Target: Sendable {}",
            "enum Target: Sendable {}",
            "actor Target: Sendable {}",
            "protocol Target: Sendable {}",
            "extension Target: Sendable {}",
        ]
    )
    func directInheritanceSupportsEveryDeclarationGroup(source: String) throws {
        let declaration = try #require(parseDeclarationGroup(source))
        let result = try #require(
            sendableConformanceForKnownGroup(declaration) as Bool?
        )

        #expect(result)
    }

    @Test(
        "Direct inheritance recognizes supported Sendable spellings",
        arguments: [
            "struct Target: Sendable {}",
            "struct Target: Swift.Sendable {}",
            "struct Target: Codable & Sendable {}",
            "struct Target: @unchecked Sendable {}",
            "struct Target: @preconcurrency Swift.Sendable {}",
        ]
    )
    func directInheritanceRecognizesSupportedSpellings(source: String) throws {
        let declaration = try #require(parseDeclarationGroup(source))
        let result = try #require(
            sendableConformanceForKnownGroup(declaration) as Bool?
        )

        #expect(result)
    }

    @Test("A same-file sibling extension supplies conformance")
    func siblingExtensionSuppliesConformance() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Target {}
                extension Target: Sendable {}
                """
        )
        let target = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )

        #expect(hasSendableConformance(in: target))
    }

    @Test("Qualified extensions match nested declarations")
    func qualifiedExtensionsMatchNestedDeclarations() throws {
        let sourceFile = Parser.parse(
            source: """
                enum Namespace {
                    struct Target {}
                }
                extension Namespace.Target: Sendable {}
                """
        )
        let namespace = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let target = try #require(
            namespace.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)
        )

        #expect(hasSendableConformance(in: target))
    }

    @Test("Declarations nested in extensions use the extended qualification")
    func declarationsNestedInExtensionsUseExtendedQualification() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Outer {}
                extension Outer {
                    struct Nested {}
                }
                extension Outer.Nested: Sendable {}
                """
        )
        let outerExtension = try #require(
            sourceFile.statements.dropFirst().first?
                .item.as(DeclSyntax.self)?
                .as(ExtensionDeclSyntax.self)
        )
        let nested = try #require(
            outerExtension.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)
        )

        #expect(hasSendableConformance(in: nested))
    }

    @Test("Detached lexical-context roots supply visible extensions")
    func detachedLexicalContextSuppliesExtension() throws {
        let target = try #require(
            parseDeclarationGroup("struct Target {}")?
                .as(StructDeclSyntax.self)?
                .detached
        )
        let lexicalRoot = Parser.parse(source: "extension Target: Sendable {}").detached

        #expect(
            hasSendableConformance(
                in: target,
                lexicalContext: [Syntax(lexicalRoot)]
            )
        )
    }

    @Test("Detached nested declarations use lexical qualification")
    func detachedNestedDeclarationsUseLexicalQualification() throws {
        let sourceFile = Parser.parse(
            source: """
                enum Namespace {
                    struct Target {}
                }
                extension Namespace.Target: Sendable {}
                """
        )
        let namespace = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let target = try #require(
            namespace.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)?
                .detached
        )

        #expect(
            hasSendableConformance(
                in: target,
                lexicalContext: [Syntax(namespace)]
            )
        )
    }

    @Test("Detached nested declarations reject unqualified basename extensions")
    func detachedNestedDeclarationsRejectUnqualifiedBasenameExtensions() throws {
        let sourceFile = Parser.parse(
            source: """
                enum Namespace {
                    struct Target {}
                }
                extension Target: Sendable {}
                """
        )
        let namespace = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let target = try #require(
            namespace.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)?
                .detached
        )

        #expect(
            !hasSendableConformance(
                in: target,
                lexicalContext: [Syntax(namespace)]
            )
        )
    }

    @Test("Detached declarations preserve repeated lexical type names")
    func detachedDeclarationsPreserveRepeatedLexicalTypeNames() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Target {
                    struct Target {}
                }
                extension Target.Target: Sendable {}
                """
        )
        let outerTarget = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )
        let innerTarget = try #require(
            outerTarget.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)?
                .detached
        )

        #expect(
            hasSendableConformance(
                in: innerTarget,
                lexicalContext: [Syntax(outerTarget)]
            )
        )
    }

    @Test("Qualified external basenames do not match local declarations")
    func qualifiedExternalBasenamesDoNotMatch() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Target {}
                extension ExternalModule.Target: Sendable {}
                """
        )
        let target = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )

        #expect(!hasSendableConformance(in: target))
    }

    @Test("Equal basenames in different namespaces remain distinct")
    func equalBasenamesInDifferentNamespacesRemainDistinct() throws {
        let sourceFile = Parser.parse(
            source: """
                enum First {
                    struct Target {}
                }
                enum Second {
                    struct Target {}
                }
                extension First.Target: Sendable {}
                """
        )
        let secondNamespace = try #require(
            sourceFile.statements.dropFirst().first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let secondTarget = try #require(
            secondNamespace.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)
        )

        #expect(!hasSendableConformance(in: secondTarget))
    }

    @Test("Escaped identifiers preserve qualified component boundaries")
    func escapedIdentifiersPreserveQualifiedBoundaries() throws {
        let sourceFile = Parser.parse(
            source: """
                enum `namespace` {
                    struct `repeat` {}
                }
                extension `namespace`.`repeat`: Sendable {}
                """
        )
        let namespace = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(EnumDeclSyntax.self)
        )
        let target = try #require(
            namespace.memberBlock.members.first?
                .decl.as(StructDeclSyntax.self)
        )

        #expect(hasSendableConformance(in: target))
    }

    @Test("Extensions inside executable bodies are not discovered")
    func executableBodyExtensionsAreNotDiscovered() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Target {}
                func configure() {
                    extension Target: Sendable {}
                }
                let configureAgain = {
                    extension Target: Sendable {}
                }
                """
        )
        let target = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )

        #expect(!hasSendableConformance(in: target))
    }

    @Test("Function-local declarations with colliding names are ignored")
    func functionLocalDeclarationsAreIgnored() throws {
        let sourceFile = Parser.parse(
            source: """
                struct Target {}
                func configure() {
                    struct Target: Sendable {}
                }
                let configureAgain = {
                    struct Target: Sendable {}
                }
                """
        )
        let target = try #require(
            sourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )

        #expect(!hasSendableConformance(in: target))
    }

    @Test("Source-file lookup distinguishes attached and detached nodes")
    func sourceFileLookupDistinguishesAttachment() throws {
        let parsedSourceFile = Parser.parse(source: "struct Target {}")
        let attached = try #require(
            parsedSourceFile.statements.first?
                .item.as(DeclSyntax.self)?
                .as(StructDeclSyntax.self)
        )
        let detached = attached.detached

        #expect(sourceFile(containing: Syntax(attached)) != nil)
        #expect(sourceFile(containing: Syntax(detached)) == nil)
    }

    @Test("Inherited-type lookup rejects absent and unrelated inheritance")
    func inheritedTypeLookupRejectsAbsentAndUnrelatedInheritance() throws {
        let declaration = try #require(
            parseDeclarationGroup("struct Target: Codable {}")
        )

        #expect(!inheritedTypesContainSendable(nil))
        #expect(
            !inheritedTypesContainSendable(
                declaration.inheritanceClause?.inheritedTypes
            )
        )
    }
}

struct SendableGenerationCase: Sendable {
    let source: String
    let canGenerateMembers: Bool
    let expectedExtensions: [String]
}

private func parseDeclarationGroup(_ source: String) -> (any DeclGroupSyntax)? {
    Parser.parse(source: source)
        .statements.first?
        .item.as(DeclSyntax.self)?
        .asProtocol(DeclGroupSyntax.self)
}

private func parseType(_ source: String) -> TypeSyntax {
    var parser = Parser(source)
    return TypeSyntax.parse(from: &parser)
}

private func sendableConformanceForKnownGroup(
    _ declaration: any DeclGroupSyntax
) -> Bool? {
    let syntax = Syntax(declaration)
    if let classDecl = syntax.as(ClassDeclSyntax.self) {
        return hasSendableConformance(in: classDecl)
    }
    if let structDecl = syntax.as(StructDeclSyntax.self) {
        return hasSendableConformance(in: structDecl)
    }
    if let enumDecl = syntax.as(EnumDeclSyntax.self) {
        return hasSendableConformance(in: enumDecl)
    }
    if let actorDecl = syntax.as(ActorDeclSyntax.self) {
        return hasSendableConformance(in: actorDecl)
    }
    if let protocolDecl = syntax.as(ProtocolDeclSyntax.self) {
        return hasSendableConformance(in: protocolDecl)
    }
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
        return hasSendableConformance(in: extensionDecl)
    }
    return nil
}
