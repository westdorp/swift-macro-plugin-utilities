import ArgumentParser
import Foundation

@main
struct SwiftSourceGuardrails: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-source-guardrails",
        abstract: "Check Swift syntax against repository-owned policies and counted exceptions."
    )

    @Option(help: "Path to a version 2 JSON guardrail configuration.")
    var config: String

    @Option(help: "Source root; rule paths are relative to this directory.")
    var root: String = "."

    mutating func run() throws {
        try run(
            writeOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            writeError: { try FileHandle.standardError.write(contentsOf: $0) }
        )
    }

    func run(writeOutput: (Data) throws -> Void, writeError: (Data) throws -> Void) throws {
        let report = GuardrailCommand.scan(config: URL(fileURLWithPath: config), root: URL(fileURLWithPath: root))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(report) + Data("\n".utf8)
        let summary = Data((report.humanSummary + "\n").utf8)
        try writeOutput(output)
        try writeError(summary)
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}
