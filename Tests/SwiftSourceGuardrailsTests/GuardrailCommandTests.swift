import Foundation
import Testing
@testable import SwiftSourceGuardrails

struct GuardrailCommandTests {
    @Test func version2AcceptanceExamplesReachTheCommandOutput() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("guardrails.json", #"""
        {"version":2,"scopes":{"production":["Sources"]},"rules":[
          {"id":"generated-delay","scope":"production","match":{"kind":"stringLiteral","tokens":["Task",".","sleep"]}},
          {"id":"network-import","scope":"production","match":{"kind":"import","module":{"kind":"exact","name":"Network"},"form":"declaration","importKind":"any","presence":"forbidden"}}
        ],"allowlist":[]}
        """#)
        let generated = "try await Task" + ".sleep(for: .seconds(1))"
        try fixture.write("Sources/Generated.swift", "let generated = \"\(generated)\"\n// \(generated)")
        try fixture.write("Sources/New/Imports.swift", "import Network\n@preconcurrency\nimport Network\nimport NetworkExtension")
        let command = try SwiftSourceGuardrails.parse(["--config", fixture.config.path, "--root", fixture.root.path])
        var output = Data()
        var summary = Data()
        do {
            try command.run(writeOutput: { output.append($0) }, writeError: { summary.append($0) })
            Issue.record("Policy violations must fail the command")
        } catch {
            #expect(SwiftSourceGuardrails.exitCode(for: error).rawValue == 1)
        }
        let report = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(report["scannedFiles"] as? Int == 2)
        let violations = try #require(report["violations"] as? [[String: Any]])
        #expect(violations.compactMap { $0["file"] as? String } == ["Sources/Generated.swift", "Sources/New/Imports.swift", "Sources/New/Imports.swift"])
        #expect(violations.compactMap { $0["line"] as? Int } == [1, 1, 2])
        #expect(violations.compactMap { $0["rule"] as? String } == ["generated-delay", "network-import", "network-import"])
        #expect(String(decoding: summary, as: UTF8.self).contains("3 violation(s)"))
    }

    @Test(arguments: [
        #"{"kind":"stringLiteral","text":""}"#,
        #"{"kind":"stringLiteral","regex":"Task.*"}"#,
        #"{"kind":"call","name":[]}"#,
        #"{"kind":"import","module":{"kind":"any"},"form":"canImport","importKind":"struct","presence":"forbidden"}"#
    ])
    func version2InvalidMatchersExitTwo(match: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("guardrails.json", #"{"version":2,"rules":[{"id":"bad","paths":["Sources"],"match":\#(match)}],"allowlist":[]}"#)
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.exitCode == 2)
        #expect(report.errors.isEmpty == false)
        #expect(report.scannedFiles == 0)
        #expect(report.violations.isEmpty)
    }

    @Test func version2MalformedSourceDiscardsEarlierFindingsEvenWhenConditionIsFalse() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("guardrails.json", #"{"version":2,"rules":[{"id":"calls","paths":["Sources"],"match":{"kind":"call","name":["pause"]},"when":{"imports":"Foundation"}}],"allowlist":[]}"#)
        try fixture.write("Sources/A.swift", "import Foundation\npause()")
        try fixture.write("Sources/Z.swift", "func broken( {")
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.exitCode == 2)
        #expect(report.errors.joined().contains("Sources/Z.swift"))
        #expect(report.scannedFiles == 0)
        #expect(report.violations.isEmpty)
        #expect(report.allowlistChecks.isEmpty)
    }

    @Test func namedScopeIncludesNewDescendantsWithoutRuleEdits() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let config = #"{"version":2,"scopes":{"production":["Sources"]},"rules":[{"id":"names","scope":"production","match":{"kind":"identifier","target":"token","pattern":{"kind":"prefix","text":"Forbidden"}}}],"allowlist":[]}"#
        try fixture.write("guardrails.json", config)
        try fixture.write("Sources/Existing.swift", "let ordinary = 0")
        #expect(GuardrailCommand.scan(config: fixture.config, root: fixture.root).exitCode == 0)
        try fixture.write("Sources/New/Nested.swift", "struct ForbiddenNewType {}")
        try fixture.write("SourcesOther/File.swift", "struct ForbiddenOutOfScope {}")
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root)
        #expect(report.scannedFiles == 2)
        #expect(report.violations.map(\.file) == ["Sources/New/Nested.swift"])
        #expect(report.violations.map(\.rule) == ["names"])
    }

    @Test(arguments: [0, 1, 2])
    func entryPointPreservesReportAndExitStatus(scanExitCode: Int32) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let command = try fixture.command(scanExitCode: scanExitCode)
        var output = Data()
        var summary = Data()
        do {
            try command.run(writeOutput: { output.append($0) }, writeError: { summary.append($0) })
            #expect(scanExitCode == 0)
        } catch {
            #expect(scanExitCode != 0)
            #expect(SwiftSourceGuardrails.exitCode(for: error).rawValue == scanExitCode)
        }
        let report = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(report["schemaVersion"] as? Int == 1)
        #expect(output.last == 0x0a)
        #expect(String(decoding: summary, as: UTF8.self).contains("Swift source guardrails"))
        #expect(summary.last == 0x0a)
    }

    @Test(arguments: [FailingStream.standardOutput, .standardError], [0, 1, 2])
    func outputFailuresReachArgumentParser(stream: FailingStream, scanExitCode: Int32) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let command = try fixture.command(scanExitCode: scanExitCode)
        let failure = WriteFailure()
        var attemptedStreams: [FailingStream] = []
        do {
            try command.run(writeOutput: { _ in
                attemptedStreams.append(.standardOutput)
                if stream == .standardOutput { throw failure }
            }, writeError: { _ in
                attemptedStreams.append(.standardError)
                if stream == .standardError { throw failure }
            })
            Issue.record("Output failure was swallowed")
        } catch {
            #expect(error is WriteFailure)
            #expect(SwiftSourceGuardrails.exitCode(for: error).rawValue == 1)
            #expect(SwiftSourceGuardrails.fullMessage(for: error).contains(WriteFailure.description))
        }
        #expect(attemptedStreams == (stream == .standardOutput ? [.standardOutput] : [.standardOutput, .standardError]))
    }

    enum FailingStream: Sendable {
        case standardOutput
        case standardError
    }

    struct WriteFailure: LocalizedError {
        static let description = "guardrail output write failed"
        var errorDescription: String? { Self.description }
    }

    @Test func documentedArgumentsUseArgumentParser() throws {
        let defaults = try SwiftSourceGuardrails.parse(["--config", "guardrails.json"])
        #expect(defaults.root == ".")
        let explicit = try SwiftSourceGuardrails.parse(["--config", "policy.json", "--root", "repository"])
        #expect(explicit.config == "policy.json")
        #expect(explicit.root == "repository")
        #expect(SwiftSourceGuardrails.helpMessage().contains("--config"))
        #expect(SwiftSourceGuardrails.helpMessage().contains("version 1 or 2"))
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

    @Test(arguments: ["missing-config", "bad-config", "missing-root", "file-root", "missing-scope", "missing-scope-ancestor", "empty-scope", "non-swift-scope", "invalid-utf8", "malformed-swift"])
    func inputFailuresAreJSONReports(scenario: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/File.swift", "let value = 1")
        try fixture.write("Tests/File.swift", "let value = 2")
        var config = fixture.config
        var root = fixture.root
        var expectedError: String?
        switch scenario {
        case "missing-config":
            config = fixture.root.appendingPathComponent("absent.json")
            expectedError = "missing config \(config.path)"
        case "bad-config": try fixture.write("guardrails.json", "{}")
        case "missing-root":
            root = fixture.root.appendingPathComponent("absent")
            expectedError = "missing root \(root.path)"
        case "file-root": root = fixture.config
        case "missing-scope":
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"Sources/Foo\""))
            expectedError = "missing scope Sources/Foo"
        case "missing-scope-ancestor":
            try fixture.write("guardrails.json", SourceGuardrailsTests.config.replacingOccurrences(of: "\"Sources\"", with: "\"Missing/Foo\""))
            expectedError = "missing scope Missing/Foo"
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
        if let expectedError { #expect(report.errors == [expectedError]) }
        #expect(report.errors.joined().contains("NSCocoaErrorDomain") == false)
        #expect(report.violations.isEmpty)
        #expect(report.humanSummary.contains("failed"))
        #expect(throws: Never.self) { try JSONEncoder().encode(report) }
    }

    @Test func unreadableConfigNamesItsPath() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let report = GuardrailCommand.scan(config: fixture.config, root: fixture.root, read: { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        #expect(report.exitCode == 2)
        #expect(report.errors.joined().contains("Cannot read config \(fixture.config.path):"))
        #expect(report.errors.joined().contains("NSCocoaErrorDomain") == false)
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
        #expect(report.errors.joined().contains("NSCocoaErrorDomain") == false)
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
        #expect(report.errors.joined().contains("NSCocoaErrorDomain") == false)
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

    func command(scanExitCode: Int32) throws -> SwiftSourceGuardrails {
        try write("Sources/File.swift", scanExitCode == 1 ? "Task" + ".sleep()" : "let value = 1")
        try write("Tests/File.swift", "let value = 2")
        let configURL = scanExitCode == 2 ? root.appendingPathComponent("absent.json") : config
        return try SwiftSourceGuardrails.parse(["--config", configURL.path, "--root", root.path])
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned fixture \(root.path): \(error)") }
    }
}
