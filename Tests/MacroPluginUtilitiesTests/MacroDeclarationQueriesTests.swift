import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Macro declaration queries")
struct MacroDeclarationQueriesTests {
    @Test(
        "Modifier matching is exact",
        arguments: [
            ("final class Target {}", "final", true),
            ("static var value: Int", "static", true),
            ("class var value: Int { 0 }", "class", true),
            ("nonisolated class Target {}", "isolated", false),
            ("public final class Target {}", "publicFinal", false),
        ]
    )
    func modifierMatchingIsExact(source: String, name: String, expected: Bool) throws {
        let modifiers = try #require(parseModifiers(source))

        #expect(hasModifier(named: name, in: modifiers) == expected)
    }

    @Test(
        "Attribute matching accepts qualification and rejects suffix collisions",
        arguments: [
            ("@MainActor class Target {}", "MainActor", true),
            ("@Concurrency.MainActor class Target {}", "MainActor", true),
            ("@NotMainActor class Target {}", "MainActor", false),
            ("@MainActorish class Target {}", "MainActor", false),
        ]
    )
    func attributeMatchingUsesCompleteBasenames(
        source: String,
        name: String,
        expected: Bool
    ) throws {
        let attributes = try #require(parseAttributes(source))
        let attribute = try #require(
            attributes.compactMap { $0.as(AttributeSyntax.self) }.first
        )

        #expect(hasAttribute(named: name, in: attributes) == expected)
        #expect(attributeNameMatches(attribute, expected: name) == expected)
    }

    @Test(
        "Type matching accepts equivalent spellings",
        arguments: [
            ("Error?", "Error?"),
            ("Int?", "Optional<Int>"),
            ("Int?", "Swift.Optional<Int>"),
            ("Swift.Int?", "Optional<Int>"),
            ("Swift.Int?", "Swift.Optional<Int>"),
            ("Optional<Int>", "Swift.Optional<Int>"),
            ("Int??", "Optional<Int?>"),
            ("Int??", "Optional<Optional<Int>>"),
            ("Int??", "Swift.Optional<Swift.Optional<Int>>"),
            ("Int??", "Swift.Optional<Int>?"),
            ("((Int) -> Int)?", "Optional<(Int)->Int>"),
            ("((Int) -> Int)?", "Swift.Optional<(Int)->Int>"),
            ("(Int, Int)?", "Optional<(Int,Int)>"),
            ("()?", "Optional<()>"),
            ("Box<Int?>", "Box<Optional<Int>>"),
            ("Box<Int?>", "Box<Swift.Optional<Int>>"),
            ("any Swift.Equatable & Swift.Sendable", "Equatable&Swift.Sendable"),
            ("any Swift.Equatable & Swift.Sendable", "Equatable&Sendable"),
            ("any Swift.Equatable & Swift.Sendable", "Equatable & Sendable"),
            ("(any Swift.Equatable & Swift.Sendable)?", "(Equatable&Sendable)?"),
            ("(any Swift.Equatable & Swift.Sendable)!", "(Equatable&Sendable)!"),
            ("Optional<any Swift.Equatable & Swift.Sendable>", "(Equatable&Sendable)?"),
            ("Optional<any Swift.Equatable & Swift.Sendable>", "Optional<Equatable&Sendable>"),
            ("(any Swift.Equatable & Swift.Sendable).Type", "(any Equatable&Sendable).Type"),
            ("(Swift.Equatable & Swift.Sendable).Type", "(Equatable&Sendable).Type"),
            ("Optional<Int>.Type", "Swift.Optional<Int>.Type"),
            ("Int?.Type", "Optional<Int>.Type"),
            ("Int?.Type", "Swift.Optional<Int>.Type"),
            ("(any Error)?", "Error?"),
            ("(any Error)?", "(any Error)?"),
            ("(any Error)?", "Optional<any Error>"),
            ("(any Error)?", "Swift.Optional<any Error>"),
            ("Swift.Optional<any Error>", "(any Error)?"),
            ("Optional<any Error>", "Swift.Optional<any Error>"),
            ("(any Swift.Error)!", "(any Error)!"),
            ("(any Swift.Equatable & Swift.Sendable)?", "Swift.Optional<any Equatable&Sendable>"),
            ("Swift.Optional<any Swift.Equatable & Swift.Sendable>", "(any Equatable&Sendable)?"),
            ("Swift.Optional<any Error>?", "(any Error)??"),
            ("any Swift.Error.Type", "any Error.Type"),
            ("Swift.Error.Type", "any Error.Type"),
            ("any Error", "any Error"),
            ("any Error", "(any Error)"),
            ("MyModule.Optional<Int>", "MyModule.Optional<Int>"),
            ("Outer.MyModule.Optional<Int>", "MyModule.Optional<Int>"),
            ("MyModule.Optional<Int, String>", "Optional<Int,String>"),
            ("(Error)?", "Error?"),
            ("any Error", "Error"),
            ("(any Swift.Error)?", "Error?"),
            ("Optional<Error>", "Error?"),
            ("Optional<Error>", "Optional<Error>"),
            ("Swift.Optional<Error>", "Error?"),
            ("Swift.Optional<Error>", "Swift.Optional<Error>"),
            ("Swift.Optional<Error>", "Optional<Error>"),
            ("Swift.Optional<Int>?", "Swift.Optional<Int>?"),
            ("Swift.Optional<Int>?", "Optional<Int>?"),
            ("Swift.Optional<Int>?", "Int??"),
            ("Swift.Optional<Swift.Int>?", "Optional<Int>?"),
            ("Swift.Optional<Swift.Optional<Int>>", "Optional<Int>?"),
            ("Swift.Optional<Swift.Error>", "Error?"),
            ("Swift.Optional<((Int) -> Int)>", "Swift.Optional<(Int)->Int>"),
            ("Optional<((Int) -> Int)>", "((Int)->Int)?"),
            ("Optional<any Error>", "Error?"),
            ("AVPlayer.TimeControlStatus", "AVPlayer.TimeControlStatus"),
            ("External.Error", "Error"),
            ("someModule.Error", "Error"),
            ("Swift.Int.Type", "Int.Type"),
            ("Swift.Int.Type.Type", "Int.Type.Type"),
            ("Swift.Int.Type?", "Int.Type?"),
            ("Optional<Int>.Type", "Optional<Int>.Type"),
            ("Swift.Optional<Int>.Type", "Optional<Int>.Type"),
            ("Swift.Optional<Int>.Type", "Int?.Type"),
            ("(Swift.Optional<Int>).Type", "Optional<Int>.Type"),
            ("(Swift.Optional<Int>).Type", "Int?.Type"),
            ("(Swift.Int).Type", "Int.Type"),
            ("(Swift.Int).Type", "(Int).Type"),
            ("((Swift.Int)).Type", "Int.Type"),
            ("(Swift.Int.Type).Type", "Int.Type.Type"),
            ("(Swift.Int?).Type", "Int?.Type"),
            ("Swift.Int?.Type", "Int?.Type"),
            ("Swift.Int!", "Int!"),
            ("(any Swift.Error)!", "Error!"),
            ("any Swift.Error.Type", "Error.Type"),
            ("(any Error).Type", "(any Error).Type"),
            ("(any Swift.Error).Type", "(any Error).Type"),
            ("((any Swift.Error)).Type", "(any Error).Type"),
            ("(any (Swift.Error)).Type", "(any Error).Type"),
            ("(any Swift.Error.Type).Type", "(any Error.Type).Type"),
            ("((Int, String)).Type", "(Int,String).Type"),
            ("(()).Type", "().Type"),
            ("([Int]).Type", "[Int].Type"),
            ("(((Int) -> Int)?).Type", "((Int)->Int)?.Type"),
            ("Dictionary < String, Int >", "Dictionary<String,Int>"),
            ("Module.Outer<Swift.Int>.Item", "Outer<Int>.Item"),
            ("Swift.InlineArray<4, Swift.Int>", "InlineArray<4,Int>"),
            ("Swift.InlineArray<4, Swift.Int>", "InlineArray<4, Int>"),
            ("Module.Vector<-1, Swift.Int>", "Vector<-1,Int>"),
        ]
    )
    func typeMatchingAcceptsEquivalentSpellings(actual: String, expected: String) {
        #expect(typeMatches(parseType(actual), expectedTypeName: expected))
    }

    @Test(
        "Type matching rejects distinct and deceptive spellings",
        arguments: [
            ("some Error", "Error"),
            ("some Equatable", "someEquatable"),
            ("(some Equatable)?", "someEquatable?"),
            ("some 🐱", "some🐱"),
            ("Box<some Probe>", "Box<someProbe>"),
            ("borrowing some Probe", "borrowingsomeProbe"),
            ("some Swift.Error", "Error"),
            ("borrowing some Swift.Error", "Error"),
            ("(some Swift.Error)?", "Error?"),
            ("(some Swift.Error).Type", "Error.Type"),
            ("(any Error).Type", "Error.Type"),
            ("(any Swift.Error).Type", "Error.Type"),
            ("(any Swift.Error).Type", "any Error.Type"),
            ("(any Swift.Error).Type", "(Error).Type"),
            ("(any Swift.Error.Type).Type", "Error.Type.Type"),
            ("any Error.Type", "(any Error).Type"),
            ("any Swift.Error.Type", "(any Error).Type"),
            ("Swift.Int.Type", "Type"),
            ("Swift.Int.Type.Type", "Type.Type"),
            ("Swift.Int.Type?", "Type?"),
            ("Box<Outer<Int>.Item>", "Box<Item>"),
            ("Outer<Int>.Item", "Item"),
            ("Outer<Int>.Mid.Item", "Mid.Item"),
            ("Swift.Optional<Outer<Int>.Item>", "Item?"),
            ("Swift.InlineArray<4, Swift.Int>", "InlineArray<8,Int>"),
            ("Swift.InlineArray<4, Swift.Int>", "InlineArray<4,String>"),
            ("(((Int) -> Int)?).Type", "(Int)->Int?.Type"),
            ("Swift.Optional<some Swift.Error>", "Error?"),
            ("Swift.Optional<some Swift.Error>?", "Error??"),
            ("Optional<((Int) -> Int)>", "(Int)->Int?"),
            ("Swift.Optional<((Int) -> Int)>", "(Int)->Int?"),
            ("Optional<Int>.Type", "MyModule.Optional<Int>.Type"),
            ("MyModule.Optional<Int>", "Int?"),
            ("MyModule.Optional<Int>", "Swift.Optional<Int>"),
            ("MyModule.Optional<Int>", "Optional<Int>"),
            ("Box<MyModule.Optional<Int>>", "Box<Optional<Int>>"),
            ("MyModule.Optional<Int>.Type", "Optional<Int>.Type"),
            ("MyModule.Optional<Int>?", "Optional<Int>?"),
            ("(any Error)?", "any Error?"),
            ("Swift.Optional<any Error>", "any Error?"),
            ("Swift.Optional<any Error>?", "any Error??"),
            ("(any Swift.Error)!", "any Error!"),
            ("some Error", "any Error"),
            ("Error", "any any Error"),
            ("Int?", "MyModule.Optional<Int>"),
            ("Optional<Int>", "MyModule.Optional<Int>"),
            ("some Swift.Equatable & Swift.Sendable", "Equatable&Sendable"),
            ("(any Swift.Equatable & Swift.Sendable)?", "Equatable&Sendable?"),
            ("(any Swift.Equatable & Swift.Sendable)!", "Equatable&Sendable!"),
            ("(any Swift.Equatable & Swift.Sendable).Type", "any Equatable&Sendable.Type"),
            ("(any Swift.Equatable & Swift.Sendable).Type", "Equatable&Sendable.Type"),
            ("(Swift.Equatable & Swift.Sendable).Type", "Equatable&Sendable.Type"),
            ("any Swift.Equatable & Outer<Int>.Item", "Equatable&Item"),
            ("(some Swift.Error)?", "Optional<Error>"),
            ("(some Swift.Error)?", "Swift.Optional<Error>"),
            ("Swift.Int.Protocol", "Protocol"),
            ("((Int) -> Swift.Int).Type", "(Int)->Swift.Int.Type"),
            ("((Int) -> Int)?", "(Int)->Int?"),
            ("((Int) -> Int)!", "(Int)->Int!"),
            ("Optional<some Swift.Error>", "Error?"),
            ("Bool", "Bool?"),
            ("(Int, Int)", "Int"),
            ("Int", "Float"),
            ("Optional<Int>", "Int"),
            ("External.ErrorBox", "Error"),
            ("NotError", "Error"),
            ("Errors.ErrorLike", "Error"),
        ]
    )
    func typeMatchingRejectsDistinctSpellings(actual: String, expected: String) {
        #expect(!typeMatches(parseType(actual), expectedTypeName: expected))
    }

    @Test("Existential markers normalize while opaque markers remain distinct")
    func existentialAndOpaqueTypesRemainAsymmetric() {
        #expect(typeMatches(parseType("any Error"), expectedTypeName: "Error"))
        #expect(!typeMatches(parseType("some Error"), expectedTypeName: "Error"))
    }

    @Test(
        "Instance-variable matching excludes type properties",
        arguments: [
            ("var value: Int", true),
            ("private let value: Int", true),
            ("static var value: Int", false),
            ("private static let value: Int", false),
            ("override class var value: Int { 0 }", false),
        ]
    )
    func instanceVariableMatchingExcludesTypeProperties(source: String, expected: Bool) throws {
        let variable = try #require(parseDeclaration(source)?.as(VariableDeclSyntax.self))

        #expect(isInstanceVariable(variable) == expected)
    }

    @Test("Collects every source member namespace")
    func collectsCompleteMemberNames() throws {
        let declaration = try #require(
            Parser.parse(
                source: """
                enum Surface {
                    case idle, active
                    let primary, secondary: Int
                    func refresh() {}
                    enum NestedEnum {}
                    struct NestedStruct {}
                    class NestedClass {}
                    actor NestedActor {}
                    protocol NestedProtocol {}
                    typealias Alias = Int
                }
                """
            )
            .statements.first?.item.as(EnumDeclSyntax.self)
        )

        #expect(
            existingMemberNames(in: declaration) == [
                "idle",
                "active",
                "primary",
                "secondary",
                "refresh",
                "NestedEnum",
                "NestedStruct",
                "NestedClass",
                "NestedActor",
                "NestedProtocol",
                "Alias",
            ]
        )
    }

    @Test("Renders payload labels through one enum case pattern boundary")
    func rendersEnumCasePatterns() throws {
        let declaration = try #require(
            Parser.parse(
                source: """
                enum Event {
                    case idle
                    case loaded(String)
                    case progress(seconds: Double, _ marker: Int)
                }
                """
            )
            .statements.first?.item.as(EnumDeclSyntax.self)
        )
        let elements = declaration.memberBlock.members
            .compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
            .flatMap(\.elements)
        let parameters = elements.compactMap(\.parameterClause).flatMap(\.parameters)

        let wildcardPatterns = elements.map { element in
            renderEnumCasePattern(for: element) { _ in "_" }
        }
        let bindingPatterns = elements.map { element in
            renderEnumCasePattern(for: element) { index in "let value\(index)" }
        }

        #expect(wildcardPatterns == [".idle", ".loaded(_)", ".progress(seconds: _, _)"])
        #expect(
            bindingPatterns
                == [
                    ".idle",
                    ".loaded(let value0)",
                    ".progress(seconds: let value0, let value1)",
                ]
        )
        #expect(parameters.map(enumCaseLabel) == [nil, "seconds", nil])
    }
}

private func parseModifiers(_ source: String) -> DeclModifierListSyntax? {
    guard let declaration = parseDeclaration(source) else {
        return nil
    }
    if let classDecl = declaration.as(ClassDeclSyntax.self) {
        return classDecl.modifiers
    }
    return declaration.as(VariableDeclSyntax.self)?.modifiers
}

private func parseAttributes(_ source: String) -> AttributeListSyntax? {
    parseDeclaration(source)?.as(ClassDeclSyntax.self)?.attributes
}

private func parseDeclaration(_ source: String) -> DeclSyntax? {
    Parser.parse(source: source).statements.first?.item.as(DeclSyntax.self)
}

private func parseType(_ source: String) -> TypeSyntax {
    var parser = Parser(source)
    return TypeSyntax.parse(from: &parser)
}
