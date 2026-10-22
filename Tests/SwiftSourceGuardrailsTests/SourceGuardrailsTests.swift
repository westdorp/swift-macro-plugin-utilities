import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct SourceGuardrailsTests {
    static let config = """
    {"version":2,"rules":[
      {"id":"no-delay","match":{"kind":"tokens","tokens":["Task",".","sleep"]},"paths":["Sources","Tests"]},
      {"id":"injected-clock","match":{"kind":"tokens","tokens":["ContinuousClock","(",")"]},"paths":["Tests"]}
    ],"allowlist":[]}
    """

    @Test func literalAndCommentClassification() throws {
        let report = try scan(fixture("literals"))
        #expect(report.violations.map(\.line) == [25, 26, 27, 28, 29, 30, 32, 35])
        #expect(report.violations.allSatisfy { $0.rule == "no-delay" })
    }

    @Test func tokenBoundariesAndScopes() throws {
        let source = try fixture("boundaries")
        let tests = try scan(source)
        #expect(tests.violations.map(\.rule) == ["no-delay", "no-delay", "injected-clock"])
        let sources = try scan(source, file: "Sources/File.swift")
        #expect(sources.violations.map(\.rule) == ["no-delay", "no-delay"])
        #expect(try scan(source, file: "TestsOther/File.swift").violations.isEmpty)
    }

    @Test func conditionalDirectivesDoNotInterruptMatching() throws {
        let source = try fixture("conditional-compilation")
        let report = try scan(source)
        #expect(report.exitCode == 1)
        #expect(report.violations.map(\.line) == [1, 5, 13, 19, 24, 26, 28])
        let conditions = Self.config.replacingOccurrences(of: "\"Task\",\".\",\"sleep\"", with: "\"A\"")
        #expect(try scan(source, config: conditions).violations.map(\.line) == [2, 6, 14, 20, 23])
        let alternate = conditions.replacingOccurrences(of: "\"A\"", with: "\"B\"")
        #expect(try scan(source, config: alternate).violations.map(\.line) == [7, 25])
    }

    @Test(arguments: [
        (["canImport", "(", "X", ")"], [2]),
        (["DEBUG"], [4, 9]),
        (["canImport", "(", "Y", ")"], [11]),
        (["OUTER"], [14]),
        (["INNER"], [15]),
        (["A"], [21]),
        (["A", ".", "sleep"], []),
        (["Task", "canImport"], []),
        (["OUTER", "INNER"], []),
        (["#if"], []),
        (["#elseif"], []),
        (["#else"], []),
        (["#endif"], [])
    ])
    func conditionalConditionsAreSeparateCodeRuns(tokens: [String], lines: [Int]) throws {
        let encoded = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        let config = Self.config.replacingOccurrences(of: "[\"Task\",\".\",\"sleep\"]", with: encoded)
        let report = try scan(fixture("conditional-conditions"), config: config)
        #expect(report.violations.map(\.line) == lines)
    }

    @Test func conditionRunsPreserveSurroundingCodeMatches() throws {
        let report = try scan(fixture("conditional-conditions"))
        #expect(report.violations.map(\.line) == [1, 20])
    }

    @Test(arguments: ["\"foo\"", "#\"foo\"#", "\"\"\"\nfoo\n\"\"\"", "/foo/", "#/foo/#", "#/\nfoo\n/#", "\"", "\"\"\""])
    func literalPatternsFailClosed(pattern: String) throws {
        let encoded = String(decoding: try JSONEncoder().encode([pattern]), as: UTF8.self)
        let config = Self.config.replacingOccurrences(of: "[\"Task\",\".\",\"sleep\"]", with: encoded)
        do {
            _ = try GuardrailConfiguration.decode(Data(config.utf8))
            Issue.record("Literal pattern was accepted: \(pattern)")
        } catch let error as GuardrailInputError {
            #expect(error.description.contains("pattern token kinds must be code tokens"))
        }
    }

    @Test func directiveStringContentsAreNotCodeTokens() throws {
        let config = Self.config.replacingOccurrences(of: "\"Task\",\".\",\"sleep\"", with: "\"Task\"")
        let report = try scan("""
        #sourceLocation(file: "Task", line: 1)
        let ordinary = "Task"
        let raw = #"Task"#
        let regex = /Task/
        @_silgen_name("Task") func example()
        """, config: config)
        #expect(report.violations.isEmpty)
    }

    @Test func locationsArePhysicalAndUTF8Based() throws {
        let source = "#sourceLocation(file: \"virtual\", line: 500)\r\nlet café = 0; " + invocation
        let report = try scan(source)
        let match = try #require(report.violations.first)
        #expect(match.file == "Tests/File.swift")
        #expect(match.line == 2)
        #expect(match.column == 26)
    }

    @Test(arguments: [1, 2, 3]) func exactAllowlistCounts(expected: Int) throws {
        let config = Self.config.replacingOccurrences(of: "\"allowlist\":[]", with: """
        "allowlist":[{"rule":"no-delay","file":"Tests/File.swift","reason":"Parser fixture","expectedCount":\(expected)}]
        """)
        let report = try scan(invocation + "\n" + invocation, config: config)
        #expect(report.allowlistChecks.count == 1)
        #expect(report.allowlistChecks.first?.actualCount == 2)
        #expect(report.allowlistChecks.first?.reason == "Parser fixture")
        #expect(report.violations.isEmpty == (expected == 2))
        #expect(report.allowlistChecks.first?.isSatisfied == (expected == 2))
        #expect(report.exitCode == (expected == 2 ? 0 : 1))
    }

    @Test func unusedAllowlistFails() throws {
        let config = Self.config.replacingOccurrences(of: "\"allowlist\":[]", with: """
        "allowlist":[{"rule":"no-delay","file":"Tests/File.swift","reason":"Fixture","expectedCount":1}]
        """)
        let report = try scan("let value = 0", config: config)
        #expect(report.allowlistChecks.first?.actualCount == 0)
        #expect(report.exitCode == 1)
    }

    @Test(arguments: [
        "{", "{}",
        config.replacingOccurrences(of: "\"version\":2", with: "\"version\":99"),
        config.replacingOccurrences(of: "\"allowlist\":[]", with: "\"allowlist\":[],\"allowList\":[]"),
        config.replacingOccurrences(of: "\"no-delay\"", with: "\"\""),
        config.replacingOccurrences(of: "\"Task\",\".\",\"sleep\"", with: "\"Task" + ".sleep\""),
        config.replacingOccurrences(of: "\"Task\",\".\",\"sleep\"", with: ""),
        config.replacingOccurrences(of: "\"Sources\",\"Tests\"", with: "\"../Sources\""),
        config.replacingOccurrences(of: "\"Sources\",\"Tests\"", with: "\"/Sources\""),
        config.replacingOccurrences(of: "\"Sources\",\"Tests\"", with: "\"Sources//Nested\""),
        config.replacingOccurrences(of: "\"Sources\",\"Tests\"", with: ""),
        config.replacingOccurrences(of: "\"injected-clock\"", with: "\"no-delay\"")
    ]) func invalidConfigurationIsRejected(json: String) {
        #expect(throws: GuardrailInputError.self) {
            try GuardrailConfiguration.decode(Data(json.utf8))
        }
    }

    @Test(arguments: [
        "{\"rule\":\"missing\",\"file\":\"Tests/File.swift\",\"reason\":\"Fixture\",\"expectedCount\":1}",
        "{\"rule\":\"no-delay\",\"file\":\"Other/File.swift\",\"reason\":\"Fixture\",\"expectedCount\":1}",
        "{\"rule\":\"no-delay\",\"file\":\"Tests/File.swift\",\"reason\":\"  \",\"expectedCount\":1}",
        "{\"rule\":\"no-delay\",\"file\":\"Tests/File.swift\",\"reason\":\"Fixture\",\"expectedCount\":0}",
        "{\"rule\":\"no-delay\",\"file\":\"Tests/File.swift\",\"reason\":\"Fixture\",\"expectedCount\":-1}",
        "{\"rule\":\"no-delay\",\"file\":\"Tests\",\"reason\":\"Fixture\",\"expectedCount\":1}"
    ]) func invalidAllowlistIsRejected(entry: String) {
        let config = Self.config.replacingOccurrences(of: "\"allowlist\":[]", with: "\"allowlist\":[\(entry)]")
        #expect(throws: GuardrailInputError.self) {
            try GuardrailConfiguration.decode(Data(config.utf8))
        }
    }

    @Test func duplicateAllowlistIsRejected() {
        let entry = """
        {"rule":"no-delay","file":"Tests/File.swift","reason":"Fixture","expectedCount":1}
        """
        let config = Self.config.replacingOccurrences(of: "\"allowlist\":[]", with: "\"allowlist\":[\(entry),\(entry)]")
        #expect(throws: GuardrailInputError.self) {
            try GuardrailConfiguration.decode(Data(config.utf8))
        }
    }

    @Test(arguments: ["let x = \"unterminated", "/* unclosed", "func broken( {", "let r = #/unclosed"])
    func malformedSourceFailsClosed(source: String) {
        #expect(throws: GuardrailInputError.self) { try scan(source) }
    }

    private var invocation: String { "try await Task" + ".sleep(for: .seconds(1))" }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "swift.txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func scan(_ source: String, file: String = "Tests/File.swift", config: String = config) throws -> GuardrailReport {
        try SourceGuardrails.scan(
            configuration: GuardrailConfiguration.decode(Data(config.utf8)),
            files: [GuardrailSource(file: RelativePath(file), text: source)]
        )
    }
}
