import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct GuardrailCommandTests {
    @Test func documentedArgumentsUseArgumentParser() throws {
        let defaults = try SwiftSourceGuardrails.parse(["--config", "guardrails.json"])
        #expect(defaults.root == ".")
        let explicit = try SwiftSourceGuardrails.parse(["--config", "policy.json", "--root", "repository"])
        #expect(explicit.config == "policy.json")
        #expect(explicit.root == "repository")
        #expect(SwiftSourceGuardrails.helpMessage().contains("--config"))
    }

    @Test func scansOverlappingScopesOnceAndRendersJSON() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/Nested/File.swift", "Task" + ".sleep()")
        try fixture.write("Sources/README.txt", "not Swift")
        try fixture.write("Sources/.hidden.swift", "Task" + ".sleep()")
        try fixture.write("Tests/File.swift", "ContinuousClock()")
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.exitCode == 1)
        #expect(report.scannedFiles == 3)
        #expect(report.violations.map(\.file) == ["Sources/.hidden.swift", "Sources/Nested/File.swift", "Tests/File.swift"])
        #expect(report.humanSummary.contains("3 violation(s)"))
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        let violations = try #require(json["violations"] as? [[String: Any]])
        #expect(violations.first?["line"] as? Int == 1)
        #expect(violations.first?["rule"] as? String == "no-delay")
    }

    @Test func cleanScanAndFileScope() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/File.swift", "let value = 1")
        try fixture.write("Tests/File.swift", "let value = 2")
        let config = SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\",\"Tests\"", with: "\"Sources/File.swift\",\"Tests\"")
        try fixture.write("guardrails.json", config)
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.exitCode == 0)
        #expect(report.scannedFiles == 2)
        #expect(report.humanSummary.contains("passed"))
    }

    @Test(arguments: ["missing-config", "bad-config", "missing-root", "file-root", "missing-scope", "empty-scope", "non-swift-scope", "invalid-utf8", "malformed-swift"])
    func inputFailuresAreJSONReports(scenario: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/File.swift", "let value = 1")
        try fixture.write("Tests/File.swift", "let value = 2")
        var config = fixture.config
        var root = fixture.root
        switch scenario {
        case "missing-config": config = fixture.root.appendingPathComponent("absent.json")
        case "bad-config": try fixture.write("guardrails.json", "{}")
        case "missing-root": root = fixture.root.appendingPathComponent("absent")
        case "file-root": root = fixture.config
        case "missing-scope":
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"Missing\""))
        case "empty-scope":
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"Empty\""))
        case "non-swift-scope":
            try fixture.write("readme.txt", "text")
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"readme.txt\""))
        case "invalid-utf8": try Data([0xff]).write(to: fixture.root.appendingPathComponent("Tests/File.swift"))
        case "malformed-swift": try fixture.write("Tests/File.swift", "let x = \"")
        default: Issue.record("Unknown test scenario"); return
        }
        let report = GuardrailCommand.scan(config: config, root: root)
        #expect(report.exitCode == 2)
        #expect(report.errors.isEmpty == false)
        #expect(report.violations.isEmpty)
        #expect(report.humanSummary.contains("failed"))
        #expect(throws: Never.self) { try JSONEncoder().encode(report) }
    }

    @Test(arguments: ["file", "directory", "scope-ancestor"])
    func symlinksFailClosed(kind: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/Real.swift", "let value = 1")
        try fixture.write("Tests/File.swift", "let value = 2")
        switch kind {
        case "file":
            try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Sources/Link.swift").path, withDestinationPath: "Real.swift")
        case "directory":
            try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Sources/Loop").path, withDestinationPath: ".")
        case "scope-ancestor":
            try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Alias").path, withDestinationPath: "Sources")
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"Alias/Real.swift\""))
        default: Issue.record("Unknown test scenario"); return
        }
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.exitCode == 2)
        #expect(report.errors.joined().contains("symbolic link"))
    }

    @Test func unreadableSourceFailsWithoutPartialResults() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/File.swift", "Task" + ".sleep()")
        try fixture.write("Tests/File.swift", "let value = 0")
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root, read: { url in
            if url.lastPathComponent == "File.swift" { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        #expect(report.exitCode == 2)
        #expect(report.errors.joined().contains("File.swift"))
        #expect(report.violations.isEmpty)
    }

    @Test func unreadableDirectoryFailsClosed() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/File.swift", "let value = 0")
        try fixture.write("Tests/File.swift", "let value = 0")
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root, list: { url in
            if url.lastPathComponent == "Sources" { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        #expect(report.exitCode == 2)
        #expect(report.errors.joined().contains("Sources"))
    }
}

private struct CommandFixture {
    let root: URL
    var config: URL { root.appendingPathComponent("guardrails.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-guardrails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do { try write("guardrails.json", SourceGuardrailsTests.config) }
        catch { remove(); throw error }
    }

    func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned fixture \(root.path): \(error)") }
    }
}
