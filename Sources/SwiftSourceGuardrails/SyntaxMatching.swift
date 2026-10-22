import SwiftParser
import SwiftSyntax

extension RuleMatcher {
    static func positions(in tree: SourceFileSyntax, matchers: [Self]) -> [[AbsolutePosition]] {
        let visitor = RuleMatchVisitor(matchers: matchers)
        visitor.walk(tree)
        let needsTokens = matchers.contains {
            if case .occurrences(.tokens, _) = $0.check { return true }
            return false
        }
        let runs = needsTokens ? CodeTokens.runs(in: tree) : []
        return matchers.enumerated().map { index, matcher in
            if let condition = matcher.condition, !condition.imports.matches(visitor.imports) { return [] }
            switch matcher.check {
            case .occurrences(let occurrence, let context):
                let tokens: [TokenSyntax]
                if case .tokens(let pattern) = occurrence { tokens = CodeTokens.starts(in: runs, matching: pattern) }
                else { tokens = visitor.tokens[index] }
                return tokens.filter { context?.allows($0) ?? true }.map(\.positionAfterSkippingLeadingTrivia)
            case .required:
                return visitor.tokens[index].isEmpty ? [AbsolutePosition(utf8Offset: 0)] : []
            }
        }
    }
}

private extension OccurrenceMatcher {
    func match(_ syntax: Syntax) -> TokenSyntax? {
        switch self {
        case .tokens: return nil
        case .identifier(let pattern, let target):
            let token: TokenSyntax?
            switch target {
            case .token: token = syntax.as(TokenSyntax.self)
            case .function: token = syntax.as(FunctionDeclSyntax.self)?.name
            }
            return token.flatMap { pattern.matches($0) ? $0 : nil }
        case .call(let name):
            guard let call = syntax.as(FunctionCallExprSyntax.self), name.matches(call.calledExpression) else { return nil }
            return call.calledExpression.firstToken(viewMode: .sourceAccurate)
        case .member(let name):
            guard let member = syntax.as(MemberAccessExprSyntax.self), name.matches(ExprSyntax(member)) else { return nil }
            return member.firstToken(viewMode: .sourceAccurate)
        case .argument(let name, let selection, let validation):
            guard let call = syntax.as(FunctionCallExprSyntax.self), name.matches(call.calledExpression) else { return nil }
            if let argument = selection.argument(in: call), validation.accepts(argument) { return nil }
            return call.calledExpression.firstToken(viewMode: .sourceAccurate)
        case .import(let pattern):
            return pattern.match(syntax)
        case .stringLiteral(let pattern):
            return syntax.as(StringLiteralExprSyntax.self).flatMap { pattern.match($0) }
        }
    }
}

private extension StringContentPattern {
    func match(_ literal: StringLiteralExprSyntax) -> TokenSyntax? {
        var hasEarlierReason = false
        for segments in literal.guardrailLiteralGroups {
            let value = segments.map(\.value).joined()
            let offsets: [Int]
            switch content {
            case .text(let text): offsets = value == text ? [0] : []
            case .tokens(let tokens):
                offsets = CodeTokens.starts(in: Parser.parse(source: value), matching: tokens)
                    .map { $0.positionAfterSkippingLeadingTrivia.utf8Offset }.sorted()
            }
            for offset in offsets {
                let prefix = String(decoding: value.utf8.prefix(offset), as: UTF8.self)
                if reasonMarkers.isEmpty || (!hasEarlierReason && !reasonMarkers.contains(where: prefix.contains)) {
                    var remaining = offset
                    for segment in segments {
                        if remaining < segment.value.utf8.count { return segment.token }
                        remaining -= segment.value.utf8.count
                    }
                }
            }
            hasEarlierReason = hasEarlierReason || reasonMarkers.contains(where: value.contains)
        }
        return nil
    }
}

private struct LiteralSegment {
    let value: String
    let token: TokenSyntax
}

private extension StringLiteralExprSyntax {
    var guardrailLiteralGroups: [[LiteralSegment]] {
        var groups: [[LiteralSegment]] = [[]]
        for segment in segments {
            switch segment {
            case .stringSegment(let text):
                var literal = self
                literal.segments = StringLiteralSegmentListSyntax([segment])
                // SwiftParser decodes complete segments from the already validated literal.
                groups[groups.count - 1].append(LiteralSegment(value: literal.representedLiteralValue!, token: text.content))
            case .expressionSegment: groups.append([])
            }
        }
        return groups.filter { !$0.isEmpty }
    }
}

private extension FileRequirement {
    func match(_ syntax: Syntax) -> TokenSyntax? {
        switch self {
        case .attribute(let name):
            guard let attribute = syntax.as(AttributeSyntax.self),
                SyntaxName.components(of: attribute.attributeName) == name.components
            else { return nil }
            return attribute.atSign
        case .import(let pattern):
            return pattern.match(syntax)
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
        if expression.is(SuperExprSyntax.self) { return ["super"] }
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

private extension ArgumentSelection {
    func argument(in call: FunctionCallExprSyntax) -> ExprSyntax? {
        switch self {
        case .named(let label):
            let arguments = call.arguments.filter { $0.label?.guardrailText == label.text }.map(\.expression)
                + call.additionalTrailingClosures.filter { $0.label.guardrailText == label.text }.map { ExprSyntax($0.closure) }
            return arguments.count == 1 ? arguments.first : nil
        case .position(let position):
            guard let argument = call.arguments.dropFirst(position).first, argument.label == nil else { return nil }
            return argument.expression
        }
    }
}

private extension ArgumentValidation {
    func accepts(_ expression: ExprSyntax) -> Bool {
        switch self {
        case .literal(let validation): return validation.accepts(expression)
        case .call(let name, let validation):
            guard let call = expression.as(FunctionCallExprSyntax.self), name.matches(call.calledExpression),
                call.arguments.count == 1, let argument = call.arguments.first,
                argument.label == nil, call.trailingClosure == nil
            else { return false }
            return validation.accepts(argument.expression)
        }
    }
}

private extension LiteralArgumentValidation {
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
        var child = Syntax(token)
        var isInside = false
        while let node = child.parent {
            let candidate: String?
            switch kind {
            case .function:
                let declaration = node.as(FunctionDeclSyntax.self)
                candidate = declaration?.body?.id == child.id ? declaration?.name.guardrailText : nil
            case .type:
                if let declaration = node.as(StructDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ClassDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ActorDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(EnumDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ProtocolDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = declaration.name.guardrailText }
                else if let declaration = node.as(ExtensionDeclSyntax.self), declaration.memberBlock.id == child.id { candidate = SyntaxName.components(of: declaration.extendedType)?.last }
                else { candidate = nil }
            }
            if candidate == name.text { isInside = true; break }
            child = node
        }
        switch relation {
        case .inside: return isInside
        case .outside: return !isInside
        }
    }
}

private final class RuleMatchVisitor: SyntaxAnyVisitor {
    let matchers: [RuleMatcher]
    private(set) var tokens: [[TokenSyntax]]
    private(set) var imports: Set<String> = []

    init(matchers: [RuleMatcher]) {
        self.matchers = matchers
        tokens = Array(repeating: [], count: matchers.count)
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let declaration = node.as(ImportDeclSyntax.self), let module = declaration.path.first?.name {
            imports.insert(module.guardrailText)
        }
        for (index, matcher) in matchers.enumerated() {
            let token: TokenSyntax?
            switch matcher.check {
            case .occurrences(let occurrence, _): token = occurrence.match(node)
            case .required(let requirement): token = requirement.match(node)
            }
            if let token { tokens[index].append(token) }
        }
        return .visitChildren
    }
}
