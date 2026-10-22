import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct Version2Tests {
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
