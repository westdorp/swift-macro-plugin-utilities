import SwiftSyntax

enum CodeTokens {
    static func starts(in syntax: some SyntaxProtocol, matching tokens: [CodeToken]) -> [TokenSyntax] {
        starts(in: runs(in: syntax), matching: tokens)
    }

    static func runs(in syntax: some SyntaxProtocol) -> [[TokenSyntax]] {
        let visitor = CodeTokenVisitor(viewMode: .sourceAccurate)
        visitor.walk(syntax)
        return visitor.runs
    }

    static func starts(in runs: [[TokenSyntax]], matching tokens: [CodeToken]) -> [TokenSyntax] {
        let pattern = tokens.map(\.text)
        var starts: [TokenSyntax] = []
        for run in runs where run.count >= pattern.count {
            for start in 0...(run.count - pattern.count) {
                let window = run[start..<(start + pattern.count)]
                if window.map(\.guardrailText) == pattern { starts.append(run[start]) }
            }
        }
        return starts
    }
}

private final class CodeTokenVisitor: SyntaxVisitor {
    private(set) var runs: [[TokenSyntax]] = [[]]

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        for clause in node.clauses {
            if let condition = clause.condition {
                let surroundingRun = runs.removeLast()
                runs.append([])
                walk(condition)
                runs.append(surroundingRun)
            }
            if let elements = clause.elements { walk(elements) }
        }
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if token.tokenKind != .endOfFile { runs[runs.count - 1].append(token) }
        return .skipChildren
    }

    override func visit(_ node: RegexLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        runs.append([])
        return .skipChildren
    }

    override func visit(_ node: SimpleStringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        runs.append([])
        return .skipChildren
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        runs.append([])
        for segment in node.segments {
            if let interpolation = segment.as(ExpressionSegmentSyntax.self) {
                walk(interpolation.expressions)
                runs.append([])
            }
        }
        return .skipChildren
    }
}
