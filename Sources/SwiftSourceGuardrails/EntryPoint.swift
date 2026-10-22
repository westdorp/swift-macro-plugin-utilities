import ArgumentParser
import Foundation

@main
struct SwiftSourceGuardrails: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-source-guardrails",
        abstract: "Check Swift code tokens against repository-owned bans and counted exceptions."
    )

    @Option(help: "Path to the version 1 JSON guardrail configuration.")
    var config: String

    @Option(help: "Source root; rule paths are relative to this directory.")
    var root: String = "."

    mutating func run() throws {
        let report = GuardrailCommand.scan(config: URL(fileURLWithPath: config), root: URL(fileURLWithPath: root))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(encoder.encode(report) + Data("\n".utf8))
        FileHandle.standardError.write(Data((report.humanSummary + "\n").utf8))
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}
