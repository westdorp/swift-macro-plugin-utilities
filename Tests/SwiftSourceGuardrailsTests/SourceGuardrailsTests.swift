import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct SourceGuardrailsTests {
    static let config = """
    {"version":1,"rules":[
      {"id":"no-delay","tokens":["Task",".","sleep"],"paths":["Sources","Tests"]},
      {"id":"injected-clock","tokens":["ContinuousClock","(",")"],"paths":["Tests"]}
    ],"allowlist":[]}
    """

    @Test func literalAndCommentClassification() throws {
        let report = try scan(fixture("literals"))
        #expect(report.violations.map(\.line) == [25, 26, 27, 28, 29, 30, 32])
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
        config.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
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
