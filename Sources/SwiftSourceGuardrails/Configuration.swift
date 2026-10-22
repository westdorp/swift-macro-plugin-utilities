import Foundation
import SwiftParser
import SwiftSyntax

struct GuardrailInputError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

struct RelativePath: Hashable, Decodable {
    let value: String

    init(_ value: String) throws {
        let components = value.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw GuardrailInputError("Expected a relative file/directory path without '.', '..', empty components or control characters: \(value)")
        }
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func contains(_ file: RelativePath) -> Bool {
        file == self || file.value.hasPrefix(value + "/")
    }
}

struct CodeToken: Decodable {
    let text: String

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let tree = Parser.parse(source: text)
        let tokens = tree.tokens(viewMode: .sourceAccurate).filter { $0.tokenKind != .endOfFile }
        for token in tokens {
            switch token.tokenKind {
            case .stringQuote, .multilineStringQuote, .singleQuote, .stringSegment, .rawStringPoundDelimiter,
                .regexSlash, .regexPoundDelimiter, .regexLiteralPattern:
                throw GuardrailInputError("pattern token kinds must be code tokens: \(text)")
            default: break
            }
        }
        guard tokens.count == 1, let token = tokens.first,
            token.text == text, token.leadingTrivia.isEmpty, token.trailingTrivia.isEmpty,
            token.tokenDiagnostic == nil
        else {
            throw GuardrailInputError("Each rule token must be exactly one Swift token without trivia: \(text)")
        }
        self.text = token.guardrailText
    }
}

struct GuardrailConfiguration: Decodable {
    struct Rule: Decodable {
        let id: String
        let tokens: [CodeToken]
        let paths: [RelativePath]

        enum CodingKeys: String, CodingKey, CaseIterable { case id, tokens, paths }

        init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            tokens = try values.decode([CodeToken].self, forKey: .tokens)
            paths = try values.decode([RelativePath].self, forKey: .paths)
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !tokens.isEmpty, !paths.isEmpty
            else { throw GuardrailInputError("Rule id, tokens and paths must be nonempty") }
        }

        func applies(to file: RelativePath) -> Bool { paths.contains { $0.contains(file) } }
    }

    struct Allowance: Decodable {
        let rule: String
        let file: RelativePath
        let reason: String
        let expectedCount: Int

        enum CodingKeys: String, CodingKey, CaseIterable { case rule, file, reason, expectedCount }

        init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            rule = try values.decode(String.self, forKey: .rule)
            file = try values.decode(RelativePath.self, forKey: .file)
            reason = try values.decode(String.self, forKey: .reason)
            expectedCount = try values.decode(Int.self, forKey: .expectedCount)
            guard file.value.hasSuffix(".swift"), expectedCount > 0,
                !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw GuardrailInputError("Allowlist entries need a .swift file, nonblank reason and positive expectedCount") }
        }
    }

    let rules: [Rule]
    let allowlist: [Allowance]

    enum CodingKeys: String, CodingKey, CaseIterable { case version, rules, allowlist }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else { throw GuardrailInputError("Supported configuration version is 1; got \(version)") }
        rules = try values.decode([Rule].self, forKey: .rules)
        allowlist = try values.decode([Allowance].self, forKey: .allowlist)
        guard !rules.isEmpty, Set(rules.map(\.id)).count == rules.count else {
            throw GuardrailInputError("Configuration needs nonempty rules with unique ids")
        }
        var entries: Set<AllowanceKey> = []
        for allowance in allowlist {
            guard let rule = rules.first(where: { $0.id == allowance.rule }), rule.applies(to: allowance.file) else {
                throw GuardrailInputError("Allowlist rule \(allowance.rule) must exist and cover \(allowance.file.value)")
            }
            guard entries.insert(AllowanceKey(rule: allowance.rule, file: allowance.file.value)).inserted else {
                throw GuardrailInputError("Duplicate allowlist entry: \(allowance.rule), \(allowance.file.value)")
            }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GuardrailInputError("Invalid guardrail configuration: \(error)") }
    }
}

struct AllowanceKey: Hashable {
    let rule: String
    let file: String
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension Decoder {
    func rejectUnknownKeys<Key: CodingKey & CaseIterable>(_ type: Key.Type) throws {
        let keys = try container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let unknown = Set(keys).subtracting(Key.allCases.map(\.stringValue)).sorted()
        guard unknown.isEmpty else {
            throw GuardrailInputError("Unknown configuration fields: \(unknown.joined(separator: ", "))")
        }
    }
}

extension TokenSyntax {
    var guardrailText: String {
        if case .identifier = tokenKind, text.hasPrefix("`"), text.hasSuffix("`") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
