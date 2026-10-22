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
    let kind: TokenKind

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
        self.kind = token.tokenKind
    }
}

struct GuardrailConfiguration: Decodable {
    struct Rule {
        let id: String
        let matcher: RuleMatcher
        let paths: [RelativePath]

        func applies(to file: RelativePath) -> Bool { paths.contains { $0.contains(file) } }
    }

    private struct LegacyRule: Decodable {
        let rule: Rule
        enum CodingKeys: String, CodingKey, CaseIterable { case id, tokens, paths }

        init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let id = try values.decode(String.self, forKey: .id)
            let tokens = try values.decode([CodeToken].self, forKey: .tokens)
            let paths = try values.decode([RelativePath].self, forKey: .paths)
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !tokens.isEmpty, !paths.isEmpty
            else { throw GuardrailInputError("Rule id, tokens and paths must be nonempty") }
            rule = Rule(id: id, matcher: .tokens(tokens), paths: paths)
        }
    }

    private struct RuleDocument: Decodable {
        enum Scope {
            case paths([RelativePath])
            case named(String)
        }

        let id: String
        let matcher: RuleMatcher
        let scope: Scope

        enum CodingKeys: String, CodingKey, CaseIterable { case id, match, paths, scope, context, when }

        init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuardrailInputError("Rule id must be nonblank")
            }
            let context = values.contains(.context) ? try values.decode(LexicalContext.self, forKey: .context) : nil
            let condition = values.contains(.when) ? try values.decode(FileCondition.self, forKey: .when) : nil
            matcher = try RuleMatcher(from: values.superDecoder(forKey: .match), context: context, condition: condition)
            switch (values.contains(.paths), values.contains(.scope)) {
            case (true, false):
                let paths = try values.decode([RelativePath].self, forKey: .paths)
                guard !paths.isEmpty else { throw GuardrailInputError("Rule paths must be nonempty") }
                scope = .paths(paths)
            case (false, true):
                scope = .named(try values.decode(String.self, forKey: .scope))
            default: throw GuardrailInputError("Rule needs exactly one of paths or scope")
            }
        }

        func resolved(scopes: [String: [RelativePath]]) throws -> Rule {
            let paths: [RelativePath]
            switch scope {
            case .paths(let values): paths = values
            case .named(let name):
                guard let values = scopes[name] else { throw GuardrailInputError("Unknown scope set: \(name)") }
                paths = values
            }
            return Rule(id: id, matcher: matcher, paths: paths)
        }
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

    enum CodingKeys: String, CodingKey, CaseIterable { case version, rules, allowlist, scopes }
    private enum LegacyKeys: String, CodingKey, CaseIterable { case version, rules, allowlist }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        switch version {
        case 1:
            try decoder.rejectUnknownKeys(LegacyKeys.self)
            rules = try values.decode([LegacyRule].self, forKey: .rules).map(\.rule)
        case 2:
            let scopes = values.contains(.scopes) ? try values.decode([String: [RelativePath]].self, forKey: .scopes) : [:]
            for (name, paths) in scopes {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paths.isEmpty else {
                    throw GuardrailInputError("Scope sets need nonblank names and nonempty paths")
                }
            }
            rules = try values.decode([RuleDocument].self, forKey: .rules).map { try $0.resolved(scopes: scopes) }
        default: throw GuardrailInputError("Supported configuration versions are 1 and 2; got \(version)")
        }
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

extension Decoder {
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
