import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Macro property queries")
struct MacroPropertyQueriesTests {
    @Test(
        "Stored-let matching accepts normalized type spellings",
        arguments: [
            ("let value: Error", "value", "Error"),
            ("let value: Swift.Error", "value", "Error"),
            ("let value: Optional<Error>", "value", "Error?"),
            ("let value: (any Swift.Error)?", "value", "Error?"),
            ("let `repeat`: Swift.Error", "`repeat`", "Error"),
            ("let other: Int, value: Swift.Error", "value", "Error"),
        ]
    )
    func storedLetMatchingAcceptsNormalizedTypes(
        member: String,
        name: String,
        type: String
    ) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        #expect(
            hasStoredLetProperty(
                named: name,
                typeNamed: type,
                in: classDecl
            )
        )
    }

    @Test(
        "Stored-let matching rejects unsupported declarations",
        arguments: [
            ("var value: Error", "value", "Error"),
            ("static let value: Error", "value", "Error"),
            ("class var value: Error { fatalError() }", "value", "Error"),
            ("let value: Error { fatalError() }", "value", "Error"),
            ("let value = Failure()", "value", "Error"),
            ("let (value, other): (Error, Int)", "value", "Error"),
            ("let other: Error", "value", "Error"),
            ("let value: Int", "value", "Error"),
            ("let value: some Error", "value", "Error"),
        ]
    )
    func storedLetMatchingRejectsUnsupportedDeclarations(
        member: String,
        name: String,
        type: String
    ) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        #expect(
            !hasStoredLetProperty(
                named: name,
                typeNamed: type,
                in: classDecl
            )
        )
    }

    @Test(
        "Inline-initialized lookup returns the exact eligible binding",
        arguments: [
            ("let value = 1", "value", "value = 1"),
            ("var other = 0, value: Int = 1", "value", "value: Int = 1"),
            ("let `repeat` = 1", "`repeat`", "`repeat` = 1"),
        ]
    )
    func inlineInitializedLookupReturnsExactBinding(
        member: String,
        name: String,
        expectedBinding: String
    ) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        let property = try #require(
            inlineInitializedStoredProperty(named: name, in: classDecl)
        )

        #expect(property.identifier.identifier.text == name)
        #expect(property.binding.trimmedDescription == expectedBinding)
    }

    @Test(
        "Inline-initialized lookup rejects unsupported bindings",
        arguments: [
            "let value: Int",
            "var value: Int { 1 }",
            "static let value = 1",
            "class var value: Int { 1 }",
            "let (value, other) = (1, 2)",
            "let other = 1",
        ]
    )
    func inlineInitializedLookupRejectsUnsupportedBindings(member: String) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        #expect(inlineInitializedStoredProperty(named: "value", in: classDecl) == nil)
    }

    @Test("Unsupported storage returns unmanaged names in source order")
    func unsupportedStorageReturnsUnmanagedNamesInSourceOrder() throws {
        let classDecl = try parseClass(
            """
            class Target {
                let first: Int
                var initialized = 1
                var computed: Int { 1 }
                static var shared: Int
                class var inherited: Int { 1 }
                let managed: Int
                let second: Int, third: String
                let `repeat`: Int
                let (left, right): (Int, Int)
            }
            """
        )

        let names = unsupportedUninitializedStoredProperties(
            in: classDecl,
            excluding: ["managed"]
        )

        #expect(names == ["first", "second", "third", "`repeat`"])
    }

    @Test(
        "Initializer matching requires one labelled equivalent parameter",
        arguments: [
            ("init(value: Swift.Error) {}", true),
            ("init(other: Swift.Error) {}", false),
            ("init(_ value: Swift.Error) {}", false),
            ("init(value: Int) {}", false),
            ("init(value: Error, other: Int) {}", false),
            ("func value(_ value: Error) {}", false),
        ]
    )
    func initializerMatchingRequiresExactShape(member: String, expected: Bool) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        #expect(
            hasConflictingInitializer(
                parameterLabel: "value",
                parameterType: "Error",
                in: classDecl
            ) == expected
        )
    }
}

private func parseClass(_ source: String) throws -> ClassDeclSyntax {
    try #require(
        Parser.parse(source: source)
            .statements.first?
            .item.as(DeclSyntax.self)?
            .as(ClassDeclSyntax.self)
    )
}
