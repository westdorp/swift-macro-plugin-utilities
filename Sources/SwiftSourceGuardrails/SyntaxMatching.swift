import SwiftParser
import SwiftSyntax

extension RuleMatcher {
    func positions(in tree: SourceFileSyntax) -> [AbsolutePosition] {
        switch self {
        case .occurrences(let matcher, let context):
            return matcher.matchingTokens(in: tree)
                .filter { context?.allows($0) ?? true }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    }
}

private extension OccurrenceMatcher {
    func matchingTokens(in tree: SourceFileSyntax) -> [TokenSyntax] {
        switch self {
        case .tokens(let tokens):
            return CodeTokens.starts(in: tree, matching: tokens)
        case .identifier(let pattern, let target):
            return SyntaxMatches.tokens(in: tree) { syntax in
                let token: TokenSyntax?
                switch target {
                case .token: token = syntax.as(TokenSyntax.self)
                case .function: token = syntax.as(FunctionDeclSyntax.self)?.name
                }
                return token.flatMap { pattern.matches($0) ? $0 : nil }
            }
        case .call(let name):
            return SyntaxMatches.tokens(in: tree) { syntax in
                guard let call = syntax.as(FunctionCallExprSyntax.self), name.matches(call.calledExpression) else { return nil }
                return call.calledExpression.firstToken(viewMode: .sourceAccurate)
            }
        case .member(let name):
            return SyntaxMatches.tokens(in: tree) { syntax in
                guard let member = syntax.as(MemberAccessExprSyntax.self), name.matches(ExprSyntax(member)) else { return nil }
                return member.firstToken(viewMode: .sourceAccurate)
            }
        case .argument(let name, let label, let validation):
            return SyntaxMatches.tokens(in: tree) { syntax in
                guard let call = syntax.as(FunctionCallExprSyntax.self), name.matches(call.calledExpression) else { return nil }
                let arguments = call.arguments.filter { $0.label?.guardrailText == label.text }
                if arguments.count == 1, let argument = arguments.first, validation.accepts(argument.expression) { return nil }
                return call.calledExpression.firstToken(viewMode: .sourceAccurate)
            }
        }
    }
}

extension SyntaxName {
    func matches(_ expression: ExprSyntax) -> Bool { Self.components(of: expression) == components }

    static func components(of expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return [reference.baseName.guardrailText] }
        if let generic = expression.as(GenericSpecializationExprSyntax.self) { return components(of: generic.expression) }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return [member.declName.baseName.guardrailText] }
            return components(of: base).map { $0 + [member.declName.baseName.guardrailText] }
        }
        return nil
    }

    static func components(of type: TypeSyntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return [identifier.name.guardrailText] }
        if let member = type.as(MemberTypeSyntax.self) {
            return components(of: member.baseType).map { $0 + [member.name.guardrailText] }
        }
        return nil
    }
}

private extension ArgumentValidation {
    func accepts(_ expression: ExprSyntax) -> Bool {
        switch self {
        case .positiveIntegerLiteral:
            guard let value = expression.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue else { return false }
            return value > 0
        case .nonemptyStringLiteral:
            guard let value = expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension LexicalContext {
    func allows(_ token: TokenSyntax) -> Bool {
        var ancestor = token.parent
        var isInside = false
        while let node = ancestor {
            let candidate: String?
            switch kind {
            case .function: candidate = node.as(FunctionDeclSyntax.self)?.name.guardrailText
            case .type:
                if let declaration = node.as(StructDeclSyntax.self) { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ClassDeclSyntax.self) { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ActorDeclSyntax.self) { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(EnumDeclSyntax.self) { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ProtocolDeclSyntax.self) { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ExtensionDeclSyntax.self) { candidate = SyntaxName.components(of: declaration.extendedType)?.last }
                else { candidate = nil }
            }
            if candidate == name.text { isInside = true; break }
            ancestor = node.parent
        }
        switch relation {
        case .inside: return isInside
        case .outside: return !isInside
        }
    }
}

private final class SyntaxMatches: SyntaxAnyVisitor {
    let match: (Syntax) -> TokenSyntax?
    var tokens: [TokenSyntax] = []

    private init(match: @escaping (Syntax) -> TokenSyntax?) {
        self.match = match
        super.init(viewMode: .sourceAccurate)
    }

    static func tokens(in tree: SourceFileSyntax, match: @escaping (Syntax) -> TokenSyntax?) -> [TokenSyntax] {
        let visitor = SyntaxMatches(match: match)
        visitor.walk(tree)
        return visitor.tokens
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let token = match(node) { tokens.append(token) }
        return .visitChildren
    }
}
