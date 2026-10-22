import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct Version2Tests {
    @Test(arguments: ["literals", "boundaries", "conditional-compilation", "conditional-conditions", "v2-calls", "v2-imports", "v2-strings"])
    func tokenMigrationPreservesCompleteReports(name: String) throws {
        var migrated = try #require(JSONSerialization.jsonObject(with: Data(SourceGuardrailsTests.config.utf8)) as? [String: Any])
        migrated["version"] = 2
        let rules = try #require(migrated["rules"] as? [[String: Any]])
        migrated["rules"] = try rules.map { original in
            var rule = original
            let tokens = try #require(rule.removeValue(forKey: "tokens") as? [String])
            rule["match"] = ["kind": "tokens", "tokens": tokens]
            return rule
        }
        let source = try GuardrailSource(file: RelativePath("Tests/File.swift"), text: fixture(name))
        let v1 = try SourceGuardrails.scan(configuration: GuardrailConfiguration.decode(Data(SourceGuardrailsTests.config.utf8)), files: [source])
        let v2 = try SourceGuardrails.scan(configuration: GuardrailConfiguration.decode(JSONSerialization.data(withJSONObject: migrated)), files: [source])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(v1) == encoder.encode(v2))
    }

    @Test(arguments: [1, 2])
    func stringAllowancesCountLiteralsInsteadOfTokenStarts(expected: Int) throws {
        let source = "let text = \"Task" + ".sleep(); Task" + ".sleep()\""
        let allowance = #"[{"rule":"rule","file":"Sources/File.swift","reason":"Generated fixture","expectedCount":\#(expected)}]"#
        let report = try scan(source, match: #"{"kind":"stringLiteral","tokens":["Task",".","sleep"]}"#, allowlist: allowance)
        #expect(report.allowlistChecks.map(\.actualCount) == [1])
        #expect(report.violations.count == (expected == 1 ? 0 : 1))
        #expect(report.exitCode == (expected == 1 ? 0 : 1))
    }

    @Test(arguments: ["let ordinary = 0", "@MainActor struct Example {}"])
    func requiredPresenceAllowanceFailsWhenItBecomesStale(source: String) throws {
        let allowance = #"[{"rule":"rule","file":"Sources/File.swift","reason":"Missing annotation fixture","expectedCount":1}]"#
        let report = try scan(source, match: #"{"kind":"requireAttribute","name":["MainActor"]}"#, allowlist: allowance)
        let missing = source == "let ordinary = 0"
        #expect(report.allowlistChecks.map(\.actualCount) == [missing ? 1 : 0])
        #expect(report.violations.isEmpty)
        #expect(report.exitCode == (missing ? 0 : 1))
    }

    @Test func fileConditionAndLexicalContextCompose() throws {
        let fields = #","when":{"imports":"Foundation"},"context":{"relation":"outside","kind":"type","name":"Adapter"}"#
        let source = "import Foundation\nstruct Adapter { func run() { pause() } }\nstruct Other { func run() { pause() } }"
        let match = #"{"kind":"call","name":["pause"]}"#
        #expect(try scan(source, match: match, fields: fields).violations.map(\.line) == [3])
        #expect(try scan(source.replacingOccurrences(of: "import Foundation", with: "import OtherModule"), match: match, fields: fields).violations.isEmpty)
    }

    @Test func generatedStringCodeUsesDecodedSegmentsAndSwiftParser() throws {
        let match = #"{"kind":"stringLiteral","tokens":["Task",".","sleep"]}"#
        let report = try scan(fixture("v2-strings"), match: match)
        #expect(report.violations.map(\.line) == [1, 2, 3, 4, 12, 13, 17, 18, 19, 23, 24, 25])
        #expect(report.violations.filter { $0.line == 18 }.count == 1)
        #expect(try scan("// \"Task" + ".sleep()\"", match: match).violations.isEmpty)
    }

    @Test func exactStringContentIsDecodedAndDoesNotCrossInterpolation() throws {
        let text = "try await Task" + ".sleep(for: .seconds(1))"
        let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let match = #"{"kind":"stringLiteral","text":\#(encoded)}"#
        #expect(try scan(fixture("v2-strings"), match: match).violations.map(\.line) == [1, 2, 3, 12, 13, 17])
        let multiline = #"{"kind":"stringLiteral","text":"try await Task\n.sleep(for: .seconds(1))"}"#
        #expect(try scan(fixture("v2-strings"), match: multiline).violations.map(\.line) == [4, 19])
    }

    @Test func stringAndCodeRulesKeepSeparateBoundaries() throws {
        let match = #"{"kind":"call","name":["Task","sleep"]}"#
        #expect(try scan(fixture("v2-strings"), match: match).violations.map(\.line) == [10])
        let fields = #","context":{"relation":"inside","kind":"function","name":"generate"}"#
        let source = "func generate() { let text = \"Task" + ".sleep()\" }\nfunc other() { let text = \"Task" + ".sleep()\" }"
        #expect(try scan(source, match: #"{"kind":"stringLiteral","tokens":["Task",".","sleep"]}"#, fields: fields).violations.map(\.line) == [1])
    }

    @Test func compilerDirectiveStringsAreNotGeneratedStringLiterals() throws {
        let match = #"{"kind":"stringLiteral","text":"marker"}"#
        #expect(try scan("#sourceLocation(file: \"marker\", line: 1)\nlet marker = 0", match: match).violations.isEmpty)
        #expect(try scan("let text = \"marker\"", match: match).violations.count == 1)
    }

    @Test(arguments: [
        #"{"kind":"stringLiteral"}"#,
        #"{"kind":"stringLiteral","text":""}"#,
        #"{"kind":"stringLiteral","text":null}"#,
        #"{"kind":"stringLiteral","tokens":[]}"#,
        #"{"kind":"stringLiteral","tokens":["Task"],"text":"Task"}"#,
        #"{"kind":"stringLiteral","regex":"Task.*"}"#,
        #"{"kind":"stringLiteral","tokens":["Task"],"extra":true}"#
    ])
    func malformedStringPatternsAreRejected(match: String) {
        #expect(throws: GuardrailInputError.self) { try configuration(match: match) }
    }

    @Test(arguments: [
        ("declaration", "any", [1, 2, 6, 22, 23]),
        ("declaration", "module", [1, 2, 23]),
        ("declaration", "struct", [6]),
        ("declaration", "func", [22]),
        ("canImport", "any", [7, 14]),
        ("either", "any", [1, 2, 6, 7, 14, 22, 23])
    ])
    func importsUseExactModulesAndSyntaxKinds(form: String, kind: String, lines: [Int]) throws {
        let match = importMatch(form: form, kind: kind)
        #expect(try scan(fixture("v2-imports"), match: match).violations.map(\.line) == lines)
        #expect(try scan("import NetworkExtension", match: match).violations.isEmpty)
    }

    @Test(arguments: ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"])
    func eachScopedImportKindIsDistinct(kind: String) throws {
        let source = "import \(kind) Network.Symbol\nimport Network\nimport struct Other.Symbol"
        #expect(try scan(source, match: importMatch(kind: kind)).violations.map(\.line) == [1])
    }

    @Test func foundationComplementAndAnyCanImportCoverUnknownModules() throws {
        let except = #"{"kind":"except","name":"Foundation"}"#
        let declaration = importMatch(selection: except)
        #expect(try scan("import Foundation\nimport NewlyIntroducedModule", match: declaration).violations.map(\.line) == [2])
        let condition = importMatch(selection: #"{"kind":"any"}"#, form: "canImport")
        #expect(try scan(fixture("v2-imports"), match: condition).violations.map(\.line) == [7, 11, 14, 20])
        let complement = importMatch(selection: except, form: "canImport")
        #expect(try scan(fixture("v2-imports"), match: complement).violations.map(\.line) == [7, 11, 14])
    }

    @Test func requiredImportReportsAtFileStartAndChecksAllBranches() throws {
        let match = importMatch(presence: "required")
        let missing = try scan("// import Network\nlet text = \"import Network\"", match: match)
        #expect(missing.violations.map(\.line) == [1])
        #expect(missing.violations.map(\.column) == [1])
        #expect(try scan("", match: match).violations.count == 1)
        #expect(try scan("#if NEVER\n@preconcurrency import Network\n#endif", match: match).violations.isEmpty)
        let condition = importMatch(form: "canImport", presence: "required")
        #expect(try scan("import Network", match: condition).violations.count == 1)
        #expect(try scan("#if canImport(Network)\n#endif", match: condition).violations.isEmpty)
    }

    @Test(arguments: [
        ("import Foundation\npause()", true),
        ("@preconcurrency import Foundation\npause()", true),
        ("import struct Foundation.Date\npause()", true),
        ("#if NEVER\nimport Foundation\n#endif\npause()", true),
        ("import FoundationExtension\npause()", false),
        ("#if canImport(Foundation)\n#endif\npause()", false),
        ("// import Foundation\nlet text = \"import Foundation\"\npause()", false)
    ])
    func fileImportConditionsUseDeclarations(source: String, applies: Bool) throws {
        let fields = #","when":{"imports":"Foundation"}"#
        #expect(try scan(source, match: #"{"kind":"call","name":["pause"]}"#, fields: fields).violations.isEmpty == (applies == false))
    }

    @Test(arguments: [
        ("@MainActor\nfunc run() {}", true),
        ("#if NEVER\n@MainActor struct Example {}\n#endif", true),
        ("// @MainActor\nlet annotation = \"@MainActor\"", false),
        ("@OtherActor func run() {}", false),
        ("", false)
    ])
    func requiredAttributeIsFilePresence(source: String, present: Bool) throws {
        let match = #"{"kind":"requireAttribute","name":["MainActor"]}"#
        let report = try scan(source, match: match)
        #expect(report.violations.isEmpty == present)
        #expect(report.violations.allSatisfy { $0.line == 1 && $0.column == 1 })
    }

    @Test func requiredQualifiedAndUncheckedAttributesUseTypeSyntax() throws {
        #expect(try scan("@Module.Annotation<Int> func run() {}", match: #"{"kind":"requireAttribute","name":["Module","Annotation"]}"#).violations.isEmpty)
        #expect(try scan("struct Example: @unchecked Sendable {}", match: #"{"kind":"requireAttribute","name":["unchecked"]}"#).violations.isEmpty)
        let match = #"{"kind":"requireAttribute","name":["Annotation"]}"#
        #expect(try scan("@Module.Annotation func run() {}", match: match).violations.count == 1)
    }

    @Test func requiredPresenceCannotHaveContextButCanHaveFileCondition() throws {
        let match = #"{"kind":"requireAttribute","name":["MainActor"]}"#
        let context = #","context":{"relation":"inside","kind":"type","name":"Adapter"}"#
        #expect(throws: GuardrailInputError.self) { try configuration(match: match, fields: context) }
        #expect(throws: GuardrailInputError.self) { try configuration(match: importMatch(presence: "required"), fields: context) }
        #expect(try scan("let ordinary = 0", match: match, fields: #","when":{"imports":"Foundation"}"#).violations.isEmpty)
        #expect(try scan("import Foundation", match: match, fields: #","when":{"imports":"Foundation"}"#).violations.count == 1)
    }

    @Test(arguments: [#"null"#, #"{}"#, #"{"imports":"A.B"}"#, #"{"imports":"Foundation","extra":true}"#])
    func malformedFileConditionsAreRejected(condition: String) {
        #expect(throws: GuardrailInputError.self) {
            try configuration(match: #"{"kind":"tokens","tokens":["x"]}"#, fields: #","when":\#(condition)"#)
        }
    }

    @Test(arguments: [
        #"{"kind":"any","name":"Network"}"#,
        #"{"kind":"except"}"#,
        #"{"kind":"exact","name":"A.B"}"#,
        #"{"kind":"wildcard","name":"Net*"}"#
    ])
    func malformedModuleSelectionsAreRejected(selection: String) {
        #expect(throws: GuardrailInputError.self) { try configuration(match: importMatch(selection: selection)) }
    }

    @Test(arguments: [("canImport", "module"), ("either", "struct"), ("unknown", "any"), ("declaration", "unknown")])
    func incompatibleImportFormsAreRejected(form: String, kind: String) {
        #expect(throws: GuardrailInputError.self) { try configuration(match: importMatch(form: form, kind: kind)) }
    }

    private func importMatch(
        selection: String = #"{"kind":"exact","name":"Network"}"#,
        form: String = "declaration", kind: String = "any", presence: String = "forbidden"
    ) -> String {
        #"{"kind":"import","module":\#(selection),"form":"\#(form)","importKind":"\#(kind)","presence":"\#(presence)"}"#
    }

    @Test(arguments: [
        (#"{"kind":"call","name":["Task"]}"#, [1, 2, 6]),
        (#"{"kind":"call","name":["Task","sleep"]}"#, [9]),
        (#"{"kind":"member","name":["Task","sleep"]}"#, [8, 9, 17]),
        (#"{"kind":"call","name":["Thread"]}"#, [19]),
        (#"{"kind":"call","name":["Thread","init"]}"#, [22]),
        (#"{"kind":"call","name":["sleep"]}"#, [25])
    ])
    func genericCallsAndMembers(match: String, lines: [Int]) throws {
        #expect(try scan(fixture("v2-calls"), match: match).violations.map(\.line) == lines)
        #expect(try scan("Other.run()", match: match).violations.isEmpty)
    }

    @Test(arguments: ["struct", "class", "actor", "enum", "extension"])
    func lexicalTypeContextIncludesClosuresAndNestedTypes(kind: String) throws {
        let source = """
        \(kind) Adapter {
            func run() {
                pause()
                let nested = { pause() }
                struct Inner { func run() { pause() } }
            }
        }
        struct Other { func run() { pause() } }
        pause()
        """
        let match = #"{"kind":"call","name":["pause"]}"#
        let inside = #","context":{"relation":"inside","kind":"type","name":"Adapter"}"#
        let outside = #","context":{"relation":"outside","kind":"type","name":"Adapter"}"#
        #expect(try scan(source, match: match, fields: inside).violations.map(\.line) == [3, 4, 5])
        #expect(try scan(source, match: match, fields: outside).violations.map(\.line) == [8, 9])
    }

    @Test func lexicalFunctionContextIsExhaustiveAndAppliesToTokenRules() throws {
        let source = """
        func `adapter`() {
            pause()
            func nested() { pause() }
        }
        func other() { pause() }
        """
        let match = #"{"kind":"tokens","tokens":["pause","(",")"]}"#
        let inside = #","context":{"relation":"inside","kind":"function","name":"adapter"}"#
        let outside = #","context":{"relation":"outside","kind":"function","name":"adapter"}"#
        #expect(try scan(source, match: match, fields: inside).violations.map(\.line) == [2, 3])
        #expect(try scan(source, match: match, fields: outside).violations.map(\.line) == [5])
        #expect(try scan("pause()", match: match, fields: inside).violations.isEmpty)
        #expect(try scan("pause()", match: match, fields: outside).violations.count == 1)
    }

    @Test func extensionsUseTheFinalTypeComponent() throws {
        let source = "extension Outer.Adapter<Int> { func run() { pause() } }"
        let match = #"{"kind":"call","name":["pause"]}"#
        let fields = #","context":{"relation":"inside","kind":"type","name":"Adapter"}"#
        #expect(try scan(source, match: match, fields: fields).violations.count == 1)
    }

    @Test(arguments: ["1", "0x10", "0b10", "0o10", "1_000"])
    func positiveNamedIntegerLiteralsPass(value: String) throws {
        let source = """
        schedule<Result<Int, Error>>(
            work: { consume([1, 2]) },
            minutes: \(value)
        )
        """
        let match = #"{"kind":"argument","call":["schedule"],"label":"minutes","validation":"positiveIntegerLiteral"}"#
        #expect(try scan(source, match: match).exitCode == 0)
    }

    @Test(arguments: ["0", "-1", "+1", "1.5", "(1)", "1 + 2", "value", "999999999999999999999999999999"])
    func invalidNamedIntegerValuesFail(value: String) throws {
        let match = #"{"kind":"argument","call":["schedule"],"label":"minutes","validation":"positiveIntegerLiteral"}"#
        #expect(try scan("schedule(minutes: \(value))", match: match).violations.count == 1)
    }

    @Test func missingAndRepeatedArgumentsFailOncePerCall() throws {
        let match = #"{"kind":"argument","call":["schedule"],"label":"minutes","validation":"positiveIntegerLiteral"}"#
        let source = "schedule()\nschedule(minutes: 1, minutes: 2)\nother(minutes: 0)"
        #expect(try scan(source, match: match).violations.map(\.line) == [1, 2])
    }

    @Test(arguments: [("\"reason\"", true), ("#\"reason\"#", true), ("\" \"", false), ("\"\"", false), ("\"\\(value)\"", false), ("reason", false)])
    func namedReasonRequiresNonblankLiteral(value: String, passes: Bool) throws {
        let match = #"{"kind":"argument","call":["unsafeOperation"],"label":"reason","validation":"nonemptyStringLiteral"}"#
        #expect(try scan("unsafeOperation(reason: \(value))", match: match).violations.isEmpty == passes)
    }

    @Test(arguments: [
        #"{"kind":"call","name":[]}"#,
        #"{"kind":"call","name":["Task.pause"]}"#,
        #"{"kind":"call","name":["Task"],"tokens":["Task"]}"#,
        #"{"kind":"member","name":["*"]}"#,
        #"{"kind":"argument","call":["schedule"],"label":"minutes","validation":"regex"}"#,
        #"{"kind":"argument","call":["schedule"],"label":"","validation":"positiveIntegerLiteral"}"#
    ])
    func malformedCallMatchersAreRejected(match: String) {
        #expect(throws: GuardrailInputError.self) { try configuration(match: match) }
    }

    @Test(arguments: [#"null"#, #"{}"#, #"{"relation":"within","kind":"type","name":"Adapter"}"#, #"{"relation":"inside","kind":"closure","name":"Adapter"}"#, #"{"relation":"inside","kind":"type","name":"A.B"}"#, #"{"relation":"inside","kind":"type","name":"Adapter","extra":1}"#])
    func malformedContextsAreRejected(context: String) {
        #expect(throws: GuardrailInputError.self) {
            try configuration(match: #"{"kind":"call","name":["pause"]}"#, fields: #","context":\#(context)"#)
        }
    }

    @Test(arguments: [("prefix", "check", [1, 3]), ("suffix", "Clock", [4, 5])])
    func identifierTokens(kind: String, text: String, lines: [Int]) throws {
        let source = """
        func checkExample() {}
        func recheck() {}
        let `checkValue` = 0
        let fakeClock = 1
        struct ManualClock {}
        let Clockwork = 2
        // checkComment FakeClock
        let quoted = "checkText FakeClock"
        let regex = /checkPattern FakeClock/
        """
        let match = #"{"kind":"identifier","target":"token","pattern":{"kind":"\#(kind)","text":"\#(text)"}}"#
        #expect(try scan(source, match: match).violations.map(\.line) == lines)
    }

    @Test func identifierFunctionsIgnoreUsesAndTrivia() throws {
        let source = """
        func
        `checkExample`
        () {}
        let checkValue = 1
        checkExample()
        struct checkType {}
        """
        let match = #"{"kind":"identifier","target":"function","pattern":{"kind":"prefix","text":"check"}}"#
        let report = try scan(source, match: match)
        #expect(report.violations.map(\.line) == [2])
        #expect(report.violations.map(\.column) == [1])
        #expect(try scan("func other() {}", match: match).exitCode == 0)
    }

    @Test func version2TokensKeepVersion1Classification() throws {
        let source = "Task" + ".sleep()\nlet text = \"Task" + ".sleep()\""
        let match = #"{"kind":"tokens","tokens":["Task",".","sleep"]}"#
        #expect(try scan(source, match: match).violations.map(\.line) == [1])
    }

    @Test(arguments: [
        #"{"kind":"identifier","target":"token","pattern":{"kind":"regex","text":"Clock"}}"#,
        #"{"kind":"identifier","target":"token","pattern":{"kind":"suffix","text":"*Clock"}}"#,
        #"{"kind":"identifier","target":"token","pattern":{"kind":"suffix","text":""}}"#,
        #"{"kind":"identifier","target":"unknown","pattern":{"kind":"prefix","text":"check"}}"#,
        #"{"kind":"identifier","target":"token","pattern":{"kind":"prefix","text":"check","typo":1}}"#,
        #"{"kind":"identifier","target":"token","pattern":{"kind":"prefix","text":"check"},"tokens":["x"]}"#,
        #"{"kind":"tokens","tokens":[]}"#,
        #"{"kind":"tokens","tokens":["x"],"pattern":{}}"#,
        #"{"kind":"other"}"#
    ])
    func malformedMatchersAreRejected(match: String) {
        #expect(throws: GuardrailInputError.self) { try configuration(match: match) }
    }

    @Test(arguments: [
        (#""scope":"unknown""#, #"{}"#),
        (#""scope":"production","paths":["Sources"]"#, #"{"production":["Sources"]}"#),
        (#""scope":null"#, #"{}"#),
        (#""paths":[]"#, #"{}"#),
        (#""scope":"production""#, #"{"production":[]}"#),
        (#""scope":"production""#, #"{"production":["../Sources"]}"#),
        (#""paths":["Sources"]"#, #"{" ":["Sources"]}"#)
    ])
    func malformedScopesAreRejected(selection: String, scopes: String) {
        let json = #"{"version":2,"scopes":\#(scopes),"rules":[{"id":"rule",\#(selection),"match":{"kind":"tokens","tokens":["x"]}}],"allowlist":[]}"#
        #expect(throws: GuardrailInputError.self) { try GuardrailConfiguration.decode(Data(json.utf8)) }
    }

    func configuration(match: String, fields: String = "", allowlist: String = "[]") throws -> GuardrailConfiguration {
        let json = #"{"version":2,"rules":[{"id":"rule","paths":["Sources"],"match":\#(match)\#(fields)}],"allowlist":\#(allowlist)}"#
        return try GuardrailConfiguration.decode(Data(json.utf8))
    }

    func scan(_ source: String, match: String, fields: String = "", allowlist: String = "[]") throws -> GuardrailReport {
        try SourceGuardrails.scan(
            configuration: configuration(match: match, fields: fields, allowlist: allowlist),
            files: [GuardrailSource(file: RelativePath("Sources/File.swift"), text: source)]
        )
    }

    func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "swift.txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
