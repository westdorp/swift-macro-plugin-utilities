import SwiftSyntax

extension RuleMatcher {
    func positions(in tree: SourceFileSyntax) -> [AbsolutePosition] {
        switch self {
        case .tokens(let tokens):
            return CodeTokens.starts(in: tree, matching: tokens).map(\.positionAfterSkippingLeadingTrivia)
        case .identifier(let pattern, let target):
            return SyntaxMatches.positions(in: tree) { syntax in
                let token: TokenSyntax?
                switch target {
                case .token: token = syntax.as(TokenSyntax.self)
                case .function: token = syntax.as(FunctionDeclSyntax.self)?.name
                }
                return token.flatMap { pattern.matches($0) ? $0 : nil }
            }
        }
    }
}

private final class SyntaxMatches: SyntaxAnyVisitor {
    let match: (Syntax) -> TokenSyntax?
    var positions: [AbsolutePosition] = []

    private init(match: @escaping (Syntax) -> TokenSyntax?) {
        self.match = match
        super.init(viewMode: .sourceAccurate)
    }

    static func positions(in tree: SourceFileSyntax, match: @escaping (Syntax) -> TokenSyntax?) -> [AbsolutePosition] {
        let visitor = SyntaxMatches(match: match)
        visitor.walk(tree)
        return visitor.positions
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let token = match(node) { positions.append(token.positionAfterSkippingLeadingTrivia) }
        return .visitChildren
    }
}
