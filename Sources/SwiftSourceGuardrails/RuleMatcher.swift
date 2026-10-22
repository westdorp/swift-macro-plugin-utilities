import SwiftSyntax

struct RuleMatcher {
    enum Check {
        case occurrences(OccurrenceMatcher, LexicalContext?)
        case required(FileRequirement)
    }

    let check: Check
    let condition: FileCondition?

    private enum Keys: String, CodingKey { case kind, name }
    private enum AttributeKeys: String, CodingKey, CaseIterable { case kind, name }

    init(from decoder: any Decoder, context: LexicalContext?, condition: FileCondition?) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "import": check = try ImportDocument(from: decoder, context: context).check
        case "requireAttribute":
            try decoder.rejectUnknownKeys(AttributeKeys.self)
            check = .required(.attribute(try values.decode(SyntaxName.self, forKey: .name)))
        default: check = .occurrences(try OccurrenceMatcher(from: decoder), context)
        }
        if case .required = check, context != nil {
            throw GuardrailInputError("Required file presence cannot have a lexical context")
        }
        self.condition = condition
    }

    private init(check: Check, condition: FileCondition?) {
        self.check = check
        self.condition = condition
    }

    static func tokens(_ tokens: [CodeToken]) -> Self { Self(check: .occurrences(.tokens(tokens), nil), condition: nil) }
}

enum OccurrenceMatcher: Decodable {
    case tokens([CodeToken])
    case identifier(IdentifierPattern, IdentifierTarget)
    case call(SyntaxName)
    case member(SyntaxName)
    case argument(SyntaxName, SwiftName, ArgumentValidation)
    case `import`(ImportPattern)
    case stringLiteral(StringContentPattern)

    private enum Kind: String, Decodable { case tokens, identifier, call, member, argument, stringLiteral }
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
        case .stringLiteral:
            self = .stringLiteral(try StringContentPattern(from: decoder))
        }
    }
}

enum StringContentPattern: Decodable {
    case text(String)
    case tokens([CodeToken])

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, text, tokens }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch (values.contains(.text), values.contains(.tokens)) {
        case (true, false):
            let text = try values.decode(String.self, forKey: .text)
            guard !text.isEmpty else { throw GuardrailInputError("String text pattern must be nonempty") }
            self = .text(text)
        case (false, true):
            let tokens = try values.decode([CodeToken].self, forKey: .tokens)
            guard !tokens.isEmpty else { throw GuardrailInputError("String token pattern must be nonempty") }
            self = .tokens(tokens)
        default: throw GuardrailInputError("String literal matcher needs exactly one of text or tokens")
        }
    }
}

enum FileRequirement {
    case attribute(SyntaxName)
    case `import`(ImportPattern)
}

struct FileCondition: Decodable {
    let imports: SwiftName
    private enum CodingKeys: String, CodingKey, CaseIterable { case imports }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        imports = try decoder.container(keyedBy: CodingKeys.self).decode(SwiftName.self, forKey: .imports)
    }
}

enum ModuleSelection: Decodable {
    case exact(SwiftName)
    case except(SwiftName)
    case any

    private enum Kind: String, Decodable { case exact, except, any }
    private enum Keys: String, CodingKey, CaseIterable { case kind, name }
    private enum AnyKeys: String, CodingKey, CaseIterable { case kind }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(Keys.self)
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .exact: self = .exact(try values.decode(SwiftName.self, forKey: .name))
        case .except: self = .except(try values.decode(SwiftName.self, forKey: .name))
        case .any:
            try decoder.rejectUnknownKeys(AnyKeys.self)
            self = .any
        }
    }

    func matches(_ module: TokenSyntax) -> Bool {
        switch self {
        case .exact(let name): return module.guardrailText == name.text
        case .except(let name): return module.guardrailText != name.text
        case .any: return true
        }
    }
}

enum ImportKind: String, Decodable {
    case any, module, `typealias`, `struct`, `class`, `enum`, `protocol`, `let`, `var`, `func`

    func matches(_ declaration: ImportDeclSyntax) -> Bool {
        switch self {
        case .any: return true
        case .module: return declaration.importKindSpecifier == nil
        default: return declaration.importKindSpecifier?.text == rawValue
        }
    }
}

enum ImportPattern {
    case declaration(ModuleSelection, ImportKind)
    case canImport(ModuleSelection)
    case either(ModuleSelection)
}

private struct ImportDocument {
    enum Form: String, Decodable { case declaration, canImport, either }
    enum Presence: String, Decodable { case forbidden, required }
    let check: RuleMatcher.Check

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, module, form, importKind, presence }

    init(from decoder: any Decoder, context: LexicalContext?) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let module = try values.decode(ModuleSelection.self, forKey: .module)
        let kind = try values.decode(ImportKind.self, forKey: .importKind)
        let form = try values.decode(Form.self, forKey: .form)
        let pattern: ImportPattern
        switch form {
        case .declaration: pattern = .declaration(module, kind)
        case .canImport, .either:
            guard kind == .any else { throw GuardrailInputError("canImport and either forms require importKind any") }
            pattern = form == .canImport ? .canImport(module) : .either(module)
        }
        switch try values.decode(Presence.self, forKey: .presence) {
        case .forbidden: check = .occurrences(.import(pattern), context)
        case .required: check = .required(.import(pattern))
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
