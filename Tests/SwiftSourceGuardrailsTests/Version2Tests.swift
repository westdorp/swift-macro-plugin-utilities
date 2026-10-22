import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct Version2Tests {
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
