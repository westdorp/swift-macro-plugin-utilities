import SwiftParser
import SwiftSyntax

extension RuleMatcher {
    func positions(in tree: SourceFileSyntax) -> [AbsolutePosition] {
        if let condition, !condition.holds(in: tree) { return [] }
        switch check {
        case .occurrences(let matcher, let context):
            return matcher.matchingTokens(in: tree)
                .filter { context?.allows($0) ?? true }
                .map(\.positionAfterSkippingLeadingTrivia)
        case .required(let requirement):
            return requirement.isPresent(in: tree) ? [] : [AbsolutePosition(utf8Offset: 0)]
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
        case .import(let pattern):
            return SyntaxMatches.tokens(in: tree, match: pattern.match)
        case .stringLiteral(let pattern):
            return SyntaxMatches.tokens(in: tree) { syntax in
                guard let literal = syntax.as(StringLiteralExprSyntax.self),
                    literal.guardrailLiteralGroups.contains(where: pattern.matches)
                else { return nil }
                return literal.openingPounds ?? literal.openingQuote
            }
        }
    }
}

private extension StringContentPattern {
    func matches(_ value: String) -> Bool {
        switch self {
        case .text(let text): return value == text
        case .tokens(let tokens): return !CodeTokens.starts(in: Parser.parse(source: value), matching: tokens).isEmpty
        }
    }
}

private extension StringLiteralExprSyntax {
    var guardrailLiteralGroups: [String] {
        var groups: [[StringLiteralSegmentListSyntax.Element]] = [[]]
        for segment in segments {
            switch segment {
            case .stringSegment: groups[groups.count - 1].append(segment)
            case .expressionSegment: groups.append([])
            }
        }
        return groups.filter { !$0.isEmpty }.map { segments in
            var literal = self
            literal.segments = StringLiteralSegmentListSyntax(segments)
            // SwiftParser provides a value for validated literals without interpolation.
            return literal.representedLiteralValue!
        }
    }
}

private extension FileCondition {
    func holds(in tree: SourceFileSyntax) -> Bool {
        !SyntaxMatches.tokens(in: tree, match: { syntax in
            guard let declaration = syntax.as(ImportDeclSyntax.self),
                let module = declaration.path.first?.name, module.guardrailText == imports.text
            else { return nil }
            return module
        }).isEmpty
    }
}

private extension FileRequirement {
    func isPresent(in tree: SourceFileSyntax) -> Bool {
        switch self {
        case .attribute(let name):
            return !SyntaxMatches.tokens(in: tree, match: { syntax in
                guard let attribute = syntax.as(AttributeSyntax.self),
                    SyntaxName.components(of: attribute.attributeName) == name.components
                else { return nil }
                return attribute.atSign
            }).isEmpty
        case .import(let pattern):
            return !SyntaxMatches.tokens(in: tree, match: pattern.match).isEmpty
        }
    }
}

private extension ImportPattern {
    func match(_ syntax: Syntax) -> TokenSyntax? {
        switch self {
        case .declaration(let selection, let kind):
            return Self.declaration(syntax, selection: selection, kind: kind)
        case .canImport(let selection):
            return Self.condition(syntax, selection: selection)
        case .either(let selection):
            return Self.declaration(syntax, selection: selection, kind: .any) ?? Self.condition(syntax, selection: selection)
        }
    }

    static func declaration(_ syntax: Syntax, selection: ModuleSelection, kind: ImportKind) -> TokenSyntax? {
        guard let declaration = syntax.as(ImportDeclSyntax.self),
            let module = declaration.path.first?.name, selection.matches(module), kind.matches(declaration)
        else { return nil }
        return declaration.firstToken(viewMode: .sourceAccurate)
    }

    static func condition(_ syntax: Syntax, selection: ModuleSelection) -> TokenSyntax? {
        guard let call = syntax.as(FunctionCallExprSyntax.self),
            let reference = call.calledExpression.as(DeclReferenceExprSyntax.self), reference.baseName.guardrailText == "canImport",
            let argument = call.arguments.first,
            let module = firstModule(in: argument.expression), selection.matches(module), isCompilationCondition(syntax)
        else { return nil }
        return reference.baseName
    }

    static func firstModule(in expression: ExprSyntax) -> TokenSyntax? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base { return firstModule(in: base) }
        return nil
    }

    static func isCompilationCondition(_ syntax: Syntax) -> Bool {
        var child = syntax
        while let parent = child.parent {
            if let clause = parent.as(IfConfigClauseSyntax.self) { return clause.condition?.id == child.id }
            child = parent
        }
        return false
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
