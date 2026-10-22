import SwiftSyntax

enum RuleMatcher: Decodable {
    case occurrences(OccurrenceMatcher, LexicalContext?)

    init(from decoder: any Decoder) throws { self = .occurrences(try OccurrenceMatcher(from: decoder), nil) }

    static func tokens(_ tokens: [CodeToken]) -> Self { .occurrences(.tokens(tokens), nil) }

    func inContext(_ context: LexicalContext) -> Self {
        switch self {
        case .occurrences(let matcher, _): return .occurrences(matcher, context)
        }
    }
}

enum OccurrenceMatcher: Decodable {
    case tokens([CodeToken])
    case identifier(IdentifierPattern, IdentifierTarget)
    case call(SyntaxName)
    case member(SyntaxName)
    case argument(SyntaxName, SwiftName, ArgumentValidation)

    private enum Kind: String, Decodable { case tokens, identifier, call, member, argument }
    private enum Keys: String, CodingKey { case kind, tokens, pattern, target, name, call, label, validation }
    private enum TokenKeys: String, CodingKey, CaseIterable { case kind, tokens }
    private enum IdentifierKeys: String, CodingKey, CaseIterable { case kind, pattern, target }
    private enum NameKeys: String, CodingKey, CaseIterable { case kind, name }
    private enum ArgumentKeys: String, CodingKey, CaseIterable { case kind, call, label, validation }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .tokens:
            try decoder.rejectUnknownKeys(TokenKeys.self)
            let tokens = try values.decode([CodeToken].self, forKey: .tokens)
            guard !tokens.isEmpty else { throw GuardrailInputError("Token pattern must be nonempty") }
            self = .tokens(tokens)
        case .identifier:
            try decoder.rejectUnknownKeys(IdentifierKeys.self)
            self = .identifier(
                try values.decode(IdentifierPattern.self, forKey: .pattern),
                try values.decode(IdentifierTarget.self, forKey: .target)
            )
        case .call:
            try decoder.rejectUnknownKeys(NameKeys.self)
            self = .call(try values.decode(SyntaxName.self, forKey: .name))
        case .member:
            try decoder.rejectUnknownKeys(NameKeys.self)
            self = .member(try values.decode(SyntaxName.self, forKey: .name))
        case .argument:
            try decoder.rejectUnknownKeys(ArgumentKeys.self)
            self = .argument(
                try values.decode(SyntaxName.self, forKey: .call),
                try values.decode(SwiftName.self, forKey: .label),
                try values.decode(ArgumentValidation.self, forKey: .validation)
            )
        }
    }
}

struct SwiftName: Decodable {
    let text: String

    init(from decoder: any Decoder) throws {
        let token = try CodeToken(from: decoder)
        switch token.kind {
        case .identifier, .keyword: text = token.text
        default: throw GuardrailInputError("Expected a Swift name component: \(token.text)")
        }
    }
}

struct SyntaxName: Decodable {
    let components: [String]

    init(from decoder: any Decoder) throws {
        components = try decoder.singleValueContainer().decode([SwiftName].self).map(\.text)
        guard !components.isEmpty else { throw GuardrailInputError("Syntax names must have at least one component") }
    }
}

enum ArgumentValidation: String, Decodable { case positiveIntegerLiteral, nonemptyStringLiteral }

struct LexicalContext: Decodable {
    enum Relation: String, Decodable { case inside, outside }
    enum Kind: String, Decodable { case type, function }
    let relation: Relation
    let kind: Kind
    let name: SwiftName

    private enum CodingKeys: String, CodingKey, CaseIterable { case relation, kind, name }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relation = try values.decode(Relation.self, forKey: .relation)
        kind = try values.decode(Kind.self, forKey: .kind)
        name = try values.decode(SwiftName.self, forKey: .name)
    }
}

enum IdentifierTarget: String, Decodable { case token, function }

struct IdentifierPattern: Decodable {
    enum Kind: String, Decodable { case prefix, suffix }
    let kind: Kind
    let text: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, text }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        let token = try values.decode(CodeToken.self, forKey: .text)
        guard case .identifier = token.kind else { throw GuardrailInputError("Identifier pattern text must be an identifier") }
        text = token.text
    }

    func matches(_ token: TokenSyntax) -> Bool {
        guard case .identifier = token.tokenKind else { return false }
        switch kind {
        case .prefix: return token.guardrailText.hasPrefix(text)
        case .suffix: return token.guardrailText.hasSuffix(text)
        }
    }
}
