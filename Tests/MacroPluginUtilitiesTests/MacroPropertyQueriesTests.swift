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
            ("let items: some Collection<Swift.Int>", "items", "some Collection<Int>"),
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

    @Test(
        "Initializer matching preserves qualified metatypes and opaque wrapper boundaries",
        arguments: [
            ("init(value: Swift.Int.Type) {}", "Int.Type", true),
            ("init(value: Swift.Int.Type.Type) {}", "Int.Type.Type", true),
            ("init(value: Int.Type) {}", "Int.Type", true),
            ("init(value: Swift.Optional<Int>) {}", "Int?", true),
            ("init(value: Swift.Optional<Int>) {}", "Swift.Optional<Int>", true),
            ("init(value: Swift.Optional<Int>) {}", "Optional<Int>", true),
            ("init(value: Swift.Optional<Int>?) {}", "Swift.Optional<Int>?", true),
            ("init(value: Swift.Optional<Int>?) {}", "Optional<Int>?", true),
            ("init(value: Swift.Optional<Int>?) {}", "Int??", true),
            ("init(value: Optional<Int>.Type) {}", "Optional<Int>.Type", true),
            ("init(value: Swift.Optional<Int>.Type) {}", "Optional<Int>.Type", true),
            ("init(value: any P.Type) {}", "P.Type", true),
            ("init(value: (any P).Type) {}", "P.Type", false),
            ("init(value: any P.Type) {}", "(any P).Type", false),
            ("init(value: (Swift.Int).Type) {}", "Int.Type", true),
            ("init(value: (any Swift.Error).Type) {}", "(any Error).Type", true),
            ("init(value: (any Swift.Error).Type) {}", "any Error.Type", false),
            ("init(value: Box<Outer<Int>.Item>) {}", "Box<Item>", false),
            ("init(value: Module.Outer<Swift.Int>.Item) {}", "Outer<Int>.Item", true),
            ("init(value: Swift.InlineArray<4, Swift.Int>) {}", "InlineArray<4,Int>", true),
            ("init(value: Swift.InlineArray<4, Swift.Int>) {}", "InlineArray<8,Int>", false),
            ("init(value: any Swift.Equatable & Swift.Sendable) {}", "Equatable&Swift.Sendable", true),
            ("init(value: any Swift.Equatable & Swift.Sendable) {}", "Equatable&Sendable", true),
            ("init(value: Int?) {}", "Optional<Int>", true),
            ("init(value: Int?) {}", "Swift.Optional<Int>", true),
            ("init(value: Int?) {}", "MyModule.Optional<Int>", false),
            ("init(value: MyModule.Optional<Int>) {}", "Int?", false),
            ("init(value: MyModule.Optional<Int>) {}", "Optional<Int>", false),
            ("init(value: MyModule.Optional<Int,>) {}", "Optional<Int,>", false),
            ("init(value: Int?) {}", "Optional<Int,>", true),
            ("init(value: Optional<Int>.Marker) {}", "Swift.Optional<Int>.Marker", true),
            ("init(value: Int?.Marker) {}", "Optional<Int>.Marker", true),
            ("init(value: () -> Int?) {}", "() -> Swift.Optional<Int>", true),
            ("init(value: (_ x: Swift.Int) -> Void) {}", "(Int)->Void", true),
            ("init(value: [Swift.Int].Index) {}", "[Int].Index", true),
            ("init(value: Box<(repeat each T)>) {}", "Box<repeat each T>", false),
            ("init(value: Namespace.Swift.Optional<Int>) {}", "Swift.Optional<Int>", false),
            ("init(value: Namespace.Swift.Optional<Int>.Marker) {}", "Swift.Optional<Int>.Marker", false),
            ("init(value: Shapes.Optional<4>) {}", "Optional<4>", true),
            ("init(value: [4 of Swift.Int]?) {}", "[4 of Int]?", true),
            ("init(value: Box<[Swift.Int]>) {}", "Box<[Int]>", true),
            ("init(value: Box<[Int?]>) {}", "Box<[Swift.Optional<Int>]>", true),
            ("init(value: [Swift.String: Swift.Int?]) {}", "[String:Optional<Int>]", true),
            ("init(value: (any Error)?) {}", "Swift.Optional<any Error>", true),
            ("init(value: Swift.Optional<any Error>) {}", "(any Error)?", true),
            ("init(value: (any Swift.Equatable & Swift.Sendable)?) {}", "Swift.Optional<any Equatable&Sendable>", true),
            ("init(value: Swift.Int!) {}", "Int!", true),
            ("init(value: Swift.Int.Type) {}", "Type", false),
            ("init(value: ((Int) -> Swift.Int).Type) {}", "(Int)->Swift.Int.Type", false),
            ("init(value: some 🐱) {}", "some🐱", false),
            ("init(value: Box<some Probe>) {}", "Box<someProbe>", false),
            ("init(value: borrowing some Probe) {}", "borrowingsomeProbe", false),
        ]
    )
    func initializerMatchingHandlesMetatypesAndOpaqueWrappers(
        member: String,
        parameterType: String,
        expected: Bool
    ) throws {
        let classDecl = try parseClass("class Target { \(member) }")

        #expect(
            hasConflictingInitializer(
                parameterLabel: "value",
                parameterType: parameterType,
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
