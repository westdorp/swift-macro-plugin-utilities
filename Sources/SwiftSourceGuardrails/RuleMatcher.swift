import SwiftSyntax

enum RuleMatcher: Decodable {
    case tokens([CodeToken])
    case identifier(IdentifierPattern, IdentifierTarget)

    private enum Kind: String, Decodable { case tokens, identifier }
    private enum Keys: String, CodingKey { case kind, tokens, pattern, target }
    private enum TokenKeys: String, CodingKey, CaseIterable { case kind, tokens }
    private enum IdentifierKeys: String, CodingKey, CaseIterable { case kind, pattern, target }

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
        }
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
